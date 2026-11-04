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
HVK_LOCK=${HVK_ROOT:+${HVK_ROOT}/run/lock/hysteria-vps-kit.lock}
HVK_LOCK=${HVK_LOCK:-/run/lock/hysteria-vps-kit.lock}

hvk_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
hvk_log() { printf '[hysteria-vps-kit] %s\n' "$*"; }

hvk_lock() {
    # If already locked in this process hierarchy (e.g. across exec in update.sh), return success
    if [[ ${HVK_LOCKED:-} == 1 ]]; then
        return 0
    fi
    local lock_dir
    lock_dir=$(dirname "$HVK_LOCK")
    [[ -d $lock_dir ]] || mkdir -p "$lock_dir"

    exec 9>> "$HVK_LOCK"
    if ! flock -n 9; then
        hvk_die "another operation is currently in progress (lock $HVK_LOCK is held)"
    fi
    export HVK_LOCKED=1
}

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

hvk_valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

hvk_valid_domain() {
    local domain=$1
    [[ -n $domain && ${#domain} -le 253 ]] || return 1
    [[ $domain != .* && $domain != *..* && $domain != *. ]] || return 1
    [[ ! $domain =~ [[:space:]] ]] || return 1
    local old_f
    [[ $- == *f* ]] && old_f=1 || old_f=0
    set -f
    local old_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086
    set -- $domain
    IFS=$old_ifs
    (( old_f )) || set +f
    (( $# >= 1 )) || return 1
    local label last_label=""
    for label in "$@"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
        last_label=$label
    done
    # TLD / single label must not be purely numeric (RFC 1123 / RFC 3696)
    [[ ! $last_label =~ ^[0-9]+$ ]] || return 1
    return 0
}

hvk_valid_sni() {
    hvk_valid_domain "$1"
}

hvk_valid_ipv4() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]}
    local octet
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if [[ $octet =~ ^0[0-9]+ ]] || (( 10#$octet > 255 )); then return 1; fi
    done
    return 0
}

hvk_is_private_ip() {
    local ip=$1
    hvk_valid_ipv4 "$ip" || return 1
    local o1 o2 o3 o4
    local old_ifs=$IFS
    IFS=.
    read -r o1 o2 o3 o4 <<< "$ip"
    IFS=$old_ifs
    if (( 10#$o1 == 10 || 10#$o1 == 127 )); then return 0; fi
    if (( 10#$o1 == 172 && 10#$o2 >= 16 && 10#$o2 <= 31 )); then return 0; fi
    if (( 10#$o1 == 192 && 10#$o2 == 168 )); then return 0; fi
    if (( 10#$o1 == 169 && 10#$o2 == 254 )); then return 0; fi
    if (( 10#$o1 == 100 && 10#$o2 >= 64 && 10#$o2 <= 127 )); then return 0; fi
    if [[ $ip == "0.0.0.0" || $ip == "255.255.255.255" ]]; then return 0; fi
    return 1
}

hvk_valid_endpoint() {
    local ep=$1
    [[ $ep == "YOUR_SERVER_IP" ]] && return 0
    hvk_valid_ipv4 "$ep" || hvk_valid_domain "$ep"
}

hvk_client_name_conflict() {
    local name=$1
    local conflict
    conflict=$(jq -r --arg n "$name" '
        .clients // {} | keys[] | select(ascii_downcase == ($n | ascii_downcase))
    ' "$HVK_STATE" 2> /dev/null || true)
    [[ -n $conflict ]]
}

hvk_validate_state() {
    [[ -f $HVK_STATE ]] || hvk_die "state file missing: $HVK_STATE"
    [[ -s $HVK_STATE ]] || hvk_die "state file is empty: $HVK_STATE"
    if ! jq empty "$HVK_STATE" > /dev/null 2>&1; then
        hvk_die "state file contains invalid JSON: $HVK_STATE"
    fi
    local version core endpoint port sni pin obfs_enabled clients_type status
    version=$(jq -r '.version // empty' "$HVK_STATE" 2> /dev/null || true)
    [[ -n $version ]] || hvk_die "state.json has missing or empty version"
    core=$(jq -r '.core // empty' "$HVK_STATE" 2> /dev/null || true)
    [[ -n $core ]] || hvk_die "state.json has missing or empty core"
    endpoint=$(jq -r '.endpoint // empty' "$HVK_STATE" 2> /dev/null || true)
    if [[ -z $endpoint ]] || ! hvk_valid_endpoint "$endpoint"; then
        hvk_die "state.json has invalid or empty endpoint: $endpoint"
    fi
    status=$(jq -r '.status // empty' "$HVK_STATE" 2> /dev/null || true)
    if [[ -n $status && $status != "ready" && $status != "installing" && $status != "updating" ]]; then
        hvk_die "state.json has invalid status: $status"
    fi
    port=$(jq -r '.port // empty' "$HVK_STATE" 2> /dev/null || true)
    hvk_valid_port "$port" || hvk_die "state.json has invalid port: $port"
    sni=$(jq -r '.sni // empty' "$HVK_STATE" 2> /dev/null || true)
    hvk_valid_sni "$sni" || hvk_die "state.json has invalid sni: $sni"
    pin=$(jq -r '.pin // empty' "$HVK_STATE" 2> /dev/null || true)
    [[ $pin =~ ^[0-9a-f]{64}$ ]] || hvk_die "state.json has invalid pin: $pin"
    obfs_enabled=$(jq -r '
        if (.obfs | type == "object") and (.obfs | has("enabled")) and (.obfs.enabled | type == "boolean")
        then .obfs.enabled else "invalid" end
    ' "$HVK_STATE" 2> /dev/null || echo "invalid")
    [[ $obfs_enabled == "true" || $obfs_enabled == "false" ]] || hvk_die "state.json has invalid obfs.enabled"
    clients_type=$(jq -r '.clients | type' "$HVK_STATE" 2> /dev/null || true)
    [[ $clients_type == "object" ]] || hvk_die "state.json .clients must be an object"
    local dup_count
    dup_count=$(jq -r '
        .clients // {} | keys | map(ascii_downcase) | length - (unique | length)
    ' "$HVK_STATE" 2> /dev/null || echo 0)
    if (( dup_count > 0 )); then
        hvk_die "state.json has case-insensitive client name duplicates; resolve them manually"
    fi
}

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

hvk_require_state() {
    [[ -f $HVK_STATE ]] || hvk_die "not installed: $HVK_STATE is missing"
    hvk_validate_state
}

hvk_render_unit() { # [target_path]
    local target=${1:-$HVK_UNIT}
    cat << EOF > "$target"
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
    chmod 644 "$target"
}

hvk_install_unit() {
    local tmp
    tmp=$(mktemp "${HVK_ROOT:-}/tmp/hysteria-unit.XXXXXX" 2>/dev/null || mktemp "/tmp/hysteria-unit.XXXXXX")
    hvk_render_unit "$tmp"
    local changed=0
    if [[ ! -f $HVK_UNIT ]] || ! cmp -s "$tmp" "$HVK_UNIT"; then
        install -d -m 755 "$(dirname "$HVK_UNIT")"
        install -m 644 "$tmp" "$HVK_UNIT"
        changed=1
    fi
    rm -f "$tmp"
    if (( changed )) && [[ -z $HVK_ROOT ]]; then
        systemctl daemon-reload
    fi
    return 0
}

hvk_pin() { # SHA-256 of the certificate, lower-case hex, no colons
    openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

hvk_render_config_to() { # hvk_render_config_to PATH
    local target=$1
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
    } > "$target"
}

hvk_render_config() {
    local tmp_cfg="$HVK_CONFIG.new"
    rm -f "$tmp_cfg"
    # Create file immediately with 0640 permissions
    install -m 640 /dev/null "$tmp_cfg" 2>/dev/null || {
        local old_u
        old_u=$(umask)
        umask 027
        touch "$tmp_cfg"
        umask "$old_u"
    }
    if hvk_render_config_to "$tmp_cfg"; then
        chmod 640 "$tmp_cfg"
        mv -f "$tmp_cfg" "$HVK_CONFIG"
        if [[ -z $HVK_ROOT ]]; then chown "root:$HVK_USER" "$HVK_CONFIG"; fi
    else
        rm -f "$tmp_cfg"
        hvk_die "could not render configuration to $HVK_CONFIG"
    fi
}

hvk_restart_service() {
    if [[ -n $HVK_ROOT ]]; then
        if [[ ${HVK_MOCK_RESTART_FAIL:-0} == 1 ]]; then
            return 1
        fi
        return 0
    fi
    systemctl restart "$HVK_SERVICE" || return 1
    sleep 1
    systemctl is-active --quiet "$HVK_SERVICE" || return 1
    return 0
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
    if hvk_valid_ipv4 "$ip" && ! hvk_is_private_ip "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    return 1
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
