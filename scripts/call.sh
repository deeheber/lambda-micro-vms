#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# call.sh [path]: make one HTTPS request to the MicroVM recorded by run.sh and
# print the response body. Usage: call.sh [/path]

path="${1:-/}"
case "$path" in
  /*) ;;
  *) die "path must start with /, got: $path" ;;
esac
[ -f "$MICROVM_FILE" ] || die "no $MICROVM_FILE; run 'make run' first"
require_cmd aws jq curl
assert_sandbox

microvm_id="$(jq -r '.microvmId' "$MICROVM_FILE")"
endpoint="$(jq -r '.endpoint' "$MICROVM_FILE")"

# Concept: auth. Every request through the MicroVM proxy carries a short-lived
# token scoped to this MicroVM and to specific ports.
TOKEN="$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "$microvm_id" \
  --allowed-ports "$(jq -cn --argjson p "$APP_PORT" '[{port: $p}]')" \
  --expiration-in-minutes "$TOKEN_TTL_MINUTES" \
  --query 'authToken."X-aws-proxy-auth"' --output text)"

# The headers travel on stdin (curl -H @-) because command-line arguments are
# visible to every user via ps. X-aws-proxy-port routes the request to APP_PORT
# when it is not the proxy default; the token's allowed-ports only authorizes.
# The endpoint has no scheme, so we add https://. The body goes to stdout.
printf 'X-aws-proxy-auth: %s\nX-aws-proxy-port: %s\n' "$TOKEN" "$APP_PORT" \
  | curl -fsS --max-time "$CURL_MAX_TIME_SECONDS" -H @- "https://${endpoint}${path}"
