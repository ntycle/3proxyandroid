#!/bin/bash
set -e

echo "=== SETUP 3PROXY ROUND-ROBIN V2.1 (ALMALINUX 8) ==="

PROXY_FILE="/root/proxies.txt"
CFG_FILE="/etc/3proxy/3proxy.cfg"
BIN="/usr/local/bin/3proxy"
SERVICE="3proxy"

# -----------------------------
# 1. Install build tools
# -----------------------------
echo "[1/7] Installing build tools..."
dnf install -y gcc make git net-tools firewalld

# -----------------------------
# 2. Build 3proxy
# -----------------------------
echo "[2/7] Building 3proxy..."
cd /opt
if [ ! -d "3proxy" ]; then
  git clone https://github.com/z3APA3A/3proxy.git
fi
cd 3proxy
make -f Makefile.Linux
cp -f bin/3proxy "$BIN"

# -----------------------------
# 3. Prepare directories
# -----------------------------
echo "[3/7] Preparing folders..."
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy

# -----------------------------
# 4. Prepare proxy file (can be empty)
# -----------------------------
if [ ! -f "$PROXY_FILE" ]; then
  echo "⚠️ $PROXY_FILE not found – creating empty list"
  touch "$PROXY_FILE"
fi

# -----------------------------
# 5. Generate base config
# -----------------------------
echo "[4/7] Generating base 3proxy config..."

cat > "$CFG_FILE" <<EOF
daemon
maxconn 1000
nscache 65536

log /var/log/3proxy/3proxy.log D
rotate 30

# Android không cần auth
auth none

timeouts 1 5 30 60 180 1800 15 60

# ===== PARENT PROXIES (ROUND-ROBIN) =====
EOF

COUNT=0
while IFS=: read -r ip port user pass; do
  if [[ -n "\$ip" && -n "\$port" && -n "\$user" && -n "\$pass" ]]; then
    echo "parent 1000 http \$user \$pass \$ip \$port" >> "$CFG_FILE"
    ((COUNT++))
  fi
done < "$PROXY_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "# (no parent proxies yet)" >> "$CFG_FILE"
fi

cat >> "$CFG_FILE" <<EOF

# ===== LOCAL PROXY FOR ANDROID =====
proxy -p8888 -a
EOF

echo "✓ Base config created ($COUNT parents)"

# -----------------------------
# 6. Firewall
# -----------------------------
echo "[5/7] Opening firewall..."
systemctl enable firewalld --now
firewall-cmd --add-port=8888/tcp --permanent
firewall-cmd --reload

# -----------------------------
# 7. systemd service
# -----------------------------
echo "[6/7] Creating systemd service..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN $CFG_FILE
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo ""
echo "======================================"
echo "✅ 3PROXY V2.1 INSTALLED"
echo "======================================"
echo "Android set proxy to:"
echo "  VPS_IP:8888"
echo "--------------------------------------"
echo "When ready, run:"
echo "  /root/update_proxies.sh"
echo ""
