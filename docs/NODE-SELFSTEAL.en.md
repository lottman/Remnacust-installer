# Node selfsteal website

[Русский](NODE-SELFSTEAL.md) · [English](NODE-SELFSTEAL.en.md)

Installing a node with its own domain selects one of 20 bundled websites at random. Each has three topic pages, an About page, a branded 404, local styles, interactive tools and original SVG illustrations. No external CDN, font service or analytics is required.

Selection happens once. Restarting, updating the node or renewing its certificate preserves the website. Owner edits are preserved too.

## Installation

Use `install-node --node-domain DOMAIN` or enter the domain in the interactive installation. Confirm the domain and choose a certificate method. No theme selection is required.

For direct selfsteal, point the domain at the node IP in DNS-only mode, without a TLS-terminating CDN. Xray accepts the public connection and forwards ordinary HTTPS requests to local Nginx. The installer uses `/var/lib/remnacust/run/nginx.sock` with TLS and PROXY protocol; the profile's `target` and `xver` must match. Installing the website does not create or modify an inbound in the panel. Public HTTPS requires a matching running Xray profile.

## Files and editing

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
