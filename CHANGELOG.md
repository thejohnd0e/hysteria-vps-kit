# Changelog

## 0.2.3 - unreleased
- Client names may no longer contain a dot: the core splits `userpass` keys on dots, so `user.name` or an
  e-mail address produced a config it refuses to load (found by the new real-core test). `doctor` reports
  existing names with dots as a failure.
- CI feeds the rendered configs to the real pinned core (`tests/core-config.sh`).

## 0.2.2 - 2026-11-08
- `uninstall.sh --keep-config` marks the state `uninstalled`; `install.sh` then restores the installation
  with the same secrets, `update.sh` refuses to run on it.
- `uninstall.sh` works with a damaged `state.json`; `--help` needs no root.
- One ufw rule parser for installer and `doctor`: rules without protocol, port ranges and lists, first-match
  order, and deny rules are understood.
- The UDP buffer sysctl never lowers a larger value that is already set.
- Hysteria2 cannot start without identities: with none (install `--no-first-client`, removal of the last
  identity) the service stays stopped; `hy2-client add` starts it, `doctor` warns instead of failing.
- Endpoint detection tries four services, then the route source address.
- Secrets are no longer passed in `jq` arguments; `hvk_rand` is bounded.
- `update.sh` verifies the new core before it takes the backup and cleans up on failure.
- Unreadable `state.json` gives a permission error instead of "invalid JSON".

## 0.2.1 - 2026-11-04
- `doctor` fixes (UFW active detection, core exit status, sysctl values).

## 0.2.0 - 2026-11-04
- Reliability: exclusive lock, atomic state/config with rollback, fail-closed `remove`, `install.sh --repair`,
  ownership tracking, stricter validation. Added `hy2-client doctor`.

## 0.1.1 - 2026-10-26
- UDP buffer sysctl for QUIC.

## 0.1.0 - 2026-10-26
- First release: installer, `hy2-client`, update, uninstall, sandbox tests, CI.
