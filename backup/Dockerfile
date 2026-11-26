# Backup sidecar: mariadb-dump + tar + rclone, scheduled with busybox crond.
FROM alpine:3.20

# hadolint ignore=DL3018
RUN apk add --no-cache bash coreutils findutils util-linux curl tar gzip tzdata \
      mariadb-client rclone ca-certificates

COPY --chmod=0755 backup.sh restore.sh entrypoint.sh /usr/local/bin/

ENV BACKUP_DIR=/backups \
    RESOURCES_DIR=/data/server-data/resources

VOLUME ["/backups"]

# crond needs root to switch to the crontab owner; the container itself has no
# published ports and only mounts the resources volume read-only.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]
