#!/usr/bin/env bash
set -euo pipefail
# Shared helpers, sourced by every other script. Not meant to be run directly.

# The repo root is the parent of this file's directory, wherever we are called from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
# Where run.sh records the MicroVM it launched: {"microvmId","endpoint"}.
MICROVM_FILE="$BUILD_DIR/microvm.json"

# Load tunables, then local overrides (.env holds EXPECTED_ACCOUNT_ID, AWS_PROFILE).
# set -a exports everything so child processes (aws) see AWS_PROFILE.
set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/config.env"
if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.env"
fi
set +a

# Honor an AWS_REGION already in the environment; otherwise use config.env.
export AWS_REGION="${AWS_REGION:-$REGION}"

# Two stacks: bootstrap (bucket, roles, logs) changes rarely; image changes per app build.
BOOTSTRAP_STACK="${STACK_PREFIX}-bootstrap"
IMAGE_STACK="${STACK_PREFIX}-image"

# log: one progress line on stderr, so stdout stays machine-readable JSON.
log() {
  printf '[%s] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >&2
}

# die: log the error and stop the script.
die() {
  log "$@"
  exit 1
}

# require_cmd: fail early, naming the first prerequisite missing from PATH.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# assert_sandbox: refuse to touch any account but the one the operator named.
# Must run before the first aws call. Also exports AWS_PARTITION for ARN building.
assert_sandbox() {
  if [ -z "${EXPECTED_ACCOUNT_ID:-}" ]; then
    die "EXPECTED_ACCOUNT_ID is not set. Put it in .env or export it in your shell."
  fi
  local identity actual arn
  identity="$(aws sts get-caller-identity --output json)"
  actual="$(jq -r '.Account' <<<"$identity")"
  arn="$(jq -r '.Arn' <<<"$identity")"
  if [ "$actual" != "$EXPECTED_ACCOUNT_ID" ]; then
    die "wrong account: credentials are for $actual but EXPECTED_ACCOUNT_ID is $EXPECTED_ACCOUNT_ID"
  fi
  AWS_PARTITION="$(cut -d: -f2 <<<"$arn")"
  export AWS_PARTITION
}

# stack_output: print one CloudFormation output value, or an empty string if the
# key is missing. Returns non-zero when the stack does not exist.
stack_output() {
  local stack="$1" key="$2" value
  value="$(aws cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue | [0]" --output text)" || return 1
  if [ "$value" = "None" ]; then value=""; fi
  printf '%s\n' "$value"
}

# managed_connector_arn: ARN of an AWS-managed network connector (egress/ingress
# paths a MicroVM may use), e.g. INTERNET_EGRESS.
managed_connector_arn() {
  printf 'arn:%s:lambda:%s:aws:network-connector:aws-network-connector:%s\n' \
    "$AWS_PARTITION" "$AWS_REGION" "$1"
}

# base_image_arn: ARN of the managed al2023 base image that our image builds FROM.
base_image_arn() {
  printf 'arn:%s:lambda:%s:aws:microvm-image:al2023-1\n' "$AWS_PARTITION" "$AWS_REGION"
}
