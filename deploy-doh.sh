#!/usr/bin/env bash
set -euo pipefail

DNSPROXY_VERSION="v0.82.1-custom"
DNSPROXY_BASE_DIR="/opt/dnsproxy"
DNSPROXY_BIN_DIR="${DNSPROXY_BASE_DIR}"
DNSPROXY_BINARY="${DNSPROXY_BIN_DIR}/dnsproxy"
ACME_DIR="${DNSPROXY_BASE_DIR}/acme.sh"
ACME_REPO="git@github.com:acmesh-official/acme.sh.git"
CERT_DIR="${DNSPROXY_BASE_DIR}/certs"
CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
CERT_KEY="${CERT_DIR}/key.pem"
DNSPROXY_LISTEN_ADDRS="0.0.0.0"
DNSPROXY_HTTPS_PORT="443"
DNSPROXY_UPSTREAM="https://dns.adguard.com/dns-query"
DNSPROXY_CACHE_FLAG="--cache"

DNSPROXY_SERVICE_PATH="/etc/systemd/system/dnsproxy-doh.service"
RENEW_SERVICE_PATH="/etc/systemd/system/dnsproxy-acme-renew.service"
RENEW_TIMER_PATH="/etc/systemd/system/dnsproxy-acme-renew.timer"
DNSPROXY_UNIT_NAME="dnsproxy-doh.service"
RENEW_TIMER_NAME="dnsproxy-acme-renew.timer"

BINARY_BASE_URL="https://github.com/KexiChanProjectAI/dnsproxy/releases/download"
BINARY_NAME_PREFIX="dnsproxy-linux"

PUBLIC_IP_SERVERS=("https://ifconfig.me" "https://icanhazip.com")

REQUIRED_BINS=(curl git systemctl)

if [ -t 1 ]; then
  COLOR_RED='\033[0;31m'
  COLOR_GREEN='\033[0;32m'
  COLOR_YELLOW='\033[1;33m'
  COLOR_BLUE='\033[0;34m'
  COLOR_RESET='\033[0m'
else
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_BLUE=''
  COLOR_RESET=''
fi

log_info() {
  printf '%s[INFO]%s %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"
}

log_error() {
  printf '%s[ERROR]%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

log_success() {
  printf '%s[OK]%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

usage() {
  cat <<'EOF'
Usage: deploy-doh.sh [--help]

Deploys or re-runs deployment of a DoH-only dnsproxy service using an ACME issued IP certificate.

What it does:
  - Checks architecture (x86_64 -> amd64, aarch64 -> arm64)
  - Downloads and installs dnsproxy binary from v0.82.1-custom release
  - Clones acme.sh under /opt/dnsproxy/acme.sh if absent
  - Detects public IPv4 and issues/renews a 30-day IP certificate
  - Writes /etc/systemd/system/dnsproxy-doh.service and enables it
  - Creates weekly systemd timer for cert renewal

Environment variables above are configurable at top of the script.
EOF
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    log_error "This script must be run as root."
    exit 1
  fi
}

require_bins() {
  local missing=0
  for bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      log_error "Missing required dependency: ${bin}"
      missing=1
    fi
  done

  if [ "${missing}" -ne 0 ]; then
    exit 1
  fi
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64)
      DNSPROXY_ARCH="amd64"
      ;;
    aarch64)
      DNSPROXY_ARCH="arm64"
      ;;
    *)
      log_error "Unsupported architecture: ${machine}"
      log_error "Only x86_64 and aarch64 are supported by this script."
      exit 1
      ;;
  esac
}

binary_name() {
  echo "${BINARY_NAME_PREFIX}-${DNSPROXY_ARCH}"
}

binary_url() {
  local name
  name="$(binary_name)"
  echo "${BINARY_BASE_URL}/${DNSPROXY_VERSION}/${name}"
}

download_binary() {
  local url
  url="$(binary_url)"
  local name
  name="$(binary_name)"

  mkdir -p "${DNSPROXY_BIN_DIR}"

  log_info "Downloading dnsproxy (${name}) from ${url}"
  curl -fsSL "${url}" -o "${DNSPROXY_BINARY}"
  chmod +x "${DNSPROXY_BINARY}"
  log_success "Binary installed at ${DNSPROXY_BINARY}"
}

