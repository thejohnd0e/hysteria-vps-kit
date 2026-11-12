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

lock_matches() { # the lock file and the constants in lib/common.sh must describe the same core
    # shellcheck source=lib/common.sh
    ( source "$project/lib/common.sh"
      jq -e --arg v "v$HVK_CORE_VERSION" --arg base "$HVK_CORE_URL_BASE" --arg a "$HVK_SHA256_AMD64" --arg r "$HVK_SHA256_ARM64" '
          .version == $v and .assets.amd64.sha256 == $a and .assets.arm64.sha256 == $r
          and .assets.amd64.url == ($base + "/hysteria-linux-amd64") and .assets.arm64.url == ($base + "/hysteria-linux-arm64")
      ' "$project/releases/hysteria.lock.json" > /dev/null )
}

suite_validation() {
    printf 'suite: validation\n'
    new_root
    check 'releases/hysteria.lock.json matches the pinned core in lib/common.sh' lock_matches
    refuse 'rejects a bad port' install_sandbox --port 70000
    refuse 'rejects port with leading zero 08' install_sandbox --port 08
    refuse 'rejects port with leading zero 00443' install_sandbox --port 00443
    refuse 'rejects port 0' install_sandbox --port 0
    refuse 'rejects port 65536' install_sandbox --port 65536
    refuse 'rejects negative port' install_sandbox --port -1
    refuse 'rejects a bad sni' install_sandbox --sni 'bad name'
    refuse 'rejects a dot in the client name (the core splits userpass keys on dots)' install_sandbox --first-client 'user.name'
    refuse 'rejects bad sni ...' install_sandbox --sni '...'
    refuse 'rejects bad sni -foo.com' install_sandbox --sni '-foo.com'
    refuse 'rejects bad sni foo..com' install_sandbox --sni 'foo..com'
    refuse 'rejects bad sni foo-.com' install_sandbox --sni 'foo-.com'
    refuse 'rejects wildcard sni *' install_sandbox --sni '*'
    refuse 'rejects wildcard sni *.example.com' install_sandbox --sni '*.example.com'
    (
        local gd; gd=$(mktemp -d); cd "$gd" && touch bin etc usr
        refuse 'rejects wildcard sni * with local unextended files' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --endpoint 203.0.113.7 --sni '*'
        refuse 'rejects wildcard sni *.example.com with local unextended files' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --endpoint 203.0.113.7 --sni '*.example.com'
        rm -rf "$gd"
    )
    refuse 'rejects bad endpoint spaces' install_sandbox --endpoint 'bad ip'
    refuse 'rejects bad endpoint 1.2.3.4.5' install_sandbox --endpoint '1.2.3.4.5'
    refuse 'rejects bad endpoint leading zero 010.0.0.1' install_sandbox --endpoint '010.0.0.1'
    refuse 'rejects a bad client name' install_sandbox --first-client '@bad'
    refuse 'force-secrets requires repair' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --force-secrets
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
    check 'certificate carries a SAN for the SNI' test "$(openssl x509 -in "$sandbox/etc/hysteria-vps-kit/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -c 'DNS:www.bing.com')" = 1
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
    mkdir -p "$sandbox/mockbin"
    cat > "$sandbox/mockbin/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [[ $arg != *to_entries* ]] || exit 42
done
exec /usr/bin/jq "$@"
EOF
    chmod +x "$sandbox/mockbin/jq"
    cp "$cfg" "$sandbox/original-config"
    refuse 'failed client render rejects add' env PATH="$sandbox/mockbin:$PATH" HVK_ROOT="$sandbox" bash "$project/hy2-client" add render_failure
    check 'failed client render preserves config' cmp "$cfg" "$sandbox/original-config"
    refuse 'failed client render rolls back state' grep -q render_failure "$sandbox/etc/hysteria-vps-kit/state.json"
    rm -rf "$sandbox"
}

