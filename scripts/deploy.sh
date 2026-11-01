#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# deploy.sh: package the app, create both stacks, and wait for an active image.
# Usage: deploy.sh [--package-only]
# Safe to re-run: unchanged source gives an identical zip, so nothing rebuilds.

package_only=false
case "${1:-}" in
  "") ;;
  --package-only) package_only=true ;;
  *) die "usage: deploy.sh [--package-only]" ;;
esac

# --- 1. Port check -----------------------------------------------------------
# The Dockerfile and config.env both name the ports; a mismatch would build an
# image whose servers listen where the platform is not looking.
dockerfile="$REPO_ROOT/app/Dockerfile"
check_port() {
  local key="$1" want="$2" have
  have="$(sed -n "s/^ENV ${key}=//p" "$dockerfile")"
  if [ "$have" != "$want" ]; then
    die "$key mismatch: app/Dockerfile has '$have' but config.env has '$want'; make them equal"
  fi
}
check_port APP_PORT "$APP_PORT"
check_port HOOKS_PORT "$HOOKS_PORT"

# --- 2. Packaging ------------------------------------------------------------
# Concept: the image is rebuilt only when its source artifact changes, so the
# zip must be byte-for-byte reproducible. We normalise file order, modes and
# timestamps, and name the zip after its own SHA-256.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

package_app() {
  require_cmd zip tar find sort
  local stage="$BUILD_DIR/stage" tmp_zip="$BUILD_DIR/app.zip.tmp"
  mkdir -p "$BUILD_DIR"
  rm -rf "$stage" "$tmp_zip"
  mkdir -p "$stage"
  # Copy app/ without dependencies, tests or Finder litter.
  tar -C "$REPO_ROOT/app" --exclude node_modules --exclude test --exclude .DS_Store -cf - . \
    | tar -C "$stage" -xf -
  find "$stage" -type f -exec chmod 644 {} +
  find "$stage" -type d -exec chmod 755 {} +
  # Fixed 1980-01-01 00:00 (the zip epoch), built from parts to keep it readable.
  fixed_stamp="$(printf "%s" "1980-01-01 00:00" | tr -d " :-")"
  find "$stage" -exec touch -t "$fixed_stamp" {} +
  # Sorted names, no extra attributes, no directory entries: deterministic.
  (cd "$stage" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -X -D -q "$tmp_zip" -@)
  ZIP_SHA="$(sha256_of "$tmp_zip")"
  ZIP_PATH="$BUILD_DIR/app-${ZIP_SHA}.zip"
  mv "$tmp_zip" "$ZIP_PATH"
  rm -rf "$stage"
}

package_app
log "packaged $ZIP_PATH"

# --- 3. --package-only -------------------------------------------------------
if [ "$package_only" = true ]; then
  jq -n --arg zip "$ZIP_PATH" --arg sha256 "$ZIP_SHA" '{zip: $zip, sha256: $sha256}'
  exit 0
fi

# --- 4. Sandbox guard --------------------------------------------------------
assert_sandbox
require_cmd aws jq zip

# --- 5. Bootstrap stack ------------------------------------------------------
# Concept: the long-lived plumbing (bucket, roles, log group) goes first, since
# the zip needs somewhere to be uploaded before an image can reference it.
log "deploying $BOOTSTRAP_STACK"
aws cloudformation deploy \
  --stack-name "$BOOTSTRAP_STACK" \
  --template-file "$REPO_ROOT/infra/bootstrap.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
  "ImageName=$IMAGE_NAME" \
  "LogRetentionDays=$LOG_RETENTION_DAYS" \
  >&2 || die "bootstrap stack deploy failed; run 'make destroy' before retrying"

# --- 6. Base image version ---------------------------------------------------
# Empty BASE_IMAGE_VERSION means "newest buildable": rebuilding picks up
# base-image patches, which is the intended way to stay patched.
if [ -z "$BASE_IMAGE_VERSION" ]; then
  base_version="$(aws lambda-microvms list-managed-microvm-image-versions \
    --image-identifier "$(base_image_arn)" --output json \
    | jq -r '[.items[]|select(.status=="AVAILABLE" or .status=="DEPRECATED")]|max_by(.imageVersion|tonumber).imageVersion')"
  if [ -z "$base_version" ] || [ "$base_version" = "null" ]; then
    die "could not resolve a buildable base image version"
  fi
  log "base image version $base_version (resolved newest)"
