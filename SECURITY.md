# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub:
**Security → Report a vulnerability** on <https://github.com/thejohnd0e/hysteria-vps-kit/security>.
Do not open a public issue for them. Include the affected version (`hy2-client version`), the
operating system, and the steps to reproduce. This is a single-maintainer project; expect an answer
within a few days.

## Scope

- The scripts in this repository (`install.sh`, `update.sh`, `uninstall.sh`, `hy2-client`, `lib/`).
- How the kit handles secrets: client passwords, the Salamander password, the TLS key and `state.json`
  (mode 0600/0640, never printed by `doctor`).
- Integrity of the downloaded Hysteria2 core (pinned version, SHA-256 checked before install).

Out of scope: vulnerabilities in Hysteria2 itself (report them upstream) and in the operating system.

## Trust notes

- The certificate is self-signed and pinned by SHA-256 (`pinSHA256`); there is no certificate authority.
- `install.sh` and `update.sh` run from a git clone of `master` in `/opt/hysteria-vps-kit-src`; whoever can
  push to that branch can change what runs as root on the next update. Review changes before updating.
