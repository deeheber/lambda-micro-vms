#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# smoke.sh: end-to-end check of the MicroVM lifecycle:
#   run -> call -> suspend -> resume -> call -> terminate
# stdout carries only JSON lines; progress goes to stderr. Exit 0 only if every
# assertion passed.

assert_sandbox
require_cmd aws jq curl

# Concept: always tear down. Whatever happens below, the MicroVM is terminated
# on exit. microvm.sh terminate is harmless when nothing was launched.
trap '"$SCRIPT_DIR/microvm.sh" terminate >/dev/null || true' EXIT

step=1

# fail: report which step broke and why, then exit non-zero (the trap runs).
fail() {
  jq -cn --argjson step "$step" --arg reason "$*" '{ok: false, step: $step, reason: $reason}'
  log "FAILED at step $step: $*"
  exit 1
}

# call_with_retry <wait seconds>: call the app until it answers or the wait
# ends. Sets CALL_BODY. Connecting is the readiness test, because get-microvm
# state is eventually consistent and can lag the real state.
call_with_retry() {
  local wait_seconds="$1" deadline
  deadline=$((SECONDS + wait_seconds))
  while true; do
    if CALL_BODY="$("$SCRIPT_DIR/call.sh" / 2>/dev/null)"; then
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

# --- Step 1: launch ----------------------------------------------------------
# Concept: a MicroVM starts from an image's snapshot; its run hook then fires.
log "step 1: run"
"$SCRIPT_DIR/run.sh" >/dev/null || fail "run.sh failed"
microvm_id="$(jq -r '.microvmId' "$MICROVM_FILE")"

# --- Step 2: first call ------------------------------------------------------
# Concept: the proxy. The run hook has set instanceId and microvmId by the time
# the app answers.
step=2
log "step 2: first call"
call_with_retry "$CALL_READY_TIMEOUT_SECONDS" || fail "app did not answer within CALL_READY_TIMEOUT_SECONDS"
instance_before="$(jq -r '.instanceId // empty' <<<"$CALL_BODY")"
reported_id="$(jq -r '.microvmId // empty' <<<"$CALL_BODY")"
count_before="$(jq -r '.requestCount // empty' <<<"$CALL_BODY")"
[ -n "$instance_before" ] || fail "instanceId is null: the run hook did not set it"
[ -n "$reported_id" ] || fail "microvmId is null: the run hook did not receive it"
[ -n "$count_before" ] || fail "response has no requestCount"

# --- Step 3: suspend ---------------------------------------------------------
# Concept: suspend keeps memory and disk and stops compute billing.
step=3
log "step 3: suspend"
"$SCRIPT_DIR/microvm.sh" suspend >/dev/null || fail "suspend failed"
deadline=$((SECONDS + RESUME_WAIT_SECONDS * 2))
while true; do
  state="$("$SCRIPT_DIR/microvm.sh" status | jq -r '.state')"
  [ "$state" != "SUSPENDED" ] || break
  [ "$SECONDS" -lt "$deadline" ] || fail "never reached SUSPENDED (last state: $state)"
  sleep "$POLL_INTERVAL_SECONDS"
done

# --- Step 4: resume ----------------------------------------------------------
# Concept: auto-resume. A request to a suspended MicroVM should wake it. If it
# does not, resume explicitly. Which path worked is an answer worth recording.
step=4
log "step 4: call the suspended MicroVM (expecting auto-resume)"
if call_with_retry "$RESUME_WAIT_SECONDS"; then
  resume_path="auto"
else
  log "no auto-resume; resuming explicitly"
  "$SCRIPT_DIR/microvm.sh" resume >/dev/null || fail "resume failed"
  call_with_retry "$CALL_READY_TIMEOUT_SECONDS" || fail "app did not answer after explicit resume"
  resume_path="explicit"
fi
jq -cn --arg path "$resume_path" '{resumePath: $path}'

# --- Step 5: memory survived -------------------------------------------------
# A fresh MicroVM would have a new instanceId and requestCount 1. Same
# instanceId and a larger count prove the memory came back. Not "exactly +1":
# a request delivered during resume whose response was lost still counts.
step=5
instance_after="$(jq -r '.instanceId // empty' <<<"$CALL_BODY")"
count_after="$(jq -r '.requestCount // empty' <<<"$CALL_BODY")"
[ "$instance_after" = "$instance_before" ] || fail "instanceId changed ($instance_before -> $instance_after): memory did not survive"
[ -n "$count_after" ] && [ "$count_after" -gt "$count_before" ] || fail "requestCount did not grow ($count_before -> $count_after)"

# --- Step 6: terminate -------------------------------------------------------
step=6
log "step 6: terminate"
"$SCRIPT_DIR/microvm.sh" terminate >/dev/null || fail "terminate failed"

# --- Step 7: summary ---------------------------------------------------------
jq -cn \
  --arg microvmId "$microvm_id" \
  --arg instanceId "$instance_after" \
  --argjson before "$count_before" \
  --argjson after "$count_after" \
  --arg resumePath "$resume_path" \
  '{ok: true, microvmId: $microvmId, instanceId: $instanceId,
    requestCountBefore: $before, requestCountAfter: $after, resumePath: $resumePath}'
