#!/bin/bash
set -e

# ================= CONFIG =================
PROXY_URL="https://raw.githubusercontent.com/ntycle/3proxyandroid/refs/heads/main/proxies.txt"
PROXY_FILE="/root/proxies.txt"
CFG_FILE="/etc/3proxy/3proxy.cfg"
BIN="/usr/local/bin/3proxy"
BASE_PORT=9001
MAX_PROXIES=10  # Số lượng proxy tối đa (cho 10 Android)
SERVICE="3proxy"
# ==========================================

echo "=== 3PROXY MULTI-PORT SETUP ==="
echo "Mỗi port trên VPS forward đến 1 proxy upstream duy nhất"
echo "Tổng: $MAX_PROXIES port ($BASE_PORT đến $((BASE_PORT+MAX_PROXIES-1)))"
echo ""

# ------------------------------------------------
# 1. Install 3proxy (nếu chưa có)
# ------------------------------------------------
if ! command -v 3proxy >/dev/null 2>&1; then
  echo "[1/6] Installing 3proxy..."
  dnf install -y gcc make git curl firewalld
  
  cd /opt
  git clone https://github.com/z3APA3A/3proxy.git 2>/dev/null || true
  cd 3proxy
  
  make -f Makefile.Linux
  mkdir -p /usr/local/bin
  cp bin/3proxy "$BIN"
  chmod +x "$BIN"
fi

# ------------------------------------------------
# 2. Prepare folders
# ------------------------------------------------
echo "[2/6] Preparing folders..."
mkdir -p /etc/3proxy /var/log/3proxy
touch /var/log/3proxy/3proxy.log
chmod 666 /var/log/3proxy/3proxy.log

# ------------------------------------------------
# 3. Update proxy list
# ------------------------------------------------
echo "[3/6] Updating proxy list..."
echo "Downloading from: $PROXY_URL"

if curl -fsSL "$PROXY_URL" -o "$PROXY_FILE.tmp"; then
  if [ -s "$PROXY_FILE.tmp" ]; then
    mv "$PROXY_FILE.tmp" "$PROXY_FILE"
    echo "✓ Downloaded $(wc -l < "$PROXY_FILE") proxies"
  else
    echo "❌ Downloaded file is empty"
    exit 1
  fi
else
  echo "❌ Failed to download proxy list"
  
  # Nếu download fail, dùng file cũ hoặc tạo sample
  if [ -f "$PROXY_FILE" ]; then
    echo "⚠️  Using existing proxy file"
  else
    echo "⚠️  Creating sample proxy file"
    cat > "$PROXY_FILE" <<EOF
# Format: ip:port:user:pass
# Mỗi dòng là 1 proxy upstream
103.82.25.188:19280:user19280:1765679342
45.77.123.45:8080:user2:pass2
104.238.123.45:3128:user3:pass3
138.68.123.45:8888:user4:pass4
207.148.123.45:8118:user5:pass5
139.180.123.45:8080:user6:pass6
167.71.123.45:3128:user7:pass7
165.227.123.45:8080:user8:pass8
68.183.123.45:8080:user9:pass9
206.189.123.45:3128:user10:pass10
EOF
    echo "✓ Created sample with 10 proxies"
  fi
fi

# ------------------------------------------------
# 4. Build 3proxy config - KEY PART!
# ------------------------------------------------
echo "[4/6] Building 3proxy config..."
echo "Creating $MAX_PROXIES ports ($BASE_PORT-$((BASE_PORT+MAX_PROXIES-1)))"

# Đọc tất cả proxies từ file
mapfile -t PROXY_LIST < <(grep -v '^#' "$PROXY_FILE" | grep -v '^$' | head -$MAX_PROXIES)

