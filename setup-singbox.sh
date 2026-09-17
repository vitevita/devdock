#!/usr/bin/env bash

# ============================================================
# setup-singbox.sh
#
# Version: V4
#
# Target:
#   Ubuntu 22.04 / 24.04
#   Oracle Cloud VPS
#
# Features:
#   - sing-box 1.14+
#   - VLESS + Reality + Vision
#   - Caddy HTTPS subscription
#   - Clash Verge Rev subscription
#   - Hiddify subscription
#   - BBR + FQ
#   - UFW
#   - Automatic validation
#   - Secure subscription token
#
# Ports:
#   22    SSH
#   80    Caddy ACME HTTP challenge
#   443   VLESS Reality
#   8443  HTTPS subscription
#
# ============================================================

set -Eeuo pipefail

VERSION="V4"

# ============================================================
# Configuration
# ============================================================

DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

# Reality SNI / handshake target
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

# HTTPS subscription port
SUBSCRIPTION_PORT="${SUBSCRIPTION_PORT:-8443}"

# ============================================================
# Paths
# ============================================================

SINGBOX_DIR="/etc/sing-box"

SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"
SINGBOX_INFO="${SINGBOX_DIR}/connection-info.txt"
SINGBOX_TOKEN="${SINGBOX_DIR}/subscription-token.txt"

SUBSCRIPTION_ROOT="/srv/singbox-subscription"

CLASH_FILE="${SUBSCRIPTION_ROOT}/clash.yaml"
HIDDIFY_FILE="${SUBSCRIPTION_ROOT}/hiddify.txt"

CADDY_DIR="/etc/caddy"
CADDYFILE="${CADDY_DIR}/Caddyfile"

SYSCTL_FILE="/etc/sysctl.d/99-singbox-network.conf"

# ============================================================
# Functions
# ============================================================

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo
    echo "============================================================"
    echo "[ERROR]"
    echo "$1"
    echo "============================================================"
    echo
    exit 1
}

cleanup_on_error() {

    echo
    echo "============================================================"
    echo "[ERROR] Installation failed"
    echo "============================================================"
    echo

    echo "sing-box:"
    echo "  systemctl status sing-box --no-pager"
    echo

    echo "sing-box logs:"
    echo "  journalctl -u sing-box -n 100 --no-pager"
    echo

    echo "Caddy:"
    echo "  systemctl status caddy --no-pager"
    echo

    echo "Caddy logs:"
    echo "  journalctl -u caddy -n 100 --no-pager"
    echo
}

trap cleanup_on_error ERR

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {

    if [[ "${EUID}" -ne 0 ]]; then

        echo
        echo "Please run this script as root:"
        echo
        echo "  sudo bash setup-singbox.sh"
        echo

        exit 1

    fi

}

# ============================================================
# Root
# ============================================================

require_root

# ============================================================
# Operating System
# ============================================================

log "Checking operating system"

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

echo "OS:"
echo "  ${PRETTY_NAME}"

if [[ "${ID}" != "ubuntu" ]]; then

    echo
    echo "[WARNING]"
    echo "This script is optimized for Ubuntu."

fi

# ============================================================
# User configuration
# ============================================================

if [[ -z "${DOMAIN}" ]]; then

    read -r -p \
        "Enter subscription domain, e.g. sub.example.com: " \
        DOMAIN

fi

if [[ -z "${DOMAIN}" ]]; then
    die "DOMAIN cannot be empty."
fi

if [[ -z "${ACME_EMAIL}" ]]; then

    read -r -p \
        "Enter ACME email: " \
        ACME_EMAIL

fi

if [[ -z "${ACME_EMAIL}" ]]; then
    die "ACME_EMAIL cannot be empty."
fi

echo
echo "Configuration:"
echo
echo "  DOMAIN            = ${DOMAIN}"
echo "  ACME_EMAIL        = ${ACME_EMAIL}"
echo "  REALITY_SNI       = ${REALITY_SNI}"
echo "  SUBSCRIPTION_PORT = ${SUBSCRIPTION_PORT}"
echo

# ============================================================
# Install dependencies
# ============================================================

log "Installing required packages"

apt-get update