suite_clients() {
    printf 'suite: clients\n'
    new_root
    install_sandbox --first-client main-user > /dev/null
    check 'list shows the first client' test "$(hy list)" = main-user
    check 'add' hy add phone_one
    check 'add with @' hy add 'one@us'
    refuse 'duplicate add' hy add phone_one
    check 'add Alice' hy add Alice
    refuse 'rejects case-insensitive duplicate alice' hy add alice
    refuse 'rejects case-insensitive duplicate ALICE' hy add ALICE
    refuse 'bad name' hy add '@x'
    check 'four clients' test "$(hy list | wc -l)" = 4
    local uri
    uri=$(hy show phone_one)
    check 'URI scheme' test "${uri#hysteria2://}" != "$uri"
    check 'URI has obfs' test "${uri#*obfs=salamander}" != "$uri"
    check 'URI has the pin' test "${uri#*pinSHA256=}" != "$uri"
    check 'URI endpoint' test "${uri#*@203.0.113.7:}" != "$uri"
    check '@ in a name is percent-encoded in the URI' test "$(hy show 'one@us' | grep -c '^hysteria2://one%40us:')" = 1
    check 'yaml has server and auth' test "$(hy show phone_one --yaml | grep -Ec '^(server: 203.0.113.7:443|auth: phone_one:)')" = 2
    check 'yaml honours --http/--socks' test "$(hy show phone_one --yaml --http 0.0.0.0:9230 --socks 0.0.0.0:8230 | grep -Ec 'listen: 0.0.0.0:(9230|8230)')" = 2
    check 'passwords differ between clients' test "$(jq -r '.clients | [.[]] | unique | length' "$sandbox/etc/hysteria-vps-kit/state.json")" = 4
    check 'config lists every client' test "$(grep -c '^    "' "$sandbox/etc/hysteria-vps-kit/config.yaml")" = 4
    check 'remove' hy remove phone_one
    refuse 'remove twice' hy remove phone_one
    refuse 'show of a removed client' hy show phone_one
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

    # Render failure on remove: fail-closed
    check 'add user_render_fail' hy add user_render_fail
    mkdir -p "$sandbox/etc/hysteria-vps-kit/config.yaml.new"
    refuse 'remove fails when config render fails' hy remove user_render_fail
    rm -rf "$sandbox/etc/hysteria-vps-kit/config.yaml.new"

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

    # Mark status as incomplete and pretend an older kit wrote the state
    jq '.status = "installing" | .version = "0.0.9"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"

    refuse 'normal install refuses incomplete install' install_sandbox
    check 'install --repair succeeds' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --repair
    check 'status is ready after repair' test "$(jq -r .status "$sandbox/etc/hysteria-vps-kit/state.json")" = "ready"
    check 'repair updates state version to the kit version' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = "$(tr -d '[:space:]' < "$project/VERSION")"
    check 'pin preserved after repair' test "$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")" = "$orig_pin"
    check 'obfs password preserved after repair' test "$(jq -r .obfs.password "$sandbox/etc/hysteria-vps-kit/state.json")" = "$orig_obfs"
    check 'certificate preserved after repair' test "$(cat "$sandbox/etc/hysteria-vps-kit/server.crt")" = "$orig_cert"
    check 'client preserved after repair' test "$(hy list)" = "user1"
    check 'ownership recorded' test "$(jq -r '.created_resources | has("user") and has("firewall_rule")' "$sandbox/etc/hysteria-vps-kit/state.json")" = "true"

    # Repair refuses corrupted state
    echo '{corrupt' > "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'repair refuses corrupted JSON state' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --repair

    # Repair without key: refuses without --force-secrets, succeeds with it
    rm -rf "$sandbox"
    new_root
    install_sandbox --first-client user1 > /dev/null
    orig_pin=$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")
    rm -f "$sandbox/etc/hysteria-vps-kit/server.key"
    jq '.status = "installing"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"

    refuse 'repair refuses to regenerate missing key without --force-secrets' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --repair
    check 'pin unchanged after refused repair' test "$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")" = "$orig_pin"
    check 'repair with --force-secrets succeeds' bash "$project/install.sh" --no-service --root "$sandbox" --non-interactive --repair --force-secrets
    check 'pin changed after forced secret regeneration' test "$(jq -r .pin "$sandbox/etc/hysteria-vps-kit/state.json")" != "$orig_pin"
    check 'clients kept after forced secret regeneration' test "$(hy list)" = "user1"
    rm -rf "$sandbox"
}

