#!/usr/bin/env bash
# Compressed Frappe/ERPNext/CRM backup (MariaDB dump + public/private files)
# via `bench backup --with-files`, copied out of the ephemeral container
# onto the host. Save at /srv/docker/frappe/production/backup-frappe.sh,
# make executable, and schedule with host-level cron (see PRODUCTION.md) -
# deliberately NOT scheduled from inside any container.
set -euo pipefail

APP_DIR="/srv/docker/frappe"
BACKUP_DIR="/srv/docker/backups/frappe"
SITE_NAME="$(grep -oP '(?<=^SITE_NAME=).*' "$APP_DIR/.env")"
COMPOSE="sudo docker compose --env-file $APP_DIR/.env -f $APP_DIR/compose.yaml -f $APP_DIR/overrides/compose.mariadb.yaml -f $APP_DIR/overrides/compose.redis.yaml -f $APP_DIR/overrides/compose.proxy-net.yaml"

cd "$APP_DIR"
mkdir -p "$BACKUP_DIR"

echo "==> Running bench backup for $SITE_NAME"
$COMPOSE exec -T backend bench --site "$SITE_NAME" backup --with-files

echo "==> Copying backup files out of the sites volume"
TIMESTAMP="$(date -u +'%Y-%m-%d_%H-%M-%S')"
DEST="$BACKUP_DIR/$TIMESTAMP"
mkdir -p "$DEST"
CONTAINER_ID="$($COMPOSE ps -q backend)"
sudo docker cp "$CONTAINER_ID:/home/frappe/frappe-bench/sites/$SITE_NAME/private/backups/." "$DEST/"
chmod 600 "$DEST"/*

echo "==> Pruning backups older than 14 days"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \;

echo "Backup created in: $DEST"
