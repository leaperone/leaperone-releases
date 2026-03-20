#!/bin/bash
set -euo pipefail

PROJECT="${1:?Usage: deploy.sh <project> <env>}"
ENV="${2:?Usage: deploy.sh <project> <env>}"
APP_DIR="/opt/apps/${PROJECT}/${ENV}"

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: ${APP_DIR} does not exist" >&2
  exit 1
fi

if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
  echo "ERROR: ${APP_DIR}/docker-compose.yml not found" >&2
  exit 1
fi

if [ ! -f "$APP_DIR/.env" ]; then
  echo "ERROR: ${APP_DIR}/.env not found (create it with required env vars)" >&2
  exit 1
fi

cd "$APP_DIR"

echo "==> Pulling images for ${PROJECT}/${ENV}..."
docker compose pull

echo "==> Starting services..."
docker compose up -d --remove-orphans

echo "==> Cleaning up old images..."
docker image prune -f

echo "==> Deploy ${PROJECT}/${ENV} complete"
docker compose ps
