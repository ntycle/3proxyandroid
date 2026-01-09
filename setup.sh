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

echo "=== 3PROXY FINAL SETUP ==="

# ------------------------------------------------
# 1. Install deps + 3proxy (if not exists)
# ------------------------------------------------
if ! command -v 3proxy >/dev/null 2>&1; then
  echo "[1/7] Installing 3proxy..."
  dnf install -y gcc make git firewalld curl tar
  
  # Install dependencies for CentOS/RHEL 8+
  dnf groupinstall -y "Development Tools"
  
  cd /opt
  if [ ! -d "3proxy" ]; then
    git clone https://github.com/z3APA3A/3proxy.git
  fi
  cd 3proxy
  
  # Fix for newer systems
  sed -i 's/-m64//g' Makefile.Linux
  sed -i 's/-march=i686//g' Makefile.Linux
  
  make -f Makefile.Linux
  mkdir -p /usr/local/bin
  cp bin/3proxy "$BIN"
  chmod +x "$BIN"
fi

# ------------------------------------------------
# 2. Prepare folders
# ------------------------------------------------
echo "[2/7] Preparing folders..."
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy
touch /var/log/3proxy/3proxy.log
chmod 666 /var/log/3proxy/3proxy.log

# ------------------------------------------------
# 3. Update proxy list
# ------------------------------------------------
echo "[3/7] Updating proxy list..."
curl -fsSL "$PROXY_URL" -o "$PROXY_FILE.tmp" || {
  echo "❌ Proxy list download failed"
  exit 1
}

if [ ! -s "$PROXY_FILE.tmp" ]; then
  echo "❌ Proxy list is empty"
  exit 1
fi

# Backup if exists
if [ -f "$PROXY_FILE" ]; then
  cp -f "$PROXY_FILE" "$PROXY_FILE.bak.$(date +%F_%H%M%S)"
fi

mv "$PROXY_FILE.tmp" "$PROXY_FILE"
echo "✓ Proxy list updated ($(wc -l < "$PROXY_FILE") lines)"

# ------------------------------------------------
# 4. Build 3proxy config - CORRECTED
# ------------------------------------------------
echo "[4/7] Building 3proxy config..."

# Start with basic config
cat > "$CFG_FILE" <<EOF
# ===== BASIC SETTINGS =====
nserver 8.8.8.8
nserver 1.1.1.1

maxconn 100
nscache 65536

log /var/log/3proxy/3proxy.log D
rotate 30

users \$/etc/3proxy/passwd
auth strong

allow * * * 80-88,8080
allow * * * 443
allow * * * 9001-9100

timeouts 1 5 30 60 180 1800 15 60
EOF

# Create/clear password file
> /etc/3proxy/passwd

PORT=$BASE_PORT
COUNT=0

echo "Processing proxy list..."

# Process proxy list - FIXED: reading from PROXY_FILE not CFG_FILE
while IFS= read -r line || [[ -n "$line" ]]; do
  # Remove leading/trailing whitespace and carriage returns
  line=$(echo "$line" | tr -d '\r' | xargs)
  
  # Skip empty lines and comments
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue
  
  echo "Processing: $line"
  
  # Parse ip:port:user:pass format
  if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+):([^:]+):(.+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    user="${BASH_REMATCH[3]}"
    pass="${BASH_REMATCH[4]}"
    
    echo "  ✓ Valid proxy: $user:***@$ip:$port -> local port $PORT"
    
    # Add to 3proxy config
    cat >> "$CFG_FILE" <<PROXYCONFIG

# ===== PROXY $((COUNT+1)) [$ip:$port] =====
allow $user
parent 1000 http $ip $port $user $pass
proxy -p$PORT -a
flush
PROXYCONFIG
    
    # Add to password file
    echo "$user:CL:$pass" >> /etc/3proxy/passwd
    
    ((COUNT++))
    ((PORT++))
  else
    echo "  ✗ Skipping - invalid format"
  fi
  
done < "$PROXY_FILE"  # <-- ĐÃ SỬA: "$PROXY_FILE" thay vì "$CFG_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies found!"
  exit 1
fi

echo "✓ Generated config with $COUNT proxies"
echo "✓ Port range: $BASE_PORT → $((BASE_PORT+COUNT-1))"

# ------------------------------------------------
# 5. Firewall
# ------------------------------------------------
echo "[5/7] Configuring firewall..."
systemctl enable firewalld --now >/dev/null 2>&1 || true
systemctl start firewalld >/dev/null 2>&1 || true

# Add firewall rules
for ((p=BASE_PORT; p<BASE_PORT+COUNT; p++)); do
  firewall-cmd --add-port=${p}/tcp --permanent >/dev/null 2>&1 || true
done
firewall-cmd --reload >/dev/null 2>&1 || true

echo "✓ Opened ports $BASE_PORT-$((BASE_PORT+COUNT-1))"

# ------------------------------------------------
# 6. systemd service
# ------------------------------------------------
echo "[6/7] Creating systemd service..."

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3Proxy Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/3proxy
ExecStart=$BIN $CFG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1

# ------------------------------------------------
# 7. Restart service
# ------------------------------------------------
echo "[7/7] Starting 3proxy..."

# Kill any existing 3proxy processes
pkill -f "3proxy" || true
sleep 2

# Start service
systemctl restart "$SERVICE"

# Check status
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  echo "✅ Service is running successfully!"
  
  # Show listening ports
  echo "Listening ports:"
  ss -tlnp | grep 3proxy || netstat -tlnp | grep 3proxy || echo "  (check with: ss -tlnp | grep 9001)"
else
  echo "❌ Service failed to start!"
  echo "=== Checking logs ==="
  journalctl -u "$SERVICE" -n 30 --no-pager
  exit 1
fi

echo ""
echo "======================================"
echo "✅ 3PROXY SETUP COMPLETED SUCCESSFULLY"
echo "======================================"
echo "Total proxies : $COUNT"
echo "Port range    : $BASE_PORT - $((BASE_PORT+COUNT-1))"
echo ""
echo "Usage:"
echo "  HTTP Proxy: http://YOUR_VPS_IP:9001"
echo "  (each port is a different upstream proxy)"
echo ""
echo "Commands:"
echo "  Check status: systemctl status $SERVICE"
echo "  View logs:    journalctl -u $SERVICE -f"
echo ""
