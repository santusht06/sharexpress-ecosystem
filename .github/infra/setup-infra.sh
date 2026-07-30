#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Sharexpress Cloud — Master Infrastructure Setup Script
# Installs: k3s, kubectl, Helm, Docker Compose stack (MongoDB/Redis/PG/MinIO)
# GitHub Actions self-hosted runner
#
# Run on VPS as: sudo bash setup-infra.sh <RUNNER_TOKEN>
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RUNNER_TOKEN="${1:-}"
GH_REPO_URL="https://github.com/sharexpress/cloud.sharexpress.in"
INFRA_DIR="/opt/sharexpress-infra"
DATA_DIR="/opt/sharexpress-data"
RUNNER_HOME="/opt/github-runner"
RUNNER_USER="github-runner"
RUNNER_VERSION="2.317.0"

# ── Colors ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🚀 Sharexpress Cloud — Infrastructure Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# ─── 1. Data Directories ──────────────────────────────────────────────────
info "Creating data directories..."
mkdir -p \
  "$DATA_DIR/mongodb" \
  "$DATA_DIR/redis" \
  "$DATA_DIR/postgres" \
  "$DATA_DIR/minio" \
  "$INFRA_DIR"
chmod 700 "$DATA_DIR"
chown -R 999:999 "$DATA_DIR/mongodb" "$DATA_DIR/redis" "$DATA_DIR/postgres" 2>/dev/null || true
success "Data directories created at $DATA_DIR"

# ─── 2. UFW Firewall ──────────────────────────────────────────────────────
info "Configuring UFW firewall..."
if command -v ufw &>/dev/null; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp   comment 'SSH'
  ufw allow 80/tcp   comment 'HTTP'
  ufw allow 443/tcp  comment 'HTTPS'
  ufw allow 6443/tcp comment 'k3s API server (internal)'
  ufw --force enable
  success "Firewall configured (22/80/443 open)"
else
  warn "UFW not found, skipping firewall setup"
fi

# ─── 3. Docker Compose Plugin ─────────────────────────────────────────────
info "Ensuring Docker Compose v2 plugin is installed..."
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi
success "Docker Compose: $(docker compose version)"

# ─── 4. Generate secure passwords if .env doesn't exist ──────────────────
ENV_FILE="$INFRA_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  info "Generating secure passwords for infrastructure services..."
  MONGO_ROOT_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
  MONGO_APP_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
  REDIS_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
  POSTGRES_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
  MINIO_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)

  cat > "$ENV_FILE" << ENVEOF
# Sharexpress Infrastructure — Generated $(date)
# KEEP THIS FILE SECURE — do not commit to git

MONGO_ROOT_USER=sharexpress
MONGO_ROOT_PASSWORD=$MONGO_ROOT_PASS
MONGO_APP_PASSWORD=$MONGO_APP_PASS

REDIS_PASSWORD=$REDIS_PASS

POSTGRES_USER=sharexpress
POSTGRES_PASSWORD=$POSTGRES_PASS

MINIO_ROOT_USER=sharexpress
MINIO_ROOT_PASSWORD=$MINIO_PASS
ENVEOF
  chmod 600 "$ENV_FILE"
  success "Passwords generated and saved to $ENV_FILE"
  echo ""
  echo -e "${YELLOW}━━━━ SAVE THESE CREDENTIALS ━━━━${NC}"
  echo "MongoDB Root:   $MONGO_ROOT_PASS"
  echo "MongoDB App:    $MONGO_APP_PASS"
  echo "Redis:          $REDIS_PASS"
  echo "PostgreSQL:     $POSTGRES_PASS"
  echo "MinIO:          $MINIO_PASS"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
else
  info ".env already exists at $ENV_FILE, using existing passwords."
fi

# ─── 5. Copy infra files to deployment dir ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Copying infra config files to $INFRA_DIR..."
cp "$SCRIPT_DIR/docker-compose.infra.yml" "$INFRA_DIR/"
cp "$SCRIPT_DIR/mongo-init.js" "$INFRA_DIR/"
success "Files copied to $INFRA_DIR"

# ─── 6. Start Docker Compose Stack ────────────────────────────────────────
info "Starting infrastructure containers (MongoDB, Redis, PostgreSQL, MinIO)..."
cd "$INFRA_DIR"
docker compose -f docker-compose.infra.yml --env-file "$ENV_FILE" pull
docker compose -f docker-compose.infra.yml --env-file "$ENV_FILE" up -d

echo ""
info "Waiting 30s for services to initialize..."
sleep 30

# Health checks
info "Running health checks..."
HEALTHY=0
TOTAL=4

# MongoDB
if docker exec sharexpress-mongodb mongosh --eval "db.adminCommand('ping')" --quiet &>/dev/null; then
  success "MongoDB ✅ healthy"
  ((HEALTHY++))
else
  warn "MongoDB ⚠️  not yet ready (may need more time)"
fi

