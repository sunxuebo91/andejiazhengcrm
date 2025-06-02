#!/bin/bash
# 迭代更新脚本 - update.sh
# 功能：版本升级、数据库迁移、配置更新、平滑重启

set -e

# 配置变量
PROJECT_NAME="andejiazhengcrm"
CURRENT_VERSION_FILE="/opt/${PROJECT_NAME}/.version"
GIT_REPO_URL="https://github.com/your-org/${PROJECT_NAME}.git"
DEPLOY_DIR="/opt/${PROJECT_NAME}"
BACKUP_DIR="/opt/backups/${PROJECT_NAME}"
SERVICE_NAME="${PROJECT_NAME}"
LOG_FILE="/var/log/${PROJECT_NAME}_update.log"
ROLLBACK_ENABLED=true
MAX_ROLLBACK_VERSIONS=5

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" | tee -a "$LOG_FILE"
}

# 获取当前版本
get_current_version() {
    if [ -f "$CURRENT_VERSION_FILE" ]; then
        cat "$CURRENT_VERSION_FILE"
    else
        echo "unknown"
    fi
}

# 设置版本
set_version() {
    echo "$1" > "$CURRENT_VERSION_FILE"
}

# 检查版本格式
validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "无效的版本格式: $version (应为 x.y.z 格式)"
        return 1
    fi
    return 0
}

# 比较版本
version_compare() {
    local ver1="$1"
    local ver2="$2"
    
    # 将版本号分解为数组
    IFS='.' read -ra VER1 <<< "$ver1"
    IFS='.' read -ra VER2 <<< "$ver2"
    
    # 比较主版本号
    if [ "${VER1[0]}" -gt "${VER2[0]}" ]; then
        return 1  # ver1 > ver2
    elif [ "${VER1[0]}" -lt "${VER2[0]}" ]; then
        return 2  # ver1 < ver2
    fi
    
    # 比较次版本号
    if [ "${VER1[1]}" -gt "${VER2[1]}" ]; then
        return 1
    elif [ "${VER1[1]}" -lt "${VER2[1]}" ]; then
        return 2
    fi
    
    # 比较修订版本号
    if [ "${VER1[2]}" -gt "${VER2[2]}" ]; then
        return 1
    elif [ "${VER1[2]}" -lt "${VER2[2]}" ]; then
        return 2
    fi
    
    return 0  # ver1 == ver2
}

# 检查更新前置条件
check_prerequisites() {
    log "检查更新前置条件..."
    
    # 检查权限
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查磁盘空间
    local available_space=$(df "$DEPLOY_DIR" | tail -1 | awk '{print $4}')
    local required_space=1048576  # 1GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "磁盘空间不足，需要至少1GB可用空间"
        exit 1
    fi
    
    # 检查网络连接
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        warn "网络连接可能有问题，但继续执行更新"
    fi
    
    log "前置条件检查通过"
}

# 创建备份
create_backup() {
    local version="$1"
    local backup_name="${PROJECT_NAME}_backup_v${version}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log "创建备份: $backup_name"
    
    mkdir -p "$BACKUP_DIR"
    
    # 备份应用文件
    if [ -d "$DEPLOY_DIR" ]; then
        cp -r "$DEPLOY_DIR" "$backup_path"
        
        # 备份数据库
        backup_database "$backup_path"
        
        # 创建备份元信息
        cat > "${backup_path}/backup_info.txt" << EOF
备份信息
========
创建时间: $(date)
版本: $version
备份路径: $backup_path
主机名: $(hostname)
用户: $(whoami)
EOF
        
        log "备份完成: $backup_path"
        echo "$backup_path"
    else
        warn "应用目录不存在，跳过备份"
    fi
    
    # 清理旧备份
    cleanup_old_backups
}

# 备份数据库
backup_database() {
    local backup_path="$1"
    
    info "备份数据库..."
    
    # MySQL备份
    if command -v mysqldump >/dev/null 2>&1; then
        local db_name="${PROJECT_NAME}"
        if mysql -e "USE $db_name;" >/dev/null 2>&1; then
            mysqldump "$db_name" > "${backup_path}/database_mysql.sql"
            log "MySQL数据库备份完成"
        fi
    fi
    
    # PostgreSQL备份
    if command -v pg_dump >/dev/null 2>&1; then
        local db_name="${PROJECT_NAME}"
        if PGPASSWORD="${DB_PASSWORD:-}" psql -h localhost -U postgres -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
            PGPASSWORD="${DB_PASSWORD:-}" pg_dump -h localhost -U postgres "$db_name" > "${backup_path}/database_postgresql.sql"
            log "PostgreSQL数据库备份完成"
        fi
    fi
    
    # Redis备份
    if command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
        redis-cli BGSAVE
        sleep 5
        cp /var/lib/redis/dump.rdb "${backup_path}/redis_dump.rdb" 2>/dev/null || true
        log "Redis数据备份完成"
    fi
}

# 清理旧备份
cleanup_old_backups() {
    log "清理旧备份文件..."
    
    if [ -d "$BACKUP_DIR" ]; then
        # 保留最新的N个备份
        ls -t "$BACKUP_DIR" | tail -n +$((MAX_ROLLBACK_VERSIONS + 1)) | while read backup; do
            rm -rf "${BACKUP_DIR}/${backup}"
            log "删除旧备份: $backup"
        done
    fi
}

# 下载新版本
download_version() {
    local version="$1"
    local temp_dir="/tmp/${PROJECT_NAME}_update_$$"
    
    log "下载版本 $version..."
    
    # 创建临时目录
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # 克隆或下载代码
    if git clone "$GIT_REPO_URL" . >/dev/null 2>&1; then
        # 检出指定版本
        git checkout "tags/v$version" -b "update-$version" 2>/dev/null || \
        git checkout "v$version" 2>/dev/null || \
        git checkout "$version" 2>/dev/null || {
            error "无法检出版本 $version"
            rm -rf "$temp_dir"
            return 1
        }
        
        log "版本 $version 下载完成"
        echo "$temp_dir"
    else
        error "无法下载代码仓库"
        rm -rf "$temp_dir"
        return 1
    fi
}

# 执行数据库迁移
run_database_migration() {
    local temp_dir="$1"
    local version="$2"
    
    info "执行数据库迁移..."
    
    cd "$temp_dir"
    
    # 检查是否有迁移脚本
    if [ -d "migrations" ] || [ -f "migrate.sh" ]; then
        # 备份当前数据库状态
        backup_database "/tmp/pre_migration_backup"
        
        # 执行迁移
        if [ -f "migrate.sh" ]; then
            chmod +x migrate.sh
            if ./migrate.sh; then
                log "数据库迁移完成"
            else
                error "数据库迁移失败"
                return 1
            fi
        elif [ -d "migrations" ]; then
            # 根据项目类型执行迁移
            if [ -f "package.json" ] && grep -q "sequelize" package.json; then
                npm run migrate 2>/dev/null || npx sequelize-cli db:migrate
            elif [ -f "manage.py" ]; then
                python manage.py migrate
            elif [ -f "artisan" ]; then
                php artisan migrate
            else
                warn "未找到合适的迁移工具"
            fi
        fi
    else
        log "未发现数据库迁移脚本，跳过迁移"
    fi
}

# 更新配置文件
update_configuration() {
    local temp_dir="$1"
    local version="$2"
    
    info "更新配置文件..."
    
    # 保存当前配置
    if [ -f "${DEPLOY_DIR}/config/production.env" ]; then
        cp "${DEPLOY_DIR}/config/production.env" "/tmp/current_config.env"
    fi
    
    # 复制新的配置模板
    if [ -f "${temp_dir}/config/production.env.example" ]; then
        mkdir -p "${DEPLOY_DIR}/config"
        
        # 如果存在旧配置，合并配置
        if [ -f "/tmp/current_config.env" ]; then
            info "合并配置文件..."
            # 这里可以添加更复杂的配置合并逻辑
            cp "/tmp/current_config.env" "${DEPLOY_DIR}/config/production.env"
        else
            cp "${temp_dir}/config/production.env.example" "${DEPLOY_DIR}/config/production.env"
            warn "请检查并更新配置文件: ${DEPLOY_DIR}/config/production.env"
        fi
    fi
    
    log "配置文件更新完成"
}

