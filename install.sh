#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filters are meant to stay in single quotes
set -euo pipefail
# Started through `curl ... | bash` (no kit checkout beside this script): fetch the kit into
# /opt/hysteria-vps-kit-src (or fast-forward the clone there) and continue from that copy.
if [[ ! -f ${BASH_SOURCE[0]:-} || ! -f $(dirname -- "${BASH_SOURCE[0]:-/}")/lib/common.sh ]]; then
    src=${HVK_SRC:-/opt/hysteria-vps-kit-src}
    cd /
    [[ -n ${HVK_SRC:-} || $EUID == 0 ]] || { printf 'error: run as root\n' >&2; exit 1; }
    if ! command -v git > /dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        printf '[Bootstrap] Installing git and CA certificates\n' >&2
        if ! apt-get update < /dev/null >&2 || ! DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove install git ca-certificates < /dev/null >&2; then
            printf 'error: bootstrap dependency installation failed\n' >&2; exit 1
        fi
    fi
    if [[ -d $src/.git ]]; then
        git -C "$src" pull --ff-only -q || { printf 'error: cannot fast-forward %s (local changes?)\n' "$src" >&2; exit 1; }
    elif [[ -e $src ]]; then
        printf 'error: %s exists but is not a clone of the kit; move it away and run this again\n' "$src" >&2; exit 1
    else
        git clone -q "${HVK_REPO:-https://github.com/thejohnd0e/hysteria-vps-kit.git}" "$src"
    fi
    if [[ -t 0 ]]; then exec bash "$src/install.sh" "$@"; fi
    if { : < /dev/tty; } 2> /dev/null; then exec bash "$src/install.sh" "$@" < /dev/tty; fi
    exec bash "$src/install.sh" "$@" < /dev/null
fi
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
    cat << 'EOF'
Usage: install.sh [options]

  --port PORT            UDP listen port (default 443)
  --sni DNS              TLS name and masquerade site (default www.bing.com)
  --first-client NAME    first identity (default main-user)
  --no-first-client      do not create an identity
  --endpoint IPV4/HOST   address written into client URIs (default: detected)
  --no-obfs              disable Salamander obfuscation (not recommended)
  --non-interactive      use flags and defaults without questions
  --no-service --root DIR  testing only: write files under DIR, no systemd, user, firewall or download
  --binary FILE          use this Hysteria2 binary instead of downloading it (the sha256 is still checked,
                         except with --no-service)
  -h, --help             show this help
EOF
}

port=443 sni=www.bing.com first_client=main-user create_client=1 endpoint='' obfs=true interactive=1 no_service=0 binary=''
while (( $# )); do
    case $1 in
        --port) port=${2:?--port needs a value}; shift 2 ;;
        --sni) sni=${2:?--sni needs a value}; shift 2 ;;
        --first-client) first_client=${2:?--first-client needs a value}; shift 2 ;;
        --no-first-client) create_client=0; shift ;;
        --endpoint) endpoint=${2:?--endpoint needs a value}; shift 2 ;;
        --no-obfs) obfs=false; shift ;;
        --non-interactive) interactive=0; shift ;;
        --no-service) no_service=1; shift ;;
        --root) export HVK_ROOT=${2:?--root needs a value}; shift 2 ;;
        --binary) binary=${2:?--binary needs a value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; printf 'error: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
if [[ -n ${HVK_ROOT:-} && $no_service == 0 ]]; then printf 'error: --root requires --no-service\n' >&2; exit 2; fi
if [[ $no_service == 1 && -z ${HVK_ROOT:-} ]]; then printf 'error: --no-service requires --root DIR\n' >&2; exit 2; fi

# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
hvk_require_root

if [[ $no_service == 0 ]]; then
    [[ -f /etc/os-release ]] || hvk_die 'cannot detect the operating system'
    # shellcheck disable=SC1091
    os=$(. /etc/os-release && printf '%s:%s' "$ID" "$VERSION_ID")
    case $os in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) hvk_die "unsupported operating system: $os (Debian 12/13 or Ubuntu 22.04/24.04)" ;;
    esac
    command -v systemctl > /dev/null || hvk_die 'systemd is required'
    if [[ -f $HVK_STATE ]]; then hvk_die "already installed ($HVK_STATE exists); use update.sh, or uninstall.sh first"; fi
fi

if (( interactive )) && [[ -t 0 ]]; then
    read -r -p "UDP port [$port]: " answer || true; port=${answer:-$port}
    read -r -p "SNI / masquerade site [$sni]: " answer || true; sni=${answer:-$sni}
fi
hvk_valid_port "$port" || hvk_die "invalid port: $port"
[[ $sni =~ ^[A-Za-z0-9.-]+$ ]] || hvk_die "invalid SNI: $sni"
if (( create_client )); then hvk_valid_name "$first_client" || hvk_die "invalid client name: $first_client (letters, digits, _ . @ -, up to 32, start with a letter or digit)"; fi
if [[ $no_service == 0 ]] && hvk_udp_port_busy "$port"; then
    hvk_die "UDP port $port is already in use (AmneziaWG often takes 443/udp); choose another with --port"
fi