suite_stagec() {
    printf 'suite: stagec (rotate/backup/restore/logs)\n'
    new_root
    install_sandbox --first-client alice > /dev/null
    local E=$sandbox/etc/hysteria-vps-kit
    local pw_before pw_after pin_before
    pw_before=$(jq -r .clients.alice "$E/state.json")
    pin_before=$(jq -r .pin "$E/state.json")

    # rotate
    refuse 'rotate refuses an unknown client' hy rotate nobody
    hy rotate alice > /dev/null
    check 'rotate keeps the client name' test "$(hy list)" = alice
    pw_after=$(jq -r .clients.alice "$E/state.json")
    check 'rotate changes the password' test "$pw_before" != "$pw_after"
    check 'rotate password is 28 chars' test "${#pw_after}" = 28
    local rendered=$sandbox/rendered.yaml
    check 'config matches state after rotate' bash -c "HVK_ROOT='$sandbox' bash -c \"source '$project/lib/common.sh' && hvk_render_config_to '$rendered'\" && cmp -s '$rendered' '$E/config.yaml'"

    # failed rotate rolls back (mock jq failing on to_entries, as in the render suite)
    mkdir -p "$sandbox/mockbin"
    cat > "$sandbox/mockbin/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [[ $arg != *to_entries* ]] || exit 42
done
exec /usr/bin/jq "$@"
EOF
    chmod +x "$sandbox/mockbin/jq"
    local pw_still=$pw_after
    refuse 'failed rotate rejects the change' env PATH="$sandbox/mockbin:$PATH" HVK_ROOT="$sandbox" bash "$project/hy2-client" rotate alice
    check 'failed rotate preserves the password' test "$(jq -r .clients.alice "$E/state.json")" = "$pw_still"

    # backup
    local bk=$sandbox/kit-backup.tgz
    refuse 'backup refuses a relative path' hy backup relative.tgz
    hy backup "$bk" > /dev/null
    check 'backup file is created' test -s "$bk"
    check 'backup has mode 600' test "$(stat -c %a "$bk")" = 600
    local members
    members=$(tar -tzf "$bk")
    check 'backup contains state.json' grep -qx 'etc/hysteria-vps-kit/state.json' <<< "$members"
    check 'backup contains the TLS key and cert' bash -c "grep -qx 'etc/hysteria-vps-kit/server.key' <<< \"\$0\" && grep -qx 'etc/hysteria-vps-kit/server.crt' <<< \"\$0\"" "$members"
    check 'backup contains the unit and sysctl' bash -c "grep -qx 'etc/systemd/system/hysteria-vps-kit.service' <<< \"\$0\" && grep -qx 'etc/sysctl.d/99-hysteria-vps-kit.conf' <<< \"\$0\"" "$members"
    check 'backup contains the core binary' grep -qx 'opt/hysteria-vps-kit/hysteria' <<< "$members"

    # restore over a damaged installation
    rm -rf "$sandbox/etc/hysteria-vps-kit"
    hy restore "$bk" > /dev/null
    check 'restore recreates state.json' test -s "$E/state.json"
    check 'restore keeps the client' test "$(hy list)" = alice
    check 'restore keeps the pin' test "$(jq -r .pin "$E/state.json")" = "$pin_before"
    check 'restore keeps the rotated password' test "$(jq -r .clients.alice "$E/state.json")" = "$pw_after"

    # restore rejects a foreign tar
    local notbk=$sandbox/not-a-backup.tgz
    tar -czf "$notbk" -C "$sandbox" rendered.yaml
    refuse 'restore rejects a non-kit archive' hy restore "$notbk"
    refuse 'restore rejects a missing file' hy restore "$sandbox/nope.tgz"

    # logs
    refuse 'logs refuses in sandbox mode' hy logs
    rm -rf "$sandbox"
}