if [ ${#PROXY_LIST[@]} -eq 0 ]; then
  echo "❌ No valid proxies found in file"
  echo "First few lines:"
  head -n 5 "$PROXY_FILE"
  exit 1
fi

echo "Found ${#PROXY_LIST[@]} proxies to use"

# Tạo config file mới
cat > "$CFG_FILE" <<EOF
# ===== 3PROXY CONFIG =====
# Generated: $(date)
# Total proxies: ${#PROXY_LIST[@]}
# Port range: $BASE_PORT-$((BASE_PORT+${#PROXY_LIST[@]}-1))

daemon
maxconn 50  # Giới hạn connection mỗi proxy
nscache 65536
log /var/log/3proxy/3proxy.log D
rotate 30

# Client không cần auth
auth none
allow *

timeouts 1 5 30 60 180 1800 15 60
EOF

# Thêm từng proxy vào config
for i in "${!PROXY_LIST[@]}"; do
  line="${PROXY_LIST[$i]}"
  line=$(echo "$line" | tr -d '\r' | xargs)
  
  if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+):([^:]+):(.+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    user="${BASH_REMATCH[3]}"
    pass="${BASH_REMATCH[4]}"
    
    current_port=$((BASE_PORT + i))
    
    # THÊM VÀO CONFIG - MỖI PORT LÀ 1 PROXY ĐỘC LẬP
    cat >> "$CFG_FILE" <<PROXYCONFIG

# === PORT $current_port ===
# Upstream: $ip:$port ($user)
parent 1000 http $ip $port $user $pass
proxy -p$current_port
flush
PROXYCONFIG
    
    echo "✓ Port $current_port → $ip:$port ($user)"
  else
    echo "⚠️  Skipping invalid line: $line"
  fi
done

# ------------------------------------------------
# 5. Configure firewall
# ------------------------------------------------
echo "[5/6] Configuring firewall..."
systemctl enable firewalld --now 2>/dev/null || true

# Mở port trên firewall
for ((p=BASE_PORT; p<BASE_PORT+${#PROXY_LIST[@]}; p++)); do
  firewall-cmd --add-port=${p}/tcp --permanent 2>/dev/null || true
done
firewall-cmd --reload 2>/dev/null || true

# ------------------------------------------------
# 6. Restart service
# ------------------------------------------------
echo "[6/6] Restarting 3proxy service..."

# Tạo systemd service nếu chưa có
if [ ! -f /etc/systemd/system/3proxy.service ]; then
  cat > /etc/systemd/system/3proxy.service <<SERVICE_EOF
[Unit]
Description=3Proxy Multi-Port Proxy Server
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
SERVICE_EOF
  
  systemctl daemon-reload
fi

# Khởi động service
systemctl enable 3proxy 2>/dev/null || true
systemctl restart 3proxy

# Kiểm tra
sleep 2
if systemctl is-active --quiet 3proxy; then
  echo "✅ 3proxy is running!"
else
  echo "❌ 3proxy failed to start"
  journalctl -u 3proxy -n 20 --no-pager
  exit 1
fi

# ================= FINAL OUTPUT =================
echo ""
echo "=========================================="
echo "✅ SETUP COMPLETED SUCCESSFULLY!"
echo "=========================================="
echo ""
echo "📱 ANDROID CONFIGURATION:"
echo "--------------------------"
echo "Proxy type: HTTP"
echo "Proxy host: YOUR_VPS_IP"
echo "Proxy port: $BASE_PORT to $((BASE_PORT+${#PROXY_LIST[@]}-1))"
echo "No username/password required"
echo ""
echo "🔗 PORT MAPPING:"
echo "----------------"
for i in "${!PROXY_LIST[@]}"; do
  line="${PROXY_LIST[$i]}"
  if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+):([^:]+):(.+)$ ]]; then
    ip="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    user="${BASH_REMATCH[3]}"
    current_port=$((BASE_PORT + i))
    
    echo "Port $current_port → $ip:$port (user: $user)"
  fi
done
echo ""
echo "🛠️  MANAGEMENT:"
echo "---------------"
echo "Check status:  systemctl status 3proxy"
echo "View logs:     journalctl -u 3proxy -f"
echo "Restart:       systemctl restart 3proxy"
echo "Update proxies: Run this script again"
echo ""
echo "🌐 TEST COMMANDS:"
echo "-----------------"
echo "# Test từng port:"
for i in "${!PROXY_LIST[@]}"; do
  current_port=$((BASE_PORT + i))
  echo "curl -x http://127.0.0.1:$current_port https://api.ipify.org"
done
echo ""
