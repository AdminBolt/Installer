# AdminBolt - Powerful and flexible hosting control panel

## Requirements

- **AlmaLinux 9**, **Rocky Linux 9** or **CloudLinux 9**
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
| `sudo ./install.sh --mariadb-version=<10.11\|11.4>` | MariaDB series to install: `11.4` (default, supported until 2029-05) or `10.11` (supported until 2028-02). A server that already has a database server keeps it as it is (see below) |
| `sudo ./install.sh --skip-database` | Run no database step: no MariaDB package, series, root password reset or MariaDB profile. The panel uses the database server already on this server (see below) |
| `sudo ./install.sh --skip-apache` | Run no Apache step (`manage-my-apache` and the default Apache profile); the web server is then set up by whoever runs the installer |
| `sudo ./install.sh --agent-version=<version-release>` | Install exactly this bolt-agent build (for example `1.30.4-1.el9`) instead of the latest |
| `sudo ./install.sh --package=<bolt-name>=<version-release>` | Install exactly this build of another `bolt-*` package (for example `--package=bolt-php=8.4.14-1.el9`); repeatable, one package per option |
| `sudo ./install.sh --channel=<name>` | Name what started the install (`direct` by default; `get-script`, `web-installer`, `vultr`, `akamai`, `node`, `image-build`, `test`, `hostinger`, `digitalocean`, `aws`, `azure`); any other value prints a warning and the install is reported as `direct` |
| `sudo ./install.sh --no-telemetry` | Do not send the install report (same as `ADMINBOLT_NO_TELEMETRY=1`) |
| `sudo ./install.sh --ssh-key="<public key>"` | Add an SSH key for root and turn SSH password login for root off once a sign-in with that key is seen (also `--ssh-key=https://...` for a URL that serves keys) |
| `sudo ./install.sh --help` | Show usage information |

### Existing database server

The installer never installs, upgrades or reconfigures a database server that is already there. The database steps are skipped, with a line saying why, when:

- `--skip-database` is given;
- a server answers `mysqladmin ping` (or `mariadb-admin ping`);
- a database server package is installed: `MariaDB-server`, `mariadb-server`, `mysql-server`, `mysql-community-server`, `percona-server-server`, `cl-MySQL*`, `cl-MariaDB*` or `Percona-Server-server*` (MySQL under MySQL Governor on CloudLinux included).

The panel then uses that server, which must listen on `localhost:3306`. bolt-agent needs its administrator login: the installer copies `user=` and `password=` from the `[client]` (or `[mysql]`) section of `/root/.my.cnf` into the `[dbservers.mariadb]` section of `/etc/bolt-agent/agent.conf` (`user` is `root` when only a password is there). Without a password in `/root/.my.cnf` the installer warns and leaves `agent.conf` as it is: set `user=` and `password=` in `[dbservers.mariadb]` yourself (bolt-agent reloads the file by itself).

The readiness check at the end accepts the database server under the `mariadb`, `mysqld` or `mysql` unit.

### Pinned builds

`--version`, `--agent-version` and `--package` install exact builds from the repositories `--source` selects (`stable`, `staging`, or `testing`, where PR builds are published; without `--source` the default bolt-repo). Every pinned build is looked up before any Bolt package is installed, and the install stops with the list of builds that are not there. A pinned build also replaces another version of the package already on the server. `bolt-panel` takes `--version` and `bolt-agent` takes `--agent-version`, not `--package`.

```bash
sudo ./install.sh --source=testing --agent-version=1.30.4-pr230.1.el9 --package=bolt-php=8.4.14-1.el9
```

### SSH key and password login

`--ssh-key` takes one public key (`ssh-ed25519 AAAA... comment`) or an `https://` URL that returns one key per line.
The key is checked before anything is installed and added to `/root/.ssh/authorized_keys`; keys already there stay.

At the end of the install, SSH password login for root is turned off only when all of these hold (other users, such as hosting accounts, keep theirs):

- the key is still in root's `authorized_keys`;
- sshd lets root sign in with a key, for the address the key was used from;
- none of the files sshd reads root's keys from (its `AuthorizedKeysFile` list) holds the key with options such as `command=`, `restrict` or `no-pty`, and sshd does not take root's keys from an `AuthorizedKeysCommand`;
- sshd logs a root sign-in with that key after the installer has set up SSH. The installer asks you to sign in with the key from a new terminal and waits up to 10 minutes (Enter skips). Without a terminal (for example cloud-init) there is no such sign-in, so password login stays on.

Otherwise password login stays on and the installer prints the reason and the command to turn it off later.
Password login for root is turned off by `/etc/ssh/sshd_config.d/00-adminbolt-ssh-key-only.conf`; remove that file and run `systemctl reload sshd` to allow it again.

## Install flow

The installer runs in 3 stages:

1. Check prerequisites (root, supported OS, required commands, port 8443 availability, an existing database server)
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
