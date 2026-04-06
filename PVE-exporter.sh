#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="prometheus-pve-exporter"
VENV_DIR="/opt/prometheus-pve-exporter"
CONFIG_DIR="/etc/prometheus"
CONFIG_FILE="${CONFIG_DIR}/pve.yml"
SERVICE_FILE="/etc/systemd/system/prometheus-pve-exporter.service"

PVE_USER="prometheus@pve"
PVE_PASSWORD="hh000000"
PVE_ROLE="PVEAuditor"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

err() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

step() {
  echo
  echo -e "${BLUE}========== $* ==========${NC}"
}

on_error() {
  local exit_code=$?
  err "脚本执行失败，退出码: ${exit_code}"
  warn "建议执行以下命令进一步诊断："
  echo "  systemctl status ${APP_NAME} --no-pager -l"
  echo "  journalctl -u ${APP_NAME} -n 100 --no-pager"
  echo "  ${VENV_DIR}/bin/pve_exporter --help"
  exit "${exit_code}"
}
trap on_error ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请以 root 身份运行此脚本。"
    exit 1
  fi
}

check_os() {
  step "检查运行环境"
  if command -v pveversion >/dev/null 2>&1; then
    log "检测到 Proxmox VE 环境：$(pveversion | head -n 1)"
  else
    warn "未检测到 pveversion，当前主机可能不是 PVE 节点。"
    warn "如果这台机器不是 PVE 宿主机，那么创建 PVE 用户/权限那一步需要你在真正的 PVE 平台上完成。"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    err "当前系统未检测到 systemd，无法继续配置服务。"
    exit 1
  fi

  log "系统环境检查通过。"
}

install_dependencies() {
  step "安装依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3-venv
  log "python3-venv 安装完成。"
}

create_venv() {
  step "创建 Python 虚拟环境"
  if [[ -d "${VENV_DIR}" ]]; then
    warn "虚拟环境目录已存在：${VENV_DIR}"
  else
    python3 -m venv "${VENV_DIR}"
    log "已创建虚拟环境：${VENV_DIR}"
  fi
}

install_exporter() {
  step "安装 prometheus-pve-exporter"
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install --upgrade prometheus-pve-exporter
  log "prometheus-pve-exporter 安装完成。"
}

verify_binary() {
  step "检查 pve_exporter 可执行文件"

  if [[ ! -x "${VENV_DIR}/bin/pve_exporter" ]]; then
    err "未找到可执行文件：${VENV_DIR}/bin/pve_exporter"
    exit 1
  fi

  "${VENV_DIR}/bin/pve_exporter" --help >/dev/null
  log "pve_exporter 可执行检查通过。"

  log "版本/帮助信息预检完成。"
}

maybe_create_pve_user() {
  step "PVE 用户与权限检查/创建"

  if ! command -v pveum >/dev/null 2>&1; then
    warn "未检测到 pveum，跳过 PVE 用户自动创建。"
    warn "请确认你已经在 PVE 平台创建了用户 ${PVE_USER} 并授予只读权限。"
    return
  fi

  if pveum user list | awk 'NR>1 {print $1}' | grep -Fxq "${PVE_USER}"; then
    warn "PVE 用户已存在：${PVE_USER}，跳过创建。"
  else
    log "创建 PVE 用户：${PVE_USER}"
    pveum user add "${PVE_USER}" --password "${PVE_PASSWORD}"
    log "PVE 用户已创建。"
  fi

  if pveum acl list | awk 'NR>1 {print $1, $2, $3}' | grep -Fq "/ ${PVE_USER} ${PVE_ROLE}"; then
    warn "用户 ${PVE_USER} 已拥有 / 路径上的 ${PVE_ROLE} 权限，跳过授权。"
  else
    log "授予 ${PVE_USER} 只读角色：${PVE_ROLE}"
    pveum aclmod / -user "${PVE_USER}" -role "${PVE_ROLE}"
    log "权限授予完成。"
  fi

  log "当前用户信息："
  pveum user list | grep -F "${PVE_USER}" || true

  log "当前 ACL 条目："
  pveum acl list | grep -F "${PVE_USER}" || true
}

write_config() {
  step "写入 exporter 配置文件"

  mkdir -p "${CONFIG_DIR}"
  cat > "${CONFIG_FILE}" <<EOF
default:
    user: ${PVE_USER}
    password: ${PVE_PASSWORD}
    verify_ssl: false
EOF

  chmod 600 "${CONFIG_FILE}"
  log "配置文件已写入：${CONFIG_FILE}"
  log "已设置权限为 600。"
}

write_service() {
  step "写入 systemd 服务文件"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Prometheus exporter for Proxmox VE
Documentation=https://github.com/znerol/prometheus-pve-exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
User=root
ExecStart=${VENV_DIR}/bin/pve_exporter --config.file ${CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF

  log "服务文件已写入：${SERVICE_FILE}"
}

reload_and_start_service() {
  step "重载 systemd 并启动服务"

  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}"

  sleep 2

  if systemctl is-active --quiet "${APP_NAME}"; then
    log "服务已成功启动：${APP_NAME}"
  else
    err "服务未成功启动。"
    systemctl status "${APP_NAME}" --no-pager -l || true
    journalctl -u "${APP_NAME}" -n 100 --no-pager || true
    exit 1
  fi
}

post_checks() {
  step "最终检查与诊断信息"

  echo "----- systemctl status -----"
  systemctl status "${APP_NAME}" --no-pager -l || true

  echo
  echo "----- 监听端口检查（若系统安装了 ss）-----"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp | grep -E 'pve_exporter|:9221' || warn "未明确看到 9221 监听，请结合日志判断。"
  fi

  echo
  echo "----- 访问建议 -----"
  echo "你现在可以在本机尝试："
  echo "  curl http://127.0.0.1:9221/metrics | head"
  echo
  echo "如果失败，请查看："
  echo "  journalctl -u ${APP_NAME} -n 100 --no-pager"
  echo
  echo "Prometheus 抓取配置示例："
  cat <<EOF
scrape_configs:
  - job_name: 'pve'
    static_configs:
      - targets: ['$(hostname -I | awk '{print $1}'):9221']
EOF
}

main() {
  require_root
  check_os
  install_dependencies
  create_venv
  install_exporter
  verify_binary
  maybe_create_pve_user
  write_config
  write_service
  reload_and_start_service
  post_checks

  echo
  log "全部步骤执行完成。"
}

main "$@"