apt-get install -y \
    curl \
    wget \
    openssl \
    ca-certificates \
    gnupg \
    jq \
    ufw \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https

# ============================================================
# Install sing-box
# ============================================================

log "Installing sing-box"

if ! command_exists sing-box; then

    mkdir -p /etc/apt/keyrings

    curl -fsSL \
        https://sing-box.app/gpg.key \
        -o /etc/apt/keyrings/sagernet.asc

    chmod 644 \
        /etc/apt/keyrings/sagernet.asc

    echo \
        "deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
        > /etc/apt/sources.list.d/sagernet.list

    apt-get update

    apt-get install -y sing-box

else

    echo "sing-box already installed."

fi

echo
echo "sing-box version:"
sing-box version

# ============================================================
# Install Caddy
# ============================================================

log "Installing Caddy"

if ! command_exists caddy; then

    curl -1sLf \
        'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor \
        -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf \
        'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    apt-get update

    apt-get install -y caddy

else

    echo "Caddy already installed."

fi

echo
echo "Caddy version:"
caddy version

# ============================================================
# Detect public IPv4
# ============================================================

log "Detecting public IPv4"

SERVER_IP="$(
    curl \
        -4 \
        -fsS \
        --max-time 10 \
        https://api.ipify.org \
        || true
)"

if [[ -z "${SERVER_IP}" ]]; then

    SERVER_IP="$(
        curl \
            -4 \
            -fsS \
            --max-time 10 \
            https://ifconfig.me \
            || true
    )"

fi

if [[ -z "${SERVER_IP}" ]]; then
    die "Unable to detect public IPv4."
fi

echo
echo "Public IPv4:"
echo "  ${SERVER_IP}"

# ============================================================
# BBR + FQ
# ============================================================

log "Configuring BBR + FQ"

AVAILABLE_CC="$(
    sysctl \
        -n \
        net.ipv4.tcp_available_congestion_control \
        2>/dev/null \
        || true
)"

echo
echo "Available TCP congestion control:"
echo "  ${AVAILABLE_CC}"

if echo "${AVAILABLE_CC}" | grep -qw "bbr"; then

    echo
    echo "BBR is available."

    cat > "${SYSCTL_FILE}" <<'EOF'
# ============================================================
# sing-box network optimization
# ============================================================

# BBR congestion control
net.ipv4.tcp_congestion_control=bbr

# Fair Queueing
# Works well with BBR packet pacing.
net.core.default_qdisc=fq

# TCP window scaling
net.ipv4.tcp_window_scaling=1

# TCP Selective Acknowledgement
net.ipv4.tcp_sack=1

# TCP timestamps
net.ipv4.tcp_timestamps=1
EOF

else

    echo
    echo "[WARNING] BBR is not available in the current kernel."

    cat > "${SYSCTL_FILE}" <<'EOF'
# ============================================================
# sing-box network optimization
# ============================================================

# Fair Queueing
net.core.default_qdisc=fq

# TCP window scaling
net.ipv4.tcp_window_scaling=1

# TCP Selective Acknowledgement
net.ipv4.tcp_sack=1

# TCP timestamps
net.ipv4.tcp_timestamps=1
EOF

fi

chmod 644 "${SYSCTL_FILE}"

echo
echo "Applying sysctl configuration..."

sysctl --system

CURRENT_CC="$(
    sysctl \
        -n \
        net.ipv4.tcp_congestion_control
)"

CURRENT_QDISC="$(
    sysctl \
        -n \
        net.core.default_qdisc
)"

echo
echo "TCP status:"
echo
echo "  Congestion control : ${CURRENT_CC}"
echo "  Default qdisc      : ${CURRENT_QDISC}"

if echo "${AVAILABLE_CC}" | grep -qw "bbr"; then

    if [[ "${CURRENT_CC}" == "bbr" ]]; then
        echo "  BBR                 : ENABLED"
    else
        echo "  BBR                 : NOT ACTIVE"
    fi

else

    echo "  BBR                 : NOT AVAILABLE"

fi

if [[ "${CURRENT_QDISC}" == "fq" ]]; then
    echo "  FQ                  : ENABLED"
else
    echo "  FQ                  : ${CURRENT_QDISC}"
fi

