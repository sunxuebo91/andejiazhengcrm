#!/bin/bash
# 运维监控脚本 - monitoring.sh
# 功能：系统监控、应用健康检查、性能监控、日志分析、自动报警

set -e

# 配置变量
PROJECT_NAME="andejiazhengcrm"
SERVICE_NAME="${PROJECT_NAME}"
APP_PORT=8080
LOG_DIR="/var/log/${PROJECT_NAME}"
MONITOR_LOG="/var/log/${PROJECT_NAME}_monitor.log"
ALERT_EMAIL="admin@yourcompany.com"
SLACK_WEBHOOK_URL=""  # 设置你的Slack Webhook URL
THRESHOLD_CPU=80      # CPU使用率阈值
THRESHOLD_MEM=85      # 内存使用率阈值
THRESHOLD_DISK=90     # 磁盘使用率阈值
RESPONSE_TIME_THRESHOLD=5000  # 响应时间阈值(毫秒)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$MONITOR_LOG"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$MONITOR_LOG"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a "$MONITOR_LOG"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$MONITOR_LOG"
}

# 发送报警
send_alert() {
    local message="$1"
    local severity="$2"
    
    # 发送邮件报警
    if command -v mail >/dev/null 2>&1 && [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "[$severity] ${PROJECT_NAME} 监控报警" "$ALERT_EMAIL"
    fi
    
    # 发送Slack通知
    if [ -n "$SLACK_WEBHOOK_URL" ] && command -v curl >/dev/null 2>&1; then
        curl -X POST -H 'Content-type: application/json' \
             --data "{\"text\":\"[$severity] ${PROJECT_NAME}: $message\"}" \
             "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
    
    error "ALERT [$severity]: $message"
}

# 系统资源监控
check_system_resources() {
    info "检查系统资源使用情况..."
    
    # CPU使用率
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    cpu_usage=${cpu_usage%.*}  # 去掉小数点
    
    if [ "$cpu_usage" -gt "$THRESHOLD_CPU" ]; then
        send_alert "CPU使用率过高: ${cpu_usage}% (阈值: ${THRESHOLD_CPU}%)" "HIGH"
    else
        log "CPU使用率正常: ${cpu_usage}%"
    fi
    
    # 内存使用率
    local mem_info=$(free | grep Mem)
    local total_mem=$(echo $mem_info | awk '{print $2}')
    local used_mem=$(echo $mem_info | awk '{print $3}')
    local mem_usage=$(( used_mem * 100 / total_mem ))
    
    if [ "$mem_usage" -gt "$THRESHOLD_MEM" ]; then
        send_alert "内存使用率过高: ${mem_usage}% (阈值: ${THRESHOLD_MEM}%)" "HIGH"
    else
        log "内存使用率正常: ${mem_usage}%"
    fi
    
    # 磁盘使用率
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | cut -d'%' -f1)
    
    if [ "$disk_usage" -gt "$THRESHOLD_DISK" ]; then
        send_alert "磁盘使用率过高: ${disk_usage}% (阈值: ${THRESHOLD_DISK}%)" "HIGH"
    else
        log "磁盘使用率正常: ${disk_usage}%"
    fi
    
    # 负载平均值
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | cut -d',' -f1)
    local cpu_cores=$(nproc)
    local load_ratio=$(echo "$load_avg * 100 / $cpu_cores" | bc -l | cut -d'.' -f1)
    
    if [ "$load_ratio" -gt 80 ]; then
        send_alert "系统负载过高: ${load_avg} (CPU核心数: ${cpu_cores})" "MEDIUM"
    else
        log "系统负载正常: ${load_avg}"
    fi
}

# 应用服务健康检查
check_application_health() {
    info "检查应用服务健康状态..."
    
    # 检查服务状态
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "服务状态: 运行中"
    elif docker ps | grep -q "$PROJECT_NAME"; then
        log "Docker容器状态: 运行中"
    else
        send_alert "服务未运行: $SERVICE_NAME" "CRITICAL"
        return 1
    fi
    
    # 检查端口监听
    if netstat -tuln | grep -q ":$APP_PORT "; then
        log "端口监听正常: $APP_PORT"
    else
        send_alert "端口未监听: $APP_PORT" "CRITICAL"
        return 1
    fi
    
    # HTTP健康检查
    if command -v curl >/dev/null 2>&1; then
        local start_time=$(date +%s%3N)
        local http_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$APP_PORT/health" --connect-timeout 10 --max-time 30)
        local end_time=$(date +%s%3N)
        local response_time=$((end_time - start_time))
        
        if [ "$http_status" = "200" ]; then
            log "HTTP健康检查通过 (响应时间: ${response_time}ms)"
            
            if [ "$response_time" -gt "$RESPONSE_TIME_THRESHOLD" ]; then
                send_alert "响应时间过长: ${response_time}ms (阈值: ${RESPONSE_TIME_THRESHOLD}ms)" "MEDIUM"
            fi
        else
            send_alert "HTTP健康检查失败: HTTP状态码 $http_status" "HIGH"
        fi
    fi
}

