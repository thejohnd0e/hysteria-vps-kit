#!/usr/bin/env bash
# shellcheck disable=SC2034  # the paths below are used by the scripts that source this file
# Shared helpers for hysteria-vps-kit. Sourced by install.sh, update.sh, uninstall.sh and hy2-client.
# HVK_ROOT is a path prefix used only by the sandbox tests (--no-service --root DIR).

HVK_CORE_VERSION=2.13.0
HVK_CORE_URL_BASE=https://github.com/HyNetworks/hysteria/releases/download/app/v${HVK_CORE_VERSION}
HVK_SHA256_AMD64=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
HVK_SHA256_ARM64=a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7

HVK_ROOT=${HVK_ROOT:-}
HVK_ETC=$HVK_ROOT/etc/hysteria-vps-kit
HVK_STATE=$HVK_ETC/state.json
HVK_CONFIG=$HVK_ETC/config.yaml
HVK_CERT=$HVK_ETC/server.crt
HVK_KEY=$HVK_ETC/server.key
HVK_OPT=$HVK_ROOT/opt/hysteria-vps-kit
HVK_CORE_BIN=$HVK_OPT/hysteria
HVK_LINK=$HVK_ROOT/usr/local/bin/hy2-client
HVK_UNIT=$HVK_ROOT/etc/systemd/system/hysteria-vps-kit.service
HVK_SERVICE=hysteria-vps-kit
HVK_USER=hysteria-vps-kit

hvk_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
hvk_log() { printf '[hysteria-vps-kit] %s\n' "$*"; }

hvk_project_version() { tr -d '[:space:]' < "$1/VERSION"; }

hvk_require_root() {
    [[ -n $HVK_ROOT || $EUID == 0 ]] || hvk_die 'run as root'
}

hvk_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) hvk_die "unsupported architecture: $(uname -m)" ;;
    esac
}

hvk_expected_sha() {
    case $1 in amd64) printf '%s' "$HVK_SHA256_AMD64" ;; arm64) printf '%s' "$HVK_SHA256_ARM64" ;; esac
}

hvk_rand() { # hvk_rand LENGTH -> alphanumeric
    local out=''
    while (( ${#out} < $1 )); do
        out+=$(openssl rand -base64 48 | tr -d '=+/\n')
    done
    printf '%s' "${out:0:$1}"
}

hvk_valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,31}$ ]]; }

hvk_valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

hvk_state_get() { jq -r "$1" "$HVK_STATE"; }

hvk_state_update() { # hvk_state_update JQ_FILTER [jq args...]
    local filter=$1 tmp
    shift
    tmp=$(mktemp "$HVK_ETC/.state.XXXXXX")
    if jq "$@" "$filter" "$HVK_STATE" > "$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$HVK_STATE"
    else
        rm -f "$tmp"
        hvk_die 'could not update state.json'
    fi
}

hvk_require_state() { [[ -f $HVK_STATE ]] || hvk_die "not installed: $HVK_STATE is missing"; }