arch=$(hvk_arch)
if [[ $no_service == 0 ]]; then
    missing=()
    for tool in curl jq openssl; do command -v "$tool" > /dev/null || missing+=("$tool"); done
    command -v qrencode > /dev/null || missing+=(qrencode)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        hvk_log "Installing missing packages: ${missing[*]}"
        if ! apt-get update -qq < /dev/null || ! DEBIAN_FRONTEND=noninteractive apt-get -y -qq --no-remove install "${missing[@]}" < /dev/null; then
            hvk_die 'dependency installation failed'
        fi
    fi
else
    for tool in jq openssl; do command -v "$tool" > /dev/null || hvk_die "$tool is required"; done
fi

install -d -m 755 "$HVK_OPT" "$HVK_ROOT/usr/local/bin"
install -d -m 750 "$HVK_ETC"

# --- core binary ---
if [[ $no_service == 1 ]]; then
    if [[ -n $binary ]]; then install -m 755 "$binary" "$HVK_CORE_BIN"; else printf '#!/bin/sh\nexit 0\n' > "$HVK_CORE_BIN"; chmod 755 "$HVK_CORE_BIN"; fi
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    if [[ -n $binary ]]; then
        cp "$binary" "$tmp/hysteria"
    else
        hvk_log "Downloading Hysteria2 v$HVK_CORE_VERSION ($arch)"
        curl -fsSL -m 180 -o "$tmp/hysteria" "$HVK_CORE_URL_BASE/hysteria-linux-$arch" || hvk_die 'download failed'
    fi
    actual=$(sha256sum "$tmp/hysteria" | cut -d' ' -f1)
    [[ $actual == "$(hvk_expected_sha "$arch")" ]] || hvk_die "sha256 mismatch for the core binary: $actual"
    install -m 755 "$tmp/hysteria" "$HVK_CORE_BIN"
    "$HVK_CORE_BIN" version > /dev/null 2>&1 || hvk_die 'the core binary does not run on this host'
fi

# --- identity and certificate ---
if [[ $no_service == 0 ]]; then
    id "$HVK_USER" > /dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$HVK_USER"
    chown "root:$HVK_USER" "$HVK_ETC"
fi
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -subj "/CN=$sni" -keyout "$HVK_KEY" -out "$HVK_CERT" 2> /dev/null
chmod 640 "$HVK_KEY" "$HVK_CERT"
[[ $no_service == 1 ]] || chown "root:$HVK_USER" "$HVK_KEY" "$HVK_CERT"
pin=$(hvk_pin "$HVK_CERT")

if [[ -z $endpoint ]]; then endpoint=$(hvk_detect_endpoint); fi
[[ -n $endpoint ]] || { endpoint=YOUR_SERVER_IP; hvk_log 'could not detect the public address; set it with --endpoint (state.json "endpoint")'; }

# --- state ---
obfs_password=''
[[ $obfs == false ]] || obfs_password=$(hvk_rand 28)
jq -n --arg version "$(hvk_project_version "$project")" --arg core "$HVK_CORE_VERSION" --argjson port "$port" --arg sni "$sni" \
    --arg endpoint "$endpoint" --arg pin "$pin" --argjson obfs_enabled "$obfs" --arg obfs_password "$obfs_password" \
    '{version: $version, core: $core, port: $port, sni: $sni, endpoint: $endpoint, pin: $pin,
      obfs: {enabled: $obfs_enabled, password: $obfs_password}, firewall: "none", clients: {}}' > "$HVK_STATE"
chmod 600 "$HVK_STATE"
if (( create_client )); then
    hvk_state_update '.clients[$n] = $p' --arg n "$first_client" --arg p "$(hvk_rand 28)"
fi
hvk_render_config

# --- command link, unit, firewall ---
chmod +x "$project/hy2-client" "$project/update.sh" "$project/uninstall.sh"
ln -sfn "$project/hy2-client" "$HVK_LINK"
if [[ $no_service == 0 ]]; then
    cat > "$HVK_UNIT" << EOF
[Unit]
Description=Hysteria2 server (hysteria-vps-kit)
After=network-online.target
Wants=network-online.target

[Service]
User=$HVK_USER
ExecStart=$HVK_CORE_BIN server -c $HVK_CONFIG
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    if command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q '^Status: active'; then
        ufw allow "$port/udp" comment hysteria-vps-kit > /dev/null
        hvk_state_update '.firewall = "ufw"'
        hvk_log "ufw: opened $port/udp"
    fi
    systemctl daemon-reload
    systemctl enable --now "$HVK_SERVICE" > /dev/null 2>&1
    sleep 2
    systemctl is-active --quiet "$HVK_SERVICE" || hvk_die "service did not start: journalctl -u $HVK_SERVICE -n 30"
    hvk_udp_port_busy "$port" || hvk_log "warning: nothing is listening on $port/udp yet"
fi

hvk_log "Hysteria2 v$HVK_CORE_VERSION installed: UDP $port, SNI $sni, endpoint $endpoint"
[[ $no_service == 1 ]] || hvk_log "Check the provider firewall too: UDP $port must be reachable."
if (( create_client )); then
    printf 'Client %s\nURI:\n' "$first_client"
    hvk_client_uri "$first_client"
    if command -v qrencode > /dev/null && [[ $no_service == 0 ]]; then
        printf '\nQR code:\n'
        hvk_client_uri "$first_client" | qrencode -t ANSIUTF8
    fi
fi
