#!/bin/bash
# Run this once on the app LXC (200) to bootstrap the standard directory structure.
# Usage: bash setup-app-lxc.sh
set -euo pipefail

echo "==> Creating standard directory structure..."
mkdir -p /opt/apps/bin

echo "==> Installing deploy script..."
cat > /opt/apps/bin/deploy.sh << 'DEPLOY_EOF'
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
DEPLOY_EOF
chmod +x /opt/apps/bin/deploy.sh

echo "==> Logging in to Aliyun Docker Registry (Shanghai)..."
echo "    You will be prompted for credentials."
docker login registry.cn-shanghai.aliyuncs.com

echo ""
echo "=== Setup complete ==="
echo ""
echo "To add a new project environment, run:"
echo "  mkdir -p /opt/apps/<project>/<env>"
echo "  vim /opt/apps/<project>/<env>/.env"
echo ""
echo "Example for 2SOMEone production:"
echo "  mkdir -p /opt/apps/twosomeone/production"
echo "  vim /opt/apps/twosomeone/production/.env"