suite_update() {
    printf 'suite: update\n'
    new_root
    install_sandbox > /dev/null
    check 'update --check reports up to date' env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --check --no-git

    # Modify unit to simulate outdated unit
    mkdir -p "$sandbox/etc/systemd/system"
    echo "# old unit" > "$sandbox/etc/systemd/system/hysteria-vps-kit.service"

    # Mock older kit version in state
    jq '.version = "0.0.9"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"

    local out
    out=$(env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git)
    check 'update runs without core change message' contains <(printf '%s' "$out") '(no core change)'
    refuse 'update does not claim previous core kept when unchanged' contains <(printf '%s' "$out") 'previous core kept'
    check 'unit was synchronized during update' contains "$sandbox/etc/systemd/system/hysteria-vps-kit.service" 'AmbientCapabilities=CAP_NET_BIND_SERVICE'

    # Test update failure with restart failure: rollback
    jq '.version = "0.0.1"' "$sandbox/etc/hysteria-vps-kit/state.json" > "$sandbox/etc/hysteria-vps-kit/state.json.tmp"
    mv "$sandbox/etc/hysteria-vps-kit/state.json.tmp" "$sandbox/etc/hysteria-vps-kit/state.json"
    refuse 'update with restart failure fails' env HVK_ROOT="$sandbox" HVK_NO_GIT=1 HVK_MOCK_RESTART_FAIL=1 bash "$project/update.sh" --no-git
    check 'update rollback restored state version' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = "0.0.1"

    # Blocker 1 regression test: failure after state update (render failure)
    local E="$sandbox/etc/hysteria-vps-kit"
    jq '.version = "0.0.9"' "$E/state.json" > "$sandbox/y" && mv "$sandbox/y" "$E/state.json"
    mkdir -p "$E/config.yaml.new"
    refuse 'update fails when render fails' env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git
    check 'backup directory preserved after failed update' test "$(find "$E" -name '.backup-update.*' | wc -l)" -ge 1
    check 'state rolled back after failed render' test "$(jq -r .version "$E/state.json")" = "0.0.9"
    rm -rf "$E/config.yaml.new"
    check 'subsequent update detects update available' test "$(env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git --check >/dev/null 2>&1; echo $?)" = 10
    refuse 'subsequent update does not claim up to date' contains <(env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git --check 2>&1 || true) 'up to date'

    mkdir -p "$E/.backup-update.old"
    touch -d '10 days ago' "$E/.backup-update.old"
    env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git >/dev/null
    refuse 'old backup directory pruned after successful update' test -d "$E/.backup-update.old"

    # Incomplete installation must not be silently completed by update.sh
    jq '.status = "installing"' "$E/state.json" > "$sandbox/y" && mv "$sandbox/y" "$E/state.json"
    refuse 'update refuses incomplete installation' env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git
    check 'status unchanged after refused update' test "$(jq -r .status "$E/state.json")" = "installing"
    rm -rf "$sandbox"
}

