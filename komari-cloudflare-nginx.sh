#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck shell=bash

# 将现有 Komari Docker 面板安全地置于 Nginx 与 Cloudflare 之后。
# 适用于 Debian 13（Trixie）。

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename -- "$0")
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.2.0"
readonly NGINX_SITE_NAME="komari"
readonly NGINX_SITE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
readonly NGINX_LINK="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
readonly CERT_DIRECTORY="/etc/nginx/ssl/komari"

DOMAIN=""
CERT_SOURCE=""
KEY_SOURCE=""
AOP_CA_SOURCE=""
KOMARI_DIRECTORY="/opt/komari"
CONTAINER_NAME="komari"
AUTO_SECURITY_UPDATES="ask"
ASSUME_YES=0

# 仅在交互式终端中输出颜色；重定向到日志或 CI 时保持纯文本。
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly COLOR_RESET=$'\033[0m'
  readonly COLOR_CYAN=$'\033[36m'
  readonly COLOR_GREEN=$'\033[32m'
  readonly COLOR_YELLOW=$'\033[33m'
  readonly COLOR_RED=$'\033[31m'
else
  readonly COLOR_RESET=''
  readonly COLOR_CYAN=''
  readonly COLOR_GREEN=''
  readonly COLOR_YELLOW=''
  readonly COLOR_RED=''
fi

log() {
  local color=$1 level=$2 message=$3
  printf '%b[%s]%b %s\n' "$color" "$level" "$COLOR_RESET" "$message"
}
info() { log "$COLOR_CYAN" '信息' "$*"; }
success() { log "$COLOR_GREEN" '完成' "$*"; }
warn() { log "$COLOR_YELLOW" '警告' "$*" >&2; }
die() { log "$COLOR_RED" '错误' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  log "$COLOR_RED" '错误' "脚本在第 ${BASH_LINENO[0]} 行失败（退出码 ${exit_code}）。未输出任何证书私钥或凭据。" >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<EOF
用法：
  ${SCRIPT_NAME} --domain 域名 --cert-file 路径 --key-file 路径 [选项]

主要参数：
  --domain 域名                对外访问域名，例如 komari.example.com
  --cert-file 路径             Cloudflare 源证书 PEM 文件（默认：/root/komari-origin/origin.pem）
  --key-file 路径              与源证书匹配的私钥 PEM 文件（默认：/root/komari-origin/origin.key）
  --cloudflare-aop-ca-file PATH
                              使用此 CA PEM 启用 Cloudflare AOP
  --enable-aop                 使用默认 AOP CA 路径启用 AOP：
                              /root/komari-origin/cloudflare-aop-ca.pem

可选参数：
  --komari-dir 路径            Komari 数据目录的上级目录（默认：/opt/komari）
  --container-name 名称        现有 Komari 容器名称（默认：komari）
  --enable-security-updates    启用 Debian 无人值守安全更新（包含 Nginx）
  --disable-security-updates   不修改现有的自动更新设置
  --yes                        跳过交互确认；仅限已核对所有参数时使用
  -h, --help                   显示本帮助

脚本不会创建、上传或输出私钥；它只通过 HTTPS 443 提供 Komari 服务，
并保留旧容器（停止状态）以便回滚。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请以 root 用户运行此脚本。"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "无法识别当前操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "此脚本仅支持 Debian；当前检测到：${ID:-未知}。"
  [[ "${VERSION_ID:-}" == "13" ]] || warn "脚本按 Debian 13 编写和测试；当前检测到 Debian ${VERSION_ID:-未知}。"
}

confirm() {
  local prompt=$1 answer
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N，直接回车=否]：" answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

