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
    refuse 'rejects port with leading zero 08' install_sandbox --port 08
    refuse 'rejects port with leading zero 00443' install_sandbox --port 00443
    refuse 'rejects port 0' install_sandbox --port 0
    refuse 'rejects port 65536' install_sandbox --port 65536
    refuse 'rejects negative port' install_sandbox --port -1
    refuse 'rejects a bad sni' install_sandbox --sni 'bad name'
    refuse 'rejects bad sni ...' install_sandbox --sni '...'
    refuse 'rejects bad sni -foo.com' install_sandbox --sni '-foo.com'
    refuse 'rejects bad sni foo..com' install_sandbox --sni 'foo..com'
    refuse 'rejects bad sni foo-.com' install_sandbox --sni 'foo-.com'
    refuse 'rejects bad endpoint spaces' install_sandbox --endpoint 'bad ip'
    refuse 'rejects bad endpoint 1.2.3.4.5' install_sandbox --endpoint '1.2.3.4.5'
    refuse 'rejects bad endpoint leading zero 010.0.0.1' install_sandbox --endpoint '010.0.0.1'
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
    check 'UDP buffer sysctl written' contains "$sandbox/etc/sysctl.d/99-hysteria-vps-kit.conf" 'net.core.rmem_max = 7500000'
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
    check 'add Alice' hy add Alice
    refuse 'rejects case-insensitive duplicate alice' hy add alice
    refuse 'rejects case-insensitive duplicate ALICE' hy add ALICE
    refuse 'bad name' hy add '@x'
    check 'four clients' test "$(hy list | wc -l)" = 4
    local uri
    uri=$(hy show phone.one)
    check 'URI scheme' test "${uri#hysteria2://}" != "$uri"
    check 'URI has obfs' test "${uri#*obfs=salamander}" != "$uri"
    check 'URI has the pin' test "${uri#*pinSHA256=}" != "$uri"
    check 'URI endpoint' test "${uri#*@203.0.113.7:}" != "$uri"
    check '@ in a name is percent-encoded in the URI' test "$(hy show 'one@us' | grep -c '^hysteria2://one%40us:')" = 1
    check 'yaml has server and auth' test "$(hy show phone.one --yaml | grep -Ec '^(server: 203.0.113.7:443|auth: phone.one:)')" = 2
    check 'yaml honours --http/--socks' test "$(hy show phone.one --yaml --http 0.0.0.0:9230 --socks 0.0.0.0:8230 | grep -Ec 'listen: 0.0.0.0:(9230|8230)')" = 2
    check 'passwords differ between clients' test "$(jq -r '.clients | [.[]] | unique | length' "$sandbox/etc/hysteria-vps-kit/state.json")" = 4
    check 'config lists every client' test "$(grep -c '^    "' "$sandbox/etc/hysteria-vps-kit/config.yaml")" = 4
    check 'remove' hy remove phone.one
    refuse 'remove twice' hy remove phone.one
    refuse 'show of a removed client' hy show phone.one
    check 'config follows removal' test "$(grep -c '^    "' "$sandbox/etc/hysteria-vps-kit/config.yaml")" = 3
    check 'version prints' hy version
    refuse 'unknown command' hy frobnicate

    # Restart failure on add: rollback
    local client_count_before
    client_count_before=$(hy list | wc -l)
    refuse 'add fails when restart fails' env HVK_ROOT="$sandbox" HVK_MOCK_RESTART_FAIL=1 bash "$project/hy2-client" add doomed_user
    check 'doomed_user not in client list after failed add' test "$(hy list | wc -l)" = "$client_count_before"
    refuse 'doomed_user not in config.yaml' contains "$sandbox/etc/hysteria-vps-kit/config.yaml" 'doomed_user'

    # Restart failure on remove: fail-closed (user stays removed, not silently restored)
    check 'add user_to_remove' hy add user_to_remove
    refuse 'remove fails when restart fails' env HVK_ROOT="$sandbox" HVK_MOCK_RESTART_FAIL=1 bash "$project/hy2-client" remove user_to_remove
    refuse 'user_to_remove was NOT restored after failed remove restart' contains "$sandbox/etc/hysteria-vps-kit/config.yaml" 'user_to_remove'
    refuse 'user_to_remove not in state after failed remove restart' contains "$sandbox/etc/hysteria-vps-kit/state.json" 'user_to_remove'

    # Corrupted state handling
    echo '{invalid json' > "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'corrupted state rejects hy list' hy list
    refuse 'corrupted state rejects hy add' hy add newuser
    check 'corrupted state not overwritten' test "$(cat "$sandbox/etc/hysteria-vps-kit/state.json")" = '{invalid json'

    # State with case-insensitive duplicates manually planted
    printf '{"version":"0.1.1","core":"2.13.0","port":443,"sni":"www.bing.com","endpoint":"1.1.1.1","pin":"%s","obfs":{"enabled":false,"password":""},"firewall":"none","clients":{"alice":"p1","Alice":"p2"}}\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'state with existing case-insensitive duplicate clients rejected' hy list
    rm -rf "$sandbox"
}