# ============================================================
# Generate VLESS / Reality credentials
# ============================================================

log "Generating VLESS / Reality credentials"

UUID="$(
    cat /proc/sys/kernel/random/uuid
)"

REALITY_KEYS="$(
    sing-box generate reality-keypair
)"

PRIVATE_KEY="$(
    echo "${REALITY_KEYS}" |
        awk '/PrivateKey:/ {print $2}'
)"

PUBLIC_KEY="$(
    echo "${REALITY_KEYS}" |
        awk '/PublicKey:/ {print $2}'
)"

if [[ -z "${PRIVATE_KEY}" ]]; then
    die "Failed to generate Reality private key."
fi

if [[ -z "${PUBLIC_KEY}" ]]; then
    die "Failed to generate Reality public key."
fi

SHORT_ID="$(
    openssl rand -hex 8
)"

# 32 random bytes = 64 hex characters
SUB_TOKEN="$(
    openssl rand -hex 32
)"

echo
echo "Generated:"
echo
echo "  UUID       = ${UUID}"
echo "  Public Key = ${PUBLIC_KEY}"
echo "  Short ID   = ${SHORT_ID}"
echo "  Sub Token  = ${SUB_TOKEN}"

# ============================================================
# Create directories
# ============================================================

log "Creating directories"

mkdir -p "${SINGBOX_DIR}"
mkdir -p "${SUBSCRIPTION_ROOT}"
mkdir -p "${CADDY_DIR}"

# ============================================================
# IMPORTANT:
# Make sure /etc/sing-box contains ONLY runtime config files
# that we explicitly use.
#
# We intentionally DO NOT generate schema.json here.
# ============================================================

rm -f \
    "${SINGBOX_DIR}/schema.json"

# ============================================================
# sing-box configuration
# ============================================================

log "Creating sing-box configuration"

cat > "${SINGBOX_CONFIG}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,

      "users": [
        {
          "name": "user1",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],

      "tls": {
        "enabled": true,

        "server_name": "${REALITY_SNI}",

        "reality": {
          "enabled": true,

          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },

          "private_key": "${PRIVATE_KEY}",

          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ]
}
EOF

chmod 600 "${SINGBOX_CONFIG}"

chown root:root "${SINGBOX_CONFIG}"

# ============================================================
# Validate sing-box config
# ============================================================

log "Validating sing-box configuration"

sing-box check \
    -c "${SINGBOX_CONFIG}"

echo
echo "sing-box configuration: OK"

# ============================================================
# Generate VLESS URI
# ============================================================

VLESS_URL="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-Reality"

# ============================================================
# Create Clash subscription
# ============================================================

log "Creating Clash subscription"

cat > "${CLASH_FILE}" <<EOF
mixed-port: 7890

allow-lan: false

mode: rule

log-level: info

ipv6: false

proxies:

  - name: "VLESS-Reality"

    type: vless

    server: ${SERVER_IP}

    port: 443

    uuid: ${UUID}

    network: tcp

    udp: true

    tls: true

    servername: ${REALITY_SNI}

    flow: xtls-rprx-vision

    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

    client-fingerprint: chrome


proxy-groups:

  - name: "PROXY"

    type: select

    proxies:
      - "VLESS-Reality"
      - DIRECT


rules:

  - MATCH,PROXY
EOF

# ============================================================
# Create Hiddify subscription
# ============================================================

log "Creating Hiddify subscription"

printf '%s\n' \
    "${VLESS_URL}" \
    > "${HIDDIFY_FILE}"

# ============================================================
# Secure subscription directory
# ============================================================

log "Configuring subscription permissions"

# Caddy runs as:
#
#   caddy:caddy
#
# The caddy user needs:
#
#   x -> directory traversal
#   r -> file read
#
# It does NOT need write permission.

chown root:root \
    "${SUBSCRIPTION_ROOT}"

chmod 755 \
    "${SUBSCRIPTION_ROOT}"

chown root:root \
    "${CLASH_FILE}" \
    "${HIDDIFY_FILE}"

chmod 644 \
    "${CLASH_FILE}" \
    "${HIDDIFY_FILE}"

# ============================================================
# Verify Caddy read access
# ============================================================

log "Testing Caddy subscription file access"

