#!/usr/bin/env bash
# Diagnose "folders visible but empty".
# Usage: docker exec artifactory-smb /diag.sh [sub/folder]
# rclone's http backend sends a HEAD per file and silently drops files whose HEAD fails.
# This script shows what Artifactory returns for each step.
set -uo pipefail

: "${ART_URL:?ART_URL not set}"
SUB="${1:-}"
SUB="${SUB#/}"

AUTH_HEADER=""
if [[ -n "${ART_TOKEN:-}" ]]; then
  AUTH_HEADER="Bearer ${ART_TOKEN}"
elif [[ -n "${ART_USER:-}" && -n "${ART_PASSWORD:-}" ]]; then
  AUTH_HEADER="Basic $(printf '%s:%s' "$ART_USER" "$ART_PASSWORD" | base64 -w0)"
fi
auth=()
[[ -n "$AUTH_HEADER" ]] && auth=(-H "Authorization: ${AUTH_HEADER}")

url="${ART_URL%/}/"
if [[ -n "$SUB" ]]; then url="${url}${SUB%/}/"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== 1. GET listing: $url"
curl -sS -D "$tmp/h" -o "$tmp/body" "${auth[@]}" "$url" || { echo "curl failed"; exit 1; }
head -n1 "$tmp/h"
grep -i '^content-type' "$tmp/h" || echo "(no content-type)"
echo "   (rclone requires exactly text/html here)"

echo
echo "== 2. First links on the page"
grep -oE 'href="[^"]*"' "$tmp/body" | sed 's/^href="//;s/"$//' | head -15
files="$(grep -oE 'href="[^"]*"' "$tmp/body" | sed 's/^href="//;s/"$//' | grep -vE '/$|^\.\.|\?|^#' | head -3)"
dirs="$(grep -oE 'href="[^"]*"' "$tmp/body" | sed 's/^href="//;s/"$//' | grep -E '/$' | grep -v '^\.\.' | head -3)"

if [[ -z "$files" ]]; then
  echo
  echo "No file links on this page, only folders. Try one of these:"
  echo "$dirs" | sed 's/^/   \/diag.sh /'
  exit 0
fi

echo
echo "== 3. HEAD on files (this is what rclone does per file; failure = file hidden)"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  echo "-- HEAD ${url}${f}"
  curl -sS -I "${auth[@]}" "${url}${f}" | grep -iE '^(HTTP|location|content-length|content-type|last-modified|accept-ranges)' || true
  loc="$(curl -sS -I "${auth[@]}" "${url}${f}" | grep -i '^location:' | tr -d '\r' | cut -d' ' -f2-)"
  if [[ -n "$loc" ]]; then
    echo "   redirected -> HEAD on target (no auth header):"
    curl -sS -I "$loc" | grep -iE '^(HTTP|content-length|accept-ranges)' | sed 's/^/   /' || true
    echo "   redirected -> ranged GET on target:"
    curl -sS -o /dev/null -w '   HTTP %{http_code}\n' -H 'Range: bytes=0-99' "$loc"
  fi
done <<< "$files"

echo
echo "== 4. What rclone itself says (look for 'skipping because of error')"
export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_ART_TYPE=http
export RCLONE_CONFIG_ART_URL="$ART_URL"
[[ -n "$AUTH_HEADER" ]] && export RCLONE_CONFIG_ART_HEADERS="Authorization,${AUTH_HEADER}"
rclone lsf "ART:${SUB}" -vv 2>&1 | grep -iE 'skipping|HTTP Error|failed|error' | head -10
echo "-- entries rclone returned:"
rclone lsf "ART:${SUB}" 2>&1 | head -10