suite_uninstall() {
    printf 'suite: uninstall\n'
    new_root
    install_sandbox > /dev/null
    check 'uninstall --keep-config' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --keep-config --yes
    check 'state kept' test -f "$sandbox/etc/hysteria-vps-kit/state.json"
    check 'state marked uninstalled' test "$(jq -r .status "$sandbox/etc/hysteria-vps-kit/state.json")" = uninstalled
    local pw_before
    pw_before=$(jq -r '.clients["main-user"]' "$sandbox/etc/hysteria-vps-kit/state.json")
    refuse 'update refuses an uninstalled state' env HVK_ROOT="$sandbox" HVK_NO_GIT=1 bash "$project/update.sh" --no-git
    check 'install after --keep-config restores the installation' install_sandbox
    check 'restored status is ready' test "$(jq -r .status "$sandbox/etc/hysteria-vps-kit/state.json")" = ready
    check 'restored install keeps client secrets' test "$(jq -r '.clients["main-user"]' "$sandbox/etc/hysteria-vps-kit/state.json")" = "$pw_before"
    check 'restored install passes doctor' hy doctor
    check 'uninstall --keep-config again' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --keep-config --yes
    refuse 'core removed' test -e "$sandbox/opt/hysteria-vps-kit"
    refuse 'command link removed' test -e "$sandbox/usr/local/bin/hy2-client"
    refuse 'sysctl file removed' test -e "$sandbox/etc/sysctl.d/99-hysteria-vps-kit.conf"
    check 'uninstall --help needs no state' env HVK_ROOT="$sandbox/none" bash "$project/uninstall.sh" --help
    echo '{broken' > "$sandbox/etc/hysteria-vps-kit/state.json"
    check 'uninstall works with a damaged state.json' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    refuse 'damaged install fully removed' test -e "$sandbox/etc/hysteria-vps-kit"
    install_sandbox > /dev/null
    check 'full uninstall' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    refuse 'config dir removed' test -e "$sandbox/etc/hysteria-vps-kit"
    refuse 'uninstall twice' env HVK_ROOT="$sandbox" bash "$project/uninstall.sh" --yes
    rm -rf "$sandbox"
}

