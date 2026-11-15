# Database compatibility and migration

[Русский](DATABASE-COMPATIBILITY.md) · [English](DATABASE-COMPATIBILITY.en.md)

## Tested versions

Panel **1.1.7.126** was tested on PostgreSQL **14.25, 15.20, 16.16, 17.12 and 18.7**. All 15 targeted checks passed on each version, covering upgrades, saved settings, concurrent changes and rollback on failure. Disposable test environments do not establish the state of your production database. [Completed CI run](https://github.com/lottman/Remnacust-panel/actions/runs/43658336477).

Choose a supported major version with current patches for a new installation. PostgreSQL 14 support ended on **November 12, 2026**; PostgreSQL 13 and older versions are outside the tested range. [PostgreSQL support policy](https://www.postgresql.org/support/versioning/).

## Updating the panel

A normal update retains the installed PostgreSQL major version and its volume. Before updating, back up the database, Compose configuration, `.env` and original `APP_SECRET`. Verify restoration into a separate database.

Changing the PostgreSQL major version requires a separate `pg_upgrade` or dump/restore procedure tested on a copy. Do not attach an existing data directory to an image from a different major version. `pg_dump` must not be older than the source server; migration back to an older major version is not guaranteed.

If an update stops, read the logs and address the cause before retrying. Do not reset the database or remove its update history. Check the original `APP_SECRET` when decryption fails.

## Moving between Remnawave and Remnacust

Use the supported `migrate-remnawave-panel` command to move to Remnacust. Preserve the environment, login secrets, domains, subscription data and node connection settings. After updating, check administrator login, subscription delivery and user access.

Before moving back, test the chosen Remnawave version on a copy of your database. Remnacust features do not become standard panel features: check limits, devices, user access and core management separately.

For older installations that need repair, follow the [Panel 1.1.7.126 procedure](https://github.com/lottman/Remnacust-panel/blob/v1.1.7.126/docs/DATABASE-COMPATIBILITY.md). It explains preliminary checks, backups and when a compatible image may be started. After a failure or lost connection, establish the actual database state before starting an older panel.

[Installer commands](../README.en.md#commands) · [Panel backups](https://github.com/lottman/Remnacust-panel/blob/v1.1.7.126/docs/BACKUPS.md).
