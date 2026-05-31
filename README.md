# vps-subdomain-mcp

Podman-based VPS environment for Claude.ai seminar participants.  
Each participant gets a Debian container reachable via a subdomain, with an MCP server that lets Claude.ai manage files and run shell commands.

## Architecture

```
Internet
  │
  ├─ :53   BIND9 (wildcard DNS: *.example.com → server IP)
  │
  ├─ :443  vps-proxy (SNI passthrough, PROXY protocol v1)
  │            └─ container :443  nginx (TLS termination)
  │                                  └─ 127.0.0.1:3000  Node.js MCP server
  │
  └─ :80   vps-proxy-http (HTTP reverse proxy)
               └─ container :80  nginx
```

- **BIND9** serves the base domain as a primary authoritative server with a wildcard A record (`*.example.com → server IP`).
- **vps-proxy** reads the TLS ClientHello SNI, maps `alice.example.com` → container `alice-web`, and TCP-proxies without decryption.  PROXY protocol v1 is injected so nginx sees the real client IP.
- **vps-proxy-http** reads the HTTP `Host` header and reverse-proxies to the matching container.
- **list-containers** (setuid-root) queries the Podman socket to build the container→IP routing table used by both proxies.
- Each container runs systemd, nginx, Postfix (nullclient), and the MCP server.

## Directory layout

```
proxy/
  cmd/list-containers/   setuid-root binary — container name/IP discovery
  cmd/vps-proxy/         TLS SNI passthrough proxy (port 443)
  cmd/vps-proxy-http/    HTTP reverse proxy (port 80)
  mapping/               hostname → container-name mapping
  routes/                live routing table (refreshed every 5 s)
  sni/                   TLS ClientHello SNI parser
container/
  Containerfile          debian:bookworm-slim + systemd + nginx + Node.js 20
  nginx/vps-mcp.conf     nginx template (server_name set by init)
  mcp/index.mjs          MCP server (OAuth 2.1, exec_command, read_file, write_file)
  mcp/package.json
  systemd/mcp-server.service
  systemd/vps-mcp-init.sh   first-boot init (run via podman exec)
  systemd/certbot-deploy.sh renewal deploy hook
host/
  bind/zone.tmpl                  BIND zone template (wildcard A record)
  bind/named.conf.local.tmpl      BIND local config template
  systemd/vps-proxy.service       proxy unit (reads DOMAIN from /etc/vps-mcp/host.env)
  systemd/vps-proxy-http.service
  nftables/vps-mcp.nft            OUTPUT restriction for non-root users
Makefile
```

## Prerequisites

- Podman (rootful)
- Go 1.21+
- `make`

## Installation

Run once as root on the host, substituting the server's public IP and base domain:

```sh
make 203.0.113.1__example.com.setupdone
```

This:
1. Applies all pending OS updates (`dnf upgrade` / `apt upgrade`) so a fresh VPS starts current
2. Sets hostname to `example.com` and writes `/etc/vps-mcp/host.env` (`DOMAIN`, `IP`)
3. Installs BIND9, writes a wildcard zone for `example.com` (with DKIM/SPF/DMARC records), starts `named`
4. Configures DKIM signing (`opendkim`) and a relay-only `postfix` so containers can send mail
5. Builds the container image (`vps-mcp:latest`) and the Go proxy binaries (`list-containers`, `vps-proxy`, `vps-proxy-http` in `/usr/local/sbin`)
6. Installs the proxy socket/service units (`vps-proxy{80,443}`) and nftables rules, then enables + starts them
7. Enables unattended security updates (`dnf-automatic` / `unattended-upgrades`) and a weekly reboot (`vps-mcp-reboot.timer`, Sunday ~04:00); `podman-restart.service` brings `--restart=always` containers back up after each reboot

After setup, the domain and IP are read from `/etc/vps-mcp/host.env` automatically — no need to pass `DOMAIN=` for subsequent commands.

> **Long-lived containers**: seminar containers run for weeks, so they receive Debian security updates automatically via `unattended-upgrades`. They are not rebooted individually — the host's weekly reboot plus `--restart=always` refreshes them.

> **DNS delegation**: point your registrar's NS records for `example.com` to this server's IP before running setup, or update them afterwards.

## Creating a VPS container

```sh
make alice__alice@gmail.com.done
```

This:
1. Runs `podman run` with `SUBDOMAIN=alice.example.com`, `MAIL_DOMAIN=alice.example.com`, and `NOTIFY_EMAIL=alice@gmail.com`
2. Waits for the proxy to route the HTTP-01 ACME challenge path to the new container
3. Runs `podman exec alice-web /usr/local/bin/vps-mcp-init.sh`, which:
   - Writes `/etc/vps-mcp-env`
   - Generates `/etc/mcp-server/secret` (`client_secret`, 16 hex chars) and `/etc/mcp-server/token`
   - Configures Postfix `myhostname`/`myorigin` to `alice.example.com`
   - Substitutes `server_name` in the nginx config and reloads nginx
   - Obtains a Let's Encrypt certificate via `certbot certonly --webroot`
   - Switches nginx to the live certificate
   - Runs `systemctl enable --now mcp-server`
   - Sends a creation notification email to `NOTIFY_EMAIL` from `noreply@alice.example.com`
4. Creates `alice__alice@gmail.com.done` to record completion

The `client_secret` is printed to the console during init.

To create a container for the **parent domain** itself (no subdomain prefix):

```sh
make default__admin@gmail.com.done
```

This works identically, but `SUBDOMAIN=example.com` and `MAIL_DOMAIN=default.example.com`.

List running containers:

```sh
make list
```

Delete a container (manual):

```sh
podman stop alice-web && podman rm alice-web
rm -f alice__alice@gmail.com.done
```

## MCP connector setup

After the container is created:

1. The creation notification email arrives at `NOTIFY_EMAIL` (confirms the mail path works).
2. Add the MCP connector in Claude.ai with the SSE URL:
   ```
   https://alice.example.com/mcp/sse
   ```
3. Claude.ai opens the OAuth authorization page. Enter the `client_secret` printed during container creation.
4. A token-issuance notification email is sent from `noreply@alice.example.com` to `NOTIFY_EMAIL`.
5. Claude.ai connects and the three tools become available: `exec_command`, `read_file`, `write_file`.

The `client_secret` and the raw token are each consumed on first use; only a SHA-256 hash of the token is retained on disk for subsequent Bearer authentication.

## Security notes

- The SNI proxy never decrypts TLS traffic.
- The PROXY protocol header is generated from `conn.RemoteAddr()` only; client-supplied PROXY headers are rejected by the SNI check (`0x16` byte).
- `set_real_ip_from` is scoped to the single gateway IP (`10.89.0.1`), not the whole subnet.
- The `/mcp/token` endpoint is restricted to Anthropic's IP range (`160.79.104.0/21`) at the nginx layer so only Claude.ai can obtain tokens.
- The `client_secret` file is deleted after first use; only a SHA-256 hash of the issued token is retained on disk.
- The MCP server listens on `127.0.0.1:3000` only.
- `vps-mcp.nft` blocks new outbound connections from non-root host users; established/related traffic is always allowed.

## License

MIT — see [LICENSE](LICENSE).

---

*This code and documentation were created with [Claude](https://claude.ai/) (Sonnet 4.6 and Opus 4.8).*
