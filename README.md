# AdminBolt - Powerful and flexible hosting control panel

## Requirements

- **AlmaLinux 9** or **Rocky Linux 9**
- Root access (run with `sudo`)
- A **fresh** server: the installer sets up its own web, mail, DNS, database and firewall stack (see [Servers already in use](#servers-already-in-use))

## Installation

### Option 1: Download and run (one-liner)

Install the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/refs/heads/main/install.sh -o install.sh && sudo bash install.sh
```

Install from staging source:

```bash
curl -fsSL https://raw.githubusercontent.com/AdminBolt/Installer/refs/heads/main/install.sh -o install.sh && sudo bash install.sh --source=staging
```

### Option 2: Clone repository and run

```bash
git clone https://github.com/AdminBolt/Installer.git
cd Installer
sudo ./install.sh
```

Use a specific repository source:

```bash
sudo ./install.sh --source=staging
```

### Command reference

| Command | Description |
|---------|-------------|
| `sudo ./install.sh` | Install latest bolt-panel from repo |
| `sudo ./install.sh --source=<stable\|staging\|testing>` | Install from a specific repository source |
| `sudo ./install.sh --channel=<name>` | Name what started the install (`direct` by default; `get-script`, `web-installer`, `vultr`, `akamai`, `node`, `image-build`, `test`, `hostinger`, `digitalocean`, `aws`, `azure`); any other value prints a warning and the install is reported as `direct` |
| `sudo ./install.sh --force-existing-server` | Install on a server that is already in use, after backing up its configuration (see [Servers already in use](#servers-already-in-use)) |
| `sudo ./install.sh --no-telemetry` | Do not send the install report (same as `ADMINBOLT_NO_TELEMETRY=1`) |
| `sudo ./install.sh --help` | Show usage information |

## Install flow

The installer runs in 3 stages:

1. Check prerequisites (root, supported OS, required commands, port 8443 availability, no existing web/mail/DNS/database setup)
2. Prepare system and install prerequisite/Bolt packages
3. Run `bolt-cli` post-install actions and print access details

## Servers already in use

The installer is meant for a fresh AlmaLinux 9 or Rocky Linux 9 server. It does not import existing sites, mailboxes or databases; to bring those over, install on a fresh server and use the panel's migration tools.

Before it installs anything, the installer checks whether the server is already in use and stops if it finds any of:

- an installed web, mail, DNS or database server package (`httpd`, `nginx`, `lighttpd`, `caddy`, `haproxy`, `postfix`, `sendmail`, `exim`, `dovecot`, `bind`, `pdns`, `vsftpd`, `redis`, `mariadb-server`, `MariaDB-server`, `mysql-server`, `community-mysql-server`, `mysql-community-server`, `percona-server-server`, `postgresql-server`) or such a service running;
- something listening on a web, mail, FTP, DNS or database TCP port (21, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 5432);
- an nftables table not created by firewalld, or firewalld rules beyond an image's default zone (services other than `ssh`, `dhcpv6-client`, `cockpit`; open ports, sources, rich or direct rules) in the default zone or an active one;
- a user with uid 1000 or above whose home holds files of their own, or anything else in `/home` that holds files;
- files in `/var/www`, or database files in `/var/lib/mysql` or `/var/lib/pgsql/data`.

A fresh cloud image passes: its firewalld default zone and its cloud user (whose home holds only the skeleton files, `~/.ssh` and tool caches) do not count, and neither does the installer itself when a sudo user downloads `install.sh` or clones this repository into their home. A server that already has AdminBolt (a reinstall, or a rerun after a failed install) is not checked, and nothing is backed up there.

When it stops, it lists what it found and what the install would change: SELinux is switched off, firewalld is stopped and the nftables tables `ip filter` and `ip6 filter` are replaced by AdminBolt's, whose INPUT and forward chains drop everything but the panel's own ports, the main configuration files of Apache, Postfix, Dovecot, PowerDNS, Redis, vsftpd, Fail2Ban and sshd are written over, and an existing MariaDB is replaced with a new root password. The refusal is reported as `check_existing_server` / `existing_server` in the install report.

`--force-existing-server` installs anyway. Before anything is installed, `/etc`, `/var/spool/cron`, `/root/.my.cnf`, `/usr/bin/mlmmj-make-ml.sh` and `/var/www/html/index.html` / `index.php` are copied to `/root/adminbolt-preinstall-backup-<date>/` (root only), with the firewall's live ruleset (`nft-ruleset.nft`) and the SELinux mode; the install does not start if that copy fails. At the end the installer lists the backed-up files it changed or removed (`replaced-files.txt`). With the flag the backup is always taken, also when nothing was found. Site files and databases are not part of the backup, and nothing is restored automatically: restore single files from `files.tar.gz` as `README.txt` in that directory shows.

Tests (no network, no root): `bash tests/preflight_test.sh`.

## Install report

Every run reports its progress and result to `https://ai-hub.adminbolt.com/install-events`, so failed installs can be counted and fixed:

- `install_started`: random install ID, channel, cloud platform (from DMI, mapped to a fixed list), OS name and version, architecture, requested bolt-panel version, package source, and the SHA-256 of the running `install.sh`;
- `stage_finished`: stage, duration, result;
- `install_finished`: result (`succeeded`, `succeeded_with_warnings`, `failed`, `cancelled`), the failed step and its reason code, exit code, signal, failed optional and required steps, installed bolt-panel and bolt-agent versions, trial licence result, total duration.

No hostname, e-mail address, password, licence key or command output is sent. Sending never changes the install: errors are ignored, intermediate events go out in the background, and only the final event waits (at most 5 seconds).

As root, the events are also kept in `/var/lib/adminbolt-install-report/` (root only), and the `adminbolt-install-report.timer` systemd timer resends undelivered events every 15 minutes for 24 hours (each run at most 4 minutes; the service is limited to 5 minutes, 64 MB and 20 % of one CPU), then removes itself, its service and `/usr/local/libexec/adminbolt/install-report-send`. The install ID is written to `/etc/bolt/bolt-config.ini` as `BOLT_INSTALL_ID`, with `BOLT_INSTALL_MACHINE` (SHA-256 of the machine ID in `/etc/machine-id`, without the newline), so a server booted from an image of this one does not report under its ID.

With `--channel=image-build` (building a server image) the run reports only directly: no spool, no timer and no install ID are left on disk, since every server booted from the image would inherit them.

`--no-telemetry` or `ADMINBOLT_NO_TELEMETRY=1`: nothing is sent or kept, no timer is created, and `BOLT_INSTALL_TELEMETRY=0` is written to `/etc/bolt/bolt-config.ini` so the panel sends nothing either. `ADMINBOLT_INSTALL_REPORT_URL` points the report at another receiver (for testing).

When the script is piped into bash (`curl ... | bash`) there is no file to hash, so the installer revision is sent as 64 zeros; download it to a file first, as the one-liners above do.

Tests for the report (no network, no root): `bash tests/telemetry_test.sh` (needs bash 4+, GNU coreutils and jq).

## Access

After installation, the script prints an admin SSO URL.

If needed, you can generate a new one with:

`bolt-cli admin-sso-generate`