else
  base_version="$BASE_IMAGE_VERSION"
  log "base image version $base_version (pinned in config.env)"
fi

# --- 7. Upload ---------------------------------------------------------------
# BuildRole can read only artifacts/*, so the key must start there. The
# content-hashed key is what makes an unchanged app a no-op.
bucket="$(stack_output "$BOOTSTRAP_STACK" ArtifactBucketName)"
[ -n "$bucket" ] || die "bootstrap stack has no ArtifactBucketName output"
artifact_uri="s3://${bucket}/artifacts/app-${ZIP_SHA}.zip"
log "uploading to $artifact_uri"
aws s3 cp "$ZIP_PATH" "$artifact_uri" --only-show-errors >&2

# --- 8. Image stack ----------------------------------------------------------
# Concept: a new artifact URI is a changed property, so CloudFormation asks the
# service for a new image version, which builds and snapshots the app.
build_start=$SECONDS
log "deploying $IMAGE_STACK"
aws cloudformation deploy \
  --stack-name "$IMAGE_STACK" \
  --template-file "$REPO_ROOT/infra/image.yaml" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
  "BootstrapStackName=$BOOTSTRAP_STACK" \
  "ImageName=$IMAGE_NAME" \
  "ImageDescription=$IMAGE_DESCRIPTION" \
  "BaseImageVersion=$base_version" \
  "ArtifactUri=$artifact_uri" \
  "MemoryMiB=$MEMORY_MIB" \
  "HooksPort=$HOOKS_PORT" \
  "ReadyTimeoutInSeconds=$READY_TIMEOUT_SECONDS" \
  "RunTimeoutInSeconds=$RUN_TIMEOUT_SECONDS" \
  >&2 || die "image stack deploy failed; run 'make destroy' before retrying"

# --- 9. Wait for the build ---------------------------------------------------
# Concept: the image is built asynchronously; poll until a version is ACTIVE.
image_arn="$(stack_output "$IMAGE_STACK" ImageArn)"
[ -n "$image_arn" ] || die "image stack has no ImageArn output"
deadline=$((SECONDS + IMAGE_WAIT_SECONDS))
first_state=""
image_state=""
image_version=""
while true; do
  image_json="$(aws lambda-microvms get-microvm-image --image-identifier "$image_arn" --output json)"
  image_state="$(jq -r '.state' <<<"$image_json")"
  image_version="$(jq -r '.latestActiveImageVersion // ""' <<<"$image_json")"
  if [ -z "$first_state" ]; then
    first_state="$image_state"
    log "image state right after CloudFormation: $first_state"
  fi
  case "$image_state" in
    *_FAILED) die "image build failed: state $image_state" ;;
    CREATED | UPDATED) break ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die "timed out waiting for image state (last: $image_state)"
  log "image state $image_state; waiting"
  sleep "$POLL_INTERVAL_SECONDS"
done

# The image can be CREATED before its newest version is usable; wait for that too.
while true; do
  version_json="$(aws lambda-microvms get-microvm-image-version \
    --image-identifier "$image_arn" --image-version "$image_version" --output json)"
  version_state="$(jq -r '.state' <<<"$version_json")"
  version_status="$(jq -r '.status' <<<"$version_json")"
  if [ "$version_state" = "FAILED" ]; then
    die "image version $image_version failed: $(jq -r '.stateReason // ""' <<<"$version_json")"
  fi
  if [ "$version_state" = "SUCCESSFUL" ] && [ "$version_status" = "ACTIVE" ]; then
    break
  fi
  [ "$SECONDS" -lt "$deadline" ] || die "timed out waiting for image version $image_version ($version_state/$version_status)"
  log "image version $image_version is $version_state/$version_status; waiting"
  sleep "$POLL_INTERVAL_SECONDS"
done

# --- 10. Result --------------------------------------------------------------
jq -n \
  --arg imageArn "$image_arn" \
  --arg imageVersion "$image_version" \
  --arg baseImageVersion "$base_version" \
  --arg artifactUri "$artifact_uri" \
  --arg imageStateAfterCfn "$first_state" \
  --argjson buildSeconds "$((SECONDS - build_start))" \
  '{imageArn: $imageArn, imageVersion: $imageVersion, baseImageVersion: $baseImageVersion,
    artifactUri: $artifactUri, imageStateAfterCfn: $imageStateAfterCfn, buildSeconds: $buildSeconds}'
