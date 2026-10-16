#!/usr/bin/env bash
# Artifactory -> SMB gateway.
#   rclone (http backend, HTTP Range reads) -> FUSE mount -> Samba (read-only share)
set -euo pipefail

log() { echo "[gateway] $*"; }
die() { echo "[gateway] ERROR: $*" >&2; exit 1; }

# ---------- settings ----------
: "${ART_URL:?Set ART_URL, e.g. https://yourorg.jfrog.io/artifactory/my-repo/}"
ART_TOKEN="${ART_TOKEN:-}"
ART_USER="${ART_USER:-}"
ART_PASSWORD="${ART_PASSWORD:-}"

SMB_USER="${SMB_USER:-artuser}"
SMB_PASSWORD="${SMB_PASSWORD:-}"
SMB_SHARE="${SMB_SHARE:-artifacts}"
SMB_GUEST="${SMB_GUEST:-false}"
SMB_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"

# off | minimal | writes | full. "full" caches only the byte ranges actually read.
CACHE_MODE="${CACHE_MODE:-full}"
CACHE_MAX_SIZE="${CACHE_MAX_SIZE:-20G}"
CACHE_MAX_AGE="${CACHE_MAX_AGE:-24h}"
READ_CHUNK_SIZE="${READ_CHUNK_SIZE:-16M}"
READ_CHUNK_LIMIT="${READ_CHUNK_LIMIT:-256M}"
READ_AHEAD="${READ_AHEAD:-64M}"
DIR_CACHE_TIME="${DIR_CACHE_TIME:-10m}"
RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-NOTICE}"
RCLONE_EXTRA_ARGS="${RCLONE_EXTRA_ARGS:-}"

MNT=/mnt/art
UID_SMB=1000

if [[ "$SMB_GUEST" != "true" && -z "$SMB_PASSWORD" ]]; then
  die "Set SMB_PASSWORD, or set SMB_GUEST=true for an open share."
fi
[[ -e /dev/fuse ]] || die "/dev/fuse missing. Run the container with --device /dev/fuse --cap-add SYS_ADMIN."

# ---------- Artifactory auth ----------
AUTH_HEADER=""
if [[ -n "$ART_TOKEN" ]]; then
  AUTH_HEADER="Bearer ${ART_TOKEN}"
elif [[ -n "$ART_USER" && -n "$ART_PASSWORD" ]]; then
  AUTH_HEADER="Basic $(printf '%s:%s' "$ART_USER" "$ART_PASSWORD" | base64 -w0)"
fi

# ---------- fail fast if Artifactory is unreachable or rejects us ----------
curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 20)
[[ -n "$AUTH_HEADER" ]] && curl_args+=(-H "Authorization: ${AUTH_HEADER}")
code="$(curl "${curl_args[@]}" "$ART_URL" || true)"
case "$code" in
  200) log "Artifactory reachable (HTTP 200)." ;;
  401|403) die "Artifactory answered HTTP $code. Check ART_TOKEN / ART_USER+ART_PASSWORD and repo permissions." ;;
  404) die "Artifactory answered HTTP 404. Check ART_URL (needs /artifactory/<repo>/ on self-hosted)." ;;
  *) log "WARNING: probe returned '$code' (continuing; rclone will retry)." ;;
esac

# ---------- rclone remote, configured via env (no secrets written to disk) ----------
export RCLONE_CONFIG_ART_TYPE=http
export RCLONE_CONFIG_ART_URL="$ART_URL"
if [[ -n "$AUTH_HEADER" ]]; then
  export RCLONE_CONFIG_ART_HEADERS="Authorization,${AUTH_HEADER}"
fi
export RCLONE_CONFIG=/dev/null

# ---------- unix + samba user (uid must match the FUSE mount owner) ----------
if ! id "$SMB_USER" >/dev/null 2>&1; then
  useradd -M -u "$UID_SMB" -s /usr/sbin/nologin "$SMB_USER"
fi
GID_SMB="$(id -g "$SMB_USER")"

if [[ -n "$SMB_PASSWORD" ]]; then
  printf '%s\n%s\n' "$SMB_PASSWORD" "$SMB_PASSWORD" | smbpasswd -a -s "$SMB_USER" >/dev/null
fi

# ---------- samba config ----------
guest_global=""
share_access="valid users = ${SMB_USER}"
if [[ "$SMB_GUEST" == "true" ]]; then
  guest_global="map to guest = Bad User"
  share_access="guest ok = yes"$'\n'"   force user = ${SMB_USER}"
else
  guest_global="map to guest = Never"
fi

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = ${SMB_WORKGROUP}
   server string = Artifactory SMB gateway
   server role = standalone server
   server min protocol = SMB2
   smb ports = 445
   disable netbios = yes
   ${guest_global}
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   log file = /dev/null
   logging = stdout
   # Remote read-only content behind FUSE: no locking games, no sendfile.
   oplocks = no
   level2 oplocks = no
   kernel oplocks = no
   strict locking = no
   posix locking = no
   use sendfile = no
   socket options = TCP_NODELAY IPTOS_LOWDELAY

[${SMB_SHARE}]
   path = ${MNT}
   read only = yes
   browseable = yes
   ${share_access}
EOF
testparm -s >/dev/null 2>&1 || die "Generated smb.conf is invalid."

# ---------- start rclone mount ----------
mkdir -p "$MNT" /cache
# shellcheck disable=SC2086
rclone mount ART: "$MNT" \
  --read-only \
  --allow-other \
  --uid "$UID_SMB" --gid "$GID_SMB" --umask 022 \
  --cache-dir /cache \
  --vfs-cache-mode "$CACHE_MODE" \
  --vfs-cache-max-size "$CACHE_MAX_SIZE" \
  --vfs-cache-max-age "$CACHE_MAX_AGE" \
  --vfs-read-chunk-size "$READ_CHUNK_SIZE" \
  --vfs-read-chunk-size-limit "$READ_CHUNK_LIMIT" \
  --vfs-read-ahead "$READ_AHEAD" \
  --dir-cache-time "$DIR_CACHE_TIME" \
  --attr-timeout "$DIR_CACHE_TIME" \
  --log-level "$RCLONE_LOG_LEVEL" \
  $RCLONE_EXTRA_ARGS &
RCLONE_PID=$!

SMBD_PID=""
cleanup() {
  log "Shutting down."
  [[ -n "$SMBD_PID" ]] && kill "$SMBD_PID" 2>/dev/null || true
  kill "$RCLONE_PID" 2>/dev/null || true
  fusermount3 -uz "$MNT" 2>/dev/null || fusermount -uz "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "Waiting for FUSE mount..."
for _ in $(seq 1 60); do
  mountpoint -q "$MNT" && break
  kill -0 "$RCLONE_PID" 2>/dev/null || die "rclone exited before the mount came up (see log above)."
  sleep 0.5
done
mountpoint -q "$MNT" || die "Mount did not appear within 30s."
log "Mounted ${ART_URL} at ${MNT} (cache mode: ${CACHE_MODE})."

# ---------- start samba ----------
smbd --foreground --no-process-group --debug-stdout &
SMBD_PID=$!
log "SMB share '\\\\<host>\\${SMB_SHARE}' is up on port 445 (read-only)."

# Exit (so the orchestrator restarts us) if either side dies.
wait -n "$RCLONE_PID" "$SMBD_PID"
die "A child process exited."
