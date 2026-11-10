# Node selfsteal website

[Русский](NODE-SELFSTEAL.md) · [English](NODE-SELFSTEAL.en.md)

Installing a node with its own domain selects one of 20 bundled websites at random. Each has three topic pages, an About page, a branded 404, local styles, interactive tools and original SVG illustrations. No external CDN, font service or analytics is required.

Selection happens once. Restarting, updating the node or renewing its certificate preserves the website. Owner edits are preserved too.

## Installation

Use `install-node --node-domain DOMAIN` or enter the domain in the interactive installation. Confirm the domain and choose a certificate method. No theme selection is required.

For direct selfsteal, point the domain at the node IP in DNS-only mode, without a TLS-terminating CDN. Xray accepts the public connection and forwards ordinary HTTPS requests to local Nginx. The installer uses `/var/lib/remnacust/run/nginx.sock` with TLS and PROXY protocol; the profile's `target` and `xver` must match. Installing the website does not create or modify an inbound in the panel. Public HTTPS requires a matching running Xray profile.

### Standalone HTTPS and a cascade

Installation and migration offer a standalone HTTPS website. The wizard asks for the website port (443 by default) and the Xray inbound port to configure in the panel (8443 by default). The API port is separate and is retained during migration. All three ports must differ. HTTP-01 reserves TCP 80 for certificate issuance and renewal; use DNS-01 or an existing certificate for other arrangements.

Nginx serves HTTPS independently of the active Xray profile. Its local Unix socket remains available. Only the selected website TCP port is publicly allowed by the managed node firewall. A separate UFW application profile is used without enabling an initially disabled UFW or changing SSH rules. Allow that port in the provider's firewall too. Changing ports updates the managed website profile; removing the node or switching to selfsteal removes its website exception.

With UFW installed, a separate managed rule allows the API and selected TCP inbound only from the main server's IP/CIDR. Removing the node removes its own rule and managed `node-nginx` container and disables its certificate renewal timer. Other proxies, website files, certificates and backups are preserved.

For HTTPS on 443 and REALITY on 8443, configure the panel profile with inbound port 8443, REALITY `target: "127.0.0.1:443"`, `xver: 0` and your domain in `serverNames`. The public Nginx listener does not require PROXY protocol. Enable `acceptProxyProtocol` on the Xray inbound only if the main server sends it. The Unix Nginx listener requires `xver: 1`.

The selected inbound port is saved and displayed in the installation instructions. Existing panel profiles are not rewritten. The `--port` option controls the node API port.

Automation options are `--node-site-mode standalone`, `--node-site-port 443` and `--node-inbound-port 8443`. Use `--node-site-mode selfsteal` for the Unix-only arrangement. Updates preserve the mode and ports. Use `change-domain --component node` with these options to change an existing node; the domain can remain the same.

Standalone readiness checks make a real local HTTPS request, verifying the domain and installed certificate. A failed check during a mode change triggers rollback of the website configuration.

## Files and editing

Nginx runs in Docker as `node-nginx`; there is no host `nginx.service`. Use `docker compose ps` and `docker compose logs --tail=80 node-nginx` from `/opt/remnacust/node`.

The default location is `/opt/remnacust/node/www/`. Edit the HTML, CSS, JavaScript and images there. These are static websites: filters, notes and calculators work locally in the browser. Orders, payments and game-server provisioning require your own separate service; the bundled websites do not perform those operations.

Keep `.env`, private keys, database dumps and backups outside `www`. Selection metadata and backup receipts live outside the public directory. Bundled pages have a local-resource CSP; an existing owner-managed website is not given a new global CSP.

## Another random theme

Open the node management menu and choose the action to select another random website, or run:

```bash
sudo remnacust configure-node-site
```

After confirmation, the old website is archived under `/opt/remnacust/backups/node-sites/`. Running Nginx is recreated to mount the new directory and its configuration is checked. Stopped Nginx stays stopped. Xray and its profile are unchanged. If Nginx fails, the installer attempts a guarded restore and reports its result in the operation log. It does not overwrite edits made after replacement during rollback.

If the installed CLI does not recognise the command, download the current `installer.sh` from Latest and run the action through that file first.

## Source catalogue

All 20 websites live in this repository's `sites/` directory. See [the editing and testing guide](../sites/README.md). `scripts/build-node-sites.py` builds the deterministic catalogue used by the installer. Source, catalogue consistency, module safety, CLI rollback and actual Nginx HTTP/TLS checks run before publication.

When the panel IP/CIDR is empty, the installer adds no nftables/UFW rules, including website and HTTP-01 exceptions. Previous rules are removed only after verifying ownership by this installation; unrelated firewall configuration is preserved. Existing generated renewal scripts are detached from managed firewall hooks. Configure website, API and TCP 80 access yourself on the server and at the provider.
