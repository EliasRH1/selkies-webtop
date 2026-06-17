#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

NOVNC_PORT="${NOVNC_PORT:-6080}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/novnc-data}"
COMPOSE_FILE="${COMPOSE_FILE:-$HOME/selkies-webtop/docker-compose.yml}"
NETWORK="novnc-net"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  noVNC Desktop + Cloudflare Tunnel${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── Docker ──────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  warn "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  log "Docker installed. Re-login or run 'newgrp docker'."
fi

mkdir -p "$CONFIG_DIR" "$(dirname "$COMPOSE_FILE")"

echo ""
read -rp "Cloudflare Tunnel token (dejar vacío para saltar): " CF_TOKEN

# ── docker-compose.yml ──────────────────────────────────────────────────────
cat > "$COMPOSE_FILE" <<EOF
services:
  novnc:
    image: dorowu/ubuntu-desktop-lxde-vnc:focal
    container_name: novnc
    restart: unless-stopped
    environment:
      - VNC_PASSWORD=  # opcional
      - RESOLUTION=1280x800
    ports:
      - "127.0.0.1:${NOVNC_PORT}:80"
    volumes:
      - ${CONFIG_DIR}:/root
    shm_size: "2gb"
    networks:
      - ${NETWORK}
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
      - ${NETWORK}
EOF
fi

cat >> "$COMPOSE_FILE" <<EOF

networks:
  ${NETWORK}:
    driver: bridge
EOF

log "docker-compose.yml creado en ${COMPOSE_FILE}"

log "Descargando imágenes..."
docker compose -f "$COMPOSE_FILE" pull

log "Iniciando servicios..."
docker compose -f "$COMPOSE_FILE" up -d

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Listo!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Local: http://localhost:${NOVNC_PORT}"
echo ""

if [ -n "$CF_TOKEN" ]; then
  echo "  Cloudflare Tunnel activo."
  echo "  → En Zero Trust dashboard, añade Public Hostname:"
  echo "    Service: http://novnc:80"
  echo "    (novnc se resuelve dentro de la red Docker)"
else
  echo "  Sin Cloudflare. Para añadirlo después:"
  echo "  1. Crea un tunnel en https://one.dash.cloudflare.com"
  echo " 2. Vuelve a ejecutar este script con el token"
fi
echo ""
echo "  Gestionar: docker compose -f ${COMPOSE_FILE} [up|down|logs|ps]"
echo ""