suite_locking() {
    printf 'suite: locking\n'
    new_root
    install_sandbox > /dev/null
    local lockfile=$sandbox/run/lock/hysteria-vps-kit.lock
    mkdir -p "$(dirname "$lockfile")"
    (
        exec 9>> "$lockfile"
        flock -x 9
        sleep 1
    ) &
    local bg_pid=$!
    sleep 0.1
    refuse 'concurrent command blocked while lock held' hy add blocked_user
    wait "$bg_pid"
    check 'command succeeds after lock released' hy add allowed_user
    check 're-exec with HVK_LOCKED=1 does not self-lock' env HVK_ROOT="$sandbox" HVK_LOCKED=1 bash -c "source '$project/lib/common.sh'; hvk_lock"
    rm -rf "$sandbox"
}

suite_repair() {
    printf 'suite: repair\n'
    new_root
    install_sandbox --first-client user1 > /dev/null
    local orig_pin orig_obfs orig_cert
    orig_pin=$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")
    orig_obfs=$(jq -r .obfs.password "$sandbox/etc/hysteria-vps-kit/state.json")
    orig_cert=$(cat "$sandbox/etc/hysteria-vps-kit/server.crt")

    # Mark status as incomplete
    jq '.status = "installing"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"

    refuse 'normal install refuses incomplete install' install_sandbox
    check 'install --repair succeeds' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --repair
    check 'status is ready after repair' test "$(jq -r .status "$sandbox/etc/hysteria-vps-kit/state.json")" = "ready"
    check 'pin preserved after repair' test "$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")" = "$orig_pin"
    check 'obfs password preserved after repair' test "$(jq -r .obfs.password "$sandbox/etc/hysteria-vps-kit/state.json")" = "$orig_obfs"
    check 'certificate preserved after repair' test "$(cat "$sandbox/etc/hysteria-vps-kit/server.crt")" = "$orig_cert"
    check 'client preserved after repair' test "$(hy list)" = "user1"
    check 'ownership recorded' test "$(jq -r '.created_resources | has("user") and has("firewall_rule")' "$sandbox/etc/hysteria-vps-kit/state.json")" = "true"
    rm -rf "$sandbox"
}

suite_update() {
    printf 'suite: update\n'
    new_root
    install_sandbox > /dev/null
    check 'update --check reports up to date' env HVK_ROOT="$sandbox" bash "$project/update.sh" --check

    # Modify unit to simulate outdated unit
    mkdir -p "$sandbox/etc/systemd/system"
    echo "# old unit" > "$sandbox/etc/systemd/system/hysteria-vps-kit.service"

    # Mock older kit version in state
    jq '.version = "0.0.9"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"

    local out
    out=$(env HVK_ROOT="$sandbox" bash "$project/update.sh")
    check 'update runs without core change message' contains <(printf '%s' "$out") '(no core change)'
    refuse 'update does not claim previous core kept when unchanged' contains <(printf '%s' "$out") 'previous core kept'
    check 'unit was synchronized during update' contains "$sandbox/etc/systemd/system/hysteria-vps-kit.service" 'AmbientCapabilities=CAP_NET_BIND_SERVICE'

    # Test update failure with restart failure: rollback
    jq '.version = "0.0.1"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'update with restart failure fails' env HVK_ROOT="$sandbox" HVK_MOCK_RESTART_FAIL=1 bash "$project/update.sh"
    check 'update rollback restored state version' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = "0.0.1"
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
    refuse 'sysctl file removed' test -e "$sandbox/etc/sysctl.d/99-hysteria-vps-kit.conf"
    check 'full uninstall' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    refuse 'config dir removed' test -e "$sandbox/etc/hysteria-vps-kit"
    refuse 'uninstall twice' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    rm -rf "$sandbox"
}

suites=(validation install render clients locking repair update uninstall)
if [[ ${1:-} == --suite ]]; then suites=("${2:?--suite needs a name}"); fi
for suite in "${suites[@]}"; do
    declare -F "suite_$suite" > /dev/null || { printf 'error: unknown suite: %s\n' "$suite" >&2; exit 2; }
    "suite_$suite"
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