ensure_acme_dir() {
  if [ -d "${ACME_DIR}" ] && [ -x "${ACME_DIR}/acme.sh" ]; then
    log_info "acme.sh already present at ${ACME_DIR}"
    return
  fi

  log_info "Cloning acme.sh to ${ACME_DIR}"
  rm -rf "${ACME_DIR}"
  git clone "${ACME_REPO}" "${ACME_DIR}"
}

detect_public_ip() {
  local ip
  for endpoint in "${PUBLIC_IP_SERVERS[@]}"; do
    ip="$(curl -fsSL --max-time 10 "${endpoint}" | tr -d '\\n\r ' || true)"
    if [ -n "${ip}" ]; then
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        PUBLIC_IP="${ip}"
        return
      fi
    fi
  done

  log_error "Could not detect a valid public IPv4 address from known endpoints."
  exit 1
}

ensure_certificate() {
  local command_args=(
    --home "${ACME_DIR}"
    --days 30
    --cert-home "${CERT_DIR}"
    --fullchain-file "${CERT_FULLCHAIN}"
    --key-file "${CERT_KEY}"
  )

  mkdir -p "${CERT_DIR}"

  if [ -f "${CERT_FULLCHAIN}" ] && [ -f "${CERT_KEY}" ]; then
    log_info "Existing certificate found. Running renewal for ${PUBLIC_IP}."
    (cd "${ACME_DIR}" && ./acme.sh --renew -d "${PUBLIC_IP}" "${command_args[@]}")
    return
  fi

  log_info "Issuing new 30-day IPv4 certificate for ${PUBLIC_IP}."
  (cd "${ACME_DIR}" && ./acme.sh \
    --home "${ACME_DIR}" \
    --issue \
    --ipv4 \
    -d "${PUBLIC_IP}" \
    --days 30 \
    --standalone \
    --cert-home "${CERT_DIR}" \
    --fullchain-file "${CERT_FULLCHAIN}" \
    --key-file "${CERT_KEY}")
}

write_service_unit() {
  log_info "Writing systemd service unit: ${DNSPROXY_SERVICE_PATH}"
  cat > "${DNSPROXY_SERVICE_PATH}" <<EOF
[Unit]
Description=DNS over HTTPS service (dnsproxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DNSPROXY_BINARY} --doh-only --https-port=${DNSPROXY_HTTPS_PORT} --listen-addrs=${DNSPROXY_LISTEN_ADDRS} --tls-crt=${CERT_FULLCHAIN} --tls-key=${CERT_KEY} --upstream=${DNSPROXY_UPSTREAM} ${DNSPROXY_CACHE_FLAG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_renew_units() {
  log_info "Writing cert renewal service: ${RENEW_SERVICE_PATH}"
  cat > "${RENEW_SERVICE_PATH}" <<EOF
[Unit]
Description=Renew dnsproxy DoH certificate weekly

[Service]
Type=oneshot
ExecStart=${ACME_DIR}/acme.sh --home ${ACME_DIR} --renew -d ${PUBLIC_IP} --days 30 --cert-home ${CERT_DIR} --fullchain-file ${CERT_FULLCHAIN} --key-file ${CERT_KEY}
ExecStartPost=/usr/bin/systemctl restart dnsproxy-doh.service
[Install]
WantedBy=multi-user.target
EOF

  log_info "Writing cert renewal timer: ${RENEW_TIMER_PATH}"
  cat > "${RENEW_TIMER_PATH}" <<EOF
[Unit]
Description=Weekly dnsproxy DoH certificate renewal
Wants=network-online.target
After=network-online.target

[Timer]
OnCalendar=weekly
Persistent=true
Unit=dnsproxy-acme-renew.service

[Install]
WantedBy=timers.target
EOF
}

enable_and_start_services() {
  log_info "Reloading systemd and enabling services"
  systemctl daemon-reload
  systemctl enable --now "${DNSPROXY_UNIT_NAME}"
  systemctl enable --now "${RENEW_TIMER_NAME}"
}

main() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
  fi

  require_root
  require_bins
  detect_arch
  download_binary
  ensure_acme_dir
  detect_public_ip
  ensure_certificate
  write_service_unit
  write_renew_units
  enable_and_start_services

  log_success "Deployment complete. Service: ${DNSPROXY_UNIT_NAME}, renew timer: ${RENEW_TIMER_NAME}."
  log_info "Certificate location: ${CERT_FULLCHAIN}"
  log_info "Public IP used for cert: ${PUBLIC_IP}"
}

main "$@"
