#!/usr/bin/env bash

# ============================================================
# How to use:
# wget https://raw.githubusercontent.com/用户名/仓库名/分支名/setup-singbox.sh && chmod +x ./singbox.sh && ./setup-singbox.sh
# ============================================================

# ============================================================
# setup-singbox.sh
#
# Version: V6
#
# Target:
#   Ubuntu 22.04 / 24.04
#
# Features:
#   - sing-box
#   - VLESS + Reality + Vision
#   - Clash Verge Rev subscription file
#   - Hiddify subscription file
#   - POST subscriptions to remote API
#   - JSON API request
#   - X-Access-Token authentication
#   - BBR + FQ
#   - UFW
#   - Automatic validation
#
# Files:
#   /etc/sing-box/config.json
#   /etc/sing-box/connection-info.txt
#   /srv/singbox-subscription/clash
#   /srv/singbox-subscription/hiddify
#
# Remote API:
#   https://sub.vitevita.com/singbox/create
#
# POST JSON:
#   {
#     "ip": "...",
#     "type": "clash",
#     "content": "..."
#   }
#
#   {
#     "ip": "...",
#     "type": "hiddify",
#     "content": "..."
#   }
#
# ============================================================

set -Eeuo pipefail


# ============================================================
# Version
# ============================================================

VERSION="V6"


# ============================================================
# Configuration
# ============================================================

REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

SUBSCRIPTION_API="${SUBSCRIPTION_API:-https://sub.vitevita.com/singbox/create}"

SUBSCRIPTION_ACCESS_TOKEN="${SUBSCRIPTION_ACCESS_TOKEN:-singbox-sub}"

API_TIMEOUT="${API_TIMEOUT:-30}"


# ============================================================
# Paths
# ============================================================

SINGBOX_DIR="/etc/sing-box"

SINGBOX_CONFIG="${SINGBOX_DIR}/config.json"

SINGBOX_INFO="${SINGBOX_DIR}/connection-info.txt"

SUBSCRIPTION_ROOT="/srv/singbox-subscription"

CLASH_FILE="${SUBSCRIPTION_ROOT}/clash"

HIDDIFY_FILE="${SUBSCRIPTION_ROOT}/hiddify"

SYSCTL_FILE="/etc/sysctl.d/99-singbox-network.conf"

SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/sing-box.service.d"

SYSTEMD_OVERRIDE="${SYSTEMD_OVERRIDE_DIR}/override.conf"


# ============================================================
# Temporary files
# ============================================================

CLASH_API_RESPONSE="/tmp/singbox-clash-api-response.txt"

HIDDIFY_API_RESPONSE="/tmp/singbox-hiddify-api-response.txt"


# ============================================================
# Functions
# ============================================================

log() {

    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo

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
# Configuration display
# ============================================================

echo
echo "Configuration:"
echo
echo "  REALITY_SNI             = ${REALITY_SNI}"
echo "  SUBSCRIPTION_API        = ${SUBSCRIPTION_API}"
echo "  SUBSCRIPTION_ACCESS_TOKEN = ${SUBSCRIPTION_ACCESS_TOKEN}"
echo "  API_TIMEOUT             = ${API_TIMEOUT}"
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
    apt-transport-https


# ============================================================
# Install sing-box
# ============================================================

log "Installing sing-box"

if ! command_exists sing-box; then

    mkdir -p /etc/apt/keyrings

    curl \
        -fsSL \
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
echo


# ============================================================
# Validate IPv4
# ============================================================

if ! [[ "${SERVER_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

    die "Detected server IP does not look like an IPv4 address: ${SERVER_IP}"

fi


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


echo
echo "Generated:"
echo
echo "  UUID       = ${UUID}"
echo "  Public Key = ${PUBLIC_KEY}"
echo "  Short ID   = ${SHORT_ID}"
echo


# ============================================================
# Create directories
# ============================================================

log "Creating directories"


mkdir -p "${SINGBOX_DIR}"

mkdir -p "${SUBSCRIPTION_ROOT}"


# ============================================================
# Remove schema.json
#
# IMPORTANT:
# sing-box must explicitly load config.json.
#
# This prevents:
#
#   /etc/sing-box/schema.json
#
# from accidentally being interpreted as runtime configuration.
# ============================================================

log "Cleaning sing-box directory"


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


chmod 600 \
    "${SINGBOX_CONFIG}"


chown root:root \
    "${SINGBOX_CONFIG}"


# ============================================================
# Validate sing-box configuration
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
#
# IMPORTANT:
# File name is exactly:
#
#   /srv/singbox-subscription/clash
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
#
# IMPORTANT:
# File name is exactly:
#
#   /srv/singbox-subscription/hiddify
# ============================================================

log "Creating Hiddify subscription"


printf '%s\n' \
    "${VLESS_URL}" \
    > "${HIDDIFY_FILE}"


# ============================================================
# Subscription file permissions
# ============================================================

log "Configuring subscription file permissions"


chown root:root \
    "${SUBSCRIPTION_ROOT}" \
    "${CLASH_FILE}" \
    "${HIDDIFY_FILE}"


chmod 755 \
    "${SUBSCRIPTION_ROOT}"


chmod 644 \
    "${CLASH_FILE}" \
    "${HIDDIFY_FILE}"


# ============================================================
# Validate subscription files
# ============================================================

log "Validating subscription files"


if [[ ! -f "${CLASH_FILE}" ]]; then

    die "Clash subscription file was not created."

fi


if [[ ! -s "${CLASH_FILE}" ]]; then

    die "Clash subscription file is empty."

fi


if [[ ! -f "${HIDDIFY_FILE}" ]]; then

    die "Hiddify subscription file was not created."

fi


if [[ ! -s "${HIDDIFY_FILE}" ]]; then

    die "Hiddify subscription file is empty."

fi


if ! grep -q "VLESS-Reality" "${CLASH_FILE}"; then

    die "Expected VLESS-Reality entry was not found in Clash file."

fi


if ! grep -q "^vless://" "${HIDDIFY_FILE}"; then

    die "Expected VLESS URI was not found in Hiddify file."

fi


echo
echo "Subscription files:"
echo
echo "  Clash:"
echo "    ${CLASH_FILE}"
echo
echo "  Hiddify:"
echo "    ${HIDDIFY_FILE}"
echo


# ============================================================
# Create explicit systemd override
#
# IMPORTANT:
# Always explicitly run:
#
#   /usr/bin/sing-box run -c /etc/sing-box/config.json
#
# This prevents sing-box from loading schema.json or another
# JSON file automatically.
# ============================================================

log "Configuring sing-box systemd service"


mkdir -p \
    "${SYSTEMD_OVERRIDE_DIR}"


cat > "${SYSTEMD_OVERRIDE}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/sing-box run -c ${SINGBOX_CONFIG}
EOF


chmod 644 \
    "${SYSTEMD_OVERRIDE}"


systemctl daemon-reload


# ============================================================
# Show effective systemd configuration
# ============================================================

echo
echo "Effective sing-box ExecStart:"
echo


systemctl cat sing-box 2>/dev/null |
    grep "ExecStart=" \
    || true


# ============================================================
# Enable sing-box
# ============================================================

log "Enabling sing-box service"


systemctl enable sing-box


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
# Check listening port
# ============================================================

log "Checking sing-box listening port"


if ! ss -lntp | grep -q ":443"; then

    echo
    echo "[WARNING]"
    echo "Port 443 is not detected in listening sockets."
    echo

    ss -lntp || true

else

    echo
    echo "Port 443: LISTENING"

fi


# ============================================================
# Configure UFW
# ============================================================

log "Configuring UFW"


ufw allow 22/tcp

ufw allow 443/tcp


ufw --force enable


echo
echo "UFW:"
ufw status


# ============================================================
# POST subscription to remote API
#
# Request:
#
# POST https://sub.vitevita.com/singbox/create
#
# Headers:
#
# X-Access-Token: singbox-sub
# Content-Type: application/json
#
# JSON:
#
# {
#   "ip": "...",
#   "type": "clash",
#   "content": "..."
# }
#
# ============================================================

post_subscription() {

    local TYPE="$1"

    local FILE="$2"

    local RESPONSE_FILE="$3"

    local JSON_FILE

    local HTTP_CODE

    local CONTENT


    if [[ ! -f "${FILE}" ]]; then

        die "Subscription file does not exist: ${FILE}"

    fi


    if [[ ! -s "${FILE}" ]]; then

        die "Subscription file is empty: ${FILE}"

    fi


    echo
    echo "Preparing ${TYPE} subscription..."

    echo "  File:"
    echo "    ${FILE}"

    echo "  API:"
    echo "    ${SUBSCRIPTION_API}"

    echo "  Server IP:"
    echo "    ${SERVER_IP}"

    echo "  Type:"
    echo "    ${TYPE}"


    # --------------------------------------------------------
    # Read complete text content
    # --------------------------------------------------------

    CONTENT="$(<"${FILE}")"


    if [[ -z "${CONTENT}" ]]; then

        die "${TYPE} subscription content is empty."

    fi


    # --------------------------------------------------------
    # Build JSON using jq
    #
    # This safely handles:
    #
    #   newlines
    #   quotes
    #   backslashes
    #   special characters
    #
    # --------------------------------------------------------

    JSON_FILE="$(mktemp)"


    jq -n \
        --arg ip "${SERVER_IP}" \
        --arg type "${TYPE}" \
        --arg content "${CONTENT}" \
        '{
            ip: $ip,
            type: $type,
            content: $content
        }' \
        > "${JSON_FILE}"


    echo
    echo "Generated JSON:"
    echo


    jq . "${JSON_FILE}"


    # --------------------------------------------------------
    # POST JSON
    # --------------------------------------------------------

    echo
    echo "Sending ${TYPE} subscription to remote API..."


    HTTP_CODE="$(
        curl \
            -sS \
            -X POST \
            --max-time "${API_TIMEOUT}" \
            -H "X-Access-Token: ${SUBSCRIPTION_ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            --data-binary "@${JSON_FILE}" \
            -o "${RESPONSE_FILE}" \
            -w "%{http_code}" \
            "${SUBSCRIPTION_API}" \
            || true
    )"


    rm -f "${JSON_FILE}"


    echo
    echo "API HTTP status:"
    echo
    echo "  ${HTTP_CODE}"


    echo
    echo "API response:"
    echo "------------------------------------------------------------"


    if [[ -f "${RESPONSE_FILE}" ]]; then

        cat "${RESPONSE_FILE}"

    fi


    echo
    echo "------------------------------------------------------------"


    if [[ "${HTTP_CODE}" != "200" ]] &&
       [[ "${HTTP_CODE}" != "201" ]] &&
       [[ "${HTTP_CODE}" != "204" ]]; then

        die \
            "${TYPE} subscription POST failed. HTTP status: ${HTTP_CODE}"

    fi


    echo
    echo "${TYPE} subscription POST: OK"

}


# ============================================================
# POST Clash subscription
# ============================================================

log "Uploading Clash subscription"


post_subscription \
    "clash" \
    "${CLASH_FILE}" \
    "${CLASH_API_RESPONSE}"


# ============================================================
# POST Hiddify subscription
# ============================================================

log "Uploading Hiddify subscription"


post_subscription \
    "hiddify" \
    "${HIDDIFY_FILE}" \
    "${HIDDIFY_API_RESPONSE}"


# ============================================================
# Remove temporary API responses
# ============================================================

rm -f \
    "${CLASH_API_RESPONSE}" \
    "${HIDDIFY_API_RESPONSE}"


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
SUBSCRIPTION FILES
============================================================

Clash:
/srv/singbox-subscription/clash

Hiddify:
/srv/singbox-subscription/hiddify


============================================================
REMOTE SUBSCRIPTION API
============================================================

API:
${SUBSCRIPTION_API}

Clash:
POST type=clash

Hiddify:
POST type=hiddify


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
FILES
============================================================

sing-box config:
${SINGBOX_CONFIG}

connection info:
${SINGBOX_INFO}

Clash:
${CLASH_FILE}

Hiddify:
${HIDDIFY_FILE}

Network sysctl:
${SYSCTL_FILE}

systemd override:
${SYSTEMD_OVERRIDE}


============================================================
IMPORTANT
============================================================

The remote subscription API requires:

X-Access-Token:
${SUBSCRIPTION_ACCESS_TOKEN}

Keep this access token private.

Reality Private Key:
NOT INCLUDED

The Reality private key is stored only inside:

${SINGBOX_CONFIG}

============================================================
EOF


chmod 600 \
    "${SINGBOX_INFO}"


chown root:root \
    "${SINGBOX_INFO}"


# ============================================================
# Final validation
# ============================================================

log "Final validation"


echo
echo "sing-box:"
systemctl is-active sing-box || true


echo
echo "sing-box configuration:"
sing-box check \
    -c "${SINGBOX_CONFIG}"


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
    grep ":443" \
    || true


echo
echo "UFW:"
ufw status


# ============================================================
# Validate subscription files one more time
# ============================================================

echo
echo "Subscription files:"
echo


echo "Clash:"
ls -lh \
    "${CLASH_FILE}"


echo
echo "Hiddify:"
ls -lh \
    "${HIDDIFY_FILE}"


# ============================================================
# Verify systemd override
# ============================================================

echo
echo "systemd override:"
echo


if [[ -f "${SYSTEMD_OVERRIDE}" ]]; then

    cat "${SYSTEMD_OVERRIDE}"

else

    echo "[WARNING] systemd override not found."

fi


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
echo "SUBSCRIPTION FILES"
echo "============================================================"
echo

echo "Clash:"
echo "  ${CLASH_FILE}"

echo
echo "Hiddify:"
echo "  ${HIDDIFY_FILE}"

echo
echo "============================================================"
echo "REMOTE API"
echo "============================================================"
echo

echo "API:"
echo "  ${SUBSCRIPTION_API}"

echo
echo "Clash:"
echo "  POST type=clash"

echo
echo "Hiddify:"
echo "  POST type=hiddify"

echo
echo "Access Token:"
echo "  ${SUBSCRIPTION_ACCESS_TOKEN}"

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
echo "Clash:"
echo "  ${CLASH_FILE}"

echo
echo "Hiddify:"
echo "  ${HIDDIFY_FILE}"

echo
echo "Network:"
echo "  ${SYSCTL_FILE}"

echo
echo "systemd:"
echo "  ${SYSTEMD_OVERRIDE}"

echo
echo "============================================================"
echo "ORACLE CLOUD"
echo "============================================================"

echo
echo "Make sure Oracle Cloud VCN / NSG / Security List allows:"
echo
echo "  TCP 22"
echo "  TCP 443"

echo
echo "============================================================"
echo "SECURITY"
echo "============================================================"

echo
echo "The API access token is:"
echo
echo "  ${SUBSCRIPTION_ACCESS_TOKEN}"
echo
echo "Do NOT publish it."

echo
echo "Reality private key is stored only in:"
echo
echo "  ${SINGBOX_CONFIG}"

echo
echo "============================================================"
echo
echo "${VERSION} setup completed."
echo
echo "View connection information:"
echo
echo "  cat /etc/sing-box/connection-info.txt"
echo
echo "Clash subscription content:"
echo
echo "  cat /srv/singbox-subscription/clash"
echo
echo "Hiddify subscription content:"
echo
echo "  cat /srv/singbox-subscription/hiddify"
echo
echo "============================================================"

echo
echo "cat /etc/sing-box/connection-info.txt to view connection"
echo "windows uses clash verge rev, android uses hiddify, https://www.clashverge.dev/"
echo "============================================================"
