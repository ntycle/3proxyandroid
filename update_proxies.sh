#!/bin/bash
set -e

URL="https://raw.githubusercontent.com/ntycle/3proxyandroid/refs/heads/main/proxies.txt"
PROXY_FILE="/root/proxies.txt"
CFG_FILE="/etc/3proxy/3proxy.cfg"
SERVICE="3proxy"

echo "=== UPDATE REAL PROXIES ==="

# -----------------------------
# 1. Download
# -----------------------------
echo "[1/4] Fetching proxy list..."
curl -fsSL "$URL" -o "$PROXY_FILE.tmp"

if [ ! -s "$PROXY_FILE.tmp" ]; then
  echo "❌ Download failed or empty file"
  exit 1
fi

# -----------------------------
# 2. Backup old list
# -----------------------------
cp -f "$PROXY_FILE" "$PROXY_FILE.bak.$(date +%F_%H%M%S)" 2>/dev/null || true
mv "$PROXY_FILE.tmp" "$PROXY_FILE"
echo "✓ Proxy list updated"

# -----------------------------
# 3. Rebuild config
# -----------------------------
echo "[2/4] Rebuilding 3proxy config..."

TMP_CFG="/tmp/3proxy_new.cfg"

awk '
BEGIN { in_parent=0 }
/^# ===== PARENT PROXIES/ {
  print
  in_parent=1
  next
}
/^# ===== LOCAL PROXY/ {
  in_parent=0
}
!in_parent { print }
END {
  print ""
  print "# ===== PARENT PROXIES (ROUND-ROBIN) ====="
}
' "$CFG_FILE" > "$TMP_CFG"

COUNT=0
while IFS=: read -r ip port user pass; do
  if [[ -n "$ip" && -n "$port" && -n "$user" && -n "$pass" ]]; then
    echo "parent 1000 http $user $pass $ip $port" >> "$TMP_CFG"
    ((COUNT++))
  fi
done < "$PROXY_FILE"

if [ "$COUNT" -eq 0 ]; then
  echo "❌ No valid proxies found"
  exit 1
fi

cat >> "$TMP_CFG" <<EOF

# ===== LOCAL PROXY FOR ANDROID =====
proxy -p8888 -a
EOF

mv "$TMP_CFG" "$CFG_FILE"
echo "✓ Loaded $COUNT proxies"

# -----------------------------
# 4. Restart service
# -----------------------------
echo "[3/4] Restarting 3proxy..."
systemctl restart "$SERVICE"

echo "[4/4] Done!"
echo "✅ Proxy list refreshed & 3proxy restarted"
