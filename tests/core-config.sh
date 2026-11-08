#!/usr/bin/env bash
# Feeds the configs rendered by the kit to the real, pinned Hysteria2 core and checks that it starts.
# The sandbox suites use a stub core, so they cannot catch a config the real binary rejects.
#   bash tests/core-config.sh [CORE_BINARY]   (without an argument the pinned core is downloaded and checked)
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$project"
for tool in jq openssl curl sha256sum; do command -v "$tool" > /dev/null || { printf 'error: %s is required\n' "$tool" >&2; exit 1; }; done
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"

work=$(mktemp -d)
core_pid=''
cleanup() { [[ -z $core_pid ]] || kill "$core_pid" 2> /dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

core=${1:-}
if [[ -z $core ]]; then
    arch=$(hvk_arch)
    core=$work/hysteria
    curl -fsSL --retry 3 -m 180 -o "$core" "$HVK_CORE_URL_BASE/hysteria-linux-$arch"
    [[ $(sha256sum "$core" | cut -d' ' -f1) == "$(hvk_expected_sha "$arch")" ]] || { printf 'error: sha256 mismatch for the core\n' >&2; exit 1; }
    chmod 755 "$core"
fi
"$core" version > /dev/null 2>&1 || { printf 'error: the core does not run here\n' >&2; exit 1; }

passed=0 failed=0
ok() { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; }

# run_core ROOT -> 0 if the core reaches "server up and running" with the config rendered from ROOT
run_core() {
    local root=$1 cfg log i
    cfg=$work/config.yaml
    log=$work/core.log
    HVK_ROOT=$root bash -c 'source "$1/lib/common.sh"; hvk_render_config_to "$2"' _ "$project" "$cfg"
    sed -i "s#/etc/hysteria-vps-kit#$root/etc/hysteria-vps-kit#g" "$cfg"
    : > "$log"
    "$core" server -c "$cfg" > "$log" 2>&1 &
    core_pid=$!
    for ((i = 0; i < 50; i++)); do
        grep -q 'server up and running' "$log" && { kill "$core_pid" 2> /dev/null || true; wait "$core_pid" 2> /dev/null || true; core_pid=''; return 0; }
        kill -0 "$core_pid" 2> /dev/null || break
        sleep 0.2
    done
    kill "$core_pid" 2> /dev/null || true; wait "$core_pid" 2> /dev/null || true; core_pid=''
    return 1
}

new_install() { # new_install NAME ARGS...
    local name=$1; shift
    root=$work/$name
    mkdir -p "$root"
    bash "$project/install.sh" --no-service --root "$root" --non-interactive --endpoint 203.0.113.7 \
        --port $((30000 + RANDOM % 20000)) "$@" > /dev/null
}
add_client() { HVK_ROOT=$root bash "$project/hy2-client" add "$1" > /dev/null; }

printf 'core: %s\n' "$("$core" version 2>&1 | grep -m1 -i 'version' || true)"

new_install default
if run_core "$root"; then ok 'default install (obfs, one client)'; else bad 'default install (obfs, one client)'; cat "$work/core.log"; fi

new_install noobfs --no-obfs
if run_core "$root"; then ok 'install without obfs'; else bad 'install without obfs'; cat "$work/core.log"; fi

new_install many
add_client 'user@example_com'; add_client 'a_b-c'; add_client 'Third-User'
if run_core "$root"; then ok 'several clients incl. @ in names'; else bad 'several clients incl. @ in names'; cat "$work/core.log"; fi

# Documents the upstream behavior the kit relies on: no identities -> the core refuses to start,
# so the kit keeps the service stopped. If this ever starts passing, revisit hvk_restart_service.
new_install none --no-first-client
if run_core "$root"; then bad 'empty userpass is still refused by the core (upstream changed?)'; else
    if grep -q 'empty auth userpass' "$work/core.log"; then ok 'empty userpass is refused by the core'; else bad 'empty userpass failed for another reason'; cat "$work/core.log"; fi
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
