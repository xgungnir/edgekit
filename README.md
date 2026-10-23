# edgekit

An opinionated Bash script for personal use on Debian servers.
It installs VLESS + REALITY/Vision and TUIC v5, with certificate renewal.
REALITY uses the server's own domain and Nginx HTTPS site as its target.

Before starting, prepare:

- A fresh Debian 12/13 server: systemd, public IPv4, and root access.
- A Cloudflare-hosted domain with a DNS-only A record pointing to the server.
- A Cloudflare API token with DNS edit and Zone read access for certificates.
- `curl` and CA certificates; TCP 443 and UDP 8443 open in the cloud firewall.

## Install

Run as root:

```bash
release_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/xgungnir/edgekit/releases/latest) && curl -fsSL "https://raw.githubusercontent.com/xgungnir/edgekit/${release_url##*/}/setup.sh" -o /root/setup.sh && chmod 700 /root/setup.sh && /root/setup.sh
```

Without `/root/.ek.env`, the first run creates an empty template and exits.
Fill in `DOMAIN` and `CF_ZONE_TOKEN`, then run `ek`,
select `1. Install / Retry installation`, and confirm.
Other fields can stay blank to generate credentials automatically.

## Manage

Run `ek` to open the management menu, or `ek --help` to list commands.
