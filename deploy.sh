#!/bin/bash
# 部署脚本 - deploy.sh
# 功能：拉取指定版本代码，构建并部署应用

set -e  # 遇到错误立即退出

# 配置变量
VERSION="1.7.9"
PROJECT_NAME="andejiazhengcrm"
GIT_REPO_URL="https://github.com/your-org/${PROJECT_NAME}.git"  # 请替换为实际仓库地址
DEPLOY_DIR="/opt/${PROJECT_NAME}"
BACKUP_DIR="/opt/backups/${PROJECT_NAME}"
SERVICE_NAME="${PROJECT_NAME}"
LOG_FILE="/var/log/${PROJECT_NAME}_deploy.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# 检查权限
check_permissions() {
    log "检查部署权限..."
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
}

# 备份当前版本
backup_current_version() {
    log "备份当前版本..."
    if [ -d "$DEPLOY_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        backup_name="${PROJECT_NAME}_backup_$(date +%Y%m%d_%H%M%S)"
        cp -r "$DEPLOY_DIR" "${BACKUP_DIR}/${backup_name}"
        log "备份完成: ${BACKUP_DIR}/${backup_name}"
    fi
}

# 停止服务
stop_service() {
    log "停止服务..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        log "服务已停止"
    else
        warn "服务未运行"
    fi
}

# 拉取代码
clone_or_pull_code() {
    log "拉取代码版本 $VERSION..."
    
    if [ ! -d "$DEPLOY_DIR" ]; then
        log "首次部署，克隆仓库..."
        git clone "$GIT_REPO_URL" "$DEPLOY_DIR"
        cd "$DEPLOY_DIR"
    else
        log "更新现有仓库..."
        cd "$DEPLOY_DIR"
        git fetch --all --tags
    fi
    
    # 检出指定版本
    log "检出版本 $VERSION..."
    git checkout "tags/v$VERSION" -b "release-$VERSION" 2>/dev/null || git checkout "v$VERSION" 2>/dev/null || git checkout "$VERSION"
    log "当前版本: $(git describe --tags)"
}

# 安装依赖
install_dependencies() {
    log "安装依赖..."
    cd "$DEPLOY_DIR"
    
    # 检测项目类型并安装依赖
    if [ -f "package.json" ]; then
        log "检测到Node.js项目，安装npm依赖..."
        npm install --production
    elif [ -f "requirements.txt" ]; then
        log "检测到Python项目，安装pip依赖..."
        pip3 install -r requirements.txt
    elif [ -f "pom.xml" ]; then
        log "检测到Java项目，执行Maven构建..."
        mvn clean package -DskipTests
    elif [ -f "go.mod" ]; then
        log "检测到Go项目，构建二进制文件..."
        go build -o "${PROJECT_NAME}" .
    else
        warn "未检测到已知的项目类型，跳过依赖安装"
    fi
}

# 构建应用
build_application() {
    log "构建应用..."
    cd "$DEPLOY_DIR"
    
    # 如果存在Docker，使用Docker构建
    if [ -f "Dockerfile" ]; then
        log "使用Docker构建应用..."
        docker build -t "${PROJECT_NAME}:${VERSION}" .
        docker tag "${PROJECT_NAME}:${VERSION}" "${PROJECT_NAME}:latest"
    elif [ -f "docker-compose.yml" ]; then
        log "使用Docker Compose构建应用..."
        docker-compose build
    else
        log "使用传统方式构建..."
        # 这里可以添加其他构建命令
        if [ -f "build.sh" ]; then
            chmod +x build.sh
            ./build.sh
        fi
    fi
}

# 配置应用
configure_application() {
    log "配置应用..."
    cd "$DEPLOY_DIR"
    
    # 复制配置文件
    if [ -f "config/production.env.example" ]; then
        cp config/production.env.example config/production.env
        log "请手动编辑 config/production.env 文件"
    fi
    
    # 设置权限
    chown -R www-data:www-data "$DEPLOY_DIR" 2>/dev/null || true
    chmod -R 755 "$DEPLOY_DIR"
}

# 启动服务
start_service() {
    log "启动服务..."
    cd "$DEPLOY_DIR"
    
    if [ -f "docker-compose.yml" ]; then
        log "使用Docker Compose启动服务..."
        docker-compose up -d
    elif systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        log "使用systemd启动服务..."
        systemctl start "$SERVICE_NAME"
        systemctl enable "$SERVICE_NAME"
    else
        warn "未找到服务配置，请手动启动应用"
    fi
}

# 健康检查
health_check() {
    log "执行健康检查..."
    
    # 等待服务启动
    sleep 10
    
    # 检查端口是否监听（假设默认端口8080）
    PORT=${HEALTH_CHECK_PORT:-8080}
    if netstat -tuln | grep -q ":$PORT "; then
        log "端口 $PORT 正在监听"
    else
        warn "端口 $PORT 未监听，可能需要更长时间启动"
    fi
    
    # 检查HTTP服务（如果适用）
    if command -v curl >/dev/null 2>&1; then
        if curl -f "http://localhost:$PORT/health" >/dev/null 2>&1; then
            log "健康检查通过"
        else
            warn "健康检查失败，但这可能是正常的"
        fi
    fi
}

# 清理函数
cleanup() {
    log "清理临时文件..."
    # 清理Docker镜像
    docker image prune -f >/dev/null 2>&1 || true
}

# 主部署流程
main() {
    log "开始部署 $PROJECT_NAME 版本 $VERSION"
    
    check_permissions
    backup_current_version
    stop_service
    clone_or_pull_code
    install_dependencies
    build_application
    configure_application
    start_service
    health_check
    cleanup
    
    log "部署完成！版本: $VERSION"
    log "日志文件: $LOG_FILE"
}

# 回滚函数
rollback() {
    log "开始回滚..."
    
    if [ -z "$1" ]; then
        error "请指定回滚的备份目录"
        exit 1
    fi
    
    backup_path="$1"
    if [ ! -d "$backup_path" ]; then
        error "备份目录不存在: $backup_path"
        exit 1
    fi
    
    stop_service
    rm -rf "$DEPLOY_DIR"
    cp -r "$backup_path" "$DEPLOY_DIR"
    start_service
    health_check
    
    log "回滚完成"
}

# 命令行参数处理
case "$1" in
    "deploy")
        main
        ;;
    "rollback")
        rollback "$2"
        ;;
    "stop")
        stop_service
        ;;
    "start")
        start_service
        ;;
    "status")
        systemctl status "$SERVICE_NAME" || docker-compose ps
        ;;
    *)
        echo "用法: $0 {deploy|rollback|start|stop|status}"
        echo "  deploy  - 部署应用"
        echo "  rollback <backup_path> - 回滚到指定版本"
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  status  - 查看服务状态"
        exit 1
        ;;
esac 