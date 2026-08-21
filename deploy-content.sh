#!/bin/bash
set -euo pipefail

# Upload a built site to the bucket and invalidate the changed entry points.
#
# Usage: ./deploy-content.sh <dir> <bucket> <distribution-id> [profile] [region]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "$SCRIPT_DIR/lib-common.sh"

require_tools aws

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <source-dir> <bucket> <distribution-id> [aws-profile] [region]" >&2
  echo "Get the bucket and distribution id from the stack outputs." >&2
  exit 1
fi

SRC="${1%/}"
BUCKET="$2"
DIST_ID="$3"
PROFILE="${4:-}"
REGION="${5:-}"

[ -d "$SRC" ] || die "Source directory '$SRC' does not exist."
[ -f "$SRC/index.html" ] || echo "WARNING: no index.html in '$SRC'." >&2

# NB: expanded below as ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}. Under `set -u`,
# bash 3.2 (still the /bin/bash on macOS) treats "${A[@]}" on an EMPTY array as
# an unbound variable and aborts - which is the default path here, since both
# profile and region are optional.
AWS_ARGS=()
[ -n "$PROFILE" ] && AWS_ARGS+=(--profile "$PROFILE")
[ -n "$REGION" ] && AWS_ARGS+=(--region "$REGION")

# Anything whose URL changes when its content changes can be cached forever.
# Everything else must be revalidated on every request.
#
# These headers are only actually honored because the CachePolicy in
# static-website.yml sets MinTTL: 0. A non-zero minimum makes CloudFront ignore
# origin Cache-Control (including max-age=0) for that duration.
IMMUTABLE='public, max-age=31536000, immutable'
REVALIDATE='public, max-age=0, must-revalidate'

# Files that are re-fetched by URL and therefore must never be cached hard.
MUTABLE_PATTERNS=(
  "*.html" "*.json" "*.xml" "*.txt"
  "service-worker.js" "sw.js"
)

# Prefixes holding PERMANENT, PINNED artifacts - published once under a URL that
# encodes a version, and referenced by third parties forever after.
#
# These need their own class because extension alone gets it dangerously wrong.
# A pinned API spec at v/isn/8665/openapi.json is a *.json file, so the mutable
# rules above would (a) serve it max-age=0 and, far worse, (b) DELETE it from the
# bucket the moment a build stops emitting that version - which is every build
# after the version bumps, since most generators wipe their output directory.
# That silently breaks every consumer who pinned the URL.
#
# So: URL semantics decide cache and delete policy, not file extension.
# Anything under these prefixes is uploaded immutable, never deleted, and never
# invalidated. Override with e.g. PROTECTED_PREFIXES="v/ releases/".
read -r -a PROTECTED_PREFIXES <<< "${PROTECTED_PREFIXES:-v/}"

# Build the filter args that keep the protected prefixes out of a sync pass.
# ORDER MATTERS: the AWS CLI applies --include/--exclude in sequence and the LAST
# match wins, so these must be appended AFTER any --include that would match.
protected_excludes=()
for p in ${PROTECTED_PREFIXES[@]+"${PROTECTED_PREFIXES[@]}"}; do
  protected_excludes+=(--exclude "${p%/}/*")
done

# Pass 1: pinned artifacts. No --delete, ever - that is the whole point.
for p in ${PROTECTED_PREFIXES[@]+"${PROTECTED_PREFIXES[@]}"}; do
  [ -d "$SRC/${p%/}" ] || continue
  echo "==> Syncing pinned $p (immutable, never deleted)"
  aws s3 sync --no-progress "$SRC/${p%/}" "s3://$BUCKET/${p%/}" \
    --cache-control "$IMMUTABLE" \
    ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}
done

echo "==> Syncing immutable assets (content-hashed)"
# Assets go up BEFORE html, so newly-published html never references an asset
# that has not landed yet.
excludes=()
for p in "${MUTABLE_PATTERNS[@]}"; do excludes+=(--exclude "$p"); done
aws s3 sync --no-progress "$SRC" "s3://$BUCKET" \
  "${excludes[@]}" \
  ${protected_excludes[@]+"${protected_excludes[@]}"} \
  --cache-control "$IMMUTABLE" \
  ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}

echo "==> Syncing revalidated entry points (html/json/xml/service workers)"
includes=(--exclude "*")
for p in "${MUTABLE_PATTERNS[@]}"; do includes+=(--include "$p"); done
# --delete runs only on this pass, and the CLI applies these same filters to the
# delete scan. So stale HTML/JSON is removed, while old content-hashed assets are
# deliberately left in place: a client that loaded the previous HTML may still be
# fetching them, and deleting them mid-flight would break that page. Prune them
# separately when you want the space back.
#
# protected_excludes goes LAST so it overrides the --include rules above and the
# pinned prefixes are untouched by both the upload and the delete scan.
aws s3 sync --no-progress "$SRC" "s3://$BUCKET" \
  "${includes[@]}" \
  ${protected_excludes[@]+"${protected_excludes[@]}"} \
  --delete \
  --cache-control "$REVALIDATE" \
  ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}

# NOTE: `aws s3 sync` decides what to upload from file size/mtime, NOT from
# metadata. Changing only the Cache-Control values above will NOT reapply them to
# otherwise-unchanged objects. To fix headers alone, force a metadata rewrite:
#
#   aws s3 cp "s3://$BUCKET" "s3://$BUCKET" --recursive \
#     --metadata-directive REPLACE --cache-control '<value>'

# Invalidate only the mutable entry points. A blanket /* would throw away the
# benefit of the immutable hashed assets on every single deploy, and invalidating
# a pinned artifact contradicts the promise that its URL never changes - so the
# protected prefixes are skipped here too.
echo "==> Invalidating CloudFront"
paths=()
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  skip=""
  for p in ${PROTECTED_PREFIXES[@]+"${PROTECTED_PREFIXES[@]}"}; do
    case "$rel" in "${p%/}"/*) skip=1 ;; esac
  done
  [ -n "$skip" ] || paths+=("/$rel")
done < <(find "$SRC" \( -name '*.html' -o -name '*.json' -o -name '*.xml' \
                        -o -name '*.txt' -o -name 'service-worker.js' -o -name 'sw.js' \) -type f)

if [ "${#paths[@]}" -eq 0 ]; then
  echo "  nothing to invalidate"
else
  # CloudFront allows 3000 paths per invalidation; well past that, /* is cheaper.
  if [ "${#paths[@]}" -gt 200 ]; then
    echo "  ${#paths[@]} entry points - using /* instead of listing them all"
    paths=("/*")
  fi
  inv_id="$(aws cloudfront create-invalidation \
    --distribution-id "$DIST_ID" \
    --paths "${paths[@]}" \
    --query 'Invalidation.Id' --output text \
    ${AWS_ARGS[@]+"${AWS_ARGS[@]}"})"
  echo "  invalidation $inv_id created (${#paths[@]} path(s))"
  echo "  waiting for it to complete..."
  aws cloudfront wait invalidation-completed \
    --distribution-id "$DIST_ID" --id "$inv_id" ${AWS_ARGS[@]+"${AWS_ARGS[@]}"}
  echo "  done"
fi

echo
echo "Deployed $SRC -> s3://$BUCKET"
