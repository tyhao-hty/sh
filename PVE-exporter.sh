#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="prometheus-pve-exporter"
VENV_DIR="/opt/prometheus-pve-exporter"
CONFIG_DIR="/etc/prometheus"
CONFIG_FILE="${CONFIG_DIR}/pve.yml"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

PVE_USER="prometheus@pve"
PVE_PASSWORD="hh000000"
PVE_ROLE="PVEAuditor"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_os() {
  step "检查运行环境"

  if command_exists pveversion; then
    log "检测到 Proxmox VE 环境：$(pveversion | head -n 1)"
  else
    warn "未检测到 pveversion，当前主机可能不是 PVE 节点。"
  fi

  if ! command_exists systemctl; then
    err "当前系统未检测到 systemd，无法继续配置服务。"
    exit 1
  fi

  log "系统环境检查通过。"
}

install_dependencies() {
  step "安装依赖"

  if dpkg -s python3-venv >/dev/null 2>&1; then
    log "python3-venv 已安装，跳过。"
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3-venv
  log "python3-venv 安装完成。"
}

create_venv() {
  step "创建 Python 虚拟环境"

  if [[ -x "${VENV_DIR}/bin/python3" && -x "${VENV_DIR}/bin/pip" ]]; then
    log "虚拟环境已存在且可用：${VENV_DIR}"
    return
  fi

  mkdir -p "$(dirname "${VENV_DIR}")"
  python3 -m venv "${VENV_DIR}"
  log "已创建虚拟环境：${VENV_DIR}"
}

install_exporter() {
  step "安装 prometheus-pve-exporter"

  if [[ -x "${VENV_DIR}/bin/pve_exporter" ]]; then
    if "${VENV_DIR}/bin/pve_exporter" --help >/dev/null 2>&1; then
      log "现有 pve_exporter 可正常运行，跳过重复安装。"
      return
    else
      warn "现有 pve_exporter 不可用，将重新安装。"
    fi
  fi

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

ensure_pve_user_and_acl() {
  step "PVE 用户与权限检查/创建"

  if ! command_exists pveum; then
    warn "未检测到 pveum，跳过 PVE 用户自动创建。"
    warn "请确认你已经在 PVE 平台创建了用户 ${PVE_USER} 并授予只读权限。"
    return
  fi

  local user_add_err=""
  local acl_add_err=""
  local tmp_err=""

  tmp_err="$(mktemp)"
  if pveum user add "${PVE_USER}" --password "${PVE_PASSWORD}" 2>"${tmp_err}"; then
    log "PVE 用户已创建：${PVE_USER}"
  else
    user_add_err="$(cat "${tmp_err}")"
    if echo "${user_add_err}" | grep -qi "already exists"; then
      log "PVE 用户已存在：${PVE_USER}，跳过创建。"
    else
      err "创建 PVE 用户失败：${user_add_err}"
      rm -f "${tmp_err}"
      exit 1
    fi
  fi
  rm -f "${tmp_err}"

  if pveum acl list 2>/dev/null | grep -Fq "/ ${PVE_USER} ${PVE_ROLE}"; then
    log "用户 ${PVE_USER} 已具备 / 路径 ${PVE_ROLE} 权限，跳过授权。"
  else
    tmp_err="$(mktemp)"
    if pveum aclmod / -user "${PVE_USER}" -role "${PVE_ROLE}" 2>"${tmp_err}"; then
      log "已授予 ${PVE_USER} 角色 ${PVE_ROLE}。"
    else
      acl_add_err="$(cat "${tmp_err}")"
      err "授予 ACL 权限失败：${acl_add_err}"
      rm -f "${tmp_err}"
      exit 1
    fi
    rm -f "${tmp_err}"
  fi

  log "当前用户信息："
  pveum user list | grep -F "${PVE_USER}" || true

  log "当前 ACL 条目："
  pveum acl list | grep -F "${PVE_USER}" || true
}

write_config() {
  step "检查并写入 exporter 配置文件"

  mkdir -p "${CONFIG_DIR}"

  local tmpfile
  tmpfile="$(mktemp)"
  cat > "${tmpfile}" <<EOF
default:
    user: ${PVE_USER}
    password: ${PVE_PASSWORD}
    verify_ssl: false
EOF

  if [[ -f "${CONFIG_FILE}" ]] && cmp -s "${tmpfile}" "${CONFIG_FILE}"; then
    log "配置文件已存在且内容一致，跳过写入：${CONFIG_FILE}"
    rm -f "${tmpfile}"
    chmod 600 "${CONFIG_FILE}"
    return
  fi

  mv "${tmpfile}" "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
  log "配置文件已写入：${CONFIG_FILE}"
}

write_service() {
  step "检查并写入 systemd 服务文件"

  local tmpfile
  tmpfile="$(mktemp)"
  cat > "${tmpfile}" <<EOF
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

  if [[ -f "${SERVICE_FILE}" ]] && cmp -s "${tmpfile}" "${SERVICE_FILE}"; then
    log "systemd 服务文件已存在且内容一致，跳过写入。"
    rm -f "${tmpfile}"
    return
  fi

  mv "${tmpfile}" "${SERVICE_FILE}"
  log "服务文件已写入：${SERVICE_FILE}"
}

reload_enable_start_service() {
  step "加载 systemd、设置开机自启并启动服务"

  systemctl daemon-reload

  if systemctl is-enabled "${APP_NAME}" >/dev/null 2>&1; then
    log "服务已设置为开机自启，跳过 enable。"
  else
    systemctl enable "${APP_NAME}"
    log "已设置服务开机自启。"
  fi

  if systemctl is-active --quiet "${APP_NAME}"; then
    log "服务当前已在运行，重启以应用最新配置。"
    systemctl restart "${APP_NAME}"
  else
    log "服务当前未运行，启动服务。"
    systemctl start "${APP_NAME}"
  fi

  sleep 2

  if systemctl is-active --quiet "${APP_NAME}"; then
    log "服务运行正常：${APP_NAME}"
  else
    err "服务启动失败。"
    systemctl status "${APP_NAME}" --no-pager -l || true
    journalctl -u "${APP_NAME}" -n 100 --no-pager || true
    exit 1
  fi
}

post_checks() {
  step "最终检查与诊断信息"

  echo "----- 服务状态 -----"
  systemctl status "${APP_NAME}" --no-pager -l || true

  echo
  echo "----- 开机自启状态 -----"
  systemctl is-enabled "${APP_NAME}" || true

  echo
  echo "----- 端口监听检查 -----"
  if command_exists ss; then
    ss -lntp | grep -E 'pve_exporter|:9221' || warn "未明确看到 9221 监听，请结合日志判断。"
  fi

  echo
  echo "----- 本机指标测试建议 -----"
  echo "curl http://127.0.0.1:9221/metrics | head"
}

main() {
  require_root
  check_os
  install_dependencies
  create_venv
  install_exporter
  verify_binary
  ensure_pve_user_and_acl
  write_config
  write_service
  reload_enable_start_service
  post_checks

  echo
  log "全部步骤执行完成。"
}

main "$@"
