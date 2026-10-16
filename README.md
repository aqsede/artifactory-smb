# Artifactory → SMB gateway

A read-only SMB share that serves files straight from a JFrog Artifactory path.
Nothing is preloaded: each read becomes an HTTP `Range` request to Artifactory,
so sequential reads stream and random reads/seeks fetch only the bytes needed.

Built entirely from existing FOSS parts:

```
SMB client ──► Samba (smbd) ──► FUSE mount ──► rclone "http" backend ──► Artifactory (HTTPS, Range)
                                   └─ optional on-disk cache of only the ranges actually read
```

## Quick start

```bash
cp .env.example .env      # set ART_URL, ART_TOKEN, SMB_PASSWORD
docker compose up -d --build
docker compose logs -f
```

Connect:

| Client  | Address |
|---------|---------|
| Windows | `\\<host>\artifacts` (user `SMB_USER`) |
| macOS   | Finder → Go → Connect to Server → `smb://<host>/artifacts` |
| Linux   | `sudo mount -t cifs //<host>/artifacts /mnt/x -o user=artuser,vers=3.0,ro` |

`ART_URL` must point at the repo (or a folder inside it), e.g.
`https://yourorg.jfrog.io/artifactory/my-generic-repo/`.

## Requirements

- Docker with `/dev/fuse` available on the host (the compose file adds `SYS_ADMIN` and the device).
- Artifactory directory browsing must work for the account you use. Open the `ART_URL`
  in a browser: if you see a file listing, rclone can read it.
- Best suited to Generic / Maven / raw-file style repos. Docker, npm, etc. repos expose
  package layouts rather than plain trees.

## Verifying range reads

```bash
# Inside the container: read 1 MB from the middle of a big file
docker exec artifactory-smb dd if=/mnt/art/path/to/big.bin bs=1M skip=500 count=1 of=/dev/null
```

Then check Artifactory's request log (or `RCLONE_LOG_LEVEL=DEBUG`): you should see
ranged GETs, not a full download.

## Folders show up but are empty

rclone's http backend sends a HEAD request for every file in a listing and silently drops
any file whose HEAD fails (folders need no request, so they always appear). Run:

```bash
docker compose up -d --build        # picks up diag.sh
docker exec artifactory-smb /diag.sh            # repo root
docker exec artifactory-smb /diag.sh some/folder # a folder that has files
```

It prints the listing status, the links found, the HEAD result per file (including any
redirect to storage), and rclone's own "skipping because of error" lines.

## Tuning

| Variable | Effect |
|----------|--------|
| `CACHE_MODE=full` | Caches only the byte ranges that were read. Best for random access, repeated reads. |
| `CACHE_MODE=off` | Pure pass-through, no disk use. Fine for single sequential streams; seeks reopen the connection. |
| `READ_CHUNK_SIZE` / `READ_CHUNK_LIMIT` | Size of each ranged request; it doubles up to the limit while reading sequentially. |
| `READ_AHEAD` | How much extra is fetched ahead of a sequential reader. |
| `DIR_CACHE_TIME` | How long listings are remembered. New uploads show up after this. |

## Limitations (be aware)

- **Read-only** by design.
- rclone's `http` backend issues a `HEAD` per file to learn sizes the first time a folder
  is listed. Folders with many thousands of files are slow on first open, then cached.
  Point `ART_URL` at a narrower sub-path if that hurts.
- Windows Explorer thumbnails/previews can trigger many small reads. Disable previews for
  the mapped drive if it feels slow.
- Port 445 conflicts if the host already runs Samba. Set `SMB_PORT` (macOS/Linux clients can
  use a custom port; Windows cannot without a port proxy).
- Not for exposure to the internet. Keep it on a LAN/VPN.

## Files

- `Dockerfile` – Debian + Samba + rclone binary
- `diag.sh` – troubleshooting helper
- `entrypoint.sh` – config from env, auth probe, mount, start Samba, supervise both
- `docker-compose.yml`, `.env.example` – deployment and settings
