#!/usr/bin/env bash
set -euo pipefail
# Remove hysteria-vps-kit from this host.
#   uninstall.sh                remove everything the installer created
#   uninstall.sh --keep-config  keep /etc/hysteria-vps-kit (state, certificate, clients)
#   uninstall.sh --yes          do not ask
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
hvk_require_root
hvk_lock

keep=0 yes=0
for arg in "$@"; do
    case $arg in
        --keep-config) keep=1 ;;
        --yes) yes=1 ;;
        -h|--help) printf 'Usage: uninstall.sh [--keep-config] [--yes]\n'; exit 0 ;;
        *) hvk_die "unknown option: $arg" ;;
    esac
done
[[ -f $HVK_STATE ]] || hvk_die "not installed: $HVK_STATE is missing"

if (( ! yes )) && [[ -t 0 ]]; then
    read -r -p 'Remove the Hysteria2 server and all its clients? [y/N] ' answer || true
    [[ $answer == [yY]* ]] || { printf 'aborted\n'; exit 1; }
fi

port=$(hvk_state_get .port)
firewall=$(hvk_state_get .firewall)
del_user=$(jq -r '.created_resources.user // false' "$HVK_STATE" 2>/dev/null || echo false)
del_fw=$(jq -r '.created_resources.firewall_rule // false' "$HVK_STATE" 2>/dev/null || echo false)

if [[ -z $HVK_ROOT ]]; then
    systemctl disable --now "$HVK_SERVICE" > /dev/null 2>&1 || true
    rm -f "$HVK_UNIT"
    systemctl daemon-reload
    if [[ $firewall == ufw ]] && command -v ufw > /dev/null; then
        if [[ $del_fw == true ]]; then
            ufw delete allow "$port/udp" > /dev/null 2>&1 || true
            hvk_log "ufw: closed $port/udp"
        else
            hvk_log "ufw: kept $port/udp (not created by kit or ownership not recorded)"
        fi
    fi
fi
rm -rf "$HVK_OPT"
if [[ -f $HVK_SYSCTL ]]; then
    rm -f "$HVK_SYSCTL"
    hvk_log "sysctl: removed $HVK_SYSCTL (active kernel buffer values remain until reboot or manual change)"
fi
# remove the command link only if it is ours
if [[ -L $HVK_LINK && $(readlink -- "$HVK_LINK") == */hy2-client ]]; then rm -f "$HVK_LINK"; fi
if (( keep )); then
    hvk_log "kept $HVK_ETC"
else
    rm -rf "$HVK_ETC"
fi
if [[ -z $HVK_ROOT ]] && id "$HVK_USER" > /dev/null 2>&1 && (( ! keep )); then
    if [[ $del_user == true ]]; then
        userdel "$HVK_USER" 2> /dev/null || true
        hvk_log "removed system user $HVK_USER"
    else
        hvk_log "kept system user $HVK_USER (existed before kit installation or ownership not recorded)"
    fi
fi
hvk_log 'removed'