suite_doctor() {
    printf 'suite: doctor\n'
    new_root
    install_sandbox --first-client main-user > /dev/null
    check 'doctor succeeds on a healthy sandbox' hy doctor
    check 'doctor reports no failures' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -c '^\\[FAIL\\]' | grep -qx 0"
    check 'doctor skips system checks in sandbox' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q '^\\[SKIP\\] service'"
    local secret
    secret=$(jq -r '.clients["main-user"]' "$sandbox/etc/hysteria-vps-kit/state.json")
    refuse 'doctor does not print secrets' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q '$secret'"

    # Defect tests
    # 1. missing key
    local key_file="$sandbox/etc/hysteria-vps-kit/server.key"
    local key_bak="$sandbox/etc/hysteria-vps-kit/server.key.bak"
    mv "$key_file" "$key_bak"
    refuse 'doctor fails without the key' hy doctor
    check 'doctor names the key problem' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q 'certificate/key'"
    mv "$key_bak" "$key_file"

    # 2. modified pin in state
    local state_file="$sandbox/etc/hysteria-vps-kit/state.json"
    local orig_pin
    orig_pin=$(jq -r .pin "$state_file")
    jq '.pin = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    refuse 'doctor fails on mismatched pin' hy doctor
    jq --arg p "$orig_pin" '.pin = $p' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"

    # 3. modified config.yaml (extra line)
    local cfg_file="$sandbox/etc/hysteria-vps-kit/config.yaml"
    echo "# tampering" >> "$cfg_file"
    refuse 'doctor fails on altered config.yaml' hy doctor
    sed -i '/# tampering/d' "$cfg_file"
    check 'doctor succeeds after restoring config.yaml' hy doctor

    # 4. 0 clients in state -> WARN and exit code 0
    jq '.clients = {}' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    HVK_ROOT=$sandbox bash -c "source '$project/lib/common.sh'; hvk_render_config"
    check 'doctor succeeds with 0 clients (warn only)' hy doctor
    check 'doctor reports warning for 0 clients' bash -c "HVK_ROOT=$sandbox bash '$project/hy2-client' doctor | grep -q '^\\[WARN\\] clients: 0 configured'"
    cat > "$sandbox/opt/hysteria-vps-kit/hysteria" <<'EOF'
#!/usr/bin/env bash
printf '2.13.0\n'
exit 1
EOF
    chmod +x "$sandbox/opt/hysteria-vps-kit/hysteria"
    refuse 'doctor rejects failed core version command' hy doctor
    mkdir -p "$sandbox/mockbin"
    cat > "$sandbox/mockbin/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'Status: active\n443/udp DENY IN Anywhere\n'
EOF
    chmod +x "$sandbox/mockbin/ufw"
    cat > "$sandbox/mockbin/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'Status: active\n'
for ((i=0; i<20000; i++)); do printf '443/udp DENY IN Anywhere\n'; done
EOF
    # shellcheck disable=SC2016
    check 'active UFW with long output is detected' env PATH="$sandbox/mockbin:$PATH" bash -c 'set -o pipefail; source "$1/lib/common.sh"; hvk_ufw_is_active' _ "$project"
    cat > "$sandbox/mockbin/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'Status: active\n443/udp DENY IN Anywhere\n'
EOF
    # shellcheck disable=SC2016
    refuse 'denied UFW port is not allowed' env PATH="$sandbox/mockbin:$PATH" bash -c 'source "$1/lib/common.sh"; hvk_ufw_allows_udp 443' _ "$project"
    sed -i 's/DENY/ALLOW/' "$sandbox/mockbin/ufw"
    # shellcheck disable=SC2016
    check 'allowed UFW port is recognized' env PATH="$sandbox/mockbin:$PATH" bash -c 'source "$1/lib/common.sh"; hvk_ufw_allows_udp 443' _ "$project"
    printf 'net.core.rmem_max = 1\nnet.core.wmem_max = 1\n' > "$sandbox/sysctl.conf"
    # shellcheck disable=SC2016
    refuse 'invalid persistent sysctl is rejected' bash -c 'source "$1/lib/common.sh"; hvk_sysctl_file_valid "$2"' _ "$project" "$sandbox/sysctl.conf"
    printf 'net.core.rmem_max = 16000000\nnet.core.wmem_max = 16000000\n' > "$sandbox/sysctl.conf"
    # shellcheck disable=SC2016
    check 'larger persistent sysctl values are accepted' bash -c 'source "$1/lib/common.sh"; hvk_sysctl_file_valid "$2"' _ "$project" "$sandbox/sysctl.conf"
    # ufw rule table: first matching incoming rule wins, protocol-less and range rules count
    ufw_rule() { # ufw_rule PORT -> verdict for the mocked table in $sandbox/mockbin/ufw
        # shellcheck disable=SC2016
        env PATH="$sandbox/mockbin:$PATH" bash -c 'source "$1/lib/common.sh"; hvk_ufw_udp_rule "$2"' _ "$project" "$1"
    }
    cat > "$sandbox/mockbin/ufw" <<'EOF'
#!/usr/bin/env bash
cat <<'TABLE'
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
47069                      ALLOW IN    Anywhere
40000:40100/udp            ALLOW IN    Anywhere
5000,5001/udp              ALLOW IN    Anywhere
8443/udp                   DENY IN     Anywhere
8443/udp                   ALLOW IN    Anywhere
9000/udp                   ALLOW IN    10.0.0.0/8
7000/udp                   ALLOW OUT   Anywhere
53/tcp                     ALLOW IN    Anywhere
443/udp (v6)               ALLOW IN    Anywhere (v6)
TABLE
EOF
    check 'ufw: protocol-less rule allows udp' test "$(ufw_rule 47069)" = allow
    check 'ufw: port range rule' test "$(ufw_rule 40050)" = allow
    check 'ufw: port list rule' test "$(ufw_rule 5001)" = allow
    check 'ufw: first matching rule wins (deny before allow)' test "$(ufw_rule 8443)" = deny
    check 'ufw: restricted source does not count' test "$(ufw_rule 9000)" = none
    check 'ufw: outgoing rule does not count' test "$(ufw_rule 7000)" = none
    check 'ufw: tcp-only rule does not count' test "$(ufw_rule 53)" = none
    check 'ufw: v6 row is understood' test "$(ufw_rule 443)" = allow
    check 'ufw: unknown port has no rule' test "$(ufw_rule 12345)" = none
    printf 'net.core.rmem_max = 7500000\nnet.core.wmem_max = 7500000\n' > "$sandbox/sysctl.conf"
    # shellcheck disable=SC2016
    check 'expected persistent sysctl is accepted' bash -c 'source "$1/lib/common.sh"; hvk_sysctl_file_valid "$2"' _ "$project" "$sandbox/sysctl.conf"
    rm -rf "$sandbox"
}

