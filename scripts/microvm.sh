#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# microvm.sh <status|suspend|resume|terminate>: lifecycle control for the
# MicroVM recorded in .build/microvm.json.
#
# Concept: the lifecycle. A MicroVM moves
#   PENDING -> RUNNING <-> SUSPENDING -> SUSPENDED -> TERMINATING -> TERMINATED
# Suspend keeps memory and disk (so resume continues where it stopped) and stops
# compute billing. get-microvm state is eventually consistent: it can lag the
# action you just took, so callers poll.

action="${1:-}"
case "$action" in
  status | suspend | resume | terminate) [ "$#" -eq 1 ] || die "usage: microvm.sh <status|suspend|resume|terminate>" ;;
  *) die "usage: microvm.sh <status|suspend|resume|terminate>" ;;
esac

# terminate must be harmless when nothing was ever launched: smoke.sh's EXIT
# trap can run before run.sh wrote the file.
if [ ! -f "$MICROVM_FILE" ]; then
  if [ "$action" = "terminate" ]; then
    log "nothing to terminate (no $MICROVM_FILE)"
    exit 0
  fi
  die "no $MICROVM_FILE; run 'make run' first"
fi

require_cmd aws jq
assert_sandbox
microvm_id="$(jq -r '.microvmId' "$MICROVM_FILE")"

# is_not_found: true when an aws error text means the MicroVM no longer exists.
is_not_found() {
  grep -Eiq 'ResourceNotFound|not found' <<<"$1"
}

case "$action" in
  status)
    # Capture first so an aws failure stops the script (set -e does not see
    # failures inside a process substitution).
    state_json="$(aws lambda-microvms get-microvm --microvm-identifier "$microvm_id" --output json)"
    jq -c '{microvmId: .microvmId, state: .state}' <<<"$state_json"
    ;;
  suspend | resume)
    aws lambda-microvms "${action}-microvm" --microvm-identifier "$microvm_id" >/dev/null
    jq -cn --arg id "$microvm_id" --arg action "$action" '{microvmId: $id, action: $action}'
    ;;
  terminate)
    # Every "already gone" shape is success: teardown must be re-runnable.
    already_gone() {
      jq -cn --arg id "$microvm_id" '{microvmId: $id, action: "terminate", result: "already-gone"}'
    }
    err_file="$(mktemp)"
    trap 'rm -f "$err_file"' EXIT
    if state_json="$(aws lambda-microvms get-microvm --microvm-identifier "$microvm_id" --output json 2>"$err_file")"; then
      case "$(jq -r '.state' <<<"$state_json")" in
        TERMINATING | TERMINATED)
          already_gone
          exit 0
          ;;
      esac
    else
      if is_not_found "$(cat "$err_file")"; then
        already_gone
        exit 0
      fi
      cat "$err_file" >&2
      die "get-microvm failed for $microvm_id"
    fi
    if aws lambda-microvms terminate-microvm --microvm-identifier "$microvm_id" >/dev/null 2>"$err_file"; then
      jq -cn --arg id "$microvm_id" '{microvmId: $id, action: "terminate", result: "terminated"}'
    else
      if is_not_found "$(cat "$err_file")"; then
        already_gone
        exit 0
      fi
      cat "$err_file" >&2
      die "terminate-microvm failed for $microvm_id"
    fi
    ;;
esac