is_valid_domain() {
  local value=${1,,}
  [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN=${2:-}; shift 2 ;;
      --cert-file) CERT_SOURCE=${2:-}; shift 2 ;;
      --key-file) KEY_SOURCE=${2:-}; shift 2 ;;
      --cloudflare-aop-ca-file) AOP_CA_SOURCE=${2:-}; shift 2 ;;
      --enable-aop) AOP_CA_SOURCE="/root/komari-origin/cloudflare-aop-ca.pem"; shift ;;
      --komari-dir) KOMARI_DIRECTORY=${2:-}; shift 2 ;;
      --container-name) CONTAINER_NAME=${2:-}; shift 2 ;;
      --enable-security-updates) AUTO_SECURITY_UPDATES="yes"; shift ;;
      --disable-security-updates) AUTO_SECURITY_UPDATES="no"; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1；使用 --help 查看帮助。" ;;
    esac
  done

  # 使用 README 推荐的保存路径时，无须每次重复输入证书路径。
  [[ -n "$CERT_SOURCE" ]] || CERT_SOURCE="/root/komari-origin/origin.pem"
  [[ -n "$KEY_SOURCE" ]] || KEY_SOURCE="/root/komari-origin/origin.key"

  if [[ -z "$DOMAIN" && "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "请输入 Komari 对外域名（例如 komari.example.com）：" DOMAIN
  fi
  [[ -n "$DOMAIN" ]] || die "必须提供 --domain，或在交互提示中输入域名。"
  DOMAIN=${DOMAIN,,}
  is_valid_domain "$DOMAIN" || die "域名格式无效：$DOMAIN"
  [[ -n "$CERT_SOURCE" ]] || die "必须提供 --cert-file。"
  [[ -n "$KEY_SOURCE" ]] || die "必须提供 --key-file。"
  [[ -r "$CERT_SOURCE" ]] || die "无法读取源证书：$CERT_SOURCE"
  [[ -r "$KEY_SOURCE" ]] || die "无法读取私钥：$KEY_SOURCE"
  [[ -z "$AOP_CA_SOURCE" || -r "$AOP_CA_SOURCE" ]] || die "无法读取 AOP CA 证书：$AOP_CA_SOURCE"
  [[ "$KOMARI_DIRECTORY" == /* ]] || die "--komari-dir 必须是绝对路径。"
  [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "容器名称格式无效。"
}

validate_certificate_pair() {
  command -v openssl >/dev/null 2>&1 || die "缺少 openssl，无法校验证书。"
  openssl x509 -in "$CERT_SOURCE" -noout >/dev/null || die "源证书 PEM 文件无效。"
  openssl pkey -in "$KEY_SOURCE" -noout >/dev/null || die "私钥 PEM 文件无效。"
  if [[ -n "$AOP_CA_SOURCE" ]]; then
    openssl x509 -in "$AOP_CA_SOURCE" -noout >/dev/null || die "AOP CA PEM 文件无效。"
  fi

  local certificate_key private_key
  certificate_key=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
  private_key=$(openssl pkey -in "$KEY_SOURCE" -pubout -outform DER | sha256sum)
  [[ "$certificate_key" == "$private_key" ]] || die "源证书与私钥不匹配；请确认两者来自同一次 Cloudflare 证书创建。"

  local certificate_names
  certificate_names=$(openssl x509 -in "$CERT_SOURCE" -noout -ext subjectAltName 2>/dev/null || true)
  if [[ "$certificate_names" != *"DNS:${DOMAIN}"* && "$certificate_names" != *"DNS:*.${DOMAIN#*.}"* ]]; then
    warn "无法确认源证书是否覆盖 ${DOMAIN}；继续前请在 Cloudflare 中核对证书主机名。"
  fi
}

install_nginx() {
  info "正在安装并启用 Nginx 与证书校验依赖。"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends nginx openssl ca-certificates curl
  systemctl enable --now nginx
}

configure_automatic_security_updates() {
  if [[ "$AUTO_SECURITY_UPDATES" == "ask" ]]; then
    if confirm "是否启用 Debian 无人值守安全更新？安全更新可能自动重启 Nginx"; then
      AUTO_SECURITY_UPDATES="yes"
    else
      AUTO_SECURITY_UPDATES="no"
    fi
  fi

  if [[ "$AUTO_SECURITY_UPDATES" == "yes" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends unattended-upgrades
    cat > /etc/apt/apt.conf.d/52komari-auto-security-updates <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    info "已启用 Debian 无人值守安全更新。"
  else
    info "未修改现有的自动更新设置。"
  fi
}

detect_komari_data_directory() {
  local current_data_directory
  current_data_directory="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [[ -n "$current_data_directory" ]]; then
    KOMARI_DIRECTORY="$(dirname "$current_data_directory")"
    DATA_DIRECTORY="$current_data_directory"
    info "检测到现有 Komari 数据目录：${DATA_DIRECTORY}"
  else
    DATA_DIRECTORY="${KOMARI_DIRECTORY}/data"
    mkdir -p "$DATA_DIRECTORY"
    info "未检测到现有 Komari 容器；将使用数据目录：${DATA_DIRECTORY}"
  fi
}

write_certificate_files() {
  info "正在安装 Cloudflare 源证书；私钥将以 0600 权限保存。"
  install -d -m 0750 "$CERT_DIRECTORY"
  install -m 0644 "$CERT_SOURCE" "${CERT_DIRECTORY}/origin.pem"
  install -m 0600 "$KEY_SOURCE" "${CERT_DIRECTORY}/origin.key"
  if [[ -n "$AOP_CA_SOURCE" ]]; then
    install -m 0644 "$AOP_CA_SOURCE" "${CERT_DIRECTORY}/cloudflare-aop-ca.pem"
  fi
}

write_nginx_configuration() {
  info "正在生成仅监听 TCP 443 的 Nginx HTTPS 反向代理配置。"
  local candidate backup="" aop_directives=""
  if [[ -n "$AOP_CA_SOURCE" ]]; then
    aop_directives="    ssl_client_certificate ${CERT_DIRECTORY}/cloudflare-aop-ca.pem;
    ssl_verify_client on;"
  fi
  candidate=$(mktemp /etc/nginx/sites-available/komari.XXXXXX)
  cat > "$candidate" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIRECTORY}/origin.pem;
    ssl_certificate_key ${CERT_DIRECTORY}/origin.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    server_tokens off;
${aop_directives}
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "DENY" always;

    location / {
        proxy_pass http://127.0.0.1:25774;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 50m;
    }
}
EOF

  if [[ -e "$NGINX_SITE" ]]; then
    backup="${NGINX_SITE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$NGINX_SITE" "$backup"
    info "已备份原有 Nginx 站点配置至：${backup}"
  fi
  install -m 0644 "$candidate" "$NGINX_SITE"
  rm -f "$candidate"
  ln -sfn "../sites-available/${NGINX_SITE_NAME}" "$NGINX_LINK"

  if ! nginx -t; then
    [[ -n "$backup" ]] && cp -a "$backup" "$NGINX_SITE"
    die "Nginx 配置校验失败；如存在旧配置，已恢复旧配置。"
  fi
}

migrate_komari_container() {
  command -v docker >/dev/null 2>&1 || die "未安装 Docker，无法继续。"
  systemctl is-active --quiet docker || systemctl enable --now docker

  local image backup_name=""
  info "正在将 Komari 从公网 Docker 端口映射迁移为仅本机监听。"
  image="ghcr.io/komari-monitor/komari:latest"
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
    backup_name="${CONTAINER_NAME}-before-nginx-$(date +%Y%m%d%H%M%S)"
    info "将停止并保留现有容器为 ${backup_name}，可用于回滚。"
    docker stop "$CONTAINER_NAME"
    docker rename "$CONTAINER_NAME" "$backup_name"
  fi

  if ! docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 127.0.0.1:25774:25774 \
    -v "${DATA_DIRECTORY}:/app/data" \
    "$image"; then
    if [[ -n "$backup_name" ]]; then
      warn "新容器创建失败，正在恢复原 Komari 容器。"
      docker rename "$backup_name" "$CONTAINER_NAME" || true
      docker start "$CONTAINER_NAME" || true
    fi
    die "无法创建新的 Komari 容器。"
  fi

  local status_code="" attempt
  for ((attempt = 1; attempt <= 12; attempt++)); do
    status_code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 http://127.0.0.1:25774/ || true)
    if [[ "$status_code" != "000" && -n "$status_code" ]]; then
      info "Komari 已就绪，本机连通性检查返回 HTTP ${status_code}。"
      break
    fi
    info "Komari 正在初始化；第 ${attempt}/12 次检查尚未响应，5 秒后重试。"
    sleep 5
  done

  if [[ "$status_code" == "000" || -z "$status_code" ]]; then
    if [[ -n "$backup_name" ]]; then
      warn "新 Komari 容器在约 60 秒内未就绪，正在恢复原容器。"
      docker stop "$CONTAINER_NAME" || true
      docker rm "$CONTAINER_NAME" || true
      docker rename "$backup_name" "$CONTAINER_NAME" || true
      docker start "$CONTAINER_NAME" || true
    fi
    die "Komari 在初始化等待期内未响应 127.0.0.1:25774；请使用 docker logs komari 查看原因。"
  fi
  [[ -z "$backup_name" ]] || warn "已保留停止状态的回滚容器：${backup_name}"
}

print_change_summary() {
  cat <<EOF

即将执行以下操作：
  1. 安装并启用 Nginx，且只为 Komari 配置 HTTPS TCP 443。
  2. 将 Komari Docker 映射改为 127.0.0.1:25774:25774，移除其公网入口。
  3. 保留现有 Komari 数据目录，不拉取新镜像，不删除数据。
  4. 将原 Komari 容器改名并停止，以便必要时回滚。

不会执行：打开防火墙端口、修改 SSH、输出私钥或上传任何凭据。
EOF
}

main() {
  require_root
  require_debian
  parse_arguments "$@"
  validate_certificate_pair

  info "正在运行 ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  info "目标 Komari 域名：${DOMAIN}"
  print_change_summary
  if ! confirm "已确认 Cloudflare 小黄云已开启、证书文件无误、VPS 防火墙已放行 TCP 443；是否继续"; then
    die "已取消，系统未开始修改。"
  fi

  install_nginx
  configure_automatic_security_updates
  detect_komari_data_directory
  write_certificate_files
  write_nginx_configuration
  migrate_komari_container
  systemctl reload nginx

  success "配置完成。"
  cat <<EOF

请在 Cloudflare 完成以下检查：
  1. 确认 ${DOMAIN} 的 DNS 记录保持【小黄云（已代理）】。
  2. SSL/TLS 加密模式设为【完全（严格）/ Full (strict)】。
  3. 开启【始终使用 HTTPS / Always Use HTTPS】。

现在访问：https://${DOMAIN}

防火墙原则：仅放行原有 SSH 端口与 TCP 443；不要开放 TCP 80、Komari 容器内部端口或旧公网端口。
EOF
  [[ -z "$AOP_CA_SOURCE" ]] || info 'Nginx 已启用 Cloudflare AOP；请确认 Cloudflare 对该域名的 AOP 也已开启。'
}

main "$@"
