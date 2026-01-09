#!/bin/bash

#############################################
# 3proxy Auto Setup Script for AlmaLinux 8
# Tự động cài đặt, cấu hình và quản lý 3proxy
#############################################

set -e

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cấu hình
PROXY_LIST_URL="https://raw.githubusercontent.com/ntycle/3proxyandroid/refs/heads/main/proxies.txt"
BASE_PORT=10000
INSTALL_DIR="/opt/3proxy"
CONFIG_FILE="$INSTALL_DIR/3proxy.cfg"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
LOG_DIR="/var/log/3proxy"
PROXY_LIST_FILE="$INSTALL_DIR/proxies.txt"

# Hàm log
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Script này cần chạy với quyền root"
        exit 1
    fi
}

# Cài đặt dependencies
install_dependencies() {
    log_info "Cài đặt các gói cần thiết..."
    dnf install -y gcc make wget tar gzip firewalld
}

# Tải và cài đặt 3proxy
install_3proxy() {
    log_info "Tải và cài đặt 3proxy..."
    
    cd /tmp
    
    # Tải 3proxy version mới nhất (0.9.4)
    if [ ! -f "3proxy-0.9.4.tar.gz" ]; then
        wget https://github.com/3proxy/3proxy/archive/0.9.4.tar.gz -O 3proxy-0.9.4.tar.gz
    fi
    
    # Giải nén và compile
    tar xzf 3proxy-0.9.4.tar.gz
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    
    # Tạo thư mục cài đặt
    mkdir -p $INSTALL_DIR/bin
    mkdir -p $LOG_DIR
    
    # Copy binary
    cp bin/3proxy $INSTALL_DIR/bin/
    chmod +x $INSTALL_DIR/bin/3proxy
    
    log_info "3proxy đã được cài đặt tại $INSTALL_DIR"
}

# Tải danh sách proxy từ GitHub
download_proxy_list() {
    log_info "Tải danh sách proxy từ GitHub..."
    
    if wget -q -O "$PROXY_LIST_FILE" "$PROXY_LIST_URL"; then
        # Loại bỏ dòng trống và khoảng trắng
        sed -i '/^[[:space:]]*$/d' "$PROXY_LIST_FILE"
        
        local proxy_count=$(wc -l < "$PROXY_LIST_FILE")
        log_info "Đã tải thành công $proxy_count proxy"
        
        if [ $proxy_count -eq 0 ]; then
            log_error "File proxies.txt rỗng!"
            exit 1
        fi
    else
        log_error "Không thể tải file proxies.txt từ GitHub"
        exit 1
    fi
}

# Tạo file cấu hình 3proxy
generate_config() {
    log_info "Tạo file cấu hình 3proxy..."
    
    cat > "$CONFIG_FILE" << 'EOF'
# 3proxy configuration file
# Generated automatically

# Daemon mode
daemon

# Number of threads
maxconn 1000

# Log settings
log "$LOG_DIR/3proxy.log" D
rotate 30
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"

# ACL - Allow all
auth none

# Bind to all interfaces
internal 0.0.0.0

# Enable proxy protocols
proxy

# Flush logs
flush

EOF

    # Đọc danh sách proxy và tạo cấu hình
    local port=$BASE_PORT
    local count=0
    
    while IFS=: read -r ip proxy_port user pass; do
        # Loại bỏ khoảng trắng
        ip=$(echo "$ip" | tr -d '[:space:]')
        proxy_port=$(echo "$proxy_port" | tr -d '[:space:]')
        user=$(echo "$user" | tr -d '[:space:]')
        pass=$(echo "$pass" | tr -d '[:space:]')
        
        # Kiểm tra định dạng
        if [ -z "$ip" ] || [ -z "$proxy_port" ] || [ -z "$user" ] || [ -z "$pass" ]; then
            log_warn "Bỏ qua dòng không hợp lệ: $ip:$proxy_port:$user:$pass"
            continue
        fi
        
        count=$((count + 1))
        
        # Thêm cấu hình cho mỗi proxy
        cat >> "$CONFIG_FILE" << EOF

# Proxy #$count - Port $port -> $ip:$proxy_port
auth none
parent 1000 http $ip $proxy_port $user $pass
proxy -p$port

EOF
        
        log_info "Cấu hình Proxy #$count: Port $port -> $ip:$proxy_port (User: $user)"
        
        port=$((port + 1))
    done < "$PROXY_LIST_FILE"
    
    if [ $count -eq 0 ]; then
        log_error "Không có proxy hợp lệ nào được cấu hình!"
        exit 1
    fi
    
    log_info "Đã tạo cấu hình cho $count proxy (Port $BASE_PORT - $((port - 1)))"
    
    # Lưu số lượng port vào file để firewall sử dụng
    echo "$count" > "$INSTALL_DIR/port_count.txt"
}