if ! sudo -u caddy test -r "${CLASH_FILE}"; then
    die "Caddy cannot read ${CLASH_FILE}"
fi

if ! sudo -u caddy test -r "${HIDDIFY_FILE}"; then
    die "Caddy cannot read ${HIDDIFY_FILE}"
fi

if ! sudo -u caddy cat \
    "${CLASH_FILE}" \
    >/dev/null; then

    die "Caddy cannot read Clash YAML."

fi

if ! sudo -u caddy cat \
    "${HIDDIFY_FILE}" \
    >/dev/null; then

    die "Caddy cannot read Hiddify subscription."

fi

echo
echo "Caddy file permissions: OK"

# ============================================================
# Save subscription token
# ============================================================

printf '%s\n' \
    "${SUB_TOKEN}" \
    > "${SINGBOX_TOKEN}"

chown root:root \
    "${SINGBOX_TOKEN}"

chmod 600 \
    "${SINGBOX_TOKEN}"

# ============================================================
# Caddy configuration
# ============================================================

log "Creating Caddy configuration"

cat > "${CADDYFILE}" <<EOF
{
    email ${ACME_EMAIL}
}

${DOMAIN}:${SUBSCRIPTION_PORT} {

    # ========================================================
    # Clash Verge Rev
    # ========================================================

    @clash path /sub/${SUB_TOKEN}/clash

    handle @clash {

        rewrite * /clash.yaml

        root * ${SUBSCRIPTION_ROOT}

        header {
            Content-Type "text/yaml; charset=utf-8"
            Content-Disposition "inline"
            Cache-Control "no-store, no-cache, must-revalidate"
            Pragma "no-cache"
            X-Content-Type-Options "nosniff"
        }

        file_server
    }

    # ========================================================
    # Hiddify
    # ========================================================

    @hiddify path /sub/${SUB_TOKEN}/hiddify

    handle @hiddify {

        rewrite * /hiddify.txt

        root * ${SUBSCRIPTION_ROOT}

        header {
            Content-Type "text/plain; charset=utf-8"
            Content-Disposition "inline"
            Cache-Control "no-store, no-cache, must-revalidate"
            Pragma "no-cache"
            X-Content-Type-Options "nosniff"
        }

        file_server
    }

    # ========================================================
    # Reject all other paths
    # ========================================================

    handle {
        respond "Not Found" 404
    }
}
EOF

chmod 644 \
    "${CADDYFILE}"

chown root:root \
    "${CADDYFILE}"

# ============================================================
# Validate Caddy
# ============================================================

log "Validating Caddy configuration"

caddy validate \
    --config "${CADDYFILE}" \
    --adapter caddyfile

echo
echo "Caddy configuration: OK"

# ============================================================
# IMPORTANT SYSTEMD CHECK
#
# Make sure sing-box explicitly loads config.json.
#
# This prevents schema.json / other JSON files from accidentally
# being interpreted as runtime configuration.
# ============================================================

log "Checking sing-box systemd service"

SINGBOX_SERVICE_FILE=""

if [[ -f /lib/systemd/system/sing-box.service ]]; then
    SINGBOX_SERVICE_FILE="/lib/systemd/system/sing-box.service"
elif [[ -f /usr/lib/systemd/system/sing-box.service ]]; then
    SINGBOX_SERVICE_FILE="/usr/lib/systemd/system/sing-box.service"
fi

if [[ -n "${SINGBOX_SERVICE_FILE}" ]]; then

    echo
    echo "sing-box service:"
    echo "  ${SINGBOX_SERVICE_FILE}"

    if grep -q \
        -- "-c ${SINGBOX_CONFIG}" \
        "${SINGBOX_SERVICE_FILE}"; then

        echo
        echo "sing-box systemd configuration: OK"

    else

        echo
        echo "[WARNING]"
        echo "Installed sing-box service does not explicitly"
        echo "reference ${SINGBOX_CONFIG}."

        echo
        echo "Current ExecStart:"
        grep "ExecStart=" \
            "${SINGBOX_SERVICE_FILE}" \
            || true

        echo
        echo "This will be fixed with an explicit systemd override."

    fi

fi