# 构建应用
build_application() {
    local temp_dir="$1"
    
    log "构建新版本应用..."
    
    cd "$temp_dir"
    
    # 安装依赖
    if [ -f "package.json" ]; then
        npm install --production
    elif [ -f "requirements.txt" ]; then
        pip3 install -r requirements.txt
    elif [ -f "pom.xml" ]; then
        mvn clean package -DskipTests
    elif [ -f "go.mod" ]; then
        go build -o "${PROJECT_NAME}" .
    fi
    
    # Docker构建
    if [ -f "Dockerfile" ]; then
        docker build -t "${PROJECT_NAME}:latest" .
    fi
    
    log "应用构建完成"
}

# 平滑停止服务
graceful_stop() {
    info "平滑停止服务..."
    
    # 如果是Docker容器
    if docker ps | grep -q "$PROJECT_NAME"; then
        docker stop "$PROJECT_NAME" || true
    # 如果是systemd服务
    elif systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
    # 如果是进程
    else
        local pid=$(ps aux | grep "$PROJECT_NAME" | grep -v grep | awk '{print $2}' | head -1)
        if [ -n "$pid" ]; then
            kill -TERM "$pid"
            sleep 10
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid"
            fi
        fi
    fi
    
    log "服务已停止"
}

# 部署新版本
deploy_new_version() {
    local temp_dir="$1"
    local version="$2"
    
    log "部署新版本 $version..."
    
    # 停止服务
    graceful_stop
    
    # 备份当前部署
    if [ -d "$DEPLOY_DIR" ]; then
        mv "$DEPLOY_DIR" "${DEPLOY_DIR}.old"
    fi
    
    # 部署新版本
    mv "$temp_dir" "$DEPLOY_DIR"
    
    # 更新版本信息
    set_version "$version"
    
    # 设置权限
    chown -R www-data:www-data "$DEPLOY_DIR" 2>/dev/null || true
    chmod -R 755 "$DEPLOY_DIR"
    
    log "新版本部署完成"
}

# 启动服务
start_service() {
    log "启动服务..."
    
    cd "$DEPLOY_DIR"
    
    if [ -f "docker-compose.yml" ]; then
        docker-compose up -d
    elif systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        systemctl start "$SERVICE_NAME"
    else
        # 根据项目类型启动
        if [ -f "package.json" ]; then
            npm start &
        elif [ -f "app.py" ]; then
            python3 app.py &
        elif [ -f "${PROJECT_NAME}" ]; then
            ./"${PROJECT_NAME}" &
        fi
    fi
    
    log "服务启动完成"
}

# 健康检查
health_check() {
    local max_attempts=12
    local attempt=1
    
    log "执行健康检查..."
    
    while [ $attempt -le $max_attempts ]; do
        sleep 10
        
        # 检查端口
        if netstat -tuln | grep -q ":8080 "; then
            # HTTP检查
            if curl -f "http://localhost:8080/health" >/dev/null 2>&1; then
                log "健康检查通过"
                return 0
            fi
        fi
        
        warn "健康检查失败，重试 $attempt/$max_attempts"
        ((attempt++))
    done
    
    error "健康检查失败"
    return 1
}

# 回滚
rollback_to_backup() {
    local backup_path="$1"
    
    error "开始回滚到备份: $backup_path"
    
    if [ ! -d "$backup_path" ]; then
        error "备份目录不存在: $backup_path"
        return 1
    fi
    
    # 停止当前服务
    graceful_stop
    
    # 恢复文件
    rm -rf "$DEPLOY_DIR"
    cp -r "$backup_path" "$DEPLOY_DIR"
    
    # 恢复数据库
    if [ -f "${backup_path}/database_mysql.sql" ]; then
        mysql "${PROJECT_NAME}" < "${backup_path}/database_mysql.sql"
    fi
    
    if [ -f "${backup_path}/database_postgresql.sql" ]; then
        PGPASSWORD="${DB_PASSWORD:-}" psql -h localhost -U postgres "${PROJECT_NAME}" < "${backup_path}/database_postgresql.sql"
    fi
    
    # 启动服务
    start_service
    
    # 更新版本信息
    local backup_version=$(grep "版本:" "${backup_path}/backup_info.txt" | cut -d' ' -f2)
    if [ -n "$backup_version" ]; then
        set_version "$backup_version"
    fi
    
    log "回滚完成"
}

