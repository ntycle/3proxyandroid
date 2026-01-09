#!/bin/bash
set -e

# ================= CONFIG =================
PROXY_URL="https://raw.githubusercontent.com/ntycle/3proxyandroid/refs/heads/main/proxies.txt"
PROXY_FILE="/root/proxies.txt"
CFG_FILE="/etc/3proxy/3proxy.cfg"
BIN="/usr/local/bin/3proxy"
BASE_PORT=9001
SERVICE="3proxy"
# ==========================================

echo "=== 3PROXY FINAL SETUP (NO DAEMON ISSUE) ==="

# ------------------------------------------------
# 1. Install deps + 3proxy (if not exists)
# ------------------------------------------------
if ! command -v 3proxy >/dev/null 2>&1; then
  echo "[1/7] Installing 3proxy..."
  dnf install -y gcc make git firewalld curl

  cd /opt
  if [ ! -d "3proxy" ]; then
    git clone https://github.com/z3APA3A/3proxy.git
  fi
  cd 3proxy
  make -f Makefile.Linux
  cp bin/3proxy "$BIN"
fi

# ------------------------------------------------
# 2. Prepare folders
# ------------------------------------------------
echo "[2/7] Preparing folders..."
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy

# ------------------------------------------------
# 3. Update proxy list
# ------------------------------------------------
echo "[3/7] Updating proxy list..."
curl -fsSL "$PROXY_URL" -o "$PROXY_FILE.tmp"

if [ ! -s "$PROXY_FILE.tmp" ]; then
  echo "❌ Proxy list download failed"
  exit 1
fi

cp -f "$PROXY_FILE" "$PROXY_FILE.bak.$(date +%F_%H%M%S)" 2>/dev/null || true
mv "$PROXY_FILE.tmp" "$PROXY_FILE"
echo "✓ Proxy list updated"

# ------------------------------------------------
# 4. Build 3proxy config
# ------------------------------------------------
echo "[4/7] Building 3proxy config..."

cat > "$CFG_FILE" <<EOF
# ===== BASIC SETTINGS =====
maxconn 1000
nscache 65536

log /var/log/3proxy/3proxy.log D
rotate 30

auth none
allow *

timeouts 1 5 30 60 180 1800 15 60
EOF

PORT=$BASE_PORT
COUNT=0

while IFS=: read -r ip p user pass; do
  if [[ -n "$ip" && -n "$p" && -n "$user" && -n "$pass" ]]; then
    echo "" >> "$CFG_FILE"
    echo "# ===== PROXY $((COUNT+1)) =====" >> "$CFG_FILE"
    echo "parent 1000 http $user $pass $ip $p" >> "$CFG_FILE"
    echo "proxy -p$PORT -a" >> "$CFG_FILE"
    ((COUNT++))
    ((PORT++))
  fi
done < "$PROXY_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies found"
  exit 1
fi

echo "✓ Generated config with $COUNT proxies"
echo "  Port range: $BASE_PORT → $((BASE_PORT+COUNT-1))"

# ------------------------------------------------
# 5. Firewall
# ------------------------------------------------
echo "[5/7] Opening firewall..."
systemctl enable firewalld --now >/dev/null 2>&1 || true

for ((p=BASE_PORT; p<BASE_PORT+COUNT; p++)); do
  firewall-cmd --add-port=${p}/tcp --permanent >/dev/null 2>&1 || true
done
firewall-cmd --reload >/dev/null

# ------------------------------------------------
# 6. systemd service (NO DAEMON)
# ------------------------------------------------
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
systemctl enable "$SERVICE"

# ------------------------------------------------
# 7. Restart service
# ------------------------------------------------
echo "[7/7] Restarting 3proxy..."
systemctl restart "$SERVICE"

echo ""
echo "======================================"
echo "✅ 3PROXY SETUP COMPLETED"
echo "======================================"
echo "Total proxies : $COUNT"
echo "Port range    : $BASE_PORT - $((BASE_PORT+COUNT-1))"
echo ""
echo "Android setup:"
echo "  Proxy host : VPS_IP"
echo "  Proxy port : 9001 ~"
echo "  (mỗi port = 1 proxy)"
echo ""
