#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# shellcheck shell=bash

# Securely place an existing Komari Docker installation behind Nginx and
# Cloudflare. Designed for Debian 13 (Trixie).

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename -- "$0")
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly NGINX_SITE_NAME="komari"
readonly NGINX_SITE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
readonly NGINX_LINK="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
readonly CERT_DIRECTORY="/etc/nginx/ssl/komari"

DOMAIN=""
CERT_SOURCE=""
KEY_SOURCE=""
KOMARI_DIRECTORY="/opt/komari"
CONTAINER_NAME="komari"
AUTO_SECURITY_UPDATES="ask"
ASSUME_YES=0

log() { printf '[%s] %s\n' "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*" >&2; }
die() { log ERROR "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  log ERROR "Failed at line ${BASH_LINENO[0]} (exit ${exit_code}). No credentials were printed."
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --domain DOMAIN --cert-file PATH --key-file PATH [options]

Required:
  --domain DOMAIN              Public hostname, for example komari.example.com
  --cert-file PATH             Cloudflare Origin Certificate PEM file
  --key-file PATH              Matching Cloudflare Origin private-key PEM file

Options:
  --komari-dir PATH            Komari data parent directory (default: /opt/komari)
  --container-name NAME        Existing Komari container name (default: komari)
  --enable-security-updates    Enable Debian unattended security updates (including Nginx)
  --disable-security-updates   Do not change unattended-update settings
  --yes                        Do not ask for confirmation
  -h, --help                   Show this help

The script does not create, upload, or print private keys. It keeps the old
Komari container stopped under a timestamped backup name for rollback.
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

require_debian() {
  [[ -r /etc/os-release ]] || die "Cannot identify the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "This script supports Debian only; detected ${ID:-unknown}."
  [[ "${VERSION_ID:-}" == "13" ]] || warn "Designed and tested for Debian 13; detected Debian ${VERSION_ID:-unknown}."
}

confirm() {
  local prompt=$1 answer
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " answer
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
      --komari-dir) KOMARI_DIRECTORY=${2:-}; shift 2 ;;
      --container-name) CONTAINER_NAME=${2:-}; shift 2 ;;
      --enable-security-updates) AUTO_SECURITY_UPDATES="yes"; shift ;;
      --disable-security-updates) AUTO_SECURITY_UPDATES="no"; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  if [[ -z "$DOMAIN" && "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "Komari public domain (for example komari.example.com): " DOMAIN
  fi
  [[ -n "$DOMAIN" ]] || die "--domain is required."
  DOMAIN=${DOMAIN,,}
  is_valid_domain "$DOMAIN" || die "Invalid domain name: $DOMAIN"
  [[ -n "$CERT_SOURCE" ]] || die "--cert-file is required."
  [[ -n "$KEY_SOURCE" ]] || die "--key-file is required."
  [[ -r "$CERT_SOURCE" ]] || die "Certificate is not readable: $CERT_SOURCE"
  [[ -r "$KEY_SOURCE" ]] || die "Private key is not readable: $KEY_SOURCE"
  [[ "$KOMARI_DIRECTORY" == /* ]] || die "--komari-dir must be an absolute path."
  [[ "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "Invalid container name."
}

validate_certificate_pair() {
  command -v openssl >/dev/null 2>&1 || die "openssl is required."
  openssl x509 -in "$CERT_SOURCE" -noout >/dev/null || die "Invalid certificate PEM file."
  openssl pkey -in "$KEY_SOURCE" -noout >/dev/null || die "Invalid private-key PEM file."

  local certificate_key private_key
  certificate_key=$(openssl x509 -in "$CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
  private_key=$(openssl pkey -in "$KEY_SOURCE" -pubout -outform DER | sha256sum)
  [[ "$certificate_key" == "$private_key" ]] || die "The certificate and private key do not match."

  local certificate_names
  certificate_names=$(openssl x509 -in "$CERT_SOURCE" -noout -ext subjectAltName 2>/dev/null || true)
  if [[ "$certificate_names" != *"DNS:${DOMAIN}"* && "$certificate_names" != *"DNS:*.${DOMAIN#*.}"* ]]; then
    warn "Could not confirm that the certificate covers ${DOMAIN}. Check its SAN entries before continuing."
  fi
}

install_nginx() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends nginx openssl ca-certificates curl
  systemctl enable --now nginx
}

configure_automatic_security_updates() {
  if [[ "$AUTO_SECURITY_UPDATES" == "ask" ]]; then
    if confirm "Enable Debian unattended security updates (this can update and restart Nginx automatically)?"; then
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
    info "Enabled Debian unattended security updates."
  else
    info "Unattended-update settings were left unchanged."
  fi
}

detect_komari_data_directory() {
  local current_data_directory
  current_data_directory="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [[ -n "$current_data_directory" ]]; then
    KOMARI_DIRECTORY="$(dirname "$current_data_directory")"
    DATA_DIRECTORY="$current_data_directory"
    info "Using the existing Komari data directory: ${DATA_DIRECTORY}"
  else
    DATA_DIRECTORY="${KOMARI_DIRECTORY}/data"
    mkdir -p "$DATA_DIRECTORY"
    info "No existing Komari container found; using ${DATA_DIRECTORY}."
  fi
}

write_certificate_files() {
  install -d -m 0750 "$CERT_DIRECTORY"
  install -m 0644 "$CERT_SOURCE" "${CERT_DIRECTORY}/origin.pem"
  install -m 0600 "$KEY_SOURCE" "${CERT_DIRECTORY}/origin.key"
}

write_nginx_configuration() {
  local candidate backup=""
  candidate=$(mktemp /etc/nginx/sites-available/komari.XXXXXX)
  cat > "$candidate" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIRECTORY}/origin.pem;
    ssl_certificate_key ${CERT_DIRECTORY}/origin.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_tokens off;

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
    info "Backed up existing Nginx site to ${backup}."
  fi
  install -m 0644 "$candidate" "$NGINX_SITE"
  rm -f "$candidate"
  ln -sfn "../sites-available/${NGINX_SITE_NAME}" "$NGINX_LINK"

  if ! nginx -t; then
    [[ -n "$backup" ]] && cp -a "$backup" "$NGINX_SITE"
    die "Nginx configuration test failed; previous site configuration was restored when available."
  fi
}

migrate_komari_container() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed."
  systemctl is-active --quiet docker || systemctl enable --now docker

  local image backup_name=""
  image="ghcr.io/komari-monitor/komari:latest"
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
    backup_name="${CONTAINER_NAME}-before-nginx-$(date +%Y%m%d%H%M%S)"
    info "Preserving the existing container as ${backup_name} for rollback."
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
      warn "Restoring the prior Komari container."
      docker rename "$backup_name" "$CONTAINER_NAME" || true
      docker start "$CONTAINER_NAME" || true
    fi
    die "Could not create the replacement Komari container."
  fi

  local status_code
  status_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 http://127.0.0.1:25774/ || true)
  [[ "$status_code" != "000" && -n "$status_code" ]] || die "Komari did not answer on 127.0.0.1:25774 after migration."
  info "Komari local health check returned HTTP ${status_code}."
  [[ -z "$backup_name" ]] || warn "Retained stopped rollback container: ${backup_name}"
}

main() {
  require_root
  require_debian
  parse_arguments "$@"
  validate_certificate_pair

  info "${SCRIPT_NAME} ${SCRIPT_VERSION}"
  info "Target hostname: ${DOMAIN}"
  info "Komari will be reachable only through Nginx on ports 80/443; Docker will bind 25774 to loopback."
  if ! confirm "Continue with Nginx setup and Komari port migration?"; then
    die "Cancelled by user."
  fi

  install_nginx
  configure_automatic_security_updates
  detect_komari_data_directory
  write_certificate_files
  write_nginx_configuration
  migrate_komari_container
  systemctl reload nginx

  cat <<EOF

Setup complete.

Next steps in Cloudflare:
  1. Keep the DNS record for ${DOMAIN} proxied (orange cloud).
  2. Set SSL/TLS encryption mode to Full (strict).
  3. Enable Always Use HTTPS.

Open: https://${DOMAIN}

Only allow your existing SSH port plus ports 80 and 443 in your VPS firewall. Do not reopen Komari's internal or former public port.
EOF
}

main "$@"
