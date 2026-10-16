ARG RCLONE_TAG=latest
FROM rclone/rclone:${RCLONE_TAG} AS rclone

FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      samba fuse3 ca-certificates curl procps \
 && rm -rf /var/lib/apt/lists/* \
 && echo "user_allow_other" >> /etc/fuse.conf \
 && mkdir -p /mnt/art /cache

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 445
VOLUME ["/cache"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD mountpoint -q /mnt/art && pgrep -x smbd >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