# ============================================================
# Create explicit systemd override
# ============================================================

log "Configuring sing-box systemd service"

mkdir -p \
    /etc/systemd/system/sing-box.service.d

cat > \
    /etc/systemd/system/sing-box.service.d/override.conf \
    <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/sing-box run -c ${SINGBOX_CONFIG}
EOF

chmod 644 \
    /etc/systemd/system/sing-box.service.d/override.conf

systemctl daemon-reload

# ============================================================
# Enable services
# ============================================================

log "Enabling services"

systemctl enable sing-box
systemctl enable caddy

# ============================================================
# Start sing-box
# ============================================================

log "Starting sing-box"

systemctl restart sing-box

sleep 2

if ! systemctl is-active --quiet sing-box; then

    echo
    echo "sing-box failed to start."
    echo

    journalctl \
        -u sing-box \
        -n 100 \
        --no-pager

    die "sing-box startup failed."

fi

echo
echo "sing-box: ACTIVE"

# ============================================================
# Start Caddy
# ============================================================

log "Starting Caddy"

systemctl restart caddy

sleep 3

if ! systemctl is-active --quiet caddy; then

    echo
    echo "Caddy failed to start."
    echo

    journalctl \
        -u caddy \
        -n 100 \
        --no-pager

    die "Caddy startup failed."

fi

echo
echo "Caddy: ACTIVE"

# ============================================================
# Configure UFW
# ============================================================

log "Configuring UFW"

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "${SUBSCRIPTION_PORT}/tcp"

ufw --force enable

echo
echo "UFW:"
ufw status

# ============================================================
# Check listening ports
# ============================================================

log "Checking listening ports"

echo

ss -lntp |
    grep -E \
        ":443|:${SUBSCRIPTION_PORT}" \
        || true

# ============================================================
# Subscription URLs
# ============================================================

CLASH_URL="https://${DOMAIN}:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}/clash"

HIDDIFY_URL="https://${DOMAIN}:${SUBSCRIPTION_PORT}/sub/${SUB_TOKEN}/hiddify"

# ============================================================
# Save connection information
# ============================================================

log "Saving connection information"

cat > "${SINGBOX_INFO}" <<EOF
sing-box ${VERSION}

============================================================
SERVER
============================================================

IPv4:
${SERVER_IP}

VLESS Port:
443

Reality SNI:
${REALITY_SNI}


============================================================
VLESS
============================================================

UUID:
${UUID}

Reality Public Key:
${PUBLIC_KEY}

Reality Short ID:
${SHORT_ID}


============================================================
CLASH VERGE REV
============================================================

${CLASH_URL}


============================================================
HIDDIFY
============================================================

${HIDDIFY_URL}


============================================================
DIRECT VLESS URI
============================================================

${VLESS_URL}


============================================================
NETWORK
============================================================

TCP congestion control:
${CURRENT_CC}

Default qdisc:
${CURRENT_QDISC}


============================================================
SUBSCRIPTION TOKEN
============================================================

${SUB_TOKEN}


============================================================
IMPORTANT
============================================================

Reality Private Key:
NOT INCLUDED

The subscription URL contains a secret token.
Do not publish it publicly.


============================================================
FILES
============================================================

sing-box config:
${SINGBOX_CONFIG}

connection info:
${SINGBOX_INFO}

subscription token:
${SINGBOX_TOKEN}

Clash:
${CLASH_FILE}

Hiddify:
${HIDDIFY_FILE}

Caddy:
${CADDYFILE}

Network sysctl:
${SYSCTL_FILE}


============================================================
EOF

chmod 600 \
    "${SINGBOX_INFO}"

chown root:root \
    "${SINGBOX_INFO}"

# ============================================================
# Local subscription test
# ============================================================

log "Testing HTTPS subscription"

echo
echo "Testing:"
echo
echo "  ${CLASH_URL}"
echo

sleep 3

TEST_FILE="/tmp/singbox-subscription-test.txt"

HTTP_CODE="$(
    curl \
        -k \
        -L \
        -s \
        -o "${TEST_FILE}" \
        -w "%{http_code}" \
        --max-time 20 \
        "${CLASH_URL}" \
        || true
)"

