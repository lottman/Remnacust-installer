# Remnacust Installer — CLI reference

[Русский](README.md) · [English](README.en.md)

Stable bundle: Installer **1.2.145**, Panel/website **1.1.7.100**, Node **1.1.26**, Core **1.1.16** / Xray v26.10.31. [Requirements and quick start](../README.en.md).

Installer 1.2.145 supports Ubuntu 22.04/24.04/26.04 LTS and Debian 12/13, amd64/arm64. Docker is installed from the official repository for the host OS. Installer prompts currently use Russian. Run `sudo remnacust --help` for the complete command list.

## Install ready components

Download the latest stable installer and open its interactive menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install
```

## First installation

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-panel
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-node
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install-subscription-page
```

The command downloads the latest stable installer. Press Enter at the version prompt to select Latest; `--version` is only needed to pin a specific release.

Required empty answers are requested again. Domain confirmation defaults to `y`; other y/n questions use their displayed default. For automation supply all required values, `--yes` and an explicit `--subscription-page` or `--no-subscription-page` choice. `--yes` does not select dpkg configuration answers.

| Option | Purpose |
| --- | --- |
| `--version latest\|1.2.145` | Installer bundle release, not the panel version |
| `--domain DOMAIN` | Component hostname without scheme, port or path |
| `--port PORT` | Panel loopback port or node API port |
| `--directory PATH`, `--container NAME`, `--compose-file PATH` | Identify an existing installation |
| `--project-name NAME` | Separate Compose project |
| `--proxy caddy\|existing` | Managed Caddy or your existing proxy |
| `--tls-method auto\|http\|cloudflare\|gcore\|existing` | Supported TLS method for the component |
| `--email EMAIL` | ACME registration email |
| `--cert-file PATH`, `--key-file PATH` | Existing matching certificate/key |
| `--dns-credentials PATH` | Private INI file for the selected DNS provider |
| `--server-ip IP[,IP]` | Public addresses for DNS validation, including NAT deployments |
| `--node-domain DOMAIN` | Managed node HTTPS/XHTTP endpoint |
| `--panel-ip IP[/CIDR]` | Restrict inbound ports and ICMP to the panel address, except SSH; this also restricts VPN client ports |
| `--net-admin`, `--no-net-admin` | Container capability selection; an enabled capability is retained on updates |
| `--subscription-page`, `--no-subscription-page` | Explicit website installation/migration choice |
| `--subscription-urls URLS` | One or two website addresses, comma-separated; not the panel CDN catalog |
| `--subscription-port PORT` | Website loopback port, default 3010 |
| `--panel-url URL`, `--panel-token-file PATH` | Website backend connection and private token file |
| `--page-id ID` | Select a registered website instance |
| `--dry-run` | Inspect without changing the system |

Keep the original `APP_SECRET`, `SECRET_KEY`, database credentials, networks and volumes. A new panel gets random secrets and a separate backup password stored privately in `backup-password.txt`.

## Paths and management

```bash
sudo remnacust manage-panel
sudo remnacust manage-node
sudo remnacust manage-subscription-page
sudo remnacust show-config --component panel
sudo remnacust status --component node
sudo remnacust logs --component subscription-page --page-id ID
sudo remnacust restart --component node
```

Working files use permanent directories under `/opt/remnacust`. Start with `cat /opt/remnacust/FILES.txt`; explicit external paths can differ. `show-config` displays addresses and paths without printing secrets. Website installation state comes from the registered instance and Docker, not merely a domain in the panel `.env`.

## Website panel connection

Local panel selection uses `auto`; remote panels use an HTTPS URL without a dashboard path, query or embedded credentials. Metadata, selected page configuration and token permissions are checked before applying changes.

```bash
sudo remnacust install-subscription-page --panel-url https://panel.example.com --panel-token-file /root/subscription-token
sudo remnacust configure-subscription-page --page-id ID --panel-url https://other-panel.example.com --panel-token-file /root/subscription-token
```

Enter the token privately, use `REMNACUST_SUBSCRIPTION_TOKEN`, or provide a regular `0600` file. Minimum grants: `system:metadata`, `subscriptions:subpage-config`, `subscription-page-configs:get`, `subscription-page-configs:list`. Full user administration is unnecessary. TLS certificates are verified; token-bearing redirects are not used to bypass a wrong backend address.

Only the selected website connection changes. The image, public domain, proxy and database remain configured. Failed validation leaves settings unchanged; a readiness failure after applying changes restores the previous configuration. Stopped websites remain stopped.

## Domains, HTTPS and CDN

```bash
sudo remnacust change-domain --component panel --domain panel.example.com
sudo remnacust change-domain --component node --domain node.example.com --email admin@example.com
sudo remnacust change-domain --component subscription-page --page-id ID --domain sub.example.com
```

Configure A/AAAA first. This changes a domain, not the server IP. HTTP-01 requires external validation access. Existing certificate/key pairs must match. For Certbot operations, managed firewall handling retains and restores the original UFW state on completion/failure; restricted node HTTP-01 validation temporarily permits TCP 80.

