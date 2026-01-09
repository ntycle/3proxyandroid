#!/bin/bash
set -e

# ================= CONFIG =================
PROXY_URL="https://raw.githubusercontent.com/ntycle/3proxyandroid/refs/heads/main/proxies.txt"
PROXY_FILE="/root/proxies.txt"
CFG_FILE="/etc/3proxy/3proxy.cfg"
BIN="/usr/local/bin/3proxy"
BASE_PORT=9001
MAX_PROXIES=10
SERVICE="3proxy"
# ==========================================

echo "=== 3PROXY MULTI-PORT SETUP ==="
echo "Mỗi port trên VPS forward đến 1 proxy upstream duy nhất"
echo "Tổng: $MAX_PROXIES port ($BASE_PORT đến $((BASE_PORT+MAX_PROXIES-1)))"
echo ""

# ------------------------------------------------
# 1. Check/Create config đơn giản
# ------------------------------------------------
echo "[1/6] Creating compatible 3proxy config..."

# Đọc proxy list
if [ ! -f "$PROXY_FILE" ]; then
  echo "❌ Proxy file not found: $PROXY_FILE"
  echo "Downloading..."
  curl -fsSL "$PROXY_URL" -o "$PROXY_FILE" || {
    echo "⚠️ Creating sample proxy file"
    cat > "$PROXY_FILE" <<EOF
103.82.25.188:19280:user19280:1765679342
EOF
  }
fi

# Đọc proxy list
mapfile -t PROXY_LIST < <(grep -v '^#' "$PROXY_FILE" | grep -v '^$' | head -$MAX_PROXIES)

if [ ${#PROXY_LIST[@]} -eq 0 ]; then
  echo "❌ No proxies found in $PROXY_FILE"
  exit 1
fi

echo "Found ${#PROXY_LIST[@]} proxies"

# ------------------------------------------------
# 2. Create SIMPLE config (compatible với old 3proxy)
# ------------------------------------------------
cat > "$CFG_FILE" <<EOF
# ===== 3PROXY CONFIG =====
# Generated: $(date)
# Total proxies: ${#PROXY_LIST[@]}

# Basic settings - OLD SYNTAX
nscache 65536
log /var/log/3proxy/3proxy.log D
rotate 30
auth none
allow * * *
EOF

# Add each proxy
for i in "${!PROXY_LIST[@]}"; do
  line="${PROXY_LIST[$i]}"
  line=$(echo "$line" | tr -d '\r' | xargs)
  
  if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+):([^:]+):(.+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    user="${BASH_REMATCH[3]}"
    pass="${BASH_REMATCH[4]}"
    
    current_port=$((BASE_PORT + i))
    
    # Add proxy với syntax cũ
    cat >> "$CFG_FILE" <<PROXYCONFIG

# === Port $current_port ===
parent 1000 http $ip $port $user $pass
proxy -p$current_port
flush
PROXYCONFIG
    
    echo "✓ Port $current_port → $ip:$port ($user)"
  fi
done

echo "Config saved to $CFG_FILE"

# ------------------------------------------------
# 3. Prepare folders
# ------------------------------------------------
echo "[2/6] Preparing folders..."
mkdir -p /etc/3proxy /var/log/3proxy
touch /var/log/3proxy/3proxy.log 2>/dev/null || true

# ------------------------------------------------
# 4. Test config syntax
# ------------------------------------------------
echo "[3/6] Testing config syntax..."
if ! "$BIN" "$CFG_FILE" -h 2>&1 | head -5; then
  echo "⚠️  3proxy syntax check failed, but continuing..."
fi

# ------------------------------------------------
# 5. Configure firewall
# ------------------------------------------------
echo "[4/6] Configuring firewall..."
systemctl enable firewalld --now 2>/dev/null || true

for i in "${!PROXY_LIST[@]}"; do
  current_port=$((BASE_PORT + i))
  firewall-cmd --add-port=${current_port}/tcp --permanent 2>/dev/null || true
  echo "  Port $current_port opened"
done

firewall-cmd --reload 2>/dev/null || true

# ------------------------------------------------
# 6. Create/Update systemd service
# ------------------------------------------------
echo "[5/6] Setting up systemd service..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3Proxy Multi-Port Proxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/3proxy
ExecStart=$BIN $CFG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ------------------------------------------------
# 7. Stop old instance và start new
# ------------------------------------------------
echo "[6/6] Starting 3proxy..."

# Kill any running 3proxy
pkill -f "3proxy" 2>/dev/null || true
sleep 2

# Start service
systemctl enable 3proxy 2>/dev/null || true
systemctl restart 3proxy

# Check if running
sleep 3
if systemctl is-active --quiet 3proxy; then
  echo "✅ 3proxy started successfully!"
  
  # Test first port
  echo "Testing port $BASE_PORT..."
  if timeout 5 curl -s -x http://127.0.0.1:$BASE_PORT https://api.ipify.org >/dev/null 2>&1; then
    echo "✅ Port $BASE_PORT is working!"
  else
    echo "⚠️  Port $BASE_PORT test failed, but service is running"
  fi
else
  echo "❌ 3proxy failed to start"
  echo "=== Last 10 lines of config ==="
  tail -n 10 "$CFG_FILE"
  echo "=== Trying to run manually for debug ==="
  timeout 3 "$BIN" "$CFG_FILE" || true
  exit 1
fi

# ================= OUTPUT =================
echo ""
echo "=========================================="
echo "✅ SETUP COMPLETED!"
echo "=========================================="
echo ""
echo "📱 ANDROID CONFIG:"
echo "------------------"
echo "Type: HTTP"
echo "Host: YOUR_VPS_IP"
echo "Ports: $BASE_PORT to $((BASE_PORT+${#PROXY_LIST[@]}-1))"
echo "No auth required"
echo ""
echo "🔗 ACTIVE PORTS:"
echo "----------------"
for i in "${!PROXY_LIST[@]}"; do
  current_port=$((BASE_PORT + i))
  echo "Port $current_port"
done
echo ""
echo "🛠️  COMMANDS:"
echo "-------------"
echo "Test all ports:"
for i in "${!PROXY_LIST[@]}"; do
  current_port=$((BASE_PORT + i))
  echo "  curl -x http://127.0.0.1:$current_port https://api.ipify.org"
done
echo ""
echo "systemctl status 3proxy"
echo "journalctl -u 3proxy -f"
