# AdminBolt - Powerful and flexible hosting control panel

## Requirements

- **AlmaLinux 9** or **Rocky Linux 9**
- Root access (run with `sudo`)

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

Install MariaDB 10.11 instead of the default 11.4:

```bash
sudo ./install.sh --mariadb-version=10.11
```

### Command reference

| Command | Description |
|---------|-------------|
| `sudo ./install.sh` | Install latest bolt-panel from repo |
| `sudo ./install.sh --source=<stable\|staging\|testing>` | Install from a specific repository source |
| `sudo ./install.sh --mariadb-version=<10.11\|11.4>` | MariaDB series to install: `11.4` (default, supported until 2029-05) or `10.11` (supported until 2028-02). Without the option, a server that already runs MariaDB keeps its series |
| `sudo ./install.sh --channel=<name>` | Name what started the install (`direct` by default; `get-script`, `web-installer`, `vultr`, `akamai`, `node`, `image-build`, `test`, `hostinger`, `digitalocean`, `aws`, `azure`); any other value prints a warning and the install is reported as `direct` |
| `sudo ./install.sh --no-telemetry` | Do not send the install report (same as `ADMINBOLT_NO_TELEMETRY=1`) |
| `sudo ./install.sh --help` | Show usage information |

## Install flow

The installer runs in 3 stages:

1. Check prerequisites (root, supported OS, required commands, port 8443 availability)
2. Prepare system and install prerequisite/Bolt packages
3. Run `bolt-cli` post-install actions and print access details

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
