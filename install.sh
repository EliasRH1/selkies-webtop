#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

NOVNC_PORT=6080
VNC_PORT=5901
VNC_DISPLAY=:1
DEBIAN_FRONTEND=noninteractive
NEEDRESTART_MODE=a

sed -i 's/#\$nrconf{restart} = .i.;/\$nrconf{restart} = \"a\";/' /etc/needrestart/needrestart.conf 2>/dev/null || true

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  noVNC + KDE + Cloudflare${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── Elegir tipo de tunnel ──────────────────────────────────────────────────
echo ""
echo "Elige tipo de Cloudflare Tunnel:"
echo "  1) Quick Tunnel (gratis, sin registro, URL aleatoria trycloudflare.com)"
echo "  2) Tunnel con token (dominio propio en Cloudflare)"
echo "  3) Sin Cloudflare (solo local)"
echo ""
read -rp "Opción [1-3]: " CF_OPTION

CF_TOKEN=""
CF_QUICK=""
case "$CF_OPTION" in
  2) read -rp "Pega tu Cloudflare Tunnel token: " CF_TOKEN ;;
  1) CF_QUICK=1 ;;
esac

# ── Paquetes ───────────────────────────────────────────────────────────────
log "Actualizando..."
apt-get update -qq

log "Instalando TigerVNC..."
apt-get install -y -qq tigervnc-standalone-server --no-install-recommends

mkdir -p "$HOME/.vnc"
cat > "$HOME/.vnc/xstartup" <<'EOF'
#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
startplasma-x11 &
EOF
chmod +x "$HOME/.vnc/xstartup"

printf '1234\n1234\n' | vncpasswd "$HOME/.vnc/passwd" >/dev/null 2>&1 || true
chmod 600 "$HOME/.vnc/passwd"

log "Instalando KDE + noVNC..."
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  kde-plasma-desktop plasma-workspace novnc dbus-x11 \
  --no-install-recommends

# ── Cloudflared ────────────────────────────────────────────────────────────
if [ -n "$CF_TOKEN" ] || [ -n "$CF_QUICK" ]; then
  log "Instalando cloudflared..."
  curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared 2>/dev/null
  chmod +x /usr/local/bin/cloudflared
fi

# ── Iniciar servicios ──────────────────────────────────────────────────────
vncserver -kill "$VNC_DISPLAY" 2>/dev/null || true
sleep 1
vncserver "$VNC_DISPLAY" -geometry 1280x800 -depth 24 -localhost -PasswordFile "$HOME/.vnc/passwd"
sleep 2

pkill -f websockify 2>/dev/null || true
sleep 1
/usr/share/novnc/utils/novnc_proxy \
  --vnc localhost:$VNC_PORT \
  --listen $NOVNC_PORT &>/tmp/novnc.log &
sleep 2

# ── Systemd ────────────────────────────────────────────────────────────────
cat > /etc/systemd/system/vncserver.service <<UNIT
[Unit]
Description=VNC Server
After=network.target

[Service]
Type=forking
User=$USER
ExecStartPre=/usr/bin/vncserver -kill $VNC_DISPLAY
ExecStart=/usr/bin/vncserver $VNC_DISPLAY -geometry 1280x800 -depth 24 -localhost -PasswordFile $HOME/.vnc/passwd
ExecStop=/usr/bin/vncserver -kill $VNC_DISPLAY
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/novnc.service <<UNIT
[Unit]
Description=noVNC Proxy
After=vncserver.service

[Service]
Type=simple
User=$USER
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable vncserver novnc

# ── Cloudflare service ─────────────────────────────────────────────────────
if [ -n "$CF_TOKEN" ]; then
  cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=Cloudflare Tunnel (token)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $CF_TOKEN
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable cloudflared
  systemctl start cloudflared
fi

if [ -n "$CF_QUICK" ]; then
  cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=Cloudflare Quick Tunnel
After=novnc.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:$NOVNC_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable cloudflared
  systemctl start cloudflared
  sleep 3
  # Obtener URL del tunnel
  CF_URL=$(journalctl -u cloudflared -n 20 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 || true)
fi

# ── Fin ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Listo!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Local:${NC}  http://localhost:$NOVNC_PORT"
echo -e "  ${CYAN}Pass:${NC}   1234"
echo ""
if [ -n "$CF_TOKEN" ]; then
  echo "  Cloudflare Tunnel (token) activo."
  echo "  → Crea un Public Hostname HTTP -> http://localhost:$NOVNC_PORT"
fi
if [ -n "$CF_QUICK" ]; then
  echo -e "  ${GREEN}Cloudflare Quick Tunnel activo!${NC}"
  if [ -n "$CF_URL" ]; then
    echo -e "  ${CYAN}URL pública:${NC} $CF_URL"
  else
    echo "  Revisa la URL con: journalctl -u cloudflared -n 20 | grep trycloudflare"
  fi
fi
echo ""
echo -e "  ${YELLOW}Comandos:${NC}"
echo "  systemctl restart vncserver"
echo "  systemctl restart novnc"
echo "  systemctl restart cloudflared"
echo ""
