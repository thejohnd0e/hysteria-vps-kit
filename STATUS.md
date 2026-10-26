# Status

- **0.1.0 (2026-10-26):** installer, `hy2-client` (add/remove/list/show/version), `update.sh` (+`--check`), `uninstall.sh`, sandbox tests (54 checks), ShellCheck-clean, CI workflow.
- Verified on the Debian 13 lab VM: real install, SHA-256 check, traffic via a local client, add/remove, recovery after restart (~30 s), update path with an older core, uninstall.
- Not verified: ufw branch, arm64, Ubuntu on a real host, IPv6. CI is green on the first run (lint, sandbox suites on ubuntu-22.04 and 24.04).
- Already deployed by hand (older script, not this kit) on four servers; see the user's `my-vps-servers` notes. Migrating them to the kit is not done.
