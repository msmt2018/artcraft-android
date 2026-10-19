#!/usr/bin/env bash
# Upload GitHub release assets without Clash/TUN throttling them to a crawl.
#
# Symptom: `gh release upload` of a 40-70 MB APK hangs and dies with
#   HTTP 408: Upload body timed out due to inactivity
# while plain download works fine.
#
# Cause: the VPN's TUN interface advertises fake-IP DNS answers (198.18.x.x/15), so the upload
# connection is routed through the tunnel, where long-lived uploads get reset or throttled to
# ~30 KB/s.
#
# Fix: resolve uploads.github.com to its REAL address and pin the connection to the physical
# interface, bypassing the tunnel entirely. Measured on this machine: 30 KB/s -> 10 MB/s.
#
# Note: `dig +short uploads.github.com` returns the fake IP while the VPN runs, so the real
# address cannot be looked up at runtime -- it is pinned below and can be overridden via $GH_IP.
#
#   usage: ~/gh-upload.sh <owner/repo> <release-tag> <file> [file...]
#          ~/gh-upload.sh <owner/repo> <release-tag> --delete <asset-name>
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

REPO="${1:?usage: gh-upload.sh <owner/repo> <tag> <file|--delete name>...}"
TAG="${2:?usage: gh-upload.sh <owner/repo> <tag> <file|--delete name>...}"
shift 2

# Real address behind uploads.github.com. Override with GH_IP if GitHub moves it.
IP="${GH_IP:-20.205.243.161}"
IFACE="${GH_IFACE:-en0}"

TOKEN=$(gh auth token) || { echo "gh is not authenticated"; exit 1; }
RID=$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id) || { echo "no release $TAG in $REPO"; exit 1; }

if [ "${1:-}" = "--delete" ]; then
  shift
  for name in "$@"; do
    aid=$(gh api "repos/$REPO/releases/$RID/assets" --jq ".[] | select(.name==\"$name\") | .id")
    if [ -n "$aid" ]; then
      gh api -X DELETE "repos/$REPO/releases/assets/$aid" >/dev/null && echo "deleted $name"
    else
      echo "no such asset: $name"
    fi
  done
  exit 0
fi

rc=0
for f in "$@"; do
  [ -f "$f" ] || { echo "missing: $f"; rc=1; continue; }
  name=$(basename "$f")
  size=$(wc -c <"$f" | tr -d ' ')
  start=$(date +%s)
  resp=$(curl -sS --interface "$IFACE" --resolve "uploads.github.com:443:$IP" \
    -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$name" 2>&1)
  # The release API refuses a duplicate name, and a re-upload of a rebuilt APK always is one.
  # Replace it: delete the old asset, then post again.
  if printf '%s' "$resp" | grep -q 'already_exists'; then
    aid=$(gh api "repos/$REPO/releases/$RID/assets" --jq ".[] | select(.name==\"$name\") | .id")
    [ -n "$aid" ] && gh api -X DELETE "repos/$REPO/releases/assets/$aid" >/dev/null 2>&1
    resp=$(curl -sS --interface "$IFACE" --resolve "uploads.github.com:443:$IP" \
      -X POST \
      -H "Authorization: token $TOKEN" \
      -H "Content-Type: application/octet-stream" \
      --data-binary @"$f" \
      "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$name" 2>&1)
  fi

  end=$(date +%s)
  if printf '%s' "$resp" | grep -q '"state"[: ]*"uploaded"'; then
    printf 'OK   %-46s %5s MB  %ss\n' "$name" "$((size / 1048576))" "$((end - start))"
  else
    printf 'FAIL %-46s %s\n' "$name" "$(printf '%s' "$resp" | head -c 140)"
    rc=1
  fi
done
exit $rc
