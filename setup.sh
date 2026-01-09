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
# 4. Build 3proxy config
# ------------------------------------------------
echo "[4/7] Building 3proxy config..."

# Start with basic config
cat > "$CFG_FILE" <<EOF
# ===== BASIC SETTINGS =====
maxconn 1000
nscache 65536

log /var/log/3proxy/3proxy.log D
rotate 30

auth none
allow *

timeouts 1 5 30 60 180 1800 15 60

users \$/etc/3proxy/passwd
EOF

# Create empty password file
touch /etc/3proxy/passwd

PORT=$BASE_PORT
COUNT=0

# Process proxy list
while IFS= read -r line || [[ -n "$line" ]]; do
  # Remove leading/trailing whitespace
  line=$(echo "$line" | xargs)
  
  # Skip empty lines and comments
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue
  
  # Parse ip:port:user:pass format
  ip=$(echo "$line" | cut -d: -f1)
  p=$(echo "$line" | cut -d: -f2)
  user=$(echo "$line" | cut -d: -f3)
  pass=$(echo "$line" | cut -d: -f4)
  
  if [[ -n "$ip" && -n "$p" && -n "$user" && -n "$pass" ]]; then
    echo "" >> "$CFG_FILE"
    echo "# ===== PROXY $((COUNT+1)) =====" >> "$CFG_FILE"
    echo "parent 1000 http $ip $p $user $pass" >> "$CFG_FILE"
    echo "proxy -p$PORT" >> "$CFG_FILE"
    echo "flush" >> "$CFG_FILE"
    
    # Add to password file
    echo "$user:CL:$pass" >> /etc/3proxy/passwd
    
    ((COUNT++))
    ((PORT++))
  fi
done < "$PROXY_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies found in the list"
  echo "Sample format required: ip:port:username:password"
  exit 1
fi

echo "✓ Generated config with $COUNT proxies"
echo "  Port range: $BASE_PORT → $((BASE_PORT+COUNT-1))"

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
