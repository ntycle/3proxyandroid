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

# ... (giữ nguyên phần 1-3) ...

# ------------------------------------------------
# 4. Build 3proxy config - FIXED VERSION
# ------------------------------------------------
echo "[4/7] Building 3proxy config..."

# Start with basic config
cat > "$CFG_FILE" <<EOF
# ===== BASIC SETTINGS =====
nserver 8.8.8.8
nserver 1.1.1.1

maxconn 1000
nscache 65536

log /var/log/3proxy/3proxy.log D
rotate 30

archiver gz /usr/bin/gzip %F
counter /etc/3proxy/3proxy.3cf

users \$/etc/3proxy/passwd
auth strong

allow * * * 80-88,8080
allow * * * 443
allow * * * 9001-9100

timeouts 1 5 30 60 180 1800 15 60
EOF

# Create empty password file
> /etc/3proxy/passwd

PORT=$BASE_PORT
COUNT=0

echo "Processing proxy list..."

# Debug: show first few lines
echo "First 3 lines of proxy file:"
head -n 3 "$PROXY_FILE"

# Process proxy list
while IFS= read -r line || [[ -n "$line" ]]; do
  # Remove leading/trailing whitespace and carriage returns
  line=$(echo "$line" | tr -d '\r' | xargs)
  
  # Skip empty lines and comments
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue
  
  echo "Processing line: $line"
  
  # Try different formats
  # Format 1: ip:port:user:pass
  if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+):([^:]+):([^:]+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    p="${BASH_REMATCH[2]}"
    user="${BASH_REMATCH[3]}"
    pass="${BASH_REMATCH[4]}"
    
    echo "  Matched format: ip:port:user:pass"
    
  # Format 2: user:pass@ip:port (common format)
  elif [[ "$line" =~ ^([^:@]+):([^:@]+)@([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
    user="${BASH_REMATCH[1]}"
    pass="${BASH_REMATCH[2]}"
    ip="${BASH_REMATCH[3]}"
    p="${BASH_REMATCH[4]}"
    
    echo "  Matched format: user:pass@ip:port"
    
  # Format 3: ip:port (no auth)
  elif [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    p="${BASH_REMATCH[2]}"
    user="anonymous"
    pass="anonymous"
    
    echo "  Matched format: ip:port (no auth)"
  else
    echo "  Skipping - unrecognized format"
    continue
  fi
  
  if [[ -n "$ip" && -n "$p" ]]; then
    echo "  Adding proxy $COUNT: $user:***@$ip:$p -> local port $PORT"
    
    # Add to 3proxy config
    cat >> "$CFG_FILE" <<PROXYCONFIG

# ===== PROXY $((COUNT+1)) =====
allow $user
parent 1000 http $ip $p $user $pass
proxy -p$PORT -a
PROXYCONFIG
    
    # Add to password file (for auth strong)
    if [[ "$user" != "anonymous" ]]; then
      echo "$user:CL:$pass" >> /etc/3proxy/passwd
    fi
    
    ((COUNT++))
    ((PORT++))
  else
    echo "  Invalid proxy data"
  fi
  
done < "$PROXY_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies found in the list"
  echo "Current file content:"
  cat "$PROXY_FILE"
  echo ""
  echo "Supported formats:"
  echo "  1. ip:port:username:password"
  echo "  2. username:password@ip:port"
  echo "  3. ip:port"
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
  echo "  Port $p opened"
done
firewall-cmd --reload >/dev/null 2>&1 || true

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
systemctl stop "$SERVICE" >/dev/null 2>&1 || true
sleep 2
systemctl start "$SERVICE"

# Check status
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  echo "✅ Service is running"
else
  echo "⚠️  Service might have issues, checking logs..."
  journalctl -u "$SERVICE" -n 20 --no-pager
fi

echo ""
echo "======================================"
echo "✅ 3PROXY SETUP COMPLETED"
echo "======================================"
echo "Total proxies : $COUNT"
echo "Port range    : $BASE_PORT - $((BASE_PORT+COUNT-1))"
echo ""
echo "Check status: systemctl status $SERVICE"
echo "View logs:    journalctl -u $SERVICE -f"
echo ""
echo "Android setup:"
echo "  Proxy host : YOUR_VPS_IP"
echo "  Proxy port : $BASE_PORT (and up)"
echo "  No authentication needed"
echo ""
