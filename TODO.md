# TODO

- [ ] First CI run: confirm lint and the sandbox suites are green on ubuntu-22.04 and 24.04.
- [ ] Test the ufw branch and arm64 on real hosts.
- [ ] Decide whether to migrate the four hand-installed servers (EE, TR, US, KZ) to the kit (they use one shared password and `/etc/hysteria`).
- [ ] Optional: hot reload for identities through `auth: type: http`, to avoid the ~30 s interruption on add/remove.
- [ ] Optional: `block-ping`-style helpers are out of scope here; use the awg-vps-kit / xray-vps-kit one.
