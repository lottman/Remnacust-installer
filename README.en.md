# Remnacust Installer

[Русский](README.md) · [English](README.en.md)

Install, update, migrate and maintain the Remnacust panel, node and subscription website. The script downloads prebuilt Docker images; no VPS compilation is required. Use the interactive menu or named commands. Prompts currently use Russian; command names remain the same.

[Installation](#installation) · [Requirements](#requirements) · [Commands](#commands) · [CLI reference](installer/README.en.md)

## Where files live

| Component | Working directory |
| --- | --- |
| Panel | `/opt/remnacust/panel` |
| Node | `/opt/remnacust/node` |
| Primary subscription website | `/opt/remnacust/subscription-page` |

Each contains `.env` and `docker-compose.yml`. Additional websites have separate permanent directories and IDs. Run `cat /opt/remnacust/FILES.txt` first: an explicitly selected external path may differ.

```bash
cd /opt/remnacust/panel
ls -la
nano .env
docker compose config --quiet
docker compose up -d --no-build --pull never
```

`restart` does not reload `.env`. Do not create an empty replacement under `/opt/remnacust`; keep the original `APP_SECRET`, database credentials and node key. Backups live under `backups/`, logs under `logs/`.

Normalize older layouts with `sudo remnacust normalize-layout --component panel` or `--component node`. `cleanup-backups` moves recognized old configuration copies into the backup directory; it does not delete all database backups.

## Stable bundle

Checked on **November 7, 2026**:

| Component | Version |
| --- | --- |
| [Installer / Docker bundle](https://github.com/lottman/Remnacust-installer/releases/tag/v1.2.146) | 1.2.146 |
| [Panel / subscription website](https://github.com/lottman/Remnacust-panel/releases/tag/v1.1.7.100) | 1.1.7.100 |
| [Node](https://github.com/lottman/Remnacust-node/releases/tag/v1.1.26) | 1.1.26 |
| [Core / editor](https://github.com/lottman/Remnacust-core/releases/tag/v1.1.16) | 1.1.16, Xray v26.10.31 |

The installer version is not the panel version. Updating one component does not automatically replace the others. Pinned sources: [component-sources.json](component-sources.json). A README update does not create a new application release.

## Requirements

| Item | Minimum or planning allocation |
| --- | --- |
| Installer 1.2.146 OS | Ubuntu 22.04 / 24.04 / 26.04 LTS; Debian 12 / 13 |
| Architecture | Linux amd64 or arm64 |
| Panel with database/cache | At least 2 CPU, 2 GiB RAM and 20 GiB storage; 4 CPU / 4 GiB recommended, plus backup headroom |
| Node | At least 1 CPU / 1 GiB RAM, with headroom for Xray connections/rules |
| Separate subscription website | Initial allocation of 1 CPU / 1 GiB RAM; exact minimum not measured |
| Permissions/network | Root, working DNS, access to APT, GitHub and GHCR |
| Containers | Docker Engine and current Compose v2; legacy `docker-compose` v1 is unsuitable |

These are starting allocations, not client-capacity guarantees. Allow for all components on a shared server. [Remnawave requirements](https://docs.rw/install/requirements/).

If Docker is absent, the installer adds its official distribution repository. An existing daemon is preserved. A specific minimum Engine/Compose minor version has not been established; use current packages. Host Node.js and Go are unnecessary for prebuilt images. Development uses Node.js 26.13 LTS and Go 1.27.3 for Core.

Current panel source was tested on PostgreSQL 14–18. This is the next-update matrix, not a claim that every earlier release was tested. PostgreSQL 14 support ends on November 12, 2026. The installer retains the existing database major version; major changes require a separate migration. [Database compatibility](docs/DATABASE-COMPATIBILITY.md).

## Installation

Prepare a hostname and DNS records. Subscriptions need a separate public address. Preserve SSH access; do not expose the API, database or cache to the entire internet.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install
```

The command downloads the self-contained `Install.sh`. `@ install` opens the menu; use `@ install-node`, `@ install-panel` or `@ install-subscription-page` to choose directly. Verified helpers are already bundled and terminal input remains available. Press Enter at the version prompt to select Latest; `--version` is only needed to pin a specific release.

Or choose an action directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-panel
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-node
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-subscription-page
```

Panel installation asks separately whether to install the subscription website. Empty required answers are requested again; domain confirmation defaults to `y`. Automation must specify required inputs, `--yes` and `--subscription-page` or `--no-subscription-page`. Use `--proxy existing` for your own reverse proxy.

A website can connect to a local or remote panel. Set `--panel-url`; enter the token privately or read it from `--panel-token-file` with permissions `0600`. Choose the subscription-page token preset rather than full access. Backend addresses and tokens must not appear in public client links.

## Commands

After installation use `sudo remnacust COMMAND`.

| Task | Commands |
| --- | --- |
| Install | `install-panel`, `install-node`, `install-subscription-page` |
| Update | `upgrade-panel`, `upgrade-node`, `upgrade-subscription-page --page-id ID` |
| Management menu | `manage-panel`, `manage-node`, `manage-subscription-page` |
| Website panel address/token | `configure-subscription-page --page-id ID --panel-url URL` |
| Another node website | `configure-node-site` — random theme with a backup of the previous site |
| Domain/settings | `change-domain --component COMPONENT`, `show-config --component COMPONENT` |
| Status/logs | `status`, `logs` with `--component panel\|node\|subscription-page` |
| Start/stop | `start`, `stop`, `restart` with `--component` |
| Backups | `backup-panel`, `restore-panel --backup PATH` |
| Migration | `migrate-remnawave-panel`, `migrate-remnawave-node`, `migrate-marzban-panel` |
| Uninstall | `uninstall-panel`, `uninstall-node`, `uninstall-subscription-page --page-id ID` |
| Files/old copies | `normalize-layout --component panel\|node`, `cleanup-backups` |
| Check/help | `--check-release`, `check-panel`, `--help` |

Uninstall preserves data, volumes, settings and backups. Websites are removed by ID without removing other components. Menu numbers can change; use command names for automation.

## Node website

Installing a node with its own domain selects one of 20 multi-page websites at random: footwear, coffee, books, Minecraft and other topics. Pages, tools and illustrations use local files without external CDNs. Updates preserve the selected theme and your edits. Files live in `/opt/remnacust/node/www/`.

Run `sudo remnacust configure-node-site` to choose another random theme, keeping the previous site in `backups/node-sites/`. [Setup, selfsteal and recovery](docs/NODE-SELFSTEAL.en.md). A matching active Xray profile is required; website files alone do not expose public HTTPS.

## System packages and certificates

CLI actions first refresh package indexes and run `apt-get upgrade -y --with-new-pkgs`, except release verification (`--check-release`) and background panel updates launched by its service. APT confirmation is automatic; dpkg questions about configuration or keyboard layout remain interactive. `--yes` does not choose these settings. Opening the menu, help, exit and `--dry-run` do not change packages.

Background panel updates are not blocked by pending OS packages: they update the application and log that OS maintenance is deferred to SSH. Other commands without a terminal still require SSH for package changes. The script never reboots the server automatically, but package upgrades can restart services. A new Linux kernel takes effect after a separate reboot. An already installed 1.2.137 agent needs a one-time installer update through SSH to receive this fix.

DNS, occupied ports and the HTTPS method are checked before applying changes. Third-party proxies and CDN settings are not automatically reworked. Updating a Docker image does not patch the host Linux kernel. Do not manually enable MPTCP until distribution fixes are confirmed. [Maintenance guide](docs/INSTALLER.md).

## Updates and migration

```bash
sudo remnacust upgrade-panel
sudo remnacust upgrade-node
sudo remnacust upgrade-subscription-page --page-id ID
```

Configuration and a consistent database backup are retained before replacement. Preserve `APP_SECRET`, the node key, connection settings and permanent state directories. Node updates check the new image against saved state. An agent update can preserve a previously selected managed Core; inspect the version actually running.

Migrating an existing Remnawave website is offered separately; a website already using Remnacust should not be offered again as third-party migration. Marzban migration uses APIs rather than opening its database as a Remnacust database. Test migrations on a data copy first. [User migration](https://github.com/lottman/Remnacust-panel/blob/main/docs/USER-MIGRATION.md).

## Finding an error

CLI logs: `/opt/remnacust/logs/installer-panel.log`, `installer-node.log`, `installer-subscription-page.log`. The next action for the same component replaces its log; diagnostics use `installer-diagnostics.log`. Parallel invocations do not overwrite the active log. Failures display the path and a viewing command.

Panel updates retain `panel-update-<ID>.log`; website operations use `page-<page ID>-<job ID>.log`; SSH node maintenance retains `node-maintenance.log` on the node. Directory/file permissions are `0700`/`0600`. Do not publish logs through your proxy.

Panel-initiated updates require the local systemd management service. Use CLI if it is unavailable. An API token does not replace administrator permission to update. [CLI reference and troubleshooting](installer/README.en.md).

## Backups and restore

```bash
sudo remnacust backup-panel
sudo remnacust restore-panel --backup /opt/remnacust/backups/panel-DATE-ID
```

Restore retains the installed application version and restores the database with its `APP_SECRET`. Old PostgreSQL/Valkey/Compose from the backup are not started automatically. Preserve private node state as well. The panel ZIP contains an encrypted compressed PostgreSQL dump, not plain SQL text. [Backups](https://github.com/lottman/Remnacust-panel/blob/main/docs/BACKUPS.md).

## Documentation and support

[CLI parameters](installer/README.en.md) · [Installation/maintenance](docs/INSTALLER.md) · [Panel](https://github.com/lottman/Remnacust-panel) · [Node](https://github.com/lottman/Remnacust-node) · [Core](https://github.com/lottman/Remnacust-core).

Debian 12/13 support is available since Installer 1.2.137, using the official Docker repository for the host OS. [Current release notes (RU)](docs/releases/1.2.146.md) · [Development/publishing](docs/PUBLISHING.md). README changes do not update servers.

Component licenses and attribution are preserved. [LICENSE](LICENSE) · [NOTICE.md](NOTICE.md) · [Project support](https://t.me/lottman).

Node migration reuses the existing secret, API port and Xray state. The interactive wizard offers TLS/XHTTP and a website, certificate method, and optional firewall settings. Existing managed TLS can be retained. Additional TLS setup runs after the node has migrated; its failure does not erase the migrated node. The working Xray profile is retained; configure the corresponding inbound in the panel as for a fresh installation.

NeedRestart lists pending service restarts. It does not restart services or reboot the server; dpkg configuration questions remain interactive.