# Redis
REDIS_PASS_VAL=$(grep REDIS_PASSWORD "$ENV_FILE" | cut -d= -f2)
if docker exec sharexpress-redis redis-cli --pass "$REDIS_PASS_VAL" ping | grep -q PONG; then
  success "Redis ✅ healthy"
  ((HEALTHY++))
else
  warn "Redis ⚠️  not yet ready"
fi

# PostgreSQL
PG_PASS_VAL=$(grep POSTGRES_PASSWORD "$ENV_FILE" | cut -d= -f2)
if docker exec sharexpress-postgres pg_isready -U sharexpress &>/dev/null; then
  success "PostgreSQL ✅ healthy"
  ((HEALTHY++))
else
  warn "PostgreSQL ⚠️  not yet ready"
fi

# MinIO
if curl -sf http://localhost:9000/minio/health/live &>/dev/null; then
  success "MinIO ✅ healthy (API :9000, Console :9001)"
  ((HEALTHY++))
else
  warn "MinIO ⚠️  not yet ready"
fi

echo ""
success "$HEALTHY/$TOTAL services healthy"

# ─── 7. Install k3s ───────────────────────────────────────────────────────
info "Installing k3s (lightweight Kubernetes)..."
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
  sleep 20
  success "k3s installed: $(k3s --version | head -1)"
else
  success "k3s already installed: $(k3s --version | head -1)"
fi

# Configure kubectl for the runner user
mkdir -p /home/$RUNNER_USER/.kube 2>/dev/null || true
cp /etc/rancher/k3s/k3s.yaml /home/$RUNNER_USER/.kube/config 2>/dev/null || true
chown "$RUNNER_USER:$RUNNER_USER" /home/$RUNNER_USER/.kube/config 2>/dev/null || true

# Also set for current session
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ─── 8. Install Helm ──────────────────────────────────────────────────────
info "Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm installed: $(helm version --short)"
else
  success "Helm already installed: $(helm version --short)"
fi

# ─── 9. Install Nginx Ingress Controller via Helm ─────────────────────────
info "Installing Nginx Ingress Controller in k3s..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --wait --timeout=3m || warn "Ingress controller install may still be starting"
success "Nginx Ingress Controller deployed"

# ─── 10. Apply k3s Manifests ──────────────────────────────────────────────
info "Applying k3s manifests..."
if [ -d "$SCRIPT_DIR/k3s" ]; then
  kubectl apply -f "$SCRIPT_DIR/k3s/namespace.yml"
  kubectl apply -f "$SCRIPT_DIR/k3s/api.yml"
  kubectl apply -f "$SCRIPT_DIR/k3s/frontend.yml"
  success "k3s manifests applied"
  echo ""
  kubectl get pods -A
else
  warn "k3s/ manifest directory not found at $SCRIPT_DIR/k3s"
fi

# ─── 11. GitHub Actions Runner ────────────────────────────────────────────
if [ -n "$RUNNER_TOKEN" ]; then
  info "Setting up GitHub Actions self-hosted runner..."
  if ! id "$RUNNER_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RUNNER_USER"
    usermod -aG docker "$RUNNER_USER"
  fi
  mkdir -p "$RUNNER_HOME"
  cd "$RUNNER_HOME"

  RUNNER_TAR="actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
  if [ ! -f "$RUNNER_TAR" ]; then
    curl -fsSL -o "$RUNNER_TAR" \
      "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$RUNNER_TAR"
    tar xzf "$RUNNER_TAR"
  fi

  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

  # Configure the runner
  sudo -u "$RUNNER_USER" bash -c "cd $RUNNER_HOME && ./config.sh \
    --url $GH_REPO_URL \
    --token $RUNNER_TOKEN \
    --name vps-$(hostname) \
    --labels self-hosted,vps,linux,x64 \
    --unattended \
    --replace"

  # Install and start as systemd service
  "$RUNNER_HOME/svc.sh" install "$RUNNER_USER" || true
  "$RUNNER_HOME/svc.sh" start || true
  success "GitHub Actions runner installed and started"
else
  warn "No runner token provided. Skipping runner setup."
  warn "Run: sudo bash setup-infra.sh <RUNNER_TOKEN>"
fi

# ─── Final Summary ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Infrastructure Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"
echo ""
echo "  📊 Service Status:"
echo "     docker ps                              # all containers"
echo "     kubectl get pods -A                    # k3s pods"
echo ""
echo "  🗄️  Databases (localhost only):"
echo "     MongoDB:    localhost:27017"
echo "     Redis:      localhost:6379"
echo "     PostgreSQL: localhost:5432"
echo ""
echo "  📦 MinIO Object Storage:"
echo "     API:     http://localhost:9000"
echo "     Console: http://localhost:9001"
echo ""
echo "  ☸️  Kubernetes:"
echo "     kubectl get nodes"
echo "     export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo ""
echo "  🔑 Credentials saved at: $ENV_FILE"
echo ""