echo
echo "HTTP status:"
echo "  ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" ]]; then

    echo
    echo "Subscription endpoint: OK"

    if grep -q \
        "VLESS-Reality" \
        "${TEST_FILE}"; then

        echo "Clash YAML content: OK"

    else

        echo
        echo "[WARNING]"
        echo "HTTP 200 received, but expected Clash"
        echo "configuration was not detected."

    fi

else

    echo
    echo "[WARNING]"
    echo "Subscription did not return HTTP 200."

    echo
    echo "Possible causes:"
    echo
    echo "  - DNS does not point to this VPS"
    echo "  - Oracle Cloud blocks TCP ${SUBSCRIPTION_PORT}"
    echo "  - UFW blocks TCP ${SUBSCRIPTION_PORT}"
    echo "  - Caddy certificate is not ready"
    echo "  - Incorrect DNS AAAA record"
    echo "  - Caddy configuration problem"

    echo
    echo "Check:"
    echo
    echo "  systemctl status caddy --no-pager"
    echo
    echo "  journalctl -u caddy -n 100 --no-pager"

fi

rm -f \
    "${TEST_FILE}"

# ============================================================
# Final validation
# ============================================================

log "Final validation"

echo
echo "sing-box:"
systemctl is-active sing-box || true

echo
echo "Caddy:"
systemctl is-active caddy || true

echo
echo "BBR:"
sysctl -n \
    net.ipv4.tcp_congestion_control

echo
echo "FQ:"
sysctl -n \
    net.core.default_qdisc

echo
echo "Listening ports:"
ss -lntp |
    grep -E \
        ":443|:${SUBSCRIPTION_PORT}" \
        || true

# ============================================================
# Final output
# ============================================================

echo
echo
echo "============================================================"
echo "              sing-box ${VERSION} COMPLETE"
echo "============================================================"

echo
echo "Server:"
echo "  ${SERVER_IP}"

echo
echo "VLESS:"
echo "  ${SERVER_IP}:443"

echo
echo "Reality SNI:"
echo "  ${REALITY_SNI}"

echo
echo "============================================================"
echo "CLASH VERGE REV SUBSCRIPTION"
echo "============================================================"

echo
echo "${CLASH_URL}"

echo
echo "============================================================"
echo "HIDDIFY SUBSCRIPTION"
echo "============================================================"

echo
echo "${HIDDIFY_URL}"

echo
echo "============================================================"
echo "DIRECT VLESS URI"
echo "============================================================"

echo
echo "${VLESS_URL}"

echo
echo "============================================================"
echo "NETWORK"
echo "============================================================"

echo
echo "TCP congestion control:"
echo "  ${CURRENT_CC}"

echo
echo "Default qdisc:"
echo "  ${CURRENT_QDISC}"

echo
echo "============================================================"
echo "FILES"
echo "============================================================"

echo
echo "sing-box:"
echo "  ${SINGBOX_CONFIG}"

echo
echo "connection info:"
echo "  ${SINGBOX_INFO}"

echo
echo "subscription token:"
echo "  ${SINGBOX_TOKEN}"

echo
echo "Clash:"
echo "  ${CLASH_FILE}"

echo
echo "Hiddify:"
echo "  ${HIDDIFY_FILE}"

echo
echo "Caddy:"
echo "  ${CADDYFILE}"

echo
echo "Network:"
echo "  ${SYSCTL_FILE}"

echo
echo "============================================================"
echo "ORACLE CLOUD"
echo "============================================================"

echo
echo "Make sure Oracle Cloud VCN / NSG / Security List allows:"
echo
echo "  TCP 22"
echo "  TCP 80"
echo "  TCP 443"
echo "  TCP ${SUBSCRIPTION_PORT}"

echo
echo "============================================================"
echo "SECURITY"
echo "============================================================"

echo
echo "The subscription URL contains a secret token."
echo "Do NOT publish it."

echo
echo "Reality private key is stored only in:"
echo
echo "  ${SINGBOX_CONFIG}"

echo
echo "${VERSION} setup completed."
echo

echo
echo "cat /etc/sing-box/connection-info.txt to view connection"
echo "windows uses clash verge rev, android uses hiddify, https://www.clashverge.dev/"
echo "============================================================"
