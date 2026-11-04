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
  --repair               repair an incomplete or broken installation without regenerating secrets
  --force-secrets        with --repair: allow regenerating TLS key and certificate if missing or mismatched
  --non-interactive      use flags and defaults without questions
  --no-service --root DIR  testing only: write files under DIR, no systemd, user, firewall or download
  --binary FILE          use this Hysteria2 binary instead of downloading it (the sha256 is still checked,
                         except with --no-service)
  -h, --help             show this help
EOF
}

port=443 sni=www.bing.com first_client=main-user create_client=1 endpoint='' obfs=true interactive=1 no_service=0 binary='' repair=0 force_secrets=0
while (( $# )); do
    case $1 in
        --port) port=${2:?--port needs a value}; shift 2 ;;
        --sni) sni=${2:?--sni needs a value}; shift 2 ;;
        --first-client) first_client=${2:?--first-client needs a value}; shift 2 ;;
        --no-first-client) create_client=0; shift ;;
        --endpoint) endpoint=${2:?--endpoint needs a value}; shift 2 ;;
        --no-obfs) obfs=false; shift ;;
        --repair) repair=1; shift ;;
        --force-secrets) force_secrets=1; shift ;;
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
if (( force_secrets && ! repair )); then printf 'error: --force-secrets requires --repair\n' >&2; exit 2; fi

# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
hvk_require_root
hvk_lock

if [[ $no_service == 0 ]]; then
    [[ -f /etc/os-release ]] || hvk_die 'cannot detect the operating system'
    # shellcheck disable=SC1091
    os=$(. /etc/os-release && printf '%s:%s' "$ID" "$VERSION_ID")
    case $os in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) hvk_die "unsupported operating system: $os (Debian 12/13 or Ubuntu 22.04/24.04)" ;;
    esac
    command -v systemctl > /dev/null || hvk_die 'systemd is required'
fi

if [[ -f $HVK_STATE ]]; then
    if ! jq empty "$HVK_STATE" > /dev/null 2>&1; then
        hvk_die "state file contains invalid JSON: $HVK_STATE"
    fi
    if (( repair )); then
        hvk_validate_state
    fi
    status=$(jq -r '.status // "ready"' "$HVK_STATE")
    if (( ! repair )); then
        if [[ $status == "ready" ]]; then
            hvk_die "already installed ($HVK_STATE exists); use update.sh, or uninstall.sh first"
        else
            hvk_die "incomplete installation detected ($HVK_STATE has status '$status'); run 'install.sh --repair' to complete it, or 'uninstall.sh' to remove it first"
        fi
    fi
elif (( repair )); then
    hvk_die "cannot repair: $HVK_STATE does not exist; run install.sh without --repair"
fi

if (( repair )); then
    # In repair mode, preserve existing state values
    port=$(jq -r '.port // 443' "$HVK_STATE")
    sni=$(jq -r '.sni // "www.bing.com"' "$HVK_STATE")
    endpoint=$(jq -r '.endpoint // ""' "$HVK_STATE")
    obfs=$(jq -r '.obfs.enabled // true' "$HVK_STATE")
    create_client=0
else
    if (( interactive )) && [[ -t 0 ]]; then
        read -r -p "UDP port [$port]: " answer || true; port=${answer:-$port}
        read -r -p "SNI / masquerade site [$sni]: " answer || true; sni=${answer:-$sni}
    fi
fi

hvk_valid_port "$port" || hvk_die "invalid port: $port"
hvk_valid_sni "$sni" || hvk_die "invalid SNI: $sni"
if [[ -n $endpoint ]]; then
    hvk_valid_endpoint "$endpoint" || hvk_die "invalid endpoint: $endpoint (must be an IPv4 address or DNS domain name)"
fi
if (( create_client )); then
    hvk_valid_name "$first_client" || hvk_die "invalid client name: $first_client (letters, digits, _ . @ -, up to 32, start with a letter or digit)"
fi
if [[ $no_service == 0 ]] && (( ! repair )) && hvk_udp_port_busy "$port"; then
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
need_core=1
if [[ -f $HVK_CORE_BIN ]]; then
    if (( repair )) && "$HVK_CORE_BIN" version > /dev/null 2>&1; then
        need_core=0
    fi
fi

if (( need_core )); then
    if [[ $no_service == 1 ]]; then
        if [[ -n $binary ]]; then install -m 755 "$binary" "$HVK_CORE_BIN"; else printf '#!/bin/sh\necho "hysteria %s"\nexit 0\n' "$HVK_CORE_VERSION" > "$HVK_CORE_BIN"; chmod 755 "$HVK_CORE_BIN"; fi
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
        rm -rf "$tmp"
        trap - EXIT
    fi
fi

# --- identity and certificate ---
user_created=true
if [[ $no_service == 0 ]]; then
    if id "$HVK_USER" > /dev/null 2>&1; then
        if (( repair )); then
            user_created=$(jq -r '.created_resources.user // false' "$HVK_STATE" 2>/dev/null || echo false)
        else
            user_created=false
        fi
    else
        useradd --system --no-create-home --shell /usr/sbin/nologin "$HVK_USER"
        user_created=true
    fi
    chown "root:$HVK_USER" "$HVK_ETC"
fi

cert_ok=0
if [[ -s $HVK_KEY && -s $HVK_CERT ]]; then
    cert_pub=$(openssl x509 -in "$HVK_CERT" -pubkey -noout 2>/dev/null || true)
    key_pub=$(openssl pkey -in "$HVK_KEY" -pubout 2>/dev/null || true)
    if [[ -n $cert_pub && -n $key_pub && $cert_pub == "$key_pub" ]]; then
        cert_ok=1
    fi
fi

need_cert=0
if (( ! repair )); then
    need_cert=1
elif (( ! cert_ok )); then
    if (( ! force_secrets )); then
        hvk_die "certificate and key are missing or do not match; existing client profiles will stop working if regenerated. Re-run with --repair --force-secrets to regenerate anyway"
    fi
    if (( interactive )) && [[ -t 0 ]]; then
        read -r -p "Regenerating certificate will invalidate all existing client profiles. Continue? [y/N] " answer || true
        [[ $answer == [yY]* ]] || { printf 'aborted\n'; exit 1; }
    fi
    need_cert=1
fi

old_pin=""
if (( repair )); then
    old_pin=$(jq -r '.pin // ""' "$HVK_STATE" 2>/dev/null || true)
fi

if (( need_cert )); then
    old_umask=$(umask)
    umask 077
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -subj "/CN=$sni" -keyout "$HVK_KEY" -out "$HVK_CERT" 2> /dev/null
    umask "$old_umask"
fi
chmod 640 "$HVK_KEY" "$HVK_CERT"
[[ $no_service == 1 ]] || chown "root:$HVK_USER" "$HVK_KEY" "$HVK_CERT"
pin=$(hvk_pin "$HVK_CERT")

if (( repair )) && [[ -n $old_pin && $old_pin != "$pin" ]]; then
    hvk_log "WARNING: certificate pin changed: old=$old_pin new=$pin. All issued client profiles (URIs, QR codes, client.yaml) must be re-issued!"
fi

if [[ -z $endpoint ]]; then endpoint=$(hvk_detect_endpoint || true); fi
if [[ -z $endpoint ]]; then
    local_ip=""
    if command -v ip > /dev/null 2>&1; then
        local_ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    fi
    if [[ -n $local_ip ]] && hvk_is_private_ip "$local_ip"; then
        hvk_log "warning: detected local IP $local_ip is in a private network (behind NAT); clients outside this LAN cannot reach it directly"
    fi
    endpoint=YOUR_SERVER_IP
    hvk_log 'could not confirm public address; set it with --endpoint (state.json "endpoint")'
fi

# --- state ---
fw_created=false
firewall="none"
if [[ $no_service == 0 ]] && command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q '^Status: active'; then
    firewall="ufw"
    if ufw status 2> /dev/null | grep -q "^$port/udp"; then
        if (( repair )); then
            fw_created=$(jq -r '.created_resources.firewall_rule // false' "$HVK_STATE" 2>/dev/null || echo false)
        else
            fw_created=false
        fi
    else
        ufw allow "$port/udp" comment hysteria-vps-kit > /dev/null
        hvk_log "ufw: opened $port/udp"
        fw_created=true
    fi
fi

if (( repair )); then
    obfs_password=$(jq -r '.obfs.password // ""' "$HVK_STATE")
    hvk_state_update '
        .status = "installing" |
        .core = $core |
        .pin = $pin |
        .created_resources = {user: $user_created, firewall_rule: $fw_created}
    ' --arg core "$HVK_CORE_VERSION" --arg pin "$pin" \
      --argjson user_created "$user_created" --argjson fw_created "$fw_created"
else
    obfs_password=''
    [[ $obfs == false ]] || obfs_password=$(hvk_rand 28)
    old_umask=$(umask)
    umask 077
    jq -n --arg version "$(hvk_project_version "$project")" --arg core "$HVK_CORE_VERSION" --argjson port "$port" --arg sni "$sni" \
        --arg endpoint "$endpoint" --arg pin "$pin" --argjson obfs_enabled "$obfs" --arg obfs_password "$obfs_password" \
        --arg firewall "$firewall" --argjson user_created "$user_created" --argjson fw_created "$fw_created" \
        '{version: $version, core: $core, status: "installing", port: $port, sni: $sni, endpoint: $endpoint, pin: $pin,
          obfs: {enabled: $obfs_enabled, password: $obfs_password}, firewall: $firewall,
          created_resources: {user: $user_created, firewall_rule: $fw_created}, clients: {}}' > "$HVK_STATE"
    umask "$old_umask"
    chmod 600 "$HVK_STATE"
    if (( create_client )); then
        hvk_state_update '.clients[$n] = $p' --arg n "$first_client" --arg p "$(hvk_rand 28)"
    fi
fi
hvk_render_config
hvk_ensure_sysctl || true

# --- command link, unit, service ---
chmod +x "$project/hy2-client" "$project/update.sh" "$project/uninstall.sh"
ln -sfn "$project/hy2-client" "$HVK_LINK"
hvk_install_unit
if [[ $no_service == 0 ]]; then
    systemctl daemon-reload
    systemctl enable "$HVK_SERVICE" > /dev/null 2>&1 || true
    systemctl restart "$HVK_SERVICE"
    sleep 2
    systemctl is-active --quiet "$HVK_SERVICE" || hvk_die "service did not start: journalctl -u $HVK_SERVICE -n 30"
    hvk_udp_port_busy "$port" || hvk_log "warning: nothing is listening on $port/udp yet"
fi
hvk_state_update '.status = "ready"'

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
