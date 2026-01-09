#!/bin/bash
set -e

echo "=== SETUP 3PROXY ROUND-ROBIN V2 (ALMALINUX 8) ==="

PORT=8888
PROXY_FILE="/root/proxies.txt"
CFG_DIR="/etc/3proxy"
CFG_FILE="$CFG_DIR/3proxy.cfg"
BIN="/usr/local/bin/3proxy"
LOG_DIR="/var/log/3proxy"

# -----------------------------
# 0. Pre-check
# -----------------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run as root"
  exit 1
fi

if [ ! -f "$PROXY_FILE" ]; then
  echo "❌ $PROXY_FILE not found!"
  echo "Create it with format: ip:port:user:pass"
  exit 1
fi

# -----------------------------
# 1. Install deps
# -----------------------------
echo "[1/8] Installing dependencies..."
dnf install -y gcc make git net-tools firewalld

# -----------------------------
# 2. Build 3proxy
# -----------------------------
echo "[2/8] Building 3proxy..."
cd /opt
if [ ! -d "3proxy" ]; then
  git clone https://github.com/z3APA3A/3proxy.git
fi
cd 3proxy
make -f Makefile.Linux
cp bin/3proxy $BIN
chmod +x $BIN

# -----------------------------
# 3. Prepare folders
# -----------------------------
echo "[3/8] Preparing folders..."
mkdir -p $CFG_DIR
mkdir -p $LOG_DIR
touch $LOG_DIR/3proxy.log

# -----------------------------
# 4. Generate config
# -----------------------------
echo "[4/8] Generating config..."

cat > $CFG_FILE <<EOF
daemon
maxconn 1000
nscache 65536
cache 0

log $LOG_DIR/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%R -> %r"
rotate 30

# Android không cần auth
auth none
allow *

timeouts 1 5 30 60 180 1800 15 60

# ===== PARENT PROXIES (ROUND-ROBIN) =====
EOF

COUNT=0
while IFS=: read -r ip port user pass; do
  if [[ -n "$ip" && -n "$port" && -n "$user" && -n "$pass" ]]; then
    echo "parent 1000 http $user $pass $ip $port" >> $CFG_FILE
    ((COUNT++))
  fi
done < $PROXY_FILE

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies loaded"
  exit 1
fi

cat >> $CFG_FILE <<EOF

# ===== LOCAL PROXY FOR ANDROID =====
proxy -p$PORT -a
EOF

echo "✓ Loaded $COUNT parent proxies"

# -----------------------------
# 5. Firewall
# -----------------------------
echo "[5/8] Opening firewall port $PORT..."
systemctl enable firewalld --now
firewall-cmd --add-port=$PORT/tcp --permanent
firewall-cmd --reload

# -----------------------------
# 6. systemd service
# -----------------------------
echo "[6/8] Creating systemd service..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN $CFG_FILE
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

# -----------------------------
# 7. Test local
# -----------------------------
echo "[7/8] Quick test (local)..."
sleep 2
curl -s -x http://127.0.0.1:$PORT https://api.ipify.org || true
echo ""

# -----------------------------
# 8. Done
# -----------------------------
echo "======================================"
echo "✅ 3PROXY V2 INSTALLED & RUNNING"
echo "======================================"
echo "Port for Android: $PORT"
echo "Set Android proxy to:"
echo "  VPS_IP:$PORT"
echo ""
echo "Useful commands:"
echo "  systemctl status 3proxy"
echo "  systemctl restart 3proxy"
echo "  tail -f $LOG_DIR/3proxy.log"
echo "======================================"
