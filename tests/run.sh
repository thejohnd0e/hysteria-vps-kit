#!/usr/bin/env bash
# Sandbox tests: nothing here touches systemd, users, firewall or the network.
#   bash tests/run.sh               run every suite
#   bash tests/run.sh --suite NAME  run one (validation install clients render uninstall)
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$project"
for tool in jq openssl; do command -v "$tool" > /dev/null || { printf 'error: %s is required\n' "$tool" >&2; exit 1; }; done

passed=0 failed=0
ok() { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check DESCRIPTION CMD...
    local desc=$1; shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
refuse() { # refuse DESCRIPTION CMD... (command must fail)
    local desc=$1; shift
    if "$@" > /dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}
contains() { grep -q -- "$2" "$1"; }

new_root() { sandbox=$(mktemp -d); }
install_sandbox() { bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --endpoint 203.0.113.7 "$@"; }
hy() { HVK_ROOT=$sandbox bash "$project/hy2-client" "$@"; }

suite_validation() {
    printf 'suite: validation\n'
    new_root
    refuse 'rejects a bad port' install_sandbox --port 70000
    refuse 'rejects a bad sni' install_sandbox --sni 'bad name'
    refuse 'rejects a bad client name' install_sandbox --first-client '@bad'
    refuse '--root without --no-service' bash "$project/install.sh" --root "$sandbox"
    refuse '--no-service without --root' bash "$project/install.sh" --no-service
    refuse 'unknown option' bash "$project/install.sh" --nope
    check 'help works' bash "$project/install.sh" --help
    for f in install.sh update.sh uninstall.sh hy2-client; do check "$f is executable" test -x "$project/$f"; done
    rm -rf "$sandbox"
}

suite_install() {
    printf 'suite: install\n'
    new_root
    check 'install succeeds' install_sandbox --port 4433 --first-client one_us
    check 'state.json exists, mode 600' test "$(stat -c %a "$sandbox/etc/hysteria-vps-kit/state.json")" = 600
    check 'state has port 4433' test "$(jq -r .port "$sandbox/etc/hysteria-vps-kit/state.json")" = 4433
    check 'state has the pinned core version' test "$(jq -r .core "$sandbox/etc/hysteria-vps-kit/state.json")" = "$(sed -n 's/^HVK_CORE_VERSION=//p' lib/common.sh)"
    check 'pin is 64 hex chars' test "$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json" | grep -Ec '^[0-9a-f]{64}$')" = 1
    check 'obfs password is 28 chars' test "$(jq -r .obfs.password "$sandbox/etc/hysteria-vps-kit/state.json" | wc -c)" = 29
    check 'config.yaml written' test -s "$sandbox/etc/hysteria-vps-kit/config.yaml"
    check 'certificate written' test -s "$sandbox/etc/hysteria-vps-kit/server.crt"
    check 'command link created' test -L "$sandbox/usr/local/bin/hy2-client"
    rm -rf "$sandbox"
    new_root
    check 'install without obfs' install_sandbox --no-obfs --no-first-client
    check 'obfs disabled in state' test "$(jq -r .obfs.enabled "$sandbox/etc/hysteria-vps-kit/state.json")" = false
    refuse 'no obfs block in config' contains "$sandbox/etc/hysteria-vps-kit/config.yaml" 'salamander'
    check 'no clients' test "$(hy list | wc -l)" = 0
    rm -rf "$sandbox"
}

suite_render() {
    printf 'suite: render\n'
    new_root
    install_sandbox --port 8443 --sni www.example.com --first-client main-user > /dev/null
    local cfg=$sandbox/etc/hysteria-vps-kit/config.yaml
    check 'listens on the port' contains "$cfg" '^listen: :8443$'
    check 'obfs block present' contains "$cfg" 'type: salamander'
    check 'userpass auth' contains "$cfg" 'type: userpass'
    check 'client entry quoted' contains "$cfg" '"main-user": "'
    check 'masquerade uses the SNI' contains "$cfg" 'url: https://www.example.com/'
    check 'config is group-readable, not world' test "$(stat -c %a "$cfg")" = 640
    rm -rf "$sandbox"
}

suite_clients() {
    printf 'suite: clients\n'
    new_root
    install_sandbox --first-client main-user > /dev/null
    check 'list shows the first client' test "$(hy list)" = main-user
    check 'add' hy add phone.one
    check 'add with @' hy add 'one@us'
    refuse 'duplicate add' hy add phone.one
    refuse 'bad name' hy add '@x'
    check 'three clients' test "$(hy list | wc -l)" = 3
    local uri
    uri=$(hy show phone.one)
    check 'URI scheme' test "${uri#hysteria2://}" != "$uri"
    check 'URI has obfs' test "${uri#*obfs=salamander}" != "$uri"
    check 'URI has the pin' test "${uri#*pinSHA256=}" != "$uri"
    check 'URI endpoint' test "${uri#*@203.0.113.7:}" != "$uri"
    check '@ in a name is percent-encoded in the URI' test "$(hy show 'one@us' | grep -c '^hysteria2://one%40us:')" = 1
    check 'yaml has server and auth' test "$(hy show phone.one --yaml | grep -Ec '^(server: 203.0.113.7:443|auth: phone.one:)')" = 2
    check 'yaml honours --http/--socks' test "$(hy show phone.one --yaml --http 0.0.0.0:9230 --socks 0.0.0.0:8230 | grep -Ec 'listen: 0.0.0.0:(9230|8230)')" = 2
    check 'passwords differ between clients' test "$(jq -r '.clients | [.[]] | unique | length' "$sandbox/etc/hysteria-vps-kit/state.json")" = 3
    check 'config lists every client' test "$(grep -c '^    "' "$sandbox/etc/hysteria-vps-kit/config.yaml")" = 3
    check 'remove' hy remove phone.one
    refuse 'remove twice' hy remove phone.one
    refuse 'show of a removed client' hy show phone.one
    check 'config follows removal' test "$(grep -c '^    "' "$sandbox/etc/hysteria-vps-kit/config.yaml")" = 2
    check 'version prints' hy version
    refuse 'unknown command' hy frobnicate
    rm -rf "$sandbox"
}

suite_uninstall() {
    printf 'suite: uninstall\n'
    new_root
    install_sandbox > /dev/null
    check 'uninstall --keep-config' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --keep-config --yes
    check 'state kept' test -f "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'core removed' test -e "$sandbox/opt/hysteria-vps-kit"
    refuse 'command link removed' test -e "$sandbox/usr/local/bin/hy2-client"
    check 'full uninstall' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    refuse 'config dir removed' test -e "$sandbox/etc/hysteria-vps-kit"
    refuse 'uninstall twice' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    rm -rf "$sandbox"
}

suites=(validation install render clients uninstall)
if [[ ${1:-} == --suite ]]; then suites=("${2:?--suite needs a name}"); fi
for suite in "${suites[@]}"; do
    declare -F "suite_$suite" > /dev/null || { printf 'error: unknown suite: %s\n' "$suite" >&2; exit 2; }
    "suite_$suite"
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
