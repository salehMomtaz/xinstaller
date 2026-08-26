# xinstaller

Hardened installer for a production 3x-ui + Nginx + Let's Encrypt setup on
Ubuntu. Interactive, single-purpose, and opinionated: it wires 3x-ui behind an
official Nginx reverse proxy with a real TLS certificate and a decoy website,
using the traditional local-TCP-port transport that survives restarts cleanly.

This repository is the canonical home of the script. Versioning is integer
(`v1`, `v2`, `v3`, ...); see [VERSIONING.md](VERSIONING.md).

## What it does

- Installs and configures 3x-ui, Nginx (from nginx.org), and Certbot.
- Terminates TLS at Nginx and forwards the Xray traffic to a local loopback TCP
  port (`proxy_pass http://127.0.0.1:<port>`), matching the original
  GFW4Fun/x-ui-pro.sh transport design.
- Serves an admin panel, `/sub/` and `/json/` subscription paths, and the Xray
  traffic on their own loopback ports.
- Installs a per-domain decoy website (auto-selected template) only when the
  web root is empty; otherwise leaves existing content alone.
- Issues certificates via Certbot:
  - HTTP-01 (webroot) for standard single domains.
  - DNS-01 via Cloudflare API for automatic wildcards.
  - DNS-01 manual/universal with propagation-aware validation and retries.
- Installs a daily certificate-renewal cron and a self-update helper.
- Supports clean interactive uninstall of per-domain and shared artifacts,
  restoring the original Nginx configuration.

## Requirements

- Ubuntu 22.04, 24.04, or 26.04 (jammy / noble / oracular).
- Root access (the script re-executes itself via sudo if needed).
- A domain whose DNS you control.

## Usage

```bash
sudo bash xinstaller.sh
```

Follow the prompts:

1. Install / Reconfigure, or Uninstall.
2. Enter the subdomain (for example `sub.domain.tld`).
3. Choose the SSL method when no existing certificate is found:
   - HTTP-01 (standard, DNS must point at this server)
   - DNS-01 Cloudflare API (automatic wildcard)
   - DNS-01 manual / universal (prompts for the TXT record, wildcard capable)
4. After install, in the 3x-ui panel set each Xray inbound `Listen` to
   `127.0.0.1` and its `Port` equal to the `<port>` segment of the public URL
   (`/<port>/<path>`).

## Post-install

- Panel and subscription URLs are printed on the final "save this screen"
  output, including a random base path for the admin panel.
- Certificate renewal runs daily from `/etc/cron.d/xinstaller`, tolerating
  transient DNS failures.

## Versioning

Integer releases. The current version is stored in a single constant in the
script:

```bash
readonly XINSTALLER_VERSION="2"
```

Every release increments that value, updates the header changelog block, is
committed, and is tagged `v<N>`. See [VERSIONING.md](VERSIONING.md) for the
rules and rationale.