#!/bin/bash
########################## xinstaller v2 ########################################
# Hardened 3x-ui + Official Nginx + Let's Encrypt SSL installer (Ubuntu-only, Interactive)
# Author: deepseek-v4-pro-0813
#
# Versioning: integer. v1, v2, v3 ... Each bump = one release commit + a git
#   tag named v<N>. No more semantic-version suffixes (no 5.0.0 / 6.1.0).
#
# Changelog v2:
#   - Project and script renamed from "xui-lite" to "xinstaller". All internal
#       names, artifact paths (nginx vhost prefix, fakesite prefix, cron file,
#       maintenance scripts, manifest, log and session files) migrated.
#   - Author recorded as deepseek-v4-pro-0813 from this release onward.
#
# Transport (summary of the current, settled design):
#   - nginx → xray forwarding is on a TRADITIONAL LOCAL TCP PORT
#       (proxy_pass http://127.0.0.1:$fwdport), as in the original
#       GFW4Fun/x-ui-pro.sh base. UDS (/dev/shm/port-XXXX.sock) is not used:
#       UDS sockets live outside xray's control and get deleted on x-ui
#       restarts/cron cycles, and every consumer had to hand-tune ',0666' perms.
#       A loopback TCP listener is bound by xray itself and cannot be orphaned.
#       In 3x-ui, set the inbound Listen to 127.0.0.1 and its Port equal to the
#       <port> segment of the public URL (/<port>/<path>).
#   - proxy_pass remains mandatory for the Xray location: grpc_pass NEVER works
#       in front of xray's xhttp server regardless of transport (it speaks plain
#       HTTP/1.1 + h2c, never gRPC trailers).
#   - Admin panel + /sub/ + /json/ subscription paths remain on TCP loopback.
#
# Features (accumulated into v1 baseline):
#   - Fully interactive (install / uninstall). No CLI flags.
#   - Per-domain fake website auto-install (random template only when root is empty).
#   - Certbot WEBROOT for HTTP-01; DNS-01 (Cloudflare API or Manual/Universal) for
#       wildcards. Per-subdomain cert names (--cert-name "$DOMAIN").
#   - DNS-01 manual flow hardened: authoritative-NS preflight, a --manual-auth-hook
#       that prints the exact TXT value(s), waits for full cross-vantage propagation
#       (authoritative NS + public resolvers, with a settle delay), handles the
#       apex+wildcard two-token case, and retries issuance up to 3 times.
#   - Certbot renewal cron runs DAILY (tolerates transient failures).
#   - sqlite3 race after 3x-ui install: up-to-5s retry loop before DB queries.
#   - Nginx enforced from nginx.org; APT GPG key in /etc/apt/keyrings/ (modern layout).
#   - Post-uninstall: nginx is STARTED (not just reloaded) after a valid config restore.
#
# Usage:
#   sudo bash xinstaller.sh
#   (follow the interactive prompts)
#####################################################################################################
set -Eeuo pipefail
IFS=$'
\t'
trap 'echo "FATAL: command \"${BASH_COMMAND}\" failed at line ${LINENO} with exit code $?" >&2' ERR

# ---------------------------------------------------------------- Constants
readonly XUI_DB_PATH="/etc/x-ui/x-ui.db"
readonly XUI_PANEL_DIR="/usr/local/x-ui"
readonly NGINX_VHOST_PREFIX="xinstaller"
NGINX_VHOST_FILE=""
NGINX_VHOST_LINK=""
readonly NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
readonly NGINX_MAIN_CONF_BACKUP="/etc/nginx/nginx.conf.xinstaller.bak"
readonly FAKESITE_PREFIX="/var/www/xinstaller-fakesite"
FAKESITE_ROOT=""
readonly FAKESITE_CACHE="${HOME}/.cache/xinstaller/randomfakehtml-master"
readonly CRON_FILE="/etc/cron.d/xinstaller"
readonly MAINT_SCRIPT_DIR="/usr/local/sbin"
readonly MANUAL_AUTH_HOOK="/root/.secrets/certbot/manual-auth-hook.sh"
readonly ACME_SESSION_FILE="/tmp/xinstaller-acme-tokens"
readonly XINSTALLER_VERSION="2"
readonly NGINX_MAINT_SCRIPT="${MAINT_SCRIPT_DIR}/xinstaller-nginx-maintenance.sh"
readonly RENEW_HOOK_SCRIPT="${MAINT_SCRIPT_DIR}/xinstaller-certbot-hook.sh"
readonly UPDATE_SCRIPT="${MAINT_SCRIPT_DIR}/xinstaller-system-update.sh"
readonly MANIFEST_FILE="/var/lib/xinstaller-manifest"
readonly SUPPORTED_UBUNTU_CODENAMES="jammy noble oracular"
# NOTE: literal double-quote removed from HACK_REGEX to avoid heredoc collision with nginx.
# URL-encoded quotes (%22) are already covered by the '%' token below.
readonly HACK_REGEX='('"'"'|`|~|,|:|--|;|%|\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)'

# ---------------------------------------------------------------- Output helpers
msg()     { printf '\033[1;37;40m %s \033[0m
' "$1"; }
msg_ok()  { printf '\033[1;32;40m %s \033[0m
' "$1"; }
msg_err() { printf '\033[1;31;40m %s \033[0m
' "$1" >&2; }
msg_inf() { printf '\033[1;36;40m %s \033[0m
' "$1"; }
msg_war() { printf '\033[1;33;40m %s \033[0m
' "$1"; }
hrline()  { printf '\033[1;35;40m%s\033[0m
' "$(printf '%*s' "${COLUMNS:-80}" '' | tr ' ' "${1:--}")"; }

# ---------------------------------------------------------------- Preflight: root
[[ $EUID -ne 0 ]] && { msg_err "not root — re-executing with sudo"; exec sudo "$0" "$@"; }

# ---------------------------------------------------------------- Preflight: OS detection
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        msg_err "Cannot detect OS: /etc/os-release missing"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    msg_inf "Detected OS: ${OS_ID} ${OS_VERSION_ID:-} (codename: ${OS_VERSION_CODENAME:-n/a})"
}

enforce_ubuntu() {
    if [[ "$OS_ID" != "ubuntu" ]]; then
        msg_err "This script is for Ubuntu only (22.04, 24.04, 26.04). Detected: $OS_ID"
        exit 1
    fi
    local supported=false
    local IFS=' '    # override script-wide IFS that excludes spaces
    for c in $SUPPORTED_UBUNTU_CODENAMES; do
        [[ "$OS_VERSION_CODENAME" == "$c" ]] && supported=true && break
    done
    if [[ "$supported" != "true" ]]; then
        msg_err "Unsupported Ubuntu version: ${OS_VERSION_CODENAME:-unknown}. Supported: ${SUPPORTED_UBUNTU_CODENAMES}"
        exit 1
    fi
}

# ---------------------------------------------------------------- Package manager
update_package_index() {
    apt-get update -qq
}

pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"
}

install_packages() {
    local pkg
    local to_install=()
    for pkg in "$@"; do
        pkg_installed "$pkg" || to_install+=("$pkg")
    done
    if ((${#to_install[@]} > 0)); then
        msg_inf "Installing: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
    fi
}

# ---------------------------------------------------------------- Random generator
gen_str() {
    local len="${1:-10}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || true
}

# ---------------------------------------------------------------- Domain splitter
split_domain() {
    local input="$1"
    local sub main
    sub="${input%%.*}"
    if [[ "$sub" == "$input" ]] || [[ "$input" != *.*.* ]]; then
        SUBDOMAIN="$input"
        MAIN_DOMAIN="$input"
    else
        SUBDOMAIN="$sub"
        main="${input#*.}"
        MAIN_DOMAIN="$main"
    fi
}

# ---------------------------------------------------------------- Validation helpers
valid_hostname() {
    local h="$1"
    [[ -n "$h" ]] && [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

add_slashes() {
    local p="$1"
    [[ "$p" =~ ^/ ]] || p="/$p"
    [[ "$p" =~ /$ ]] || p="$p/"
    printf '%s' "$p"
}

ensure_dir() {
    local d="$1"
    case "$d" in
        /|/etc|/usr|/var|/bin|/sbin|/lib|/boot|/root)
            msg_err "Refusing to create top-level directory: $d"; exit 1 ;;
    esac
    install -d -m 0755 "$d"
}

record_artifact() {
    local path="$1"
    local kind="${2:-file}"
    ensure_dir "$(dirname "$MANIFEST_FILE")"
    printf '%s\t%s
' "$kind" "$path" >> "$MANIFEST_FILE"
}

# ---------------------------------------------------------------- Service helper
service_enable() {
    local svc
    for svc in "$@"; do
        systemctl is-active --quiet "$svc" 2>/dev/null && systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl start "$svc" >/dev/null 2>&1 || true
    done
}

# ---------------------------------------------------------------- Safe nginx reload
nginx_safe_reload() {
    if ! nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
        msg_err "nginx config invalid — not reloading"
        nginx -t -c "$NGINX_MAIN_CONF" || true
        return 1
    fi
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || systemctl restart nginx
    else
        systemctl start nginx
    fi
}

# ---------------------------------------------------------------- Graceful port free (SIGTERM → SIGKILL) with clean PID formatting
free_http_ports() {
    msg_inf "Freeing ports 80/443 for current domain (other domains unaffected)..."
    rm -f "$NGINX_VHOST_LINK" 2>/dev/null || true
    rm -f "/etc/nginx/sites-enabled/default" 2>/dev/null || true
    if systemctl is-active --quiet nginx 2>/dev/null; then
        if nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
            msg_inf "nginx reloaded (other domains still serving)"
        else
            msg_war "nginx config invalid after vhost removal — restarting"
            systemctl restart nginx >/dev/null 2>&1 || true
        fi
    fi
    for port in 80/tcp 80/udp 443/tcp 443/udp; do
        if fuser "$port" >/dev/null 2>&1; then
            local raw_pids clean_pids
            raw_pids=$(fuser "$port" 2>/dev/null || true)
            clean_pids=$(printf '%s' "$raw_pids" | tr -s '[:space:]' ' ' | grep -oE '[0-9]+' | paste -sd ' ' - || true)
            if [[ -n "$clean_pids" ]]; then
                local nginx_pids
                nginx_pids=$(pgrep -x nginx 2>/dev/null | paste -sd ' ' - || true)
                local non_nginx_pids=""
                for pid in $clean_pids; do
                    if [[ " $nginx_pids " != *" $pid "* ]]; then
                        non_nginx_pids="$non_nginx_pids $pid"
                    fi
                done
                if [[ -n "$non_nginx_pids" ]]; then
                    msg_war "Non-nginx process(es) on port $port:${non_nginx_pids}. Sending SIGTERM..."
                    for pid in $non_nginx_pids; do
                        kill -TERM "$pid" >/dev/null 2>&1 || true
                    done
                    sleep 2
                    for pid in $non_nginx_pids; do
                        if kill -0 "$pid" 2>/dev/null; then
                            msg_war "Process $pid did not stop. Sending SIGKILL..."
                            kill -KILL "$pid" >/dev/null 2>&1 || true
                        fi
                    done
                fi
            fi
        fi
    done
}

# ---------------------------------------------------------------- Post-install dependency check
check_dependencies() {
    local missing_deps=0
    local deps=("nginx" "systemctl" "fuser" "certbot" "curl" "jq" "sqlite3" "wget" "unzip" "nc")
    msg_inf "Checking for required command dependencies..."
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            msg_err "FATAL: Required command '$cmd' is not installed or not in PATH."
            missing_deps=1
        fi
    done
    if (( missing_deps )); then
        msg_err "Please install missing dependencies and try again."
        exit 1
    fi
    msg_ok "All required dependencies are present."
}

# ---------------------------------------------------------------- Wait for x-ui DB to appear (race fix)
wait_for_xui_db() {
    local max_wait="${1:-5}"
    local waited=0
    msg_inf "Waiting for $XUI_DB_PATH to become available (up to ${max_wait}s)..."
    while (( waited < max_wait )); do
        if [[ -r "$XUI_DB_PATH" ]]; then
            msg_ok "x-ui database is ready."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [[ ! -r "$XUI_DB_PATH" ]]; then
        msg_war "x-ui database did not appear within ${max_wait}s — continuing anyway."
        return 1
    fi
}

# ---------------------------------------------------------------- Smart SSL Hunt
smart_ssl_hunt() {
    # 1. PRIORITY: Check for existing wildcard on MAIN_DOMAIN via actual certificate
    if [[ -f "/etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem" ]]; then
        if openssl x509 -in "/etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem" -noout -text 2>/dev/null | grep -qF "DNS:*.$MAIN_DOMAIN"; then
            msg_ok "Smart Hunt: Found existing wildcard certificate for *.$MAIN_DOMAIN"
            CERT_NAME="$MAIN_DOMAIN"
            CERT_DIR="/etc/letsencrypt/live/${MAIN_DOMAIN}"
            return 0
        fi
    fi
    
    # 2. FALLBACK: Check for existing exact match on DOMAIN via actual certificate
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        if openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -text 2>/dev/null | grep -qF "DNS:${DOMAIN}"; then
            msg_ok "Smart Hunt: Found existing exact certificate for $DOMAIN"
            CERT_NAME="$DOMAIN"
            CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
            return 0
        fi
    fi
    
    return 1 # Not found
}

# ---------------------------------------------------------------- OS detection + Ubuntu enforcement
detect_os
enforce_ubuntu

# ---------------------------------------------------------------- Banner
echo
msg_inf ' _     _ _     _ _____     _ _ _       '
msg_inf '  \___/  |     |   |       | (_) |      '
msg_inf ' _/   \_ |_____| __|__     | |_| |_ ___ '
msg_inf "                     L I T E  v${XINSTALLER_VERSION}     "
hrline
msg "Author: qwen 3.7 max | Ubuntu-only edition | Interactive"
hrline

# ============================================================
# INTERACTIVE: install or uninstall?
# ============================================================
ACTION=""
while [[ "$ACTION" != "1" && "$ACTION" != "2" ]]; do
    echo
    msg_inf "What do you want to do?"
    msg     "  1) Install / Reconfigure xinstaller"
    msg     "  2) Uninstall xinstaller artifacts"
    read -rp $'\033[1;32;40m Enter choice [1/2]: \033[0m' ACTION
done

# ============================================================
# UNINSTALL
# ============================================================
if [[ "$ACTION" == "2" ]]; then
    # Discover all xinstaller vhosts
    declare -a VHOST_DOMAINS=()
    for f in /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-*.conf; do
        [[ -f "$f" ]] || continue
        local_basename=$(basename "$f" .conf)
        local_domain="${local_basename#${NGINX_VHOST_PREFIX}-}"
        VHOST_DOMAINS+=("$local_domain")
    done

    UNINSTALL_MODE=""
    if ((${#VHOST_DOMAINS[@]} == 0)); then
        msg_war "No xinstaller domain vhosts found — performing full cleanup."
        UNINSTALL_MODE="all"
    elif ((${#VHOST_DOMAINS[@]} == 1)); then
        msg_inf "Found 1 xinstaller domain: ${VHOST_DOMAINS[0]}"
        while [[ "$UNINSTALL_MODE" != "y" && "$UNINSTALL_MODE" != "n" ]]; do
            read -rp $'\033[1;32;40m Remove it and all shared artifacts? [y/n]: \033[0m' UNINSTALL_MODE
            UNINSTALL_MODE="${UNINSTALL_MODE,,}"
        done
        [[ "$UNINSTALL_MODE" == "y" ]] && UNINSTALL_MODE="all" || UNINSTALL_MODE="cancel"
    else
        msg_inf "Found ${#VHOST_DOMAINS[@]} xinstaller domains:"
        idx=1
        for d in "${VHOST_DOMAINS[@]}"; do
            msg "  $idx) $d"
            ((idx++))
        done
        echo
        msg "  a) Remove ALL domains + shared artifacts"
        msg "  s) Select specific domain(s) to remove"
        msg "  c) Cancel"
        while [[ "$UNINSTALL_MODE" != "a" && "$UNINSTALL_MODE" != "s" && "$UNINSTALL_MODE" != "c" ]]; do
            read -rp $'\033[1;32;40m Enter choice [a/s/c]: \033[0m' UNINSTALL_MODE
            UNINSTALL_MODE="${UNINSTALL_MODE,,}"
        done
    fi

    if [[ "$UNINSTALL_MODE" == "cancel" ]]; then
        msg_ok "Uninstall cancelled."
        exit 0
    fi

    declare -a DOMAINS_TO_REMOVE=()
    if [[ "$UNINSTALL_MODE" == "all" ]]; then
        DOMAINS_TO_REMOVE=("${VHOST_DOMAINS[@]}")
    elif [[ "$UNINSTALL_MODE" == "s" ]]; then
        msg_inf "Enter domain numbers to remove (comma-separated, e.g. 1,3):"
        selected=""
        while [[ -z "$selected" ]]; do
            read -rp $'\033[1;32;40m Selection: \033[0m' selected
        done
        IFS=',' read -ra SEL_NUMS <<< "$selected"
        for num in "${SEL_NUMS[@]}"; do
            num=$(echo "$num" | tr -d '[:space:]')
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#VHOST_DOMAINS[@]} )); then
                DOMAINS_TO_REMOVE+=("${VHOST_DOMAINS[$((num-1))]}")
            else
                msg_war "Invalid number: $num (skipped)"
            fi
        done
        if ((${#DOMAINS_TO_REMOVE[@]} == 0)); then
            msg_err "No valid domains selected — exiting."
            exit 1
        fi
    fi

    msg_war "Removing domains: ${DOMAINS_TO_REMOVE[*]}"

    # Remove per-domain artifacts
    for d in "${DOMAINS_TO_REMOVE[@]}"; do
        msg_inf "Removing domain: $d"
        rm -f "/etc/nginx/sites-enabled/${NGINX_VHOST_PREFIX}-${d}.conf" 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-${d}.conf" 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-${d}.conf.phase1.bak" 2>/dev/null || true
        rm -rf "/var/www/xinstaller-fakesite-${d}" 2>/dev/null || true
        rm -f "/root/.secrets/certbot/cloudflare-${d}.ini" 2>/dev/null || true
    done

    # If all domains removed, also clean shared artifacts
    REMAINING_COUNT=0
    for f in /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-*.conf; do
        [[ -f "$f" ]] && ((REMAINING_COUNT++)) || true
    done

    if (( REMAINING_COUNT == 0 )); then
        msg_inf "All domains removed — cleaning shared artifacts..."
        systemctl stop x-ui 2>/dev/null || true
        if command -v pip3 >/dev/null 2>&1; then
            pip3 uninstall -y pyasynchat pyasyncore >/dev/null 2>&1 || true
        fi
        rm -rf /root/.cache/pip 2>/dev/null || true
        apt-get purge -y -qq fail2ban python3-pip python3-pyasyncore python3-pyinotify whois >/dev/null 2>&1 || true
        apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true

        if [[ -f "$NGINX_MAIN_CONF_BACKUP" ]]; then
            cp -f "$NGINX_MAIN_CONF_BACKUP" "$NGINX_MAIN_CONF"
            rm -f "$NGINX_MAIN_CONF_BACKUP"
        fi

        rm -f /etc/nginx/sites-enabled/${NGINX_VHOST_PREFIX}.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}.conf.phase1.bak 2>/dev/null || true
        rm -f "$CRON_FILE" 2>/dev/null || true
        rm -f "$NGINX_MAINT_SCRIPT" "$RENEW_HOOK_SCRIPT" "$UPDATE_SCRIPT" 2>/dev/null || true
        rm -rf "${FAKESITE_PREFIX}" 2>/dev/null || true
        find /dev/shm -maxdepth 1 -name 'port-*.sock' -delete 2>/dev/null || true
        rm -rf /root/.secrets/certbot 2>/dev/null || true
        rm -f "$MANIFEST_FILE" 2>/dev/null || true
    else
        msg_inf "$REMAINING_COUNT domain(s) remain — shared artifacts preserved."
        nginx_safe_reload || true
    fi

    if command -v nginx >/dev/null 2>&1; then
        if nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
            systemctl start nginx 2>/dev/null || true
            msg_ok "nginx config valid — nginx started."
        else
            msg_war "nginx config is invalid — leaving nginx stopped."
            nginx -t -c "$NGINX_MAIN_CONF" || true
        fi
    fi

    if command -v x-ui >/dev/null 2>&1 && (( REMAINING_COUNT == 0 )); then
        msg_war "3x-ui is still installed. Run: printf 'y\n' | x-ui uninstall  (if you want it gone)"
    fi
    msg_ok "xinstaller uninstall complete."
    exit 0
fi

# ============================================================
# INSTALL: Interactive prompts
# ============================================================

# --- 1. Domain
DOMAIN=""
while ! valid_hostname "$DOMAIN"; do
    read -rp $'\033[1;32;40m Enter subdomain (e.g. sub.domain.tld): \033[0m' DOMAIN
done
DOMAIN="${DOMAIN//[[:space:]]/}"
split_domain "$DOMAIN"
NGINX_VHOST_FILE="/etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-${DOMAIN}.conf"
NGINX_VHOST_LINK="/etc/nginx/sites-enabled/${NGINX_VHOST_PREFIX}-${DOMAIN}.conf"
FAKESITE_ROOT="${FAKESITE_PREFIX}-${DOMAIN}"
msg_inf "Main domain: $MAIN_DOMAIN | Target host: $DOMAIN"
msg_inf "Vhost file: $NGINX_VHOST_FILE"
LEGACY_VHOST="/etc/nginx/sites-available/${NGINX_VHOST_PREFIX}.conf"
if [[ -f "$LEGACY_VHOST" ]]; then
    msg_war "Removing legacy single-file vhost from previous xinstaller version..."
    rm -f "/etc/nginx/sites-enabled/${NGINX_VHOST_PREFIX}.conf" 2>/dev/null || true
    rm -f "$LEGACY_VHOST" 2>/dev/null || true
    rm -f "${LEGACY_VHOST}.phase1.bak" 2>/dev/null || true
fi
EXISTING_MAIN_DOMAIN_VHOST=""
for f in /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-*.conf; do
    [[ -f "$f" ]] || continue
    [[ "$f" == "$NGINX_VHOST_FILE" ]] && continue
    if grep -qF "$MAIN_DOMAIN" "$f" 2>/dev/null; then
        EXISTING_MAIN_DOMAIN_VHOST="$f"
        break
    fi
done
if [[ -n "$EXISTING_MAIN_DOMAIN_VHOST" ]]; then
    msg_war "Another xinstaller vhost already uses MAIN_DOMAIN '$MAIN_DOMAIN':"
    msg_war "  $EXISTING_MAIN_DOMAIN_VHOST"
    msg_war "  server_name overlap may cause nginx routing conflicts."
fi

# --- 2. Smart SSL Hunt & SSL Method
CERT_NAME=""
CERT_DIR=""
if smart_ssl_hunt; then
    SSL_METHOD="existing"
else
    SSL_METHOD=""
    while [[ "$SSL_METHOD" != "http01" && "$SSL_METHOD" != "dns01_cf" && "$SSL_METHOD" != "dns01_manual" ]]; do
        echo
        msg_inf "Choose SSL issuance method:"
        msg     "  1) HTTP-01 (Standard — DNS A/AAAA must point to this server)"
        msg     "  2) DNS-01  (Cloudflare API — Automatic wildcard)"
        msg     "  3) DNS-01  (Manual / Universal — Pauses for TXT record creation)"
        read -rp $'\033[1;32;40m Enter choice [1/2/3]: \033[0m' _ssl_choice
        case "${_ssl_choice:-}" in
            1) SSL_METHOD="http01" ;;
            2) SSL_METHOD="dns01_cf"  ;;
            3) SSL_METHOD="dns01_manual" ;;
            *) msg_war "Invalid choice." ;;
        esac
    done
fi

CF_TOKEN=""
if [[ "$SSL_METHOD" == "dns01_cf" ]]; then
    msg_inf "Cloudflare API token requires Zone:Zone:Read (All Zones) and Zone:DNS:Edit."
    while [[ -z "$CF_TOKEN" ]]; do
        read -rp $'\033[1;32;40m Enter Cloudflare API token: \033[0m' CF_TOKEN
    done
fi

# --- 3. Existing site? (auto-detect per-domain)
EXISTING_SITE="y"
if [[ ! -d "$FAKESITE_ROOT" ]] || [[ -z "$(ls -A "$FAKESITE_ROOT" 2>/dev/null)" ]]; then
    EXISTING_SITE="n"
fi

msg_inf "Summary:"
msg     "  Domain    : $DOMAIN (parent: $MAIN_DOMAIN)"
if [[ "$SSL_METHOD" == "existing" ]]; then
    msg     "  SSL       : existing ($CERT_DIR)"
elif [[ "$SSL_METHOD" == "dns01_cf" ]]; then
    msg     "  SSL       : dns01 (Cloudflare API - Wildcard)"
elif [[ "$SSL_METHOD" == "dns01_manual" ]]; then
    msg     "  SSL       : dns01 (Manual - Wildcard)"
else
    msg     "  SSL       : $SSL_METHOD"
fi
msg     "  Socket    : tcp (Xray on local loopback port)"
msg     "  Fake site : $( [[ "$EXISTING_SITE" == "n" ]] && echo "will install random template" || echo "preserved (domain root already populated)" )"
hrline

# ---------------------------------------------------------------- Base packages
update_package_index
BASE_PKGS=(curl wget unzip openssl jq netcat-openbsd sqlite3 cron psmisc ca-certificates python3 certbot tzdata-legacy)
install_packages "${BASE_PKGS[@]}"
# Fix Ubuntu 24.04 tzdata/pytz missing files bug
if [[ ! -f /usr/share/zoneinfo/zone1970.tab ]] || [[ ! -f /usr/share/zoneinfo/tzdata.zi ]]; then
    msg_war "Fixing missing tzdata files for Python pytz compatibility..."
    apt-get install --reinstall -y -o Dpkg::Options::="--force-confmiss" tzdata tzdata-legacy >/dev/null 2>&1 || true
    # Fallback dummy files if package manager fails to place them
    [[ -f /usr/share/zoneinfo/tzdata.zi ]] || echo "#version 2024a" > /usr/share/zoneinfo/tzdata.zi
    [[ -f /usr/share/zoneinfo/zone1970.tab ]] || touch /usr/share/zoneinfo/zone1970.tab
fi
# ---------------------------------------------------------------- Enforce nginx.org repo (modern keyring path)
enforce_nginx_official() {
    msg_inf "Enforcing nginx from nginx.org (official repo)..."
    local from_official=0
    if command -v nginx >/dev/null 2>&1; then
        msg_inf "Nginx is installed: $(nginx -v 2>&1)"
        grep -q "nginx.org/packages" /etc/apt/sources.list.d/nginx.list 2>/dev/null && from_official=1 || true
    fi
    if command -v nginx >/dev/null 2>&1 && [[ $from_official -eq 0 ]]; then
        msg_war "Removing distro nginx to install from nginx.org..."
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        apt-get remove -y -qq nginx nginx-common nginx-full nginx-core 2>/dev/null || true
    fi

    install_packages curl gnupg2 ca-certificates
    ensure_dir /etc/apt/keyrings
    chmod 0755 /etc/apt/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor --yes \
        | tee /etc/apt/keyrings/nginx-archive-keyring.gpg >/dev/null
    chmod 0644 /etc/apt/keyrings/nginx-archive-keyring.gpg

    local codename="$OS_VERSION_CODENAME"
    cat > /etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu ${codename} nginx
EOF
    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF
    update_package_index
    install_packages nginx
    msg_ok "Nginx installed: $(nginx -v 2>&1)"

    local installed_ver available_ver
    installed_ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    available_ver=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/{print $2}' | sed 's/^[0-9]*://' | cut -d- -f1 || true)
    if [[ -n "$available_ver" && "$available_ver" != "$installed_ver" ]]; then
        msg_war "Nginx update available: $installed_ver → $available_ver"
        apt-get install -y -qq --only-upgrade nginx
        msg_ok "Nginx updated: $(nginx -v 2>&1)"
    fi
}
enforce_nginx_official

if [[ ! -d /etc/systemd/system/nginx.service.d ]]; then
    install -d -m 0755 /etc/systemd/system/nginx.service.d
fi
cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=65535
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable nginx >/dev/null 2>&1 || true
service_enable cron

# ---------------------------------------------------------------- Post-install dependency check
check_dependencies

# ---------------------------------------------------------------- Transport advisory (TCP mode)
msg_inf "Transport mode: nginx → xray over a TRADITIONAL LOCAL TCP PORT (loopback)"
msg_war "In 3x-ui panel, for each Xray inbound, set Listen to: 127.0.0.1"
msg_war "and set the inbound Port equal to the <port> in the public URL /<port>/<path>."
msg_war "Only the main Xray inbound uses this port. Panel + /sub/ + /json/ stay on their own TCP loopback ports."
msg_war "All xhttp modes (packet-up, stream-up, stream-down) are supported. Never use grpc_pass in front of xray."

# ---------------------------------------------------------------- Free 80/443 (graceful)
free_http_ports

# ---------------------------------------------------------------- Server IPs
IP4_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
IP6_REGEX='([a-f0-9:]+:+)+[a-f0-9]+'
IP4=$(ip route get 8.8.8.8 2>/dev/null | grep -Po 'src \K\S*' || true)
IP6=$(ip route get 2620:fe::fe 2>/dev/null | grep -Po 'src \K\S*' || true)
[[ "${IP4:-}" =~ $IP4_REGEX ]] || IP4=$(curl -fsSs ipv4.icanhazip.com || echo "")
[[ "${IP6:-}" =~ $IP6_REGEX ]] || IP6=$(curl -fsSs --max-time 3 ipv6.icanhazip.com 2>/dev/null || echo "")

# ---------------------------------------------------------------- Nginx directories + main conf
NGINX_USER="www-data"
id -u "$NGINX_USER" >/dev/null 2>&1 || NGINX_USER="nginx"
ensure_dir /etc/nginx/sites-available
ensure_dir /etc/nginx/sites-enabled
ensure_dir /etc/nginx/conf.d
ensure_dir /var/log/nginx
ensure_dir "$FAKESITE_ROOT"

if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    if grep -q "listen[[:space:]]*80" /etc/nginx/conf.d/default.conf 2>/dev/null; then
        mv -f /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.xinstaller.disabled
        record_artifact /etc/nginx/conf.d/default.conf.xinstaller.disabled file
    fi
fi

if [[ ! -f "$NGINX_MAIN_CONF_BACKUP" && -f "$NGINX_MAIN_CONF" ]]; then
    cp -a "$NGINX_MAIN_CONF" "$NGINX_MAIN_CONF_BACKUP"
fi

# Remove only the default nginx vhost and this domain's stale link (preserve other xinstaller domains)
rm -f "/etc/nginx/sites-enabled/default" 2>/dev/null || true
rm -f "$NGINX_VHOST_LINK" 2>/dev/null || true
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

TMP_MAIN=$(mktemp)
cat > "$TMP_MAIN" <<EOF
user $NGINX_USER;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 65535;
events { worker_connections 65535; use epoll; multi_accept on; }
http {
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;
    gzip on; sendfile on; tcp_nopush on;
    types_hash_max_size 4096;
    default_type application/octet-stream;
    include /etc/nginx/mime.types;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      '';
    }
}
EOF

if nginx -t -c "$TMP_MAIN" >/dev/null 2>&1; then
    cp -f "$TMP_MAIN" "$NGINX_MAIN_CONF"
else
    msg_err "nginx.conf validation failed — possible causes:"
    msg_err "  1. Generated config is invalid (unlikely)"
    msg_err "  2. Another xinstaller vhost in sites-enabled references missing files (cert, etc.)"
    msg_err "  Details:"
    nginx -t -c "$TMP_MAIN" || true
    rm -f "$TMP_MAIN"
    exit 1
fi
rm -f "$TMP_MAIN"
# ---------------------------------------------------------------- Detect IPv6 support
IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [[ -e /proc/net/if_inet6 ]] && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" != "1" ]]; then
    IPV6_LISTEN_80="listen [::]:80;"
    IPV6_LISTEN_443="listen [::]:443 ssl;"
    msg_inf "IPv6 support detected — enabling [::] listeners."
else
    msg_war "IPv6 not supported/disabled on this kernel — skipping [::] listeners."
fi

# ---------------------------------------------------------------- Phase-1 vhost: port 80 only (for certbot HTTP-01 webroot)
if [[ "$SSL_METHOD" == "http01" ]]; then
TMP_VHOST=$(mktemp)
cat > "$TMP_VHOST" <<EOF
server {
    server_tokens off;
    server_name $MAIN_DOMAIN *.$MAIN_DOMAIN;
    listen 80;
    $IPV6_LISTEN_80
    root $FAKESITE_ROOT;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

rm -f "$NGINX_VHOST_LINK" 2>/dev/null || true
rm -f "/etc/nginx/sites-enabled/default" 2>/dev/null || true
cp -f "$TMP_VHOST" "$NGINX_VHOST_FILE"
rm -f "$TMP_VHOST"
ln -sf "$NGINX_VHOST_FILE" "$NGINX_VHOST_LINK"

if ! nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
    msg_err "Phase-1 nginx config invalid:"
    nginx -t -c "$NGINX_MAIN_CONF" || true
    exit 1
fi
systemctl start nginx || systemctl restart nginx
else
    msg_inf "Skipping phase-1 (port-80 vhost) — not needed for $SSL_METHOD"
fi

# ---------------------------------------------------------------- DNS-01 propagation helpers
# Let's Encrypt does NOT query a recursive resolver (8.8.8.8/dns.google). It queries the
# domain's AUTHORITATIVE nameservers directly, from US/EU vantage points, with a strict
# timeout. If a zone update hasn't reached every NS yet, or an NS is slow/unreachable from
# there, validation fails with "SERVFAIL looking up TXT". Google's toolbox can show the
# record as present even when LE's direct NS query still SERVFAILs, so we cannot rely on it.
# These helpers make the script wait until the token is actually served by every NS.
get_authoritative_ns() {
    local domain="$1" ns_list
    ns_list=$(dig +short NS "$domain" | sed 's/\.$//' | sort -u)
    printf '%b' "$ns_list"
}

ns_preflight_check() {
    local domain="$1" ns_list failed=0 ns ip
    ns_list=$(get_authoritative_ns "$domain")
    if [[ -z "$ns_list" ]]; then
        msg_err "Could not resolve any authoritative NS for $domain — delegation broken?"
        return 1
    fi
    msg_inf "Authoritative nameservers for $domain:"
    for ns in $ns_list; do
        ip=$(dig +short A "$ns" | head -1)
        msg     "  - $ns ${ip:+($ip)}"
        # Probe with a real UDP DNS query (authoritative servers often refuse
        # raw TCP connects on 53, so a TCP port check gives false "unreachable").
        if [[ -z "$ip" ]] || ! timeout 5 dig +short +time=3 +tries=1 A "$ns" "@$ns" >/dev/null 2>&1; then
            msg_war "    WARNING: $ns${ip:+ ($ip)} did not answer a DNS query on this host."
            failed=1
        fi
    done
    if (( failed )); then
        msg_err "All authoritative NSs must be reachable for DNS-01 to work. Fix NS before issuing."
        msg_err "If this is a fresh zone at your DNS provider, confirm the domain is ACTIVE there."
        return 1
    fi
    return 0
}

# Writes a certbot --manual-auth-hook that (1) TELLS the user the exact TXT record + value
# certbot generated, (2) waits for the user to add it, then (3) blocks until that value is
# served by every authoritative NS of $CERTBOT_DOMAIN. Certbot only proceeds to validation
# when the hook exits 0, so we get both the visible token AND an automatic propagation wait
# (no early-Enter SERVFAIL). NOTE: a --manual-auth-hook replaces certbot's interactive
# "press Enter" prompt, so the hook itself must surface the token via /dev/tty.
write_manual_auth_hook() {
    ensure_dir "$(dirname "$MANUAL_AUTH_HOOK")"
    cat > "$MANUAL_AUTH_HOOK" <<'EOF'
#!/bin/bash
set -u
LOG=/var/log/xinstaller-certbot-manual-auth.log
TTS=/dev/tty
SESSION=/tmp/xinstaller-acme-tokens
RESOLVERS="8.8.8.8 1.1.1.1 9.9.9.9"
exec 3>>"$LOG"    # fd 3 = diagnostic log
say()  { echo "[$(date -Iseconds)] $*" >&3; }
tell() { printf '\033[1;33;40m%s\033[0m\n' "$*" >"$TTS" 2>/dev/null || true; }

# Wildcard identifiers arrive as CERTBOT_DOMAIN='*.example.com'. Strip '*.'
# so the TXT name and the NS query target the real apex zone.
D="${CERTBOT_DOMAIN#\*.}"
CHALLENGE="_acme-challenge.${D}"
NS_LIST=$(dig +short NS "$D" 2>/dev/null | sed 's/\.$//' | sort -u)
say "auth-hook domain=$CERTBOT_DOMAIN base=$D token_len=${#CERTBOT_VALIDATION} challenge=$CHALLENGE ns=$NS_LIST"
if [[ -z "$NS_LIST" ]]; then
    tell "ERROR: no authoritative NS resolvable for $D"
    say "FATAL no authoritative NS"
    exit 1
fi

# Accumulate every token certbot asks for in THIS run (apex + wildcard = two
# tokens at the same _acme-challenge name). Script clears SESSION before each
# certbot attempt so only the current run's tokens are listed.
touch "$SESSION" 2>/dev/null || true
grep -qxF "$CERTBOT_VALIDATION" "$SESSION" 2>/dev/null || echo "$CERTBOT_VALIDATION" >> "$SESSION"
mapfile -t EXPECTED < "$SESSION"

tell "=========================================================================="
tell "       CERTBOT DNS-01  (run #$(date +%s))"
tell "=========================================================================="
tell "name : $CHALLENGE"
tell "Ensure EXACTLY these value(s) are present at that name (the full set needed"
tell "for both the apex and the wildcard):"
for t in "${EXPECTED[@]}"; do tell "    value: $t"; done
tell ""
tell "Add any value listed above that is missing, and DELETE any other value at"
tell "$CHALLENGE that is NOT in the list above (stale values from an earlier run"
tell "make Let's Encrypt report 'Incorrect TXT record'). Then press ENTER."
tell "=========================================================================="
printf '\033[1;32;40m%s\033[0m' "Press ENTER once the TXT values above are correct..." >"$TTS" 2>/dev/null || true
read -r _ <"$TTS" 2>/dev/null || true

# Wait until the state is fully converged everywhere: every expected token is
# present AND no unexpected (stale) value remains, on every authoritative NS and
# public resolver. Then hold a settle delay and re-verify, because EdgeOne's
# authoritative NS are multi-IP/anycast and cross-instance lag makes LE see old
# values even after this VPS confirms the new one.
converged_anywhere() {
    local server="$1" vals v allok=1
    vals=$(dig +short +time=3 +tries=1 TXT "$CHALLENGE" "@$server" 2>/dev/null | tr -d '"')
    for t in "${EXPECTED[@]}"; do
        grep -qxF "$t" <<<"$vals" || { allok=0; break; }
    done
    if (( allok )); then
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            grep -qxF "$v" "$SESSION" 2>/dev/null || { allok=0; break; }
        done <<<"$vals"
    fi
    (( allok ))
}

declare -i tries=0
while (( tries < 60 )); do
    converged=1
    for server in $NS_LIST $RESOLVERS; do
        if converged_anywhere "$server"; then
            say "  $server:OK"
        else
            say "  $server:WAIT"
            converged=0
        fi
    done
    say "try=$tries converged=$converged"

    if (( converged )); then
        say "converged; settling 60s against cross-instance lag"
        sleep 60
        reok=1
        for server in $NS_LIST $RESOLVERS; do
            converged_anywhere "$server" || { reok=0; break; }
        done
        if (( reok )); then
            tell "Propagation confirmed on all NS and public resolvers (settled) — validation proceeding."
            say "PROPAGATED+SETTLED OK"
            exit 0
        fi
        say "post-settle recheck failed; continuing to wait"
    fi
    ((tries++))
    sleep 5
done
tell "TIMEOUT: token state not converged on all NS after ~5 min."
say "TIMEOUT after trials"
exit 1
EOF
    chmod 700 "$MANUAL_AUTH_HOOK"
    msg_ok "DNS-01 helper hook installed: $MANUAL_AUTH_HOOK"
}

# ---------------------------------------------------------------- SSL via certbot
if [[ "$SSL_METHOD" == "existing" ]]; then
    msg_inf "Using existing certificate: $CERT_DIR"
else
    # Determine what to request
    if [[ "$SSL_METHOD" == "http01" ]]; then
        CERT_NAME="$DOMAIN"
        CERT_DIR="/etc/letsencrypt/live/${CERT_NAME}"
        CERT_DOMAINS=("-d" "$DOMAIN")
    else
        # Both dns01_cf and dns01_manual get wildcards
        CERT_NAME="$MAIN_DOMAIN"
        CERT_DIR="/etc/letsencrypt/live/${CERT_NAME}"
        CERT_DOMAINS=("-d" "$MAIN_DOMAIN" "-d" "*.$MAIN_DOMAIN")
    fi

    # Double check if it somehow exists now
    if [[ -d "$CERT_DIR" && -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
        msg_inf "SSL certificate already exists for $CERT_NAME — skipping issuance."
        msg_ok "Using existing certificate: $CERT_DIR"
    else
        msg_inf "Issuing Let's Encrypt certificate for $CERT_NAME ..."
        if [[ "$SSL_METHOD" == "dns01_cf" ]]; then
            install_packages python3-certbot-dns-cloudflare 2>/dev/null || {
                msg_err "certbot-dns-cloudflare not available; install manually"
                exit 1
            }
            ensure_dir /root/.secrets/certbot
            CF_CRED_FILE="/root/.secrets/certbot/cloudflare-${DOMAIN}.ini"
            cat > "$CF_CRED_FILE" <<EOF
# Cloudflare API token used by Certbot (Zone ID is auto-discovered)
dns_cloudflare_api_token = $CF_TOKEN
EOF
            chmod 600 "$CF_CRED_FILE"
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials "$CF_CRED_FILE" \
                --non-interactive --agree-tos \
                --register-unsafely-without-email \
                --cert-name "$CERT_NAME" "${CERT_DOMAINS[@]}"
        elif [[ "$SSL_METHOD" == "dns01_manual" ]]; then
            # Let's Encrypt queries the AUTHORITATIVE nameservers directly (not 8.8.8.8/
            # dns.google) from US/EU vantage points. An early Enter, or a slow/unreachable
            # NS from those regions, produces "SERVFAIL looking up TXT". The auth hook below
            # runs AFTER Enter and blocks until the token is actually served by every NS, so
            # validation only starts once the record is genuinely live everywhere.
            if ! ns_preflight_check "$MAIN_DOMAIN"; then
                msg_err "Authoritative nameservers unreachable — DNS-01 cannot succeed. Aborting."
                exit 1
            fi
            write_manual_auth_hook
            msg_war "A helper hook will print the exact TXT name + value(s) certbot needs."
            msg_war "For the wildcard it asks for BOTH the apex and the wildcard token (two"
            msg_war "values at the SAME '_acme-challenge' name) — one prompt per domain."
            msg_war "Add every listed value, and delete any '_acme-challenge' value NOT in"
            msg_war "the list (stale values from an earlier run). The hook auto-waits for"
            msg_war "propagation (up to ~5 min) before letting Let's Encrypt validate."
            _cb_try=1 _cb_ok=0
            while (( _cb_try <= 3 )); do
                rm -f "$ACME_SESSION_FILE"
                if [[ $_cb_try -gt 1 ]]; then
                    msg_war "Retry $_cb_try/3 — certbot issued a NEW token set. Add the listed values"
                    msg_war "and delete any stale '_acme-challenge' value, then press ENTER."
                fi
                certbot certonly --manual --preferred-challenges dns \
                    --manual-auth-hook "$MANUAL_AUTH_HOOK" \
                    --agree-tos \
                    --register-unsafely-without-email \
                    --cert-name "$CERT_NAME" "${CERT_DOMAINS[@]}"
                if [[ -d "$CERT_DIR" && -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
                    _cb_ok=1
                    break
                fi
                if (( _cb_try == 3 )); then
                    msg_err "Manual DNS-01 issuance failed after 3 attempts — see /var/log/xinstaller-certbot-manual-auth.log."
                else
                    msg_war "Issuance attempt $_cb_try failed. Wait ~1 min (NS took a moment), then it will retry."
                    sleep 60
                fi
                ((_cb_try++))
            done
            [[ $_cb_ok -eq 1 ]] || { msg_err "SSL issuance failed for $CERT_NAME"; exit 1; }
        else
            # WEBROOT: does NOT touch nginx configs
            msg_war "Let's Encrypt rate limit: 5 duplicate certs per week per registered domain."
            msg_war "If you've issued 5 certs for $DOMAIN recently, this will fail."
            msg_war "Consider dns01 (wildcard) if you need multiple subdomains."
            certbot certonly --webroot -w "$FAKESITE_ROOT" \
                --non-interactive --agree-tos \
                --register-unsafely-without-email \
                --cert-name "$CERT_NAME" "${CERT_DOMAINS[@]}"
        fi
        if [[ ! -d "$CERT_DIR" || ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
            msg_err "SSL issuance failed for $CERT_NAME"
            exit 1
        fi
        msg_ok "SSL certificate issued: $CERT_DIR"
    fi
fi

if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
    msg_err "SSL cert/key missing — cannot enable HTTPS vhost"
    exit 1
fi

# ---------------------------------------------------------------- 3x-ui helpers
update_xui_db() {
    local port="$1" path="$2" user="$3" pass="$4"
    if [[ -f "$XUI_DB_PATH" ]]; then
        x-ui stop >/dev/null 2>&1 || true
        sqlite3 "$XUI_DB_PATH" <<EOSQL
DELETE FROM settings WHERE key IN ('webPort','webCertFile','webKeyFile','webBasePath');
INSERT INTO settings (key, value) VALUES
('webPort','${port}'),
('webCertFile',''),
('webKeyFile',''),
('webBasePath','${path}');
EOSQL
    fi
    "$XUI_PANEL_DIR/x-ui" setting -username "$user" -password "$pass" >/dev/null 2>&1 || true
}

clear_xui_ssl_bind_local() {
    if [[ -f "$XUI_DB_PATH" ]]; then
        x-ui stop >/dev/null 2>&1 || true
        sqlite3 "$XUI_DB_PATH" <<'EOSQL'
DELETE FROM settings WHERE key IN ('webCertFile','webKeyFile','listenIP');
INSERT INTO settings (key, value) VALUES
('webCertFile',''),
('webKeyFile',''),
('listenIP','127.0.0.1');
EOSQL
        command -v x-ui >/dev/null 2>&1 \
            && "$XUI_PANEL_DIR/x-ui" setting -listenIP "127.0.0.1" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------- Pre-seed apt packages to prevent upstream pip pollution
install_packages python3-pyasyncore python3-pyinotify whois

# ---------------------------------------------------------------- Install 3x-ui (only if x-ui command missing)
FIRST_INSTALL=0
if [[ ! -x "$XUI_PANEL_DIR/x-ui" ]]; then	
    FIRST_INSTALL=1
    msg_inf "Installing 3x-ui (latest)..."
    if [[ -f "$XUI_DB_PATH" ]] && sqlite3 "$XUI_DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null | grep -qE '.{4,}'; then
        XUI_INPUT=$'4y'
    else
        XUI_INPUT=$'
n4y'
    fi
    printf '%s' "$XUI_INPUT" \
        | bash <(wget -qO- "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh") \
        || printf '%s' "$XUI_INPUT" \
        | bash <(curl -fsSL "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh")
    service_enable x-ui
    msg_ok "3x-ui installed."
	# Clean up upstream pip pollution
    msg_inf "Cleaning up upstream pip pollution..."
    if command -v pip3 >/dev/null 2>&1; then
        pip3 uninstall -y pyasynchat pyasyncore >/dev/null 2>&1 || true
    fi
    # Remove pip itself if it was dragged in by the upstream script
    apt-get purge -y -qq python3-pip >/dev/null 2>&1 || true
    apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true
else
    msg_inf "3x-ui already installed — skipping reinstall (credentials preserved)."
fi

# Wait for the DB to appear (race condition fix)
wait_for_xui_db 5 || true

if [[ $FIRST_INSTALL -eq 1 ]]; then
    RNDSTR=$(gen_str 18)
    XUIUSER=$(gen_str 10)
    XUIPASS=$(gen_str 12)
    while true; do
        PORT=$((RANDOM % 30000 + 30000))
        nc -z 127.0.0.1 "$PORT" 2>/dev/null || break
    done
    if [[ -f "$XUI_DB_PATH" ]]; then
        update_xui_db "$PORT" "$(add_slashes "$RNDSTR")" "$XUIUSER" "$XUIPASS"
    else
        msg_war "x-ui DB unavailable — using CLI setter only."
        "$XUI_PANEL_DIR/x-ui" setting -username "$XUIUSER" -password "$XUIPASS" -port "$PORT" >/dev/null 2>&1 || true
        "$XUI_PANEL_DIR/x-ui" setting -webBasePath "$(add_slashes "$RNDSTR")" >/dev/null 2>&1 || true
    fi
fi

clear_xui_ssl_bind_local

if [[ $FIRST_INSTALL -eq 1 ]]; then
    msg_ok "3x-ui configured (localhost-only, no panel SSL)."
else
    msg_ok "3x-ui settings touched (panel SSL cleared, listenIP=127.0.0.1)."
fi

NOPATH=""
if [[ -f "$XUI_DB_PATH" ]]; then
    x-ui stop >/dev/null 2>&1 || true
    PORT=$(sqlite3 "$XUI_DB_PATH" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null || echo "${PORT:-2053}")
    RNDSTR=$(sqlite3 "$XUI_DB_PATH" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null || echo "${RNDSTR:-/}")
    RNDSTR=$(add_slashes "$RNDSTR")
    [[ "$RNDSTR" == "/" ]] && NOPATH="#"
    valid_port "${PORT:-0}" || PORT="2053"
    EXIST_USER=$(sqlite3 "$XUI_DB_PATH" "SELECT username FROM users ORDER BY id LIMIT 1;" 2>/dev/null || true)
else
    PORT="${PORT:-2053}"
    RNDSTR="${RNDSTR:-/}"
    NOPATH="#"
    XUIUSER="${XUIUSER:-admin}"
    XUIPASS="${XUIPASS:-admin}"
    EXIST_USER=""
fi

# ---------------------------------------------------------------- Phase-2 vhost: full SSL + TCP loopback for Xray, panel/sub/json
# Panel is always TCP loopback. Sub/JSON are always TCP loopback.
# The main Xray traffic path (/<port>/<path>) is also proxied over a
# TRADITIONAL LOCAL TCP PORT (settled design; Unix Domain Socket was reverted).
PANEL_PROXY="proxy_pass http://127.0.0.1:${PORT};"
SUB_PROXY='proxy_pass http://127.0.0.1:$fwdport/sub/$fwdpath$is_args$args;'
JSON_PROXY='proxy_pass http://127.0.0.1:$fwdport/json/$fwdpath$is_args$args;'

# Xray traffic → traditional local TCP port (GFW4Fun/x-ui-pro style)
# Always use proxy_pass here. grpc_pass does NOT work in front of xray.
#
# Why not grpc_pass: The xhttp docs recommend grpc_pass for stream-up mode, but
# that assumes xray handles TLS directly on a public TCP port (the docs'
# "default" architecture). In our setup nginx terminates TLS on public ports
# and forwards plain HTTP to xray, whose xhttp server speaks HTTP/1.1 + h2c,
# NOT gRPC. nginx's grpc_pass module expects gRPC responses with trailers
# (grpc-status) — xray never sends them, so nginx times out with
# "upstream timed out (110)". The Content-Type: application/grpc header that
# stream-up sends is just camouflage for middleboxes (CDNs, DPI); xray's xhttp
# server recognizes the protocol from the path pattern, not Content-Type.
# proxy_pass therefore works for ALL modes: packet-up, stream-up, stream-down.
#
# Why TCP loopback instead of a UDS (/dev/shm/port-XXXX.sock):
#   - Traditional local TCP ports are the battle-tested default of the
#     GFW4Fun/x-ui-pro.sh base this script derives from.
#   - No socket-file lifecycle hazards: /dev/shm sockets are deleted/recreated
#     out of band on every x-ui restart or cron cycle — nginx then logs
#     "connect() ... failed (2: No such file or directory)" and "upstream
#     prematurely closed connection" until xray re-binds. A loopback listener
#     is owned by xray itself and cannot be orphaned.
#   - No permission dance: UDS needed hand-tuned ',0666' modes in 3x-ui so
#     www-data could connect; TCP needs nothing.
#   - Performance difference on loopback is negligible for proxy workloads.
#
# See: /home/dev/mimo/xhttp-nginx-uds-analysis.md for full evidence and flowcharts.
XRAY_BLOCK='        proxy_pass http://127.0.0.1:$fwdport;'

TMP_VHOST2=$(mktemp)
# Escape HACK_REGEX safely for embedding inside nginx heredoc (no literal " to collide with)
HACK_REGEX_ESCAPED=$(printf '%s' "$HACK_REGEX" | sed -e 's/\\/\\\\/g' -e 's/\$/\\$/g')
cat > "$TMP_VHOST2" <<EOF
server {
    set \$hack 0;
    set \$safe 0;
    server_tokens off;
    server_name $MAIN_DOMAIN *.$MAIN_DOMAIN;
    listen 80;
    $IPV6_LISTEN_80
    listen 443 ssl;
    $IPV6_LISTEN_443
    http2 on;
    index index.html index.htm;
    root $FAKESITE_ROOT;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    if (\$host !~* ^(.+\\.)?$MAIN_DOMAIN\$ ) { return 444; }
    if (\$scheme ~* https)                 { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\\.)?$MAIN_DOMAIN\$ ) { set \$safe "\${safe}0"; }
    if (\$safe = 10) { return 444; }

    if (\$request_uri ~ "${HACK_REGEX_ESCAPED}") { set \$hack 1; }

    error_page 400 402 403 404 500 501 502 503 504 =200 /;
    proxy_intercept_errors on;

    # 3x-ui Admin Panel (TCP loopback)
    location $RNDSTR {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        $PANEL_PROXY
        break;
    }

    # Subscription (TCP loopback)
    location ~ ^/(?<fwdport>\\d+)/sub/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        $SUB_PROXY
        break;
    }

    # Subscription JSON (TCP loopback)
    location ~ ^/(?<fwdport>\\d+)/json/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        $JSON_PROXY
        break;
    }

    # Main Xray traffic — traditional local TCP port
    location ~ ^/(?<fwdport>\\d+)/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        $XRAY_BLOCK
        break;
    }

$NOPATH    location / { try_files \$uri \$uri/ =404; }
}
EOF

cp -f "$NGINX_VHOST_FILE" "${NGINX_VHOST_FILE}.phase1.bak" 2>/dev/null || true
cp -f "$TMP_VHOST2" "$NGINX_VHOST_FILE"
rm -f "$TMP_VHOST2"
ln -sf "$NGINX_VHOST_FILE" "$NGINX_VHOST_LINK"

if ! nginx -t -c "$NGINX_MAIN_CONF" >/dev/null 2>&1; then
    msg_err "Phase-2 nginx config invalid — reverting to phase-1"
    nginx -t -c "$NGINX_MAIN_CONF" || true
    if [[ -f "${NGINX_VHOST_FILE}.phase1.bak" ]]; then
        cp -f "${NGINX_VHOST_FILE}.phase1.bak" "$NGINX_VHOST_FILE"
        rm -f "${NGINX_VHOST_FILE}.phase1.bak"
        nginx_safe_reload || true
    fi
    msg_war "nginx is running on phase-1 (port 80) config. Fix the issue and re-run."
    exit 1
fi
rm -f "${NGINX_VHOST_FILE}.phase1.bak"
nginx_safe_reload || true

systemctl is-enabled x-ui 2>/dev/null || systemctl enable x-ui 2>/dev/null || true
x-ui start >/dev/null 2>&1 || true

# ---------------------------------------------------------------- Fake website (default install unless user said site already exists)
if [[ "$EXISTING_SITE" == "n" ]]; then
    msg_inf "Installing random fake website to $FAKESITE_ROOT ..."
    ensure_dir "$FAKESITE_ROOT"
    ensure_dir "$(dirname "$FAKESITE_CACHE")"

    if [[ ! -d "$FAKESITE_CACHE" ]]; then
        msg_inf "Downloading fake HTML templates (first time only)..."
        TMP_ZIP=$(mktemp -d)
        if wget -q https://github.com/GFW4Fun/randomfakehtml/archive/refs/heads/master.zip -O "$TMP_ZIP/master.zip"; then
            (cd "$TMP_ZIP" && unzip -q master.zip)
            mv "$TMP_ZIP/randomfakehtml-master" "$FAKESITE_CACHE"
            msg_ok "Templates cached."
        else
            msg_war "Could not download fake templates — skipping."
        fi
        rm -rf "$TMP_ZIP"
    else
        msg_inf "Using cached fake HTML templates."
    fi

    if [[ -d "$FAKESITE_CACHE" ]]; then
        # Collect already-used template names from other domains
        USED_TEMPLATES=()
        for f in /etc/nginx/sites-available/${NGINX_VHOST_PREFIX}-*.conf; do
            [[ -f "$f" ]] || continue
            local_basename=$(basename "$f" .conf)
            local_domain="${local_basename#${NGINX_VHOST_PREFIX}-}"
            [[ "$local_domain" == "$DOMAIN" ]] && continue
            local_meta="${FAKESITE_PREFIX}-${local_domain}/.xinstaller-template"
            if [[ -f "$local_meta" ]]; then
                USED_TEMPLATES+=("$(cat "$local_meta")")
            fi
        done

        (
            cd "$FAKESITE_CACHE" || exit 1
            rm -rf assets .gitattributes README.md _config.yml 2>/dev/null || true
            AllTemplates=($(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true))

            # Filter out already-used templates
            AvailableTemplates=()
            for t in "${AllTemplates[@]}"; do
                already_used=false
                for u in "${USED_TEMPLATES[@]}"; do
                    [[ "$t" == "$u" ]] && already_used=true && break
                done
                $already_used || AvailableTemplates+=("$t")
            done

            if ((${#AvailableTemplates[@]} == 0)); then
                msg_war "All templates already in use — picking randomly anyway."
                AvailableTemplates=("${AllTemplates[@]}")
            fi

            RandomHTML="${AvailableTemplates[$((RANDOM % ${#AvailableTemplates[@]}))]}"
            if [[ -n "$RandomHTML" && -d "$RandomHTML" ]]; then
                msg_inf "Selected random template: $RandomHTML"
                find "$FAKESITE_ROOT" -mindepth 1 -delete 2>/dev/null || true
                cp -a "$RandomHTML"/. "$FAKESITE_ROOT"/
                printf '%s\n' "$RandomHTML" > "$FAKESITE_ROOT/.xinstaller-template"
                msg_ok "Fake website installed at $FAKESITE_ROOT"
            else
                msg_war "No template subdirectory found in cache."
            fi
        )
    fi
else
    # Existing site — ensure at least a minimal placeholder exists if dir is empty
    if [[ ! -f "$FAKESITE_ROOT/index.html" ]] && [[ -z "$(ls -A "$FAKESITE_ROOT" 2>/dev/null)" ]]; then
        cat > "$FAKESITE_ROOT/index.html" <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>Server is online.</p></body></html>
EOF
    fi
    msg_inf "Existing site detected — fake website installation skipped."
    msg_inf "Fallback root remains: $FAKESITE_ROOT"
fi

# ---------------------------------------------------------------- Maintenance scripts
ensure_dir "$MAINT_SCRIPT_DIR"

cat > "$NGINX_MAINT_SCRIPT" <<'EOF'
#!/bin/bash
set -u
LOG=/var/log/xinstaller-nginx-maint.log
{
    echo "[$(date -Iseconds)] start"
    if nginx -t -c /etc/nginx/nginx.conf >/dev/null 2>&1; then
        systemctl reload nginx && echo "reload ok" || { systemctl restart nginx && echo "restart ok" || echo "restart FAILED"; }
    else
        echo "config invalid — not reloading"
        nginx -t -c /etc/nginx/nginx.conf 2>&1 | head -20
    fi
} >> "$LOG" 2>&1
EOF
chmod 755 "$NGINX_MAINT_SCRIPT"

cat > "$RENEW_HOOK_SCRIPT" <<'EOF'
#!/bin/bash
set -u
LOG=/var/log/xinstaller-certbot-renew.log
{
    echo "[$(date -Iseconds)] post-renew"
    if nginx -t -c /etc/nginx/nginx.conf >/dev/null 2>&1; then
        systemctl reload nginx && echo "reload ok" || echo "reload FAILED"
    else
        echo "config invalid after renewal — not reloading"
    fi
} >> "$LOG" 2>&1
EOF
chmod 755 "$RENEW_HOOK_SCRIPT"

cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -u
LOG=/var/log/xinstaller-system-update.log
{
    echo "[$(date -Iseconds)] start update"
    apt-get update -qq && apt-get upgrade -y -qq
    echo "done"
} >> "$LOG" 2>&1
EOF
chmod 755 "$UPDATE_SCRIPT"

# ---------------------------------------------------------------- Cron jobs (no daily reboot — not this script's business)
cat > "$CRON_FILE" <<EOF
# xinstaller managed cron — DO NOT EDIT (managed by xinstaller.sh v${XINSTALLER_VERSION})
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Daily x-ui restart
0 0 * * * root /usr/bin/x-ui restart >/dev/null 2>&1
# Daily nginx validation + reload
0 1 * * * root $NGINX_MAINT_SCRIPT
# DAILY certbot renewal with hook (tolerant of transient failures)
0 3 * * * root /usr/bin/certbot renew --non-interactive --deploy-hook $RENEW_HOOK_SCRIPT >> /var/log/xinstaller-certbot-renew.log 2>&1
# Daily system update (10:30)
30 10 * * * root $UPDATE_SCRIPT
EOF
chmod 644 "$CRON_FILE"
service_enable cron || true
msg_ok "Cron installed to $CRON_FILE (user crontab untouched, no daily reboot)."

# ---------------------------------------------------------------- Final info
if systemctl is-active --quiet x-ui 2>/dev/null || command -v x-ui >/dev/null 2>&1; then
    echo
    hrline
    msg_inf "INSTALLATION COMPLETE — SCROLL UP TO REVIEW LOGS"
    hrline
    printf '0
' | x-ui 2>/dev/null | grep --color=never -i ':' | awk '{print "\033[1;37;40m" $0 "\033[0m"}' || true
    hrline
    nginx -T -c "$NGINX_MAIN_CONF" 2>/dev/null | grep -i "configuration file ${NGINX_VHOST_FILE}" \
        | awk '{print "\033[1;32;40m" $0 "\033[0m"}' || true
    hrline
    certbot certificates 2>/dev/null | grep -iE 'Path:|Domains:|Expiry Date:' \
        | awk '{print "\033[1;37;40m" $0 "\033[0m"}' || true
    hrline
    IPInfo=$(curl -fsSLs "https://ipapi.co/json" || curl -fsSLs "https://ipinfo.io/json" || echo "{}")
    OS_PRETTY=$(grep -E '^(NAME|VERSION)=' /etc/*release 2>/dev/null | awk -F= '{printf $2 " "}' | xargs || true)
    msg "ID: $(cksum /etc/machine-id | awk '{print $1 % 65536}') | IP: ${IP4:-n/a} | OS: ${OS_PRETTY}"
    msg "Hostname: $(uname -n) | $(echo "${IPInfo}" | jq -r '.org, .country' 2>/dev/null | paste -sd' | ' || true)"
    printf "\033[1;37;40m CPU: %s/%s Core | RAM: %s | SSD: %s Gi\033[0m
" \
        "$(arch)" "$(nproc)" "$(free -h | awk '/^Mem:/{print $2}')" "$(df / | awk 'NR==2 {print int($2/1024/1024)}')"
    hrline
    msg_inf "Configuration:"
    msg "  SSL Method   : $SSL_METHOD"
    msg "  Socket Mode  : tcp (Xray on local TCP port; panel/sub/json also TCP loopback)"
    msg "  Fake Website : $( [[ "$EXISTING_SITE" == "n" ]] && echo "installed at $FAKESITE_ROOT" || echo "skipped (existing site)" )"
    msg "  Cert name    : $CERT_NAME"
    msg "  Cert dir     : $CERT_DIR"

    msg_war ""
    msg_war "  ⚠  TCP TRANSPORT ACTIVE — Xray Inbound Configuration Required!"
    msg_war "     In 3x-ui panel, for EACH Xray inbound:"
    msg_war "       Listen : 127.0.0.1"
    msg_war "       Port   : <PORT>  (must equal the <port> in the public URL /<port>/<path>)"
    msg_war ""
    msg_war "     • Example: client connects to https://domain/29117/zigen"
    msg_war "       → that inbound must listen on 127.0.0.1:29117."
    msg_war "     • Admin panel + /sub/ + /json/ subscription paths stay on their own ports."

    hrline
    msg_err "3x-ui Admin Panel (via nginx reverse proxy — recommended):"
    msg_inf "  https://${DOMAIN}${RNDSTR}"
    if [[ $FIRST_INSTALL -eq 1 ]]; then
        msg "  Username: $XUIUSER"
        msg "  Password: $XUIPASS"
        msg_war "  ⚠  SAVE THESE — password cannot be read back after installation!"
    else
        if [[ -n "${EXIST_USER:-}" ]]; then
            msg "  Username: $EXIST_USER"
        else
            msg_war "  Username: (not readable from database)"
        fi
        msg_war "  Password: (stored hashed — not recoverable)"
        msg "  To reset:  x-ui setting -username NEW_USER -password NEW_PASS"
    fi
    hrline
    msg_war "3x-ui is bound to 127.0.0.1 only — direct public IP access is BLOCKED."
    msg_war "To access directly (advanced): ssh -L 2222:127.0.0.1:${PORT} root@${IP4:-<your-ip>}"
    msg_war "then open http://localhost:2222${RNDSTR} on your local machine."
    hrline
    msg_ok "Website: https://${DOMAIN}/"
    hrline
    msg_war "SAVE THIS SCREEN! Installed by xinstaller v${XINSTALLER_VERSION}"
else
    nginx -t -c "$NGINX_MAIN_CONF" || true
    printf '0
' | x-ui 2>/dev/null | grep --color=never -i ':' || true
    msg_err "xinstaller: installation error — check logs above."
    exit 1
fi