# Tạo systemd service
create_service() {
    log_info "Tạo systemd service..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=$INSTALL_DIR/bin/3proxy $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable 3proxy
    log_info "Systemd service đã được tạo"
}

# Cấu hình firewall
configure_firewall() {
    log_info "Cấu hình firewall..."
    
    # Khởi động firewalld
    systemctl enable --now firewalld
    
    # Đọc số lượng port
    local port_count=$(cat "$INSTALL_DIR/port_count.txt")
    local end_port=$((BASE_PORT + port_count - 1))
    
    # Mở port range
    log_info "Mở port range: $BASE_PORT-$end_port"
    firewall-cmd --permanent --add-port=${BASE_PORT}-${end_port}/tcp
    
    # Reload firewall
    firewall-cmd --reload
    
    log_info "Firewall đã được cấu hình"
}

# Khởi động service
start_service() {
    log_info "Khởi động 3proxy service..."
    
    systemctl restart 3proxy
    
    if systemctl is-active --quiet 3proxy; then
        log_info "3proxy đã khởi động thành công!"
    else
        log_error "Lỗi khi khởi động 3proxy. Kiểm tra log: journalctl -u 3proxy -n 50"
        exit 1
    fi
}

# Hiển thị thông tin
show_info() {
    echo ""
    echo "=============================================="
    log_info "CÀI ĐẶT HOÀN TẤT!"
    echo "=============================================="
    echo ""
    
    local port_count=$(cat "$INSTALL_DIR/port_count.txt")
    local end_port=$((BASE_PORT + port_count - 1))
    local vps_ip=$(hostname -I | awk '{print $1}')
    
    echo "📊 THÔNG TIN HỆ THỐNG:"
    echo "   - Số lượng proxy: $port_count"
    echo "   - Port range: $BASE_PORT - $end_port"
    echo "   - VPS IP: $vps_ip"
    echo ""
    
    echo "📱 KẾT NỐI TỪ ANDROID:"
    echo "   - Proxy Type: HTTP/HTTPS"
    echo "   - Server: $vps_ip"
    echo "   - Port: $BASE_PORT đến $end_port"
    echo "   - Authentication: None (No Auth)"
    echo ""
    
    echo "🔧 LỆNH QUẢN LÝ:"
    echo "   - Xem status: systemctl status 3proxy"
    echo "   - Khởi động lại: systemctl restart 3proxy"
    echo "   - Xem log: tail -f $LOG_DIR/3proxy.log"
    echo "   - Cập nhật proxy: bash $0"
    echo ""
    
    echo "📁 FILE QUAN TRỌNG:"
    echo "   - Config: $CONFIG_FILE"
    echo "   - Proxy list: $PROXY_LIST_FILE"
    echo "   - Log: $LOG_DIR/3proxy.log"
    echo ""
    
    echo "✅ DANH SÁCH PROXY:"
    local port=$BASE_PORT
    while IFS=: read -r ip proxy_port user pass; do
        ip=$(echo "$ip" | tr -d '[:space:]')
        proxy_port=$(echo "$proxy_port" | tr -d '[:space:]')
        
        if [ -n "$ip" ] && [ -n "$proxy_port" ]; then
            echo "   Android Port $port -> $ip:$proxy_port"
            port=$((port + 1))
        fi
    done < "$PROXY_LIST_FILE"
    
    echo ""
    echo "=============================================="
}

# Main function
main() {
    echo ""
    echo "=============================================="
    echo "  3PROXY AUTO SETUP - ALMALINUX 8.10"
    echo "=============================================="
    echo ""
    
    check_root
    
    # Kiểm tra nếu đã cài đặt
    if [ -f "$INSTALL_DIR/bin/3proxy" ]; then
        log_info "3proxy đã được cài đặt. Đang cập nhật cấu hình..."
        download_proxy_list
        generate_config
        configure_firewall
        start_service
    else
        log_info "Bắt đầu cài đặt 3proxy từ đầu..."
        install_dependencies
        install_3proxy
        download_proxy_list
        generate_config
        create_service
        configure_firewall
        start_service
    fi
    
    show_info
}

# Chạy script
main "$@"
