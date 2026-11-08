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

check=0
no_git=${HVK_NO_GIT:-0}
for arg in "$@"; do
    case $arg in
        --check) check=1 ;;
        --no-git) no_git=1 ;;
        -h|--help) printf 'Usage: update.sh [--check] [--no-git]\n'; exit 0 ;;
        *) hvk_die "unknown option: $arg" ;;
    esac
done

hvk_require_root
hvk_require_state

status=$(jq -r '.status // "ready"' "$HVK_STATE" 2>/dev/null || echo "ready")
if [[ $status == "uninstalled" || ! -x $HVK_CORE_BIN ]]; then
    hvk_die "the installation is not complete (status: $status, core: $HVK_CORE_BIN); run 'bash install.sh --repair' first"
fi
if [[ $status == "installing" ]]; then
    hvk_die "incomplete installation detected (status: installing); run 'bash install.sh --repair' to complete it, not update.sh"
fi

if (( ! check )); then
    hvk_lock
fi

old_kit=$(hvk_state_get .version)
old_core=$(hvk_state_get .core)
old_status=$(jq -r '.status // "ready"' "$HVK_STATE" 2>/dev/null || echo "ready")

if (( ! no_git )) && [[ -d $project/.git ]]; then
    git -C "$project" fetch -q origin
    if [[ $(git -C "$project" rev-parse HEAD) != "$(git -C "$project" rev-parse '@{u}')" ]]; then
        if (( check )); then hvk_log "update available (kit $old_kit)"; exit 10; fi
        git -C "$project" pull --ff-only -q || hvk_die 'cannot fast-forward the clone (local changes?)'
        exec bash "$project/update.sh"
    fi
fi

new_kit=$(hvk_project_version "$project")
if [[ $old_kit == "$new_kit" && $old_core == "$HVK_CORE_VERSION" && $old_status == "ready" ]]; then
    hvk_log "up to date (kit $new_kit, core $old_core)"
    exit 0
fi
if (( check )); then
    hvk_log "update available: kit $old_kit -> $new_kit, core $old_core -> $HVK_CORE_VERSION (status $old_status)"
    exit 10
fi

# Fetch and verify the new core first: a failed download must leave nothing behind.
core_changed=0
tmp_dl=""
trap '[[ -z $tmp_dl ]] || rm -rf "$tmp_dl"' EXIT
if [[ $old_core != "$HVK_CORE_VERSION" ]]; then
    arch=$(hvk_arch)
    tmp_dl=$(mktemp -d)
    hvk_log "Downloading Hysteria2 v$HVK_CORE_VERSION ($arch)"
    curl -fsSL -m 180 -o "$tmp_dl/hysteria" "$HVK_CORE_URL_BASE/hysteria-linux-$arch" || hvk_die 'download failed'
    actual=$(sha256sum "$tmp_dl/hysteria" | cut -d' ' -f1)
    [[ $actual == "$(hvk_expected_sha "$arch")" ]] || hvk_die "sha256 mismatch for the core binary: $actual"
    chmod 755 "$tmp_dl/hysteria"
    "$tmp_dl/hysteria" version > /dev/null 2>&1 || hvk_die 'the new core binary does not run on this host'
    core_changed=1
fi

# Prepare backup of consistent bundle
backup_dir=$(mktemp -d "$HVK_ETC/.backup-update.XXXXXX")
cp -pf "$HVK_STATE" "$backup_dir/state.json"
cp -pf "$HVK_CONFIG" "$backup_dir/config.yaml"
[[ ! -f $HVK_CORE_BIN ]] || cp -pf "$HVK_CORE_BIN" "$backup_dir/hysteria"
[[ ! -f $HVK_UNIT ]] || cp -pf "$HVK_UNIT" "$backup_dir/unit"

rolled_back=0
update_succeeded=0
rollback_update() {
    if (( update_succeeded || rolled_back )); then return; fi
    rolled_back=1
    [[ -z $tmp_dl ]] || rm -rf "$tmp_dl"
    hvk_log "error: update failed; rolling back to previous state..."
    cp -pf "$backup_dir/state.json" "$HVK_STATE"
    cp -pf "$backup_dir/config.yaml" "$HVK_CONFIG"
    if [[ -f $backup_dir/hysteria ]]; then
        cp -pf "$backup_dir/hysteria" "$HVK_CORE_BIN"
    fi
    if [[ -f $backup_dir/unit ]]; then
        cp -pf "$backup_dir/unit" "$HVK_UNIT"
        [[ -n $HVK_ROOT ]] || systemctl daemon-reload
    fi
    hvk_log "backup preserved at $backup_dir"
    if hvk_restart_service; then
        hvk_die "update failed: previous version was restored successfully"
    else
        hvk_die "CRITICAL: update failed AND rollback failed to start the service; check logs: journalctl -u $HVK_SERVICE -n 50"
    fi
}
trap rollback_update EXIT

# Mark updating state before applying changes
hvk_state_update '.status = "updating"'

if (( core_changed )); then
    [[ ! -f $HVK_CORE_BIN ]] || cp -p "$HVK_CORE_BIN" "$HVK_CORE_BIN.previous"
    install -m 755 "$tmp_dl/hysteria" "$HVK_CORE_BIN"
    rm -rf "$tmp_dl"
fi

hvk_ensure_sysctl || true
hvk_install_unit
hvk_state_update '.version = $v | .core = $c' --arg v "$new_kit" --arg c "$HVK_CORE_VERSION"
ln -sfn "$project/hy2-client" "$HVK_LINK"
hvk_render_config

if ! hvk_restart_service; then
    rollback_update
fi

# Update verified and succeeded: finalize state and remove backup directory
hvk_state_update '.status = "ready"'
update_succeeded=1
trap - EXIT
rm -rf "$backup_dir"
find "$HVK_ETC" -maxdepth 1 -type d -name '.backup-update.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

if (( core_changed )); then
    hvk_log "updated: kit $old_kit -> $new_kit, core $old_core -> $HVK_CORE_VERSION (previous core kept as $HVK_CORE_BIN.previous)"
else
    hvk_log "updated: kit $old_kit -> $new_kit, core $old_core (no core change)"
fi
