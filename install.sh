#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
DEBIAN_FRONTEND=noninteractive

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  noVNC + Cloudflare Tunnel (sin Docker)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── Sistema actualizado ───────────────────────────────────────────────────
log "Actualizando paquetes..."
apt-get update -qq && apt-get upgrade -y -qq

# ── Desktop + VNC + noVNC ─────────────────────────────────────────────────
log "Instalando XFCE desktop, VNC server y noVNC..."
apt-get install -y -qq \
  xfce4 xfce4-goodies \
  tigervnc-standalone-server \
  novnc python3-websockify \
  dbus-x11 x11-utils \
  curl

# ── Cloudflared ────────────────────────────────────────────────────────────
CF_TOKEN=""
read -rp "Cloudflare Tunnel token (vacío para saltar): " CF_TOKEN

if [ -n "$CF_TOKEN" ]; then
  log "Instalando cloudflared..."
  if ! command -v cloudflared &>/dev/null; then
    curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi
fi

# ── VNC password ───────────────────────────────────────────────────────────
VNC_PASS="${VNC_PASS:-}"
if [ -z "$VNC_PASS" ]; then
  read -sp "Contraseña VNC (dejar vacío = solo localhost): " VNC_PASS
  echo ""
fi

# ── Configurar VNC ─────────────────────────────────────────────────────────
mkdir -p "$HOME/.vnc"

cat > "$HOME/.vnc/config" <<EOF
session=xfce4-session
geometry=1280x800
depth=24
localhost
EOF

cat > "$HOME/.vnc/xstartup" <<'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
startxfce4 &
XEOF
chmod +x "$HOME/.vnc/xstartup"

# ── Iniciar VNC ───────────────────────────────────────────────────────────
log "Iniciando VNC server en display ${VNC_DISPLAY}..."
vncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
sleep 1

if [ -n "$VNC_PASS" ]; then
  echo "$VNC_PASS" | vncpasswd -f > "$HOME/.vnc/passwd"
  chmod 600 "$HOME/.vnc/passwd"
  vncserver "$VNC_DISPLAY" -geometry 1280x800 -depth 24 -localhost -PasswordFile "$HOME/.vnc/passwd"
else
  vncserver "$VNC_DISPLAY" -geometry 1280x800 -depth 24 -localhost
fi

# ── Iniciar noVNC ─────────────────────────────────────────────────────────
log "Iniciando noVNC proxy en puerto ${NOVNC_PORT}..."
pkill -f websockify 2>/dev/null || true
sleep 1

/usr/share/novnc/utils/novnc_proxy \
  --vnc localhost:${VNC_PORT} \
  --listen ${NOVNC_PORT} \
  &>/tmp/novnc.log &
sleep 2

# ── Crear systemd services ────────────────────────────────────────────────
log "Creando servicios systemd..."

# VNC service
cat > /etc/systemd/system/vncserver@.service <<UNIT
[Unit]
Description=VNC server en display %i
After=network.target

[Service]
Type=forking
User=$USER
ExecStart=/usr/bin/vncserver %i -geometry 1280x800 -depth 24 -localhost
ExecStop=/usr/bin/vncserver -kill %i
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

# noVNC service
cat > /etc/systemd/system/novnc.service <<UNIT
[Description]
Description=noVNC proxy

[Service]
Type=simple
User=$USER
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:${VNC_PORT} --listen ${NOVNC_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable vncserver@${VNC_DISPLAY#:} novnc

# ── Cloudflare Tunnel service ─────────────────────────────────────────────
if [ -n "$CF_TOKEN" ]; then
  log "Creando servicio cloudflared..."

  cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TOKEN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl start cloudflared
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Instalación completa!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  noVNC:  http://localhost:${NOVNC_PORT}"
echo ""

if [ -n "$CF_TOKEN" ]; then
  echo "  Cloudflare Tunnel activo."
  echo "  → En Zero Trust dashboard, añade Public Hostname:"
  echo "    Subdomain: elijes.tu Dominio: tudominio.com"
  echo "    Service:   http://localhost:${NOVNC_PORT}"
  echo "    Tipo:      HTTP"
fi
echo ""
echo "  Servicios:"
echo "    systemctl status vncserver@${VNC_DISPLAY#:}"
echo "    systemctl status novnc"
echo "    systemctl status cloudflared"
echo ""