# 数据库连接检查
check_database_connection() {
    info "检查数据库连接..."
    
    # MySQL检查
    if command -v mysql >/dev/null 2>&1; then
        if mysql -u root -p"${DB_PASSWORD:-}" -e "SELECT 1;" >/dev/null 2>&1; then
            log "MySQL连接正常"
        else
            send_alert "MySQL连接失败" "HIGH"
        fi
    fi
    
    # PostgreSQL检查
    if command -v psql >/dev/null 2>&1; then
        if PGPASSWORD="${DB_PASSWORD:-}" psql -h localhost -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            log "PostgreSQL连接正常"
        else
            send_alert "PostgreSQL连接失败" "HIGH"
        fi
    fi
    
    # Redis检查
    if command -v redis-cli >/dev/null 2>&1; then
        if redis-cli ping | grep -q "PONG"; then
            log "Redis连接正常"
        else
            send_alert "Redis连接失败" "HIGH"
        fi
    fi
}

# 日志分析
analyze_logs() {
    info "分析应用日志..."
    
    local log_file="${LOG_DIR}/application.log"
    if [ ! -f "$log_file" ]; then
        warn "日志文件不存在: $log_file"
        return
    fi
    
    # 检查最近5分钟的错误日志
    local recent_errors=$(tail -n 1000 "$log_file" | grep "$(date -d '5 minutes ago' '+%Y-%m-%d %H:%M')" | grep -i "error\|exception\|fatal" | wc -l)
    
    if [ "$recent_errors" -gt 10 ]; then
        send_alert "最近5分钟内发现 $recent_errors 个错误日志" "MEDIUM"
    elif [ "$recent_errors" -gt 0 ]; then
        warn "最近5分钟内发现 $recent_errors 个错误日志"
    else
        log "最近5分钟内无错误日志"
    fi
    
    # 检查日志文件大小
    local log_size=$(du -m "$log_file" | cut -f1)
    if [ "$log_size" -gt 1000 ]; then  # 大于1GB
        send_alert "日志文件过大: ${log_size}MB" "LOW"
    fi
}

# SSL证书检查
check_ssl_certificate() {
    info "检查SSL证书..."
    
    local domain="${1:-localhost}"
    if command -v openssl >/dev/null 2>&1; then
        local cert_expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
        local expiry_timestamp=$(date -d "$cert_expiry" +%s)
        local current_timestamp=$(date +%s)
        local days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
        
        if [ "$days_until_expiry" -lt 30 ]; then
            send_alert "SSL证书即将过期: $days_until_expiry 天后过期" "HIGH"
        elif [ "$days_until_expiry" -lt 90 ]; then
            warn "SSL证书将在 $days_until_expiry 天后过期"
        else
            log "SSL证书正常: $days_until_expiry 天后过期"
        fi
    fi
}

# 磁盘空间清理
cleanup_disk_space() {
    info "清理磁盘空间..."
    
    # 清理旧日志文件
    find "${LOG_DIR}" -name "*.log" -mtime +30 -delete 2>/dev/null || true
    
    # 清理Docker资源
    if command -v docker >/dev/null 2>&1; then
        docker system prune -f >/dev/null 2>&1 || true
        docker volume prune -f >/dev/null 2>&1 || true
    fi
    
    # 清理临时文件
    find /tmp -name "${PROJECT_NAME}*" -mtime +7 -delete 2>/dev/null || true
    
    log "磁盘空间清理完成"
}

