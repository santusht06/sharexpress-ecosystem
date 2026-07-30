#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Sharexpress Cloud — VPS Bootstrap Script
# Run once on a fresh Ubuntu 24.04 LTS server to:
#   1. Install system packages (Node, Python, Nginx, MongoDB, Redis)
#   2. Set up directory structure
#   3. Register systemd services
#   4. Install the GitHub Actions self-hosted runner
#
# Usage (as root or with sudo):
#   curl -fsSL https://raw.githubusercontent.com/sharexpress/cloud.sharexpress.in/main/.github/infra/bootstrap-vps.sh | bash
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RUNNER_VERSION="2.317.0"
RUNNER_ARCH="x64"
GH_REPO_URL="https://github.com/sharexpress/cloud.sharexpress.in"
RUNNER_USER="github-runner"
RUNNER_HOME="/opt/github-runner"
BACKEND_DIR="/opt/sharexpress-cloud/backend"
WEB_DIR="/var/www/cloud.sharexpress/public"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🚀 Sharexpress Cloud — VPS Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. System update & base packages ──────────────────────────────────────
echo "→ Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git rsync unzip build-essential \
  nginx certbot python3-certbot-nginx \
  python3.12 python3.12-venv python3-pip \
  redis-server

# ── 2. Node.js 20 (via NodeSource) ────────────────────────────────────────
echo "→ Installing Node.js 20..."
if ! command -v node &>/dev/null || [[ "$(node --version | cut -d. -f1)" != "v20" ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
echo "   Node.js: $(node --version) | npm: $(npm --version)"

# ── 3. MongoDB (Community Edition) ────────────────────────────────────────
echo "→ Installing MongoDB..."
if ! command -v mongod &>/dev/null; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  apt-get update -qq && apt-get install -y -qq mongodb-org
fi
systemctl enable --now mongod
echo "   MongoDB: $(mongod --version | head -1)"

# ── 4. Directory structure ─────────────────────────────────────────────────
echo "→ Creating deployment directories..."
mkdir -p "$BACKEND_DIR" "$WEB_DIR"
chown -R www-data:www-data /var/www/cloud.sharexpress
chown -R www-data:www-data /opt/sharexpress-cloud

# ── 5. Nginx configuration ────────────────────────────────────────────────
echo "→ Installing Nginx configuration..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/nginx.conf" ]; then
  cp "$SCRIPT_DIR/nginx.conf" /etc/nginx/sites-available/cloud.sharexpress.in
  ln -sf /etc/nginx/sites-available/cloud.sharexpress.in /etc/nginx/sites-enabled/cloud.sharexpress.in
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  echo "   Nginx configured ✅"
else
  echo "   ⚠️  nginx.conf not found in $SCRIPT_DIR — install manually"
fi

# ── 6. Systemd services ────────────────────────────────────────────────────
echo "→ Installing systemd services..."
for SERVICE in sharexpress-cloud-api sharexpress-cloud-fe; do
  if [ -f "$SCRIPT_DIR/$SERVICE.service" ]; then
    cp "$SCRIPT_DIR/$SERVICE.service" /etc/systemd/system/
    echo "   Installed $SERVICE.service"
  fi
done
systemctl daemon-reload
systemctl enable sharexpress-cloud-api
echo "   Services registered ✅"

# ── 7. GitHub Actions self-hosted runner ──────────────────────────────────
echo "→ Setting up GitHub Actions self-hosted runner..."
if ! id "$RUNNER_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi

mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"

RUNNER_TAR="actions-runner-linux-$RUNNER_ARCH-$RUNNER_VERSION.tar.gz"
if [ ! -f "$RUNNER_TAR" ]; then
  curl -fsSL -o "$RUNNER_TAR" \
    "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$RUNNER_TAR"
fi
tar xzf "$RUNNER_TAR"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Bootstrap complete!"
echo ""
echo " Next steps:"
echo " 1. Generate a runner token at:"
echo "    $GH_REPO_URL/settings/actions/runners/new"
echo ""
echo " 2. Register the runner (run as $RUNNER_USER):"
echo "    sudo -u $RUNNER_USER bash -c \"cd $RUNNER_HOME && ./config.sh \\"
echo "      --url $GH_REPO_URL \\"
echo "      --token <YOUR_RUNNER_TOKEN> \\"
echo "      --name vps-runner \\"
echo "      --labels self-hosted,vps \\"
echo "      --unattended\""
echo ""
echo " 3. Install as a system service:"
echo "    sudo $RUNNER_HOME/svc.sh install $RUNNER_USER"
echo "    sudo $RUNNER_HOME/svc.sh start"
echo ""
echo " 4. Create backend .env at $BACKEND_DIR/.env"
echo "    (copy from cloud.sharexpress/backend/.env.example)"
echo ""
echo " 5. SSL (Let's Encrypt):"
echo "    sudo certbot --nginx -d cloud.sharexpress.in"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
