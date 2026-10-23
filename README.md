# edgekit

A single Bash script for Debian 12/13 with systemd. It sets up Xray REALITY/Vision, Nginx HTTPS behind Xray, sing-box TUIC v5, and automatic certificate renewal.

## Install

Download a released `setup.sh` to `/root/setup.sh` and run it as root. Keep HTTPS certificate verification enabled when downloading.

```bash
release_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/xgungnir/edgekit/releases/latest) && curl -fsSL "https://raw.githubusercontent.com/xgungnir/edgekit/${release_url##*/}/setup.sh" -o /root/setup.sh && chmod 700 /root/setup.sh && /root/setup.sh
```

The first run installs the `ek` command at `/usr/bin/ek`. If `/root/.ek.env` is missing, it creates an empty template with mode `0600` and exits. Fill in `DOMAIN` and `CF_ZONE_TOKEN` in `/root/.ek.env`, then run `ek`, select `1. Install / Retry installation`, and confirm. Leave the other fields blank to generate credentials automatically.

Use a Cloudflare DNS-only A record pointing to the server's public IPv4 address. Allow TCP 443 and UDP 8443 through your cloud firewall.

During installation, the script downloads `misc/html.zip` from this repository's `master` branch and deploys its contents as the Nginx static site behind Xray. No local copy of the ZIP is required.

[.ek.env.example](.ek.env.example) provides the same empty template for reference. The template is built into the script, so you do not need to download the example file. To use a different input file, run `/root/setup.sh install --env FILE` and give that file mode `0600`.

## Manage

Run `ek` to open the menu, or use a command directly:

```bash
ek status
ek renew
ek update-xray stable
ek update-sing-box
ek update-tls
ek tune-network
ek ssh-guard install
ek uninstall
```

Daily certificate checks run at 01:30, using the server's local time. Management and renewal work independently of the original input file and repository.

Network tuning and SSH password protection are enabled only when you explicitly select them. Uninstalling edgekit keeps these host settings, installed base tools, the isolated TLS runtime, and the Nginx mainline APT repository. Both bootstrap cleanup and a full uninstall remove `/root/.ek.env`; input files at other paths are left in place. Menu option 5 is reserved for future edgekit updates.