suite_ref() {
    printf 'suite: ref\n'
    command -v git > /dev/null || { ok 'git missing: ref suite skipped'; return 0; }
    local o src seed g tag1 tag2
    o=$(mktemp -d); seed=$o/origin; mkdir -p "$seed"
    g=(git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -C "$seed")
    git -C "$project" ls-files -z | tar --null -T - -cf - | tar -xf - -C "$seed"
    "${g[@]}" init -q -b master && "${g[@]}" add -A && "${g[@]}" commit -q -m one && "${g[@]}" tag t1
    printf '9.9.9\n' > "$seed/VERSION"
    "${g[@]}" commit -q -a -m two && "${g[@]}" tag t2
    tag1=$("${g[@]}" rev-parse t1); tag2=$("${g[@]}" rev-parse t2)
    local want_old
    want_old=$(git -C "$seed" show t1:VERSION | tr -d '[:space:]')

    # shellcheck disable=SC2329  # called through check/refuse
    bootstrap() { # bootstrap SRC [REF]: install.sh piped into bash, like curl | bash
        HVK_SRC=$1 HVK_REPO="file://$seed" HVK_REF=${2:-} bash -s -- --no-service --root "$sandbox" --non-interactive --endpoint 203.0.113.7 < "$project/install.sh"
    }
    src=$o/src
    new_root
    check 'bootstrap with HVK_REF installs the pinned tag' bootstrap "$src" t1
    check 'clone is on the pinned commit' test "$(git -C "$src" rev-parse HEAD)" = "$tag1"
    check 'installed kit version comes from the pinned tag' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = "$want_old"
    refuse 'update.sh --check reports the pin when behind it' env HVK_ROOT="$sandbox" HVK_REF=t2 bash "$src/update.sh" --check
    check 'update.sh with HVK_REF moves the clone to the new tag' env HVK_ROOT="$sandbox" HVK_REF=t2 bash "$src/update.sh"
    check 'clone follows the new tag' test "$(git -C "$src" rev-parse HEAD)" = "$tag2"
    check 'state has the new kit version' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = 9.9.9
    check 'update.sh --check is clean at the pin' env HVK_ROOT="$sandbox" HVK_REF=t2 bash "$src/update.sh" --check
    refuse 'unknown HVK_REF is refused' env HVK_ROOT="$sandbox" HVK_REF=nope bash "$src/update.sh" --check
    refuse 'malformed HVK_REF is refused' env HVK_ROOT="$sandbox" 'HVK_REF=a..b' bash "$src/update.sh" --check
    refuse 'malformed HVK_REF is refused by the bootstrap' bootstrap "$o/src-bad" 'x;y'
    check 'update.sh without HVK_REF returns the clone to master' env HVK_ROOT="$sandbox" bash "$src/update.sh"
    check 'clone is back on a branch' git -C "$src" symbolic-ref -q HEAD
    rm -rf "$sandbox"; new_root
    check 'bootstrap without HVK_REF installs master' bootstrap "$o/src2"
    check 'master carries the newest version' test "$(jq -r .version "$sandbox/etc/hysteria-vps-kit/state.json")" = 9.9.9
    rm -rf "$sandbox" "$o"
}

suites=(validation install render clients locking repair stagec update uninstall doctor ref)
if [[ ${1:-} == --suite ]]; then suites=("${2:?--suite needs a name}"); fi
for suite in "${suites[@]}"; do
    declare -F "suite_$suite" > /dev/null || { printf 'error: unknown suite: %s\n' "$suite" >&2; exit 2; }
    "suite_$suite"
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