# 主更新函数
update_to_version() {
    local target_version="$1"
    local current_version=$(get_current_version)
    
    log "开始更新 $PROJECT_NAME: $current_version -> $target_version"
    
    # 验证版本格式
    if ! validate_version "$target_version"; then
        exit 1
    fi
    
    # 检查是否需要更新
    if [ "$current_version" = "$target_version" ]; then
        log "当前已是目标版本 $target_version"
        exit 0
    fi
    
    # 检查前置条件
    check_prerequisites
    
    # 创建备份
    local backup_path=""
    if [ "$ROLLBACK_ENABLED" = true ]; then
        backup_path=$(create_backup "$current_version")
    fi
    
    # 下载新版本
    local temp_dir=$(download_version "$target_version")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # 构建应用
    build_application "$temp_dir"
    
    # 执行数据库迁移
    if ! run_database_migration "$temp_dir" "$target_version"; then
        if [ -n "$backup_path" ]; then
            rollback_to_backup "$backup_path"
        fi
        exit 1
    fi
    
    # 更新配置
    update_configuration "$temp_dir" "$target_version"
    
    # 部署新版本
    deploy_new_version "$temp_dir" "$target_version"
    
    # 启动服务
    start_service
    
    # 健康检查
    if ! health_check; then
        if [ -n "$backup_path" ]; then
            rollback_to_backup "$backup_path"
        fi
        exit 1
    fi
    
    # 清理
    rm -rf "${DEPLOY_DIR}.old" 2>/dev/null || true
    
    log "更新完成！当前版本: $target_version"
}

# 列出可用版本
list_available_versions() {
    log "获取可用版本列表..."
    
    local temp_dir="/tmp/${PROJECT_NAME}_versions_$$"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    if git clone "$GIT_REPO_URL" . >/dev/null 2>&1; then
        echo "可用版本:"
        git tag | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -10
    else
        error "无法获取版本列表"
    fi
    
    rm -rf "$temp_dir"
}

# 检查最新版本
check_latest_version() {
    log "检查最新版本..."
    
    local temp_dir="/tmp/${PROJECT_NAME}_latest_$$"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    if git clone "$GIT_REPO_URL" . >/dev/null 2>&1; then
        local latest_version=$(git tag | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 | sed 's/^v//')
        local current_version=$(get_current_version)
        
        echo "当前版本: $current_version"
        echo "最新版本: $latest_version"
        
        if [ "$current_version" != "$latest_version" ]; then
            echo "有新版本可用！"
            echo "执行更新: $0 update $latest_version"
        else
            echo "当前已是最新版本"
        fi
    else
        error "无法检查最新版本"
    fi
    
    rm -rf "$temp_dir"
}

# 命令行参数处理
case "$1" in
    "update")
        if [ -z "$2" ]; then
            error "请指定目标版本"
            echo "用法: $0 update <version>"
            exit 1
        fi
        update_to_version "$2"
        ;;
    "check")
        check_latest_version
        ;;
    "list")
        list_available_versions
        ;;
    "version")
        echo "当前版本: $(get_current_version)"
        ;;
    "rollback")
        if [ -z "$2" ]; then
            echo "可用备份:"
            ls -la "$BACKUP_DIR" 2>/dev/null || echo "无备份文件"
            exit 1
        fi
        rollback_to_backup "$2"
        ;;
    *)
        echo "用法: $0 {update|check|list|version|rollback}"
        echo "  update <version> - 更新到指定版本"
        echo "  check           - 检查最新版本"
        echo "  list            - 列出可用版本"
        echo "  version         - 显示当前版本"
        echo "  rollback <path> - 回滚到指定备份"
        exit 1
        ;;
esac 