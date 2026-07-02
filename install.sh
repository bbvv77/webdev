#!/bin/sh
set -eu

# ================= 配置变量 =================
VERSION="${VOHIVE_VERSION:-v1.5.5}"
NO_SYSTEMD=0
DRY_RUN=0
FORCE=0
ROOT_DIR="${VOHIVE_INSTALL_ROOT:-/opt/vohive}"
INSTALL_DIR="${ROOT_DIR}/bin"
CONFIG_DIR="${ROOT_DIR}/config"
DATA_DIR="${ROOT_DIR}/data"
LOG_DIR="${ROOT_DIR}/logs"
BIN_PATH="${INSTALL_DIR}/vohive"
BACKUP_PATH="${INSTALL_DIR}/vohive.bak"
SYSTEMD_SERVICE_PATH="${VOHIVE_SYSTEMD_SERVICE_PATH:-/etc/systemd/system/vohive.service}"
OPENWRT_INIT_PATH="${VOHIVE_OPENWRT_INIT_PATH:-/etc/init.d/vohive}"

# 固定的基础下载 URL
BASE_URL="https://raw.githubusercontent.com/bbvv77/webdev/refs/heads/main/vohive"

# ================= 辅助函数 =================
log() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$1"
}

err() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" >&2
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --version <ver>   指定版本号 (默认: v1.5.5)
  --no-systemd      不安装 systemd/init 服务
  --dry-run         仅打印操作，不实际执行
  --force           强制覆盖安装
  -h, --help        显示帮助信息
EOF
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        err "需要 root 权限（请使用 root 用户或安装 sudo）。"
        exit 1
    fi
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "缺少命令: $1"
        exit 1
    fi
}

need_download_cmd() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOAD_CMD="curl"
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        DOWNLOAD_CMD="wget"
        return 0
    fi
    err "缺少下载命令: 需要 curl 或 wget"
    exit 1
}

download_to() {
    url="$1"
    dest="$2"
    log "正在下载: $url"
    if [ "${DOWNLOAD_CMD}" = "curl" ]; then
        curl -fsSL "$url" -o "$dest"
    else
        wget -q -O "$dest" "$url"
    fi
}

# ================= 架构与平台检测 =================
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7|armv7l) printf 'armv7' ;;
        *)
            err "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

detect_platform() {
    if [ -n "${VOHIVE_PLATFORM_OVERRIDE:-}" ]; then
        printf '%s' "${VOHIVE_PLATFORM_OVERRIDE}"
        return 0
    fi

    if [ -d /etc/init.d ] && [ -f /etc/openwrt_release ]; then
        printf 'openwrt'
    elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        printf 'systemd'
    else
        printf 'unknown'
    fi
}

# ================= 参数解析 =================
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                if [ "$#" -lt 2 ]; then err "--version 缺少参数"; usage; exit 1; fi
                VERSION="$2"
                shift 2
                ;;
            --no-systemd) NO_SYSTEMD=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --force) FORCE=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) err "未知参数: $1"; usage; exit 1 ;;
        esac
    done
}

# ================= 服务与配置管理 =================
install_default_config() {
    run_root mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"
    if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
        log "生成默认配置文件..."
        run_root sh -c "cat > '${CONFIG_DIR}/config.yaml' <<EOF
# VoHive 默认配置
server:
  port: 8080
data_dir: ${DATA_DIR}
log_dir: ${LOG_DIR}
EOF"
    fi
}

restart_service() {
    platform="$1"
    case "${platform}" in
        systemd) run_root systemctl daemon-reload && run_root systemctl restart vohive || true ;;
        openwrt) run_root /etc/init.d/vohive restart || true ;;
    esac
}

install_service_systemd() {
    tmp_unit_path="$1"
    cat >"${tmp_unit_path}" <<EOF
[Unit]
Description=VoHive Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${ROOT_DIR}
ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    run_root install -m 0644 "${tmp_unit_path}" "${SYSTEMD_SERVICE_PATH}"
    run_root systemctl daemon-reload
    run_root systemctl enable vohive
    run_root systemctl restart vohive
    run_root systemctl is-active --quiet vohive
}

install_service_openwrt() {
    tmp_init_path="$1"
    cat >"${tmp_init_path}" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command ${BIN_PATH} -c ${CONFIG_DIR}/config.yaml
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    run_root install -m 0755 "${tmp_init_path}" "${OPENWRT_INIT_PATH}"
    run_root /etc/init.d/vohive enable
    run_root /etc/init.d/vohive restart
}

# ================= 主逻辑 =================
main() {
    parse_args "$@"
    
    need_cmd mkdir
    need_cmd cp
    need_cmd rm
    need_cmd chmod
    need_download_cmd

    ARCH="$(detect_arch)"
    PLATFORM="$(detect_platform)"
    
    log "检测架构: ${ARCH}"
    log "检测平台: ${PLATFORM}"
    log "目标版本: ${VERSION}"

    # 构造下载 URL (例: .../vohive_v1.5.5-amd64)
    DOWNLOAD_URL="${BASE_URL}/vohive_${VERSION}-${ARCH}"
    
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT
    
    TMP_BIN="${TMP_DIR}/vohive_bin"
    
    # 下载二进制文件
    if ! download_to "${DOWNLOAD_URL}" "${TMP_BIN}"; then
        err "下载失败，请检查网络或 URL 是否正确: ${DOWNLOAD_URL}"
        exit 1
    fi
    
    if [ ! -f "${TMP_BIN}" ] || [ ! -s "${TMP_BIN}" ]; then
        err "下载的二进制文件不存在或为空 (可能架构或版本不匹配)"
        exit 1
    fi

    if [ "${DRY_RUN}" = "1" ]; then
        log "[Dry Run] 将安装二进制文件到: ${BIN_PATH}"
        log "[Dry Run] 下载链接: ${DOWNLOAD_URL}"
        exit 0
    fi

    # 创建目录
    run_root mkdir -p "${INSTALL_DIR}"
    
    # 备份旧版本
    rollback_needed=0
    if [ -x "${BIN_PATH}" ]; then
        log "检测到已安装版本，备份到: ${BACKUP_PATH}"
        run_root cp -f "${BIN_PATH}" "${BACKUP_PATH}"
        rollback_needed=1
    fi
    
    # 回滚函数
    rollback() {
        if [ "${rollback_needed}" = "1" ] && [ -f "${BACKUP_PATH}" ]; then
            err "安装失败，正在回滚到上一个版本..."
            run_root cp -f "${BACKUP_PATH}" "${BIN_PATH}" || true
            run_root chmod +x "${BIN_PATH}" || true
            if [ "${NO_SYSTEMD}" = "0" ]; then
                restart_service "${PLATFORM}"
            fi
        fi
    }
    
    # 设置失败时的回滚陷阱
    trap 'rollback; rm -rf "${TMP_DIR}"' EXIT

    # 安装二进制文件
    log "正在安装二进制文件到 ${BIN_PATH}..."
    run_root install -m 0755 "${TMP_BIN}" "${BIN_PATH}"
    
    # 安装默认配置
    install_default_config

    # 安装服务
    service_registered=0
    if [ "${NO_SYSTEMD}" = "0" ]; then
        case "${PLATFORM}" in
            systemd)
                log "正在注册 systemd 服务..."
                install_service_systemd "${TMP_DIR}/vohive.service"
                service_registered=1
                ;;
            openwrt)
                log "正在注册 OpenWrt init 服务..."
                install_service_openwrt "${TMP_DIR}/vohive.init"
                service_registered=1
                ;;
            *)
                log "未检测到 systemd 或 OpenWrt 环境，跳过服务注册。"
                ;;
        esac
    fi

    # 清除回滚陷阱，因为安装成功了
    trap 'rm -rf "${TMP_DIR}"' EXIT
    
    log "VoHive ${VERSION} (${ARCH}) 安装成功！"
    if [ "${service_registered}" = "1" ]; then
        log "服务已启动。"
    else
        log "你可以手动运行: ${BIN_PATH} -c ${CONFIG_DIR}/config.yaml"
    fi
}

main "$@"
