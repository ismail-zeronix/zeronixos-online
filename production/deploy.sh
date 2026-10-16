#!/usr/bin/env bash
# Deploys/updates the Zeronix Frappe/ERPNext/CRM stack on the VPS.
# Save at /srv/docker/frappe/production/deploy.sh and run from
# /srv/docker/frappe (where compose.yaml, apps.json and .env live).
#
# Unlike a plain ERPNext deployment, this stack uses a custom-built image
# (ERPNext + CRM aren't both in any public image), built locally on the VPS
# from apps.json via images/layered/Containerfile. "Pulling latest" means
# re-running that build, not `docker compose pull`.
set -euo pipefail

APP_DIR="/srv/docker/frappe"
IMAGE="zeronix-frappe:16"
ROLLBACK_IMAGE="zeronix-frappe:rollback"
COMPOSE="sudo docker compose --env-file .env -f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml -f overrides/compose.proxy-net.yaml -f overrides/compose.healthcheck.yaml"

cd "$APP_DIR"

echo "==> Saving current image as rollback"
CURRENT_IMAGE_ID="$(sudo docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)"
if [ -n "$CURRENT_IMAGE_ID" ]; then
  sudo docker tag "$CURRENT_IMAGE_ID" "$ROLLBACK_IMAGE"
  echo "    Rollback image saved: $ROLLBACK_IMAGE"
else
  echo "    No existing image found to save as rollback (first deploy?)"
fi

echo "==> Pulling latest frappe_docker config"
git pull --ff-only origin main

echo "==> Rebuilding $IMAGE from apps.json (frappe=version-16, erpnext=version-16, crm=v1.88.0)"
sudo docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --secret=id=apps_json,src=apps.json \
  --tag="$IMAGE" \
  --file=images/layered/Containerfile .

echo "==> Starting updated stack (overrides/compose.migrator.yaml runs 'bench --site all migrate' automatically)"
$COMPOSE -f overrides/compose.migrator.yaml up -d

echo "==> Waiting for frontend health"
for i in $(seq 1 30); do
  STATUS="$(sudo docker inspect --format='{{.State.Health.Status}}' zeronix-frappe-frontend 2>/dev/null || true)"
  if [ "$STATUS" = "healthy" ]; then
    echo "Deployment complete: frontend is healthy"
    exit 0
  fi
  sleep 2
done

echo "Deployment finished starting, but frontend did not report healthy within 60s."
echo "Rollback image is available at: $ROLLBACK_IMAGE (not deleted)"
echo "Check logs:"
echo "  $COMPOSE logs frontend backend migrator --tail 100"
$COMPOSE ps
exit 1
