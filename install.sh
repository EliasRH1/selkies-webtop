#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }

NOVNC_PORT=6080
VNC_PORT=5901
VNC_DISPLAY=:1
DEBIAN_FRONTEND=noninteractive
NEEDRESTART_MODE=a

sed -i 's/#\$nrconf{restart} = .i.;/\$nrconf{restart} = \"a\";/' /etc/needrestart/needrestart.conf 2>/dev/null || true

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  noVNC + KDE + Cloudflare${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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

log "Instalando KDE + noVNC + cloudflared..."
apt-get install -y -qq \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  kde-plasma-desktop plasma-workspace novnc dbus-x11 \
  --no-install-recommends

curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared 2>/dev/null
chmod +x /usr/local/bin/cloudflared

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

systemctl daemon-reload
systemctl enable vncserver novnc cloudflared
systemctl start vncserver novnc
sleep 3
systemctl start cloudflared
sleep 4

# ── Obtener URL ────────────────────────────────────────────────────────────
CF_URL=$(journalctl -u cloudflared -n 30 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)

# ── Fin ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Listo!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Local:${NC}  http://localhost:$NOVNC_PORT"
echo -e "  ${CYAN}Pass:${NC}   1234"
echo ""
if [ -n "$CF_URL" ]; then
  echo -e "  ${GREEN}URL pública:${NC}  $CF_URL"
else
  echo -e "  ${YELLOW}URL pública (en 5s):${NC}"
  echo "  journalctl -u cloudflared -n 30 | grep trycloudflare"
fi
echo ""
echo -e "  ${YELLOW}Comandos:${NC}"
echo "  systemctl restart cloudflared"
echo "  journalctl -u cloudflared -f"
echo ""
