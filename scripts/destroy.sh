#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# destroy.sh: ordered teardown. Every step tolerates "already gone", so it is
# safe to run after a partial deploy or a failed smoke test, and to run twice.
#
# Order matters: MicroVMs first (they use the image), then the image stack,
# then the bucket contents (CloudFormation cannot delete a non-empty bucket),
# then the bootstrap stack (which also deletes the log group).

assert_sandbox
require_cmd aws jq

terminated_ids='[]'
image_stack_result="absent"
bucket_emptied=false
bootstrap_result="absent"

# stack_exists: true when CloudFormation still knows the stack.
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

# delete_stack: delete and wait. Both calls succeed when the stack is absent.
delete_stack() {
  local stack="$1" status
  aws cloudformation delete-stack --stack-name "$stack"
  if ! aws cloudformation wait stack-delete-complete --stack-name "$stack"; then
    status="$(aws cloudformation describe-stacks --stack-name "$stack" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
    die "stack $stack did not delete (status: ${status:-unknown})"
  fi
}

# --- Step 1: MicroVMs --------------------------------------------------------
# Concept: always tear down. First the one run.sh recorded (a no-op when there
# is no file or it is gone)...
log "step 1: terminating MicroVMs"
"$SCRIPT_DIR/microvm.sh" terminate >/dev/null

# ...then every MicroVM launched from this repo's image. list-microvms finds
# them even when run.sh died before recording one, and ignores MicroVMs from
# other images.
if image_arn="$(stack_output "$IMAGE_STACK" ImageArn 2>/dev/null)" && [ -n "$image_arn" ]; then
  live_ids="$(aws lambda-microvms list-microvms --image-identifier "$image_arn" --output json \
    | jq -r '.items[]? | select(.state != "TERMINATING" and .state != "TERMINATED") | .microvmId')"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    log "terminating $id"
    err="$(aws lambda-microvms terminate-microvm --microvm-identifier "$id" 2>&1 >/dev/null)" || {
      grep -Eiq 'ResourceNotFound|not found' <<<"$err" || die "terminate-microvm failed for $id: $err"
    }
    terminated_ids="$(jq -c --arg id "$id" '. + [$id]' <<<"$terminated_ids")"
  done <<<"$live_ids"

  # Wait for termination to finish; a slow one is a warning, not a failure.
  deadline=$((SECONDS + TERMINATE_WAIT_SECONDS))
  while true; do
    remaining="$(aws lambda-microvms list-microvms --image-identifier "$image_arn" --output json \
      | jq '[.items[]? | select(.state != "TERMINATED")] | length')"
    [ "$remaining" -gt 0 ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "warning: $remaining MicroVM(s) not yet TERMINATED after TERMINATE_WAIT_SECONDS; continuing"
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
fi
rm -f "$MICROVM_FILE"

# --- Step 2: image stack -----------------------------------------------------
log "step 2: deleting $IMAGE_STACK"
if stack_exists "$IMAGE_STACK"; then image_stack_result="deleted"; fi
delete_stack "$IMAGE_STACK"

# --- Step 3: empty the artifact bucket ---------------------------------------
log "step 3: emptying the artifact bucket"
if bucket="$(stack_output "$BOOTSTRAP_STACK" ArtifactBucketName 2>/dev/null)" && [ -n "$bucket" ]; then
  if aws s3 rm "s3://${bucket}" --recursive --only-show-errors >&2; then
    bucket_emptied=true
  else
    log "bucket $bucket could not be emptied (already gone?); continuing"
  fi
fi

# --- Step 4: bootstrap stack -------------------------------------------------
# Deleting it also removes the roles and the log group.
log "step 4: deleting $BOOTSTRAP_STACK"
if stack_exists "$BOOTSTRAP_STACK"; then bootstrap_result="deleted"; fi
delete_stack "$BOOTSTRAP_STACK"

jq -cn \
  --argjson terminated "$terminated_ids" \
  --arg imageStack "$image_stack_result" \
  --argjson bucketEmptied "$bucket_emptied" \
  --arg bootstrapStack "$bootstrap_result" \
  '{terminated: $terminated, imageStack: $imageStack, bucketEmptied: $bucketEmptied, bootstrapStack: $bootstrapStack}'
