#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filters are meant to stay in single quotes
set -euo pipefail
# Update the kit from its git clone, then bring the installed core and unit in line with it.
# Clients, certificate, obfuscation password and port are kept.
#   update.sh            fetch the latest kit and apply it
#   update.sh --check    only report (exit 0 = up to date, 10 = update available)
# Started through `curl ... | bash`, it finds the clone in /opt/hysteria-vps-kit-src.
if [[ ! -f ${BASH_SOURCE[0]:-} || ! -f $(dirname -- "${BASH_SOURCE[0]:-/}")/lib/common.sh ]]; then
    src=${HVK_SRC:-/opt/hysteria-vps-kit-src}
    [[ -f $src/update.sh ]] || { printf 'error: no kit clone at %s\n' "$src" >&2; exit 1; }
    exec bash "$src/update.sh" "$@"
fi
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
hvk_require_root
hvk_require_state

check=0
for arg in "$@"; do
    case $arg in
        --check) check=1 ;;
        -h|--help) printf 'Usage: update.sh [--check]\n'; exit 0 ;;
        *) hvk_die "unknown option: $arg" ;;
    esac
done

old_kit=$(hvk_state_get .version)
old_core=$(hvk_state_get .core)

if [[ -d $project/.git ]]; then
    git -C "$project" fetch -q origin
    if [[ $(git -C "$project" rev-parse HEAD) != "$(git -C "$project" rev-parse '@{u}')" ]]; then
        if (( check )); then hvk_log "update available (kit $old_kit)"; exit 10; fi
        git -C "$project" pull --ff-only -q || hvk_die 'cannot fast-forward the clone (local changes?)'
        exec bash "$project/update.sh"
    fi
fi

new_kit=$(hvk_project_version "$project")
if [[ $old_kit == "$new_kit" && $old_core == "$HVK_CORE_VERSION" ]]; then
    hvk_log "up to date (kit $new_kit, core $old_core)"
    exit 0
fi
if (( check )); then hvk_log "update available: kit $old_kit -> $new_kit, core $old_core -> $HVK_CORE_VERSION"; exit 10; fi

if [[ $old_core != "$HVK_CORE_VERSION" ]]; then
    arch=$(hvk_arch)
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    hvk_log "Downloading Hysteria2 v$HVK_CORE_VERSION ($arch)"
    curl -fsSL -m 180 -o "$tmp/hysteria" "$HVK_CORE_URL_BASE/hysteria-linux-$arch" || hvk_die 'download failed'
    actual=$(sha256sum "$tmp/hysteria" | cut -d' ' -f1)
    [[ $actual == "$(hvk_expected_sha "$arch")" ]] || hvk_die "sha256 mismatch for the core binary: $actual"
    chmod 755 "$tmp/hysteria"
    "$tmp/hysteria" version > /dev/null 2>&1 || hvk_die 'the new core binary does not run on this host'
    [[ ! -f $HVK_CORE_BIN ]] || cp -p "$HVK_CORE_BIN" "$HVK_CORE_BIN.previous"
    install -m 755 "$tmp/hysteria" "$HVK_CORE_BIN"
fi

hvk_state_update '.version = $v | .core = $c' --arg v "$new_kit" --arg c "$HVK_CORE_VERSION"
ln -sfn "$project/hy2-client" "$HVK_LINK"
hvk_render_config
hvk_restart_service
hvk_log "updated: kit $old_kit -> $new_kit, core $old_core -> $HVK_CORE_VERSION (previous core kept as $HVK_CORE_BIN.previous)"