Only recognized managed proxy configuration is changed. Unknown external proxies and CDN resources are not rewritten. Keys, database credentials, volumes and API ports are preserved; stopped services are not started arbitrarily. Private rollback copies are saved under `/opt/remnacust/backups/domain-*`. Check host SNI/addresses and subscriptions already imported into clients separately.

In the panel, subscription domains are under **Subscription → Settings → Subscription pages**. The primary synchronizes with `SUB_PUBLIC_DOMAIN` through the installer service. Each primary supports at most three CDN domains. Copy the CDN origin, Host/SNI and generated request-header pair into your provider settings. Do not use shared subscription-response caching. The backend address and token remain server-side.

## Updates and migration

```bash
sudo remnacust upgrade-panel
sudo remnacust upgrade-node
sudo remnacust upgrade-subscription-page --page-id ID
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ migrate-remnawave-panel --container remnawave
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ migrate-remnawave-node --container remnanode
```

Updates preserve configuration, mounts and secrets. The panel gets a consistent PostgreSQL backup before application shutdown. Node/Core replacement can interrupt connections; updating the panel alone does not update remote Core. Confirm the running managed Core version after an agent update.

Older Remnawave websites are discovered and migration is offered separately. Domains, port, prefix and panel connection are retained. A Remnacust image is not offered again as a third-party migration. A Compose project name alone does not identify the image. Marzban migration is API-based; follow the [user migration guide](https://github.com/lottman/Remnacust-panel/blob/main/docs/USER-MIGRATION.md).

`normalize-layout --component panel|node` normalizes older working paths. `cleanup-backups` moves recognized configuration copies into backup storage. External paths and cross-filesystem moves remain subject to safety checks.

## System packages

Selected CLI actions run `apt-get update -y` and `apt-get upgrade -y --with-new-pkgs`, except read-only release verification (`--check-release`) and background panel updates launched by its service. Menu/help/exit and `--dry-run` do not change packages. APT continuation is automatic; package configuration choices remain interactive. SSH input and secret answers are not copied into the installer log.

Background panel updates change application components and explicitly defer OS maintenance to a separate SSH session. Pending kernel packages do not block them. Other commands without a terminal still exit with code `75` when package changes require SSH; configuration answers are not guessed. There is no automatic server reboot, but upgraded packages can restart services. A new kernel takes effect only after reboot; check the distribution security bulletin for the actual package.

An already installed 1.2.137 agent calls the old CLI before downloading a release. To receive this fix, first update the installer and update service once through SSH using the new verified script. Publishing a release or editing source alone does not replace an already running old agent.

## Logs and panel-initiated updates

CLI retains one `logs/installer-<component>.log` until the next action for that component. Diagnostics use `installer-diagnostics.log`; SSH node maintenance also retains `node-maintenance.log` on the node. A failure prints the path and viewing command. SIGKILL/power loss cannot print a final diagnostic; use the path shown at startup.

Panel installation/update creates `remnacust-panel-update.service`. It needs systemd and continues working after backend shutdown or browser closure. Without the service, use CLI. Panel APIs receive the read-only control directory rather than the Docker socket. An API token does not grant administrator-only update access.

Panel update logs: `/opt/remnacust/logs/panel-update-<ID>.log`. Website jobs use `page-<page ID>-<job ID>.log`. Keep directories/files at `0700`/`0600`; never expose logs through a reverse proxy.

## Restore and uninstall

`restore-panel --backup PATH` keeps the installed application version and restores the database with its matching `APP_SECRET`. Old PostgreSQL/Valkey images and Compose files are not automatically started. Restore does not replace private node-state backup or quota reconciliation.

```bash
sudo remnacust uninstall-panel
sudo remnacust uninstall-node
sudo remnacust uninstall-subscription-page --page-id ID
```

Uninstall preserves data, configuration, certificates and backups. Removing one website does not remove the panel or other websites. Reinstallation uses `install-*` and archives recognized retired configuration rather than accumulating dated working directories.

## Development and license

[Installer architecture](../docs/INSTALLER.md) · [Database compatibility](../docs/DATABASE-COMPATIBILITY.md) · [Publishing](../docs/PUBLISHING.md) · [Source checks](../.github/workflows/check.yml).

Installer changes, helper contracts and packaged artifacts must be checked together before a software release. Updating this documentation does not publish an application version or update servers. [LICENSE](../LICENSE) · [NOTICE.md](../NOTICE.md).

Node migration reuses the existing secret, API port and Xray state. The interactive wizard offers TLS/XHTTP and a website, certificate method, and optional firewall settings. Existing managed TLS can be retained. Additional TLS setup runs after the node has migrated; its failure does not erase the migrated node. The working Xray profile is retained; configure the corresponding inbound in the panel as for a fresh installation.

NeedRestart lists pending service restarts. It does not restart services or reboot the server; dpkg configuration questions remain interactive.
