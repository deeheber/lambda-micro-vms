#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# run.sh: launch one MicroVM from the image's latest active version and record
# it in .build/microvm.json. Prints {"microvmId","endpoint"} on stdout.

assert_sandbox
require_cmd aws jq

# Which image version to run: normally a stack output, with a service lookup as
# a fallback.
image_arn="$(stack_output "$IMAGE_STACK" ImageArn)"
[ -n "$image_arn" ] || die "no ImageArn in stack $IMAGE_STACK; run 'make deploy' first"
image_version="$(stack_output "$IMAGE_STACK" LatestActiveImageVersion)"
if [ -z "$image_version" ]; then
  log "stack output LatestActiveImageVersion is empty; asking the service instead"
  image_version="$(aws lambda-microvms get-microvm-image --image-identifier "$image_arn" --output json \
    | jq -r '.latestActiveImageVersion // ""')"
fi
[ -n "$image_version" ] || die "no active image version for $image_arn"

# Identity and logging come from the bootstrap stack.
execution_role_arn="$(stack_output "$BOOTSTRAP_STACK" ExecutionRoleArn)"
log_group="$(stack_output "$BOOTSTRAP_STACK" LogGroupName)"
[ -n "$execution_role_arn" ] || die "no ExecutionRoleArn in stack $BOOTSTRAP_STACK"
[ -n "$log_group" ] || die "no LogGroupName in stack $BOOTSTRAP_STACK"

# Concept: the idle policy. With no inbound traffic for IDLE_MAX_SECONDS the
# platform suspends the MicroVM (memory kept, compute billing stops); a request
# resumes it when auto-resume is on; a MicroVM suspended for SUSPENDED_SECONDS
# is terminated. Together with MAX_DURATION_SECONDS this also bounds a MicroVM
# whose ID we failed to record; destroy.sh terminates those anyway.
idle_policy="$(jq -cn \
  --argjson idle "$IDLE_MAX_SECONDS" \
  --argjson suspended "$SUSPENDED_SECONDS" \
  --argjson auto "$AUTO_RESUME" \
  '{maxIdleDurationSeconds: $idle, suspendedDurationSeconds: $suspended, autoResumeEnabled: $auto}')"
logging="$(jq -cn --arg group "$log_group" '{cloudWatch: {logGroup: $group}}')"

# Concept: network connectors. Egress is explicit (outbound internet). Ingress
# is left to the service default unless INGRESS_CONNECTOR says otherwise.
ingress_args=()
case "$INGRESS_CONNECTOR" in
  "") ;;
  HTTP_INGRESS) ingress_args=(--ingress-network-connectors "$(managed_connector_arn HTTP_INGRESS)") ;;
  *) die "INGRESS_CONNECTOR must be empty or HTTP_INGRESS, got: $INGRESS_CONNECTOR" ;;
esac

log "launching a MicroVM from $image_arn version $image_version"
response="$(aws lambda-microvms run-microvm \
  --image-identifier "$image_arn" \
  --image-version "$image_version" \
  --execution-role-arn "$execution_role_arn" \
  --idle-policy "$idle_policy" \
  --maximum-duration-in-seconds "$MAX_DURATION_SECONDS" \
  --logging "$logging" \
  --egress-network-connectors "$(managed_connector_arn INTERNET_EGRESS)" \
  ${ingress_args[@]+"${ingress_args[@]}"} \
  --output json)"

mkdir -p "$BUILD_DIR"
if [ -f "$MICROVM_FILE" ]; then
  log "warning: overwriting $MICROVM_FILE (old microvmId $(jq -r '.microvmId' "$MICROVM_FILE")); 'make destroy' terminates it if still running"
fi
# Endpoints come back without a scheme; other scripts prepend https://.
record="$(jq -c '{microvmId: .microvmId, endpoint: .endpoint}' <<<"$response")"
printf '%s\n' "$record" >"$MICROVM_FILE"
printf '%s\n' "$record"
