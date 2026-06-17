#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

WEBTOP_IMAGE="${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:latest}"
WEBTOP_PORT="${WEBTOP_PORT:-3000}"
WEBTOP_HTTPS_PORT="${WEBTOP_HTTPS_PORT:-3001}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/webtop-config}"
COMPOSE_FILE="${COMPOSE_FILE:-$HOME/selkies-webtop/docker-compose.yml}"
NETWORK_NAME="selkies-net"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Selkies Webtop + Cloudflare Tunnel${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── Docker ──────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  warn "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  log "Docker installed. Re-login or 'newgrp docker' to use without sudo."
fi

# ── Create directories ──────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR" "$(dirname "$COMPOSE_FILE")"

# ── Cloudflare token ────────────────────────────────────────────────────────
CF_TOKEN=""
echo ""
read -rp "Enter your Cloudflare Tunnel token (leave empty to skip): " CF_TOKEN

# ── Write docker-compose.yml ────────────────────────────────────────────────
cat > "$COMPOSE_FILE" <<EOF
services:
  webtop:
    image: ${WEBTOP_IMAGE}
    container_name: webtop
    restart: unless-stopped
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
      - TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
      - CUSTOM_USER=  # set these for basic auth
      - PASSWORD=
    ports:
      - "127.0.0.1:${WEBTOP_PORT}:3000"
      - "127.0.0.1:${WEBTOP_HTTPS_PORT}:3001"
    volumes:
      - ${CONFIG_DIR}:/config
    shm_size: "2gb"
    networks:
      - ${NETWORK_NAME}
EOF

if [ -n "$CF_TOKEN" ]; then
  cat >> "$COMPOSE_FILE" <<EOF

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CF_TOKEN}
    networks:
      - ${NETWORK_NAME}
EOF
fi

cat >> "$COMPOSE_FILE" <<EOF

networks:
  ${NETWORK_NAME}:
    driver: bridge
EOF

log "docker-compose.yml written to ${COMPOSE_FILE}"

# ── Pull & start ────────────────────────────────────────────────────────────
log "Pulling images..."
docker compose -f "$COMPOSE_FILE" pull

log "Starting services..."
docker compose -f "$COMPOSE_FILE" up -d

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Local HTTP:   http://localhost:${WEBTOP_PORT}"
echo "  Local HTTPS:  https://localhost:${WEBTOP_HTTPS_PORT}"
echo ""

if [ -n "$CF_TOKEN" ]; then
  echo "  Cloudflare Tunnel is active."
  echo ""
  echo "  → In Cloudflare Zero Trust dashboard, add a Public Hostname:"
  echo "    Service: http://webtop:3000"
  echo ""
  echo "  The 'webtop' hostname resolves inside the Docker network."
else
  echo "  No Cloudflare token provided."
  echo "  To add a tunnel later, get a token from Cloudflare Zero Trust"
  echo "  (Networks → Tunnels → Create) and re-run this script."
fi
echo ""
echo "  Manage:  docker compose -f ${COMPOSE_FILE} [up|down|logs|ps]"
echo "  Config:  ${CONFIG_DIR}"
echo ""
