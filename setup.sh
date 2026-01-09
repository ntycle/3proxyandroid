#!/bin/bash

#############################################
# 3proxy Multi-Instance Auto Setup Script
# Mỗi proxy = 1 instance riêng biệt
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
LOG_DIR="/var/log/3proxy"
PROXY_LIST_FILE="$INSTALL_DIR/proxies.txt"
INSTANCES_DIR="$INSTALL_DIR/instances"

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
    mkdir -p $INSTANCES_DIR
    
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

# Dừng và xóa tất cả instance cũ
cleanup_old_instances() {
    log_info "Dọn dẹp các instance cũ..."
    
    # Dừng và disable tất cả service 3proxy-*
    for service in /etc/systemd/system/3proxy-*.service; do
        if [ -f "$service" ]; then
            service_name=$(basename "$service")
            systemctl stop "$service_name" 2>/dev/null || true
            systemctl disable "$service_name" 2>/dev/null || true
            rm -f "$service"
        fi
    done
    
    # Xóa thư mục instances cũ
    rm -rf "$INSTANCES_DIR"
    mkdir -p "$INSTANCES_DIR"
    
    systemctl daemon-reload
}

# Tạo instance cho mỗi proxy
create_instances() {
    log_info "Tạo instance cho từng proxy..."
    
    local port=$BASE_PORT
    local count=0
    local created_ports=()
    
    while IFS=: read -r ip proxy_port user pass; do
        # Loại bỏ khoảng trắng và ký tự xuống dòng
        ip=$(echo "$ip" | tr -d '[:space:]')
        proxy_port=$(echo "$proxy_port" | tr -d '[:space:]')
        user=$(echo "$user" | tr -d '[:space:]')
        pass=$(echo "$pass" | tr -d '[:space:]' | tr -d '\r')
        
        # Kiểm tra định dạng
        if [ -z "$ip" ] || [ -z "$proxy_port" ] || [ -z "$user" ] || [ -z "$pass" ]; then
            log_warn "Bỏ qua dòng không hợp lệ: $ip:$proxy_port:$user:$pass"
            continue
        fi
        
        count=$((count + 1))
        
        # Tạo thư mục cho instance
        local instance_dir="$INSTANCES_DIR/port-$port"
        mkdir -p "$instance_dir"
        
        # Tạo config file cho instance này
        cat > "$instance_dir/3proxy.cfg" << EOF
daemon
log $LOG_DIR/proxy-$port.log D
auth iponly
allow *
external 0.0.0.0
internal 0.0.0.0
parent 1000 connect $ip $proxy_port $user $pass
proxy -p$port
EOF
        
        # Tạo systemd service cho instance này
        cat > "/etc/systemd/system/3proxy-$port.service" << EOF
[Unit]
Description=3proxy Instance Port $port
After=network.target

[Service]
Type=forking
ExecStart=$INSTALL_DIR/bin/3proxy $instance_dir/3proxy.cfg
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
        
        log_info "Tạo Instance #$count: Port $port -> $ip:$proxy_port (User: $user)"
        
        created_ports+=($port)
        port=$((port + 1))
    done < "$PROXY_LIST_FILE"
    
    if [ $count -eq 0 ]; then
        log_error "Không có proxy hợp lệ nào được cấu hình!"
        exit 1
    fi
    
    log_info "Đã tạo $count instance (Port $BASE_PORT - $((port - 1)))"
    
    # Lưu thông tin
    echo "$count" > "$INSTALL_DIR/instance_count.txt"
    printf "%s\n" "${created_ports[@]}" > "$INSTALL_DIR/ports.txt"
}

