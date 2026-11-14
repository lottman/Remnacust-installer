# Remnacust Installer — CLI reference

[Русский](README.md) · [English](README.en.md)

Stable bundle: Installer **1.2.173**, Panel/website **1.1.7.125**, Node **1.1.36**, Core **1.1.21** / Xray v26.11.9. [Requirements and quick start](../README.en.md).

Installer 1.2.173 supports Ubuntu 22.04/24.04/26.04 LTS and Debian 12/13, amd64/arm64. Docker is installed from the official repository for the host OS. Installer prompts currently use Russian. Run `sudo remnacust --help` for the complete command list.

## Install ready components

Download the latest stable installer and open its interactive menu:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/Install.sh) @ install
```

## Panel and node IPv6

Panel install, upgrade and migration default to `--panel-ipv6 auto`. A read-only preflight checks host IPv6, a default route, Docker Engine 28+ and Compose 2.33.1+. When safe, the installer adds its own `remnacust_ipv6_egress` Compose bridge network to every discovered panel backend application: API, processor and scheduler. The main service is included even if missing from the application list, and duplicates are removed. The network is IPv6-only (`enable_ipv4: false`, `enable_ipv6: true`) with NAT. Docker allocates the subnet from its address pools, normally an automatic ULA; no prefix is hard-coded.

Existing networks, including an external `remnawave-network`, keep their subnet and IPAM configuration. Existing backend attachments receive higher `priority` and `gw_priority` to retain the primary network and IPv4 gateway. PostgreSQL, Redis/Valkey, the proxy, separate Node and Subscription Page are not attached to the egress network. Published ports, loopback bindings, volumes and secrets are unchanged; database/cache ports are not published over IPv6. Upgrade recreates backend applications through the existing backup/rollback workflow without restarting database or cache services.

```bash
sudo remnacust upgrade-panel --panel-ipv6 on
sudo remnacust upgrade-panel --panel-ipv6 off
```

`on` fails before applying configuration if preflight fails. `auto` explains why it cannot enable IPv6 and preserves the current configuration, including an already-enabled egress network during temporary route failures. `off` explicitly detaches all panel backend applications from the egress network. No networks are force-deleted; an unused network may remain for separate cleanup. Subsequent upgrades preserve the Compose configuration. Explicit panel `network_mode`, a conflicting egress network name, or application sysctls disabling IPv6 require separate review and are not overwritten.

When IPv6 forwarding is not yet enabled, the interface of a Router Advertisement default route (`proto ra`) needs `net.ipv6.conf.<interface>.accept_ra=2`: enabling Docker forwarding could otherwise stop kernel RA acceptance. If forwarding is already enabled and a default route exists, RA settings are preserved; the installer does not infer whether the kernel or a userspace network service manages the route. For `eth0`, inspect `sysctl net.ipv6.conf.eth0.accept_ra`. Arrange persistent OS changes separately when required. The installer does not edit sysctl, `daemon.json`, global address pools or foreign firewall rules. Disabled `ip6tables` in standard Docker configuration, or missing preconfigured forwarding with the nftables backend, prevents automatic enablement. A default route does not prove remote reachability; provider and firewall restrictions need separate checks.

Nodes retain host networking. The installer never disables node IPv6 or adds disabling sysctls. Prior OS optimization disabling IPv6 is a separate host setting, not something the panel's Docker network can repair.

For read-only diagnosis, compare the host's `ip -6 route show default` with `docker inspect <container>` and `docker network inspect <network>`. Host IPv6 working while the panel network has `EnableIPv6=false` and the container has no IPv6 route explains container `ENETUNREACH`. Verify the actual container address and route after applying the configuration, rather than relying on host ping alone.

Official references: [Docker IPv6](https://docs.docker.com/engine/daemon/ipv6/), [Engine 27 automatic ULA allocation](https://docs.docker.com/engine/release-notes/27/), [Engine 28 IPv6-only networks and gateway priority](https://docs.docker.com/engine/release-notes/28/), [Compose networks](https://docs.docker.com/reference/compose-file/networks/), [Compose gw_priority](https://docs.docker.com/reference/compose-file/services/#gw_priority), [Docker forwarding](https://docs.docker.com/engine/network/packet-filtering-firewalls/), [Linux accept_ra](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html).

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
| `--version latest\|1.2.159` | Installer bundle release, not the panel version |
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

Migration and rollback retain the running/stopped state of each application. Readiness is checked for running applications; a stopped panel defers companion page migration until the panel is started. Before switching, resolved Compose credentials are compared with the existing applications and node state mounts must match Docker, including nested quota mounts. Reconcile stale configuration before retrying. For a node with a previously running Core or a saved checkpoint, readiness also checks the Core statistics API and a stable process ID; an explicitly paused Core is preserved. Interruptions after switching enter the same recovery path as command failures. After database changes, panel writers remain stopped for explicit restore.

Node migration replaces only the selected node service. Core compatibility checks use the saved managed, bundled or recovery selection. If the initial private-state snapshot fails, rollback retains the original container layer and does not recreate it from Compose; a previously running node is started by its original container ID. Once persistent state is published, rollback uses that latest state rather than an older quota journal.

Older Remnawave websites are discovered and migration is offered separately. Domains, port, prefix and panel connection are retained. Previously registered Remnacust pages use normal upgrades; unregistered earlier Remnacust images can be adopted through the migration wizard. A Compose project name alone does not identify the image. Marzban migration is API-based; follow the [user migration guide](https://github.com/lottman/Remnacust-panel/blob/main/docs/USER-MIGRATION.md).

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

### Migrate an existing Remnawave subscription page

On the server hosting that page, choose **Migration → Subscription page from Remnawave**, or run `sudo remnacust migrate-remnawave-subscription-page`. Use `--container NAME` or `--directory /opt/subscription-page` to select a specific Compose deployment. The installer preserves its panel URL, API token, ports, networks, mounts and running/stopped state; it does not update the panel. Other services in the project remain running. A failed readiness check restores the previous page configuration. Official Remnawave and earlier Remnacust images are recognized, including digest-pinned images in the old /opt/remnawave directory. Existing .env values are preserved; the panel URL and API token are requested only when missing or malformed. If no source is found without an explicit --container/--directory, the new-install wizard opens. An explicitly selected unknown source is not changed. Afterwards use `upgrade-subscription-page`; use `configure-subscription-page` to change the panel connection.

After a successful update, unused Remnacust images are removed, including local `local/remnacust-*` images with a verified project source label. Current and previous images and images referenced by any existing container are retained. Foreign images and volumes are never removed. Database backups and manual archives are outside image cleanup; verify recovery before removing them separately.
