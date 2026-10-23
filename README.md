# edgekit

A single Bash script for Debian 12/13 with systemd. It sets up Xray REALITY/Vision, Nginx HTTPS behind Xray, sing-box TUIC v5, and automatic certificate renewal.

## Install

Download a released `setup.sh` to `/root/setup.sh` and run it as root. Keep HTTPS certificate verification enabled when downloading.

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/xgungnir/edgekit/v0.1.0/setup.sh \
  -o /root/setup.sh
chmod 700 /root/setup.sh
/root/setup.sh
# Fill in DOMAIN and CF_ZONE_TOKEN in /root/.ek.env, then run:
ek
# Select 1. Install / Retry installation and confirm.
```

The first run installs the `ek` command at `/usr/bin/ek`. If `/root/.ek.env` is missing, it creates an empty template with mode `0600` and exits. Set `DOMAIN` and `CF_ZONE_TOKEN`; leave the other fields blank to generate credentials automatically.

Use a Cloudflare DNS-only A record pointing to the server's public IPv4 address. Allow TCP 443 and UDP 8443 through your cloud firewall.

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

## Releases

Find published versions and source ZIP/tar.gz downloads on the [Releases page](https://github.com/xgungnir/edgekit/releases). The install command above pins `v0.1.0`; replace that tag with another published version when needed. Releases do not include separately uploaded script assets.

`EDGEKIT_VERSION` in `setup.sh` is the version source. A push to `master` publishes a missing version as a release and tag named `vX.Y.Z`, pointing to that workflow's commit. An already published version is skipped. The workflow can also be run manually on `master`.

The workflow keeps the five highest `vX.Y.Z` stable releases and deletes older matching releases and their tags. Drafts, prereleases, and other tag names are excluded. Download links for deleted tags stop working. Run local checks before pushing a new version; the release workflow validates version metadata but does not run the full test suite.

Script self-update is not implemented yet. Future self-update will use the latest release tag to download that tag's `setup.sh`, rather than the moving `master` branch.

## Validation scope

ARM64 has download and binary checks but no full installation test. Public IPv6 and the current network tuning profile still need live validation. Earlier server tests cover older snapshots and do not establish acceptance of every change in this release.