hvk_pin() { # SHA-256 of the certificate, lower-case hex, no colons
    openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

hvk_render_config() {
    local port obfs_enabled obfs_password sni
    port=$(hvk_state_get .port)
    sni=$(hvk_state_get .sni)
    obfs_enabled=$(hvk_state_get .obfs.enabled)
    obfs_password=$(hvk_state_get .obfs.password)
    {
        printf 'listen: :%s\n' "$port"
        if [[ $obfs_enabled == true ]]; then
            printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$obfs_password"
        fi
        printf 'tls:\n  cert: %s\n  key: %s\n' "${HVK_CERT#"$HVK_ROOT"}" "${HVK_KEY#"$HVK_ROOT"}"
        printf 'auth:\n  type: userpass\n  userpass:\n'
        jq -r '.clients | to_entries[] | "    \(.key | @json): \(.value | @json)"' "$HVK_STATE"
        printf 'masquerade:\n  type: proxy\n  proxy:\n    url: https://%s/\n    rewriteHost: true\n' "$sni"
    } > "$HVK_CONFIG.new"
    chmod 640 "$HVK_CONFIG.new"
    mv -f "$HVK_CONFIG.new" "$HVK_CONFIG"
    if [[ -z $HVK_ROOT ]]; then chown "root:$HVK_USER" "$HVK_CONFIG"; fi
}

hvk_restart_service() {
    [[ -z $HVK_ROOT ]] || return 0
    systemctl restart "$HVK_SERVICE"
    sleep 1
    systemctl is-active --quiet "$HVK_SERVICE" || hvk_die "service did not start: journalctl -u $HVK_SERVICE -n 30"
}

hvk_client_uri() { # hvk_client_uri NAME
    local name=$1 password endpoint port sni pin query
    password=$(jq -r --arg n "$name" '.clients[$n] // empty' "$HVK_STATE")
    [[ -n $password ]] || hvk_die "no such client: $name"
    endpoint=$(hvk_state_get .endpoint)
    port=$(hvk_state_get .port)
    sni=$(hvk_state_get .sni)
    pin=$(hvk_state_get .pin)
    query="sni=$sni&insecure=1&pinSHA256=$pin"
    if [[ $(hvk_state_get .obfs.enabled) == true ]]; then
        query+="&obfs=salamander&obfs-password=$(hvk_state_get .obfs.password)"
    fi
    printf 'hysteria2://%s:%s@%s:%s/?%s#%s\n' "${name//@/%40}" "$password" "$endpoint" "$port" "$query" "${name//@/%40}"
}

hvk_client_yaml() { # hvk_client_yaml NAME HTTP_LISTEN SOCKS_LISTEN
    local name=$1 password
    password=$(jq -r --arg n "$name" '.clients[$n] // empty' "$HVK_STATE")
    [[ -n $password ]] || hvk_die "no such client: $name"
    printf 'server: %s:%s\n' "$(hvk_state_get .endpoint)" "$(hvk_state_get .port)"
    printf 'auth: %s:%s\n' "$name" "$password"
    if [[ $(hvk_state_get .obfs.enabled) == true ]]; then
        printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(hvk_state_get .obfs.password)"
    fi
    printf 'tls:\n  sni: %s\n  insecure: true\n  pinSHA256: %s\n' "$(hvk_state_get .sni)" "$(hvk_state_get .pin)"
    printf 'http:\n  listen: %s\nsocks5:\n  listen: %s\n' "$2" "$3"
}

hvk_detect_endpoint() {
    local ip
    ip=$(curl -4 -fsS -m 10 https://api.ipify.org 2> /dev/null || true)
    if [[ -z $ip ]] && command -v ip > /dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    fi
    printf '%s' "$ip"
}

hvk_udp_port_busy() { # 0 = a UDP socket already listens on the port
    command -v ss > /dev/null 2>&1 || return 1
    ss -lnuH 2> /dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

HVK_SYSCTL=$HVK_ROOT/etc/sysctl.d/99-hysteria-vps-kit.conf

# Hysteria2 (quic-go) asks for about 7 MB UDP buffers; the kernel default (208 KB) drops packets under
# load and shows up as stalls. Returns 0 if the file was written or changed, 1 if it was already right.
hvk_ensure_sysctl() {
    local want
    want=$'# hysteria-vps-kit: UDP buffers for QUIC\nnet.core.rmem_max = 7500000\nnet.core.wmem_max = 7500000\n'
    if [[ -f $HVK_SYSCTL && $(cat "$HVK_SYSCTL") == "${want%$'\n'}" ]]; then return 1; fi
    install -d -m 755 "$(dirname "$HVK_SYSCTL")"
    printf '%s' "$want" > "$HVK_SYSCTL"
    if [[ -z $HVK_ROOT ]]; then sysctl -q -p "$HVK_SYSCTL" > /dev/null 2>&1 || hvk_log 'warning: could not apply the UDP buffer sysctl'; fi
    return 0
}
