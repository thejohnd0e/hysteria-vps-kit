# Decisions

- **2026-10-26 - Lean kit, not a copy of xray-vps-kit's framework.** No transactions/snapshots/ownership manifests; plain state in `state.json`, config rendered from it.
- **2026-10-26 - `userpass` auth, one password per identity.** Clients are added and removed with a service restart (no hot reload; clients reconnect after about 30 s).
- **2026-10-26 - Self-signed certificate pinned by SHA-256 (`insecure=1` + `pinSHA256`).** No domain or ACME needed.
- **2026-10-26 - Salamander obfuscation on by default.** A QUIC-looking handshake alone stalled on one ISP; obfuscation is cheap.
- **2026-10-26 - Pinned core v2.13.0 with SHA-256 for amd64 and arm64.** Taken from the release `hashes.txt`; the upstream repo moved from `apernet` to `HyNetworks`.
