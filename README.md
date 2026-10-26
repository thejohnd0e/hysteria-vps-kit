# Hysteria VPS Kit

Hysteria2 (QUIC over UDP, Salamander obfuscation) server installer and the `hy2-client` command to
manage identities. A small sibling of [xray-vps-kit](https://github.com/thejohnd0e/xray-vps-kit) and
[awg-vps-kit](https://github.com/thejohnd0e/awg-vps-kit): same idea, same commands style.

Why it exists: where inbound TCP from foreign VPS ranges is throttled, a UDP transport can still run at full
speed. Measured through one home ISP on 2026-10-26: VLESS/TCP to a VPS gave about 2 Mbit/s, Hysteria2 to the same
VPS gave 110-170 Mbit/s. That can change at any time; use it as one more channel, not as the only one.

## Requirements

| | Minimum | Notes |
|---|---|---|
| OS | **Debian 12 or 13**, Ubuntu 22.04 / 24.04 | systemd and `apt` are required |
| CPU | amd64 or arm64 | arm64 is pinned but not tested natively |
| Network | public IPv4, **UDP** port open | default UDP 443; open it in the provider's firewall too |
| Memory | about 100 MB free | the service runs with the core only |
| Access | root | |

Missing `curl`, `jq`, `openssl`, `qrencode` and CA certificates are installed through `apt` (`--no-remove`).

## Install

Run as root on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/hysteria-vps-kit/master/install.sh | bash -s -- --first-client one_us
```

The script puts the kit in `/opt/hysteria-vps-kit-src`, downloads the pinned Hysteria2 core, **verifies its
SHA-256**, creates a system user, a self-signed certificate (10 years), the state in
`/etc/hysteria-vps-kit/` and the service `hysteria-vps-kit`, and prints the first client's URI and QR code.
If `ufw` is active it opens the port (`ufw allow PORT/udp`) and records that, so uninstall closes it again.
Nothing else in your firewall is touched.

| Option | Default | Meaning |
|---|---|---|
| `--port PORT` | `443` | UDP listen port. If it is busy (AmneziaWG often uses 443/udp) the installer stops and asks for another |
| `--sni DNS` | `www.bing.com` | certificate name and the site the server impersonates for unauthenticated probes |
| `--first-client NAME` | `main-user` | first identity |
| `--no-first-client` | | do not create an identity |
| `--endpoint IPV4/HOST` | detected | address written into client URIs |
| `--no-obfs` | | turn Salamander obfuscation off (not recommended) |
| `--binary FILE` | download | use a local core binary (the SHA-256 is still checked) |
| `--non-interactive` | | use flags and defaults without questions |

## Clients

```bash
hy2-client add phone          # new identity with its own password, prints the URI
hy2-client list
hy2-client show phone         # hysteria2:// URI
hy2-client show phone --qr    # QR code
hy2-client show phone --yaml --http 0.0.0.0:9230 --socks 0.0.0.0:8230   # client.yaml for the Hysteria2 client
hy2-client remove phone
hy2-client version
```

Names: letters, digits, `_ . @ -`, up to 32, starting with a letter or digit.
Adding or removing an identity **restarts the service** (Hysteria2 has no hot reload); connected clients notice
after the QUIC idle timeout and reconnect on their own, measured about 30 seconds of interruption.

The URI looks like
`hysteria2://NAME:PASSWORD@HOST:PORT/?sni=...&insecure=1&pinSHA256=...&obfs=salamander&obfs-password=...#NAME`.
`insecure=1` only turns off chain validation of the self-signed certificate; the client still checks the
**pinned SHA-256 fingerprint**, so a different certificate is rejected.

To turn an identity into a local HTTP/SOCKS5 proxy (for a router or a LAN), run the Hysteria2 client with the
`--yaml` output: `hysteria client -c client.yaml`. A container is as good as a service; use host networking if
the Docker bridge drops the QUIC handshake.

## Update and uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/thejohnd0e/hysteria-vps-kit/master/update.sh | bash   # or: bash /opt/hysteria-vps-kit-src/update.sh
bash /opt/hysteria-vps-kit-src/update.sh --check     # exit 0 = up to date, 10 = update available
bash /opt/hysteria-vps-kit-src/uninstall.sh          # remove everything; --keep-config keeps /etc/hysteria-vps-kit; --yes does not ask
```

An update fast-forwards the clone, downloads a new core if the kit pins one (SHA-256 checked, the old binary
is kept as `hysteria.previous`), re-renders the config from `state.json` and restarts. Clients, certificate,
obfuscation password and port are kept.

## Files

| Path | Content |
|---|---|
| `/etc/hysteria-vps-kit/state.json` | port, SNI, endpoint, certificate pin, obfuscation password, identities (root only) |
| `/etc/hysteria-vps-kit/config.yaml` | rendered server config; edit `state.json` and run `hy2-client add`/`remove`, not this file |
| `/etc/hysteria-vps-kit/server.{crt,key}` | self-signed certificate |
| `/opt/hysteria-vps-kit/hysteria` | pinned core binary |
| `/etc/systemd/system/hysteria-vps-kit.service` | the unit (sandboxed: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`) |

## Tests

```bash
bash tests/lint.sh     # bash -n + ShellCheck
bash tests/run.sh      # sandbox suites (install, render, clients, uninstall): no systemd, no network
```

The sandbox suites run in CI. Verified by hand on a Debian 13 VM: real install with download and hash check,
traffic through a local Hysteria2 client (SOCKS), add/remove of identities, recovery after a server restart,
`update.sh --check` and the update path with an older core, full uninstall. **Not tested on a real host yet:**
the `ufw` branch, arm64, Ubuntu images (only in CI sandbox), IPv6-only hosts.

## Limits

- IPv4 only; the endpoint in URIs is one address.
- One UDP port, no port hopping, no bandwidth limits in the config (Hysteria2's congestion control is the default).
- If the network starts to throttle or block QUIC-like UDP, this channel stops working like any other.
  Seen once: after a long full-speed test the data path stalled for a while while the handshake still passed.

## License

MIT