# Khởi động tất cả instances
start_instances() {
    log_info "Khởi động tất cả instance..."
    
    systemctl daemon-reload
    
    local failed=0
    
    while read -r port; do
        systemctl enable "3proxy-$port.service"
        if systemctl restart "3proxy-$port.service"; then
            if systemctl is-active --quiet "3proxy-$port.service"; then
                log_info "✓ Instance port $port đã khởi động"
            else
                log_error "✗ Instance port $port khởi động thất bại"
                failed=$((failed + 1))
            fi
        else
            log_error "✗ Lỗi khi khởi động instance port $port"
            failed=$((failed + 1))
        fi
    done < "$INSTALL_DIR/ports.txt"
    
    if [ $failed -gt 0 ]; then
        log_error "$failed instance khởi động thất bại. Kiểm tra log: journalctl -u 3proxy-* -n 50"
    else
        log_info "Tất cả instance đã khởi động thành công!"
    fi
}

# Cấu hình firewall
configure_firewall() {
    log_info "Cấu hình firewall..."
    
    # Khởi động firewalld
    systemctl enable --now firewalld
    
    # Đọc số lượng port
    local instance_count=$(cat "$INSTALL_DIR/instance_count.txt")
    local end_port=$((BASE_PORT + instance_count - 1))
    
    # Mở port range
    log_info "Mở port range: $BASE_PORT-$end_port"
    firewall-cmd --permanent --add-port=${BASE_PORT}-${end_port}/tcp 2>/dev/null || true
    
    # Reload firewall
    firewall-cmd --reload
    
    log_info "Firewall đã được cấu hình"
}

# Hiển thị thông tin
show_info() {
    echo ""
    echo "=============================================="
    log_info "CÀI ĐẶT HOÀN TẤT!"
    echo "=============================================="
    echo ""
    
    local instance_count=$(cat "$INSTALL_DIR/instance_count.txt")
    local end_port=$((BASE_PORT + instance_count - 1))
    local vps_ip=$(hostname -I | awk '{print $1}')
    
    echo "📊 THÔNG TIN HỆ THỐNG:"
    echo "   - Số lượng proxy: $instance_count"
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
    echo "   - Xem tất cả instance: systemctl list-units '3proxy-*'"
    echo "   - Xem status 1 port: systemctl status 3proxy-10000"
    echo "   - Restart 1 port: systemctl restart 3proxy-10000"
    echo "   - Xem log: tail -f $LOG_DIR/proxy-10000.log"
    echo "   - Cập nhật proxy: bash $0"
    echo ""
    
    echo "📁 FILE QUAN TRỌNG:"
    echo "   - Instances dir: $INSTANCES_DIR"
    echo "   - Proxy list: $PROXY_LIST_FILE"
    echo "   - Logs: $LOG_DIR/"
    echo ""
    
    echo "✅ DANH SÁCH PROXY ĐANG CHẠY:"
    local port=$BASE_PORT
    while IFS=: read -r ip proxy_port user pass; do
        ip=$(echo "$ip" | tr -d '[:space:]')
        proxy_port=$(echo "$proxy_port" | tr -d '[:space:]')
        
        if [ -n "$ip" ] && [ -n "$proxy_port" ]; then
            local status="❌"
            if systemctl is-active --quiet "3proxy-$port.service"; then
                status="✅"
            fi
            echo "   $status Port $port: $vps_ip:$port -> $ip:$proxy_port"
            port=$((port + 1))
        fi
    done < "$PROXY_LIST_FILE"
    
    echo ""
    echo "🧪 TEST PROXY:"
    echo "   curl -x http://$vps_ip:$BASE_PORT https://api.ipify.org"
    echo ""
    echo "=============================================="
}

# Main function
main() {
    echo ""
    echo "=============================================="
    echo "  3PROXY MULTI-INSTANCE AUTO SETUP"
    echo "  ALMALINUX 8.10"
    echo "=============================================="
    echo ""
    
    check_root
    
    # Kiểm tra nếu đã cài đặt
    if [ -f "$INSTALL_DIR/bin/3proxy" ]; then
        log_info "3proxy đã được cài đặt. Đang cập nhật cấu hình..."
        download_proxy_list
        cleanup_old_instances
        create_instances
        configure_firewall
        start_instances
    else
        log_info "Bắt đầu cài đặt 3proxy từ đầu..."
        install_dependencies
        install_3proxy
        download_proxy_list
        create_instances
        configure_firewall
        start_instances
    fi
    
    show_info
}

# Chạy script
main "$@"