# 性能监控
check_performance() {
    info "检查应用性能..."
    
    # 检查进程数
    local process_count=$(ps aux | grep "$PROJECT_NAME" | grep -v grep | wc -l)
    log "运行进程数: $process_count"
    
    # 检查连接数
    if netstat -an | grep -q ":$APP_PORT "; then
        local connection_count=$(netstat -an | grep ":$APP_PORT " | grep ESTABLISHED | wc -l)
        log "当前连接数: $connection_count"
        
        if [ "$connection_count" -gt 1000 ]; then
            send_alert "连接数过多: $connection_count" "MEDIUM"
        fi
    fi
    
    # 检查文件描述符使用情况
    local fd_usage=$(lsof | grep "$PROJECT_NAME" | wc -l)
    log "文件描述符使用数: $fd_usage"
}

# 备份状态检查
check_backup_status() {
    info "检查备份状态..."
    
    local backup_dir="/opt/backups/${PROJECT_NAME}"
    if [ -d "$backup_dir" ]; then
        local latest_backup=$(ls -t "$backup_dir" | head -1)
        if [ -n "$latest_backup" ]; then
            local backup_age=$(find "$backup_dir/$latest_backup" -mtime +1 | wc -l)
            if [ "$backup_age" -gt 0 ]; then
                send_alert "备份文件过旧: $latest_backup" "MEDIUM"
            else
                log "备份状态正常: $latest_backup"
            fi
        else
            send_alert "未找到备份文件" "HIGH"
        fi
    else
        warn "备份目录不存在: $backup_dir"
    fi
}

# 生成监控报告
generate_report() {
    local report_file="/tmp/${PROJECT_NAME}_monitor_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "==============================================="
        echo "监控报告 - $(date)"
        echo "==============================================="
        echo
        echo "系统信息:"
        echo "- 主机名: $(hostname)"
        echo "- 操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
        echo "- 内核版本: $(uname -r)"
        echo "- 运行时间: $(uptime -p)"
        echo
        echo "资源使用情况:"
        echo "- CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')"
        echo "- 内存: $(free -h | grep Mem | awk '{print $3"/"$2}')"
        echo "- 磁盘: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
        echo "- 负载: $(uptime | awk -F'load average:' '{print $2}')"
        echo
        echo "应用状态:"
        if systemctl is-active --quiet "$SERVICE_NAME" || docker ps | grep -q "$PROJECT_NAME"; then
            echo "- 服务状态: 运行中"
        else
            echo "- 服务状态: 未运行"
        fi
        echo "- 端口监听: $(netstat -tuln | grep ":$APP_PORT " | wc -l) 个端口"
        echo "- 进程数: $(ps aux | grep "$PROJECT_NAME" | grep -v grep | wc -l)"
        echo
        echo "最近错误日志:"
        if [ -f "${LOG_DIR}/application.log" ]; then
            tail -n 20 "${LOG_DIR}/application.log" | grep -i "error\|exception" | tail -5
        else
            echo "- 无日志文件"
        fi
    } > "$report_file"
    
    info "监控报告已生成: $report_file"
    
    # 如果有邮件配置，发送报告
    if command -v mail >/dev/null 2>&1 && [ -n "$ALERT_EMAIL" ]; then
        mail -s "${PROJECT_NAME} 监控报告" "$ALERT_EMAIL" < "$report_file"
    fi
}

# 主监控函数
run_monitoring() {
    log "开始执行监控检查..."
    
    check_system_resources
    check_application_health
    check_database_connection
    analyze_logs
    check_performance
    check_backup_status
    
    # 如果磁盘使用率高，执行清理
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | cut -d'%' -f1)
    if [ "$disk_usage" -gt 85 ]; then
        cleanup_disk_space
    fi
    
    log "监控检查完成"
}

# 实时监控模式
real_time_monitoring() {
    log "启动实时监控模式..."
    
    while true; do
        run_monitoring
        echo "---"
        sleep 300  # 5分钟检查一次
    done
}

# 命令行参数处理
case "$1" in
    "check")
        run_monitoring
        ;;
    "realtime")
        real_time_monitoring
        ;;
    "report")
        generate_report
        ;;
    "ssl")
        check_ssl_certificate "$2"
        ;;
    "cleanup")
        cleanup_disk_space
        ;;
    "health")
        check_application_health
        ;;
    *)
        echo "用法: $0 {check|realtime|report|ssl|cleanup|health}"
        echo "  check    - 执行一次完整监控检查"
        echo "  realtime - 启动实时监控模式"
        echo "  report   - 生成监控报告"
        echo "  ssl      - 检查SSL证书状态"
        echo "  cleanup  - 清理磁盘空间"
        echo "  health   - 仅检查应用健康状态"
        exit 1
        ;;
esac 