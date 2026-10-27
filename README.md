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

### Command reference

| Command | Description |
|---------|-------------|
| `sudo ./install.sh` | Install latest bolt-panel from repo |
| `sudo ./install.sh --source=<stable\|staging\|testing>` | Install from a specific repository source |
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
- `install_finished`: result (`succeeded`, `succeeded_with_warnings`, `failed`, `cancelled`), the failed step and its reason code, exit code, signal, failed optional and required steps, installed bolt-panel and bolt-agent versions, trial licence result, total duration, and `errors`: for each failed step (required and optional) the step, the exit code of its command and the last 40 lines of its output (at most 2 KB per step and 6 KB in all; the oldest lines are cut first, so the final error stays; at most 20 steps).

Before the excerpts are sent they are redacted on the server: its host names (`uname -n`, `/etc/hostname`, `hostname -f`, and their first label), every IPv4 and IPv6 address, e-mail addresses, the `--email` address and its domain, the licence keys stored by the panel, private key blocks, `user:password@` in URLs, `Authorization` headers and bearer tokens, values of names such as `password=`, `token:`, `secret`, `APP_KEY=`, `mysql -p...`, and long random tokens become `<host>`, `<ip>`, `<email>` or `<secret>`. Colour codes are removed and anything but printable ASCII becomes `?`. The receiver redacts them again before it stores them. Without `gawk` (part of every AlmaLinux and Rocky Linux install) a failed step is sent without output. The excerpts never change the result or the reason. No other hostname, e-mail address, password, licence key or command output is sent. Sending never changes the install: errors are ignored, intermediate events go out in the background, and only the final event waits (at most 5 seconds).

As root, the events are also kept in `/var/lib/adminbolt-install-report/` (root only), and the `adminbolt-install-report.timer` systemd timer resends undelivered events every 15 minutes for 24 hours (each run at most 4 minutes; the service is limited to 5 minutes, 64 MB and 20 % of one CPU), then removes itself, its service and `/usr/local/libexec/adminbolt/install-report-send`. The install ID is written to `/etc/bolt/bolt-config.ini` as `BOLT_INSTALL_ID`, with `BOLT_INSTALL_MACHINE` (SHA-256 of the machine ID in `/etc/machine-id`, without the newline), so a server booted from an image of this one does not report under its ID.

With `--channel=image-build` (building a server image) the run reports only directly: no spool, no timer and no install ID are left on disk, since every server booted from the image would inherit them.

As root, everything the installer prints (stdout and stderr of every step) is also written to `/var/log/bolt-install.log` (mode 0600, root only), each line with its UTC time and without colour codes; the terminal shows the same output as before (programs that draw progress bars only on a terminal, such as dnf, print plain lines instead, as when the install is piped). A rerun appends to it after a header with the install ID and the start time. It is written with `--no-telemetry` too, and the last message of every run names it. It never leaves the server; like the terminal output, it holds the one-time admin sign-in link printed at the end.

`--no-telemetry` or `ADMINBOLT_NO_TELEMETRY=1`: nothing is sent or kept, no timer is created, and `BOLT_INSTALL_TELEMETRY=0` is written to `/etc/bolt/bolt-config.ini` so the panel sends nothing either. `ADMINBOLT_INSTALL_REPORT_URL` points the report at another receiver (for testing).

When the script is piped into bash (`curl ... | bash`) there is no file to hash, so the installer revision is sent as 64 zeros; download it to a file first, as the one-liners above do.

Tests for the report (no network, no root): `bash tests/telemetry_test.sh` (needs bash 4+, GNU coreutils and jq), and for the install log and the redaction of the excerpts `bash tests/excerpt_test.sh` (also needs gawk).

## Access

After installation, the script prints an admin SSO URL.

If needed, you can generate a new one with:

`bolt-cli admin-sso-generate`
