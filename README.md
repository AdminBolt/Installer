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
| `sudo ./install.sh --without=<mail,dns,ftp>` | Leave optional components out, for servers with little memory (see [Optional components](#optional-components)) |
| `sudo ./install.sh --channel=<name>` | Name what started the install (`direct` by default; `get-script`, `web-installer`, `vultr`, `akamai`, `node`, `image-build`, `test`, `hostinger`, `digitalocean`, `aws`, `azure`); any other value prints a warning and the install is reported as `direct` |
| `sudo ./install.sh --no-telemetry` | Do not send the install report (same as `ADMINBOLT_NO_TELEMETRY=1`) |
| `sudo ./install.sh --ssh-key="<public key>"` | Add an SSH key for root and turn SSH password login for root off once a sign-in with that key is seen (also `--ssh-key=https://...` for a URL that serves keys) |
| `sudo ./install.sh --help` | Show usage information |

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

1. Check prerequisites (root, supported OS, required commands, port 8443 availability)
2. Prepare system and install prerequisite/Bolt packages
3. Run `bolt-cli` post-install actions and print access details

## Optional components

Everything is installed by default. On a server with little memory, `--without=` leaves whole components out (comma-separated, or the option given more than once):

| Component | Left out | What stops working |
|-----------|----------|--------------------|
| `mail` | Postfix, Dovecot, Rspamd, MLMMJ, Roundcube webmail, the system e-mail account and their profiles | Mailboxes, webmail, mailing lists, and the panel's own e-mail (alerts, password resets), which goes through the server's mail service. The spam filter is part of mail: Postfix refuses mail on its submission ports while Rspamd is missing, so it cannot be left out alone. |
| `dns` | PowerDNS | The server answers no DNS queries; domains need their DNS hosted elsewhere. The DNS record template is still set up, for when PowerDNS is installed later. |
| `ftp` | vsftpd and its profile | FTP accounts. Files can still be managed in the panel's file manager. |

```bash
sudo ./install.sh --without=mail,dns,ftp
```

Anything else in the value stops the install before it changes anything. The skipped steps are listed as skipped, the end of the install lists what was left out, and the choice is kept in `/etc/bolt/bolt-config.ini` as `BOLT_INSTALL_WITHOUT` (empty when nothing was left out). It records what was asked for, not what is installed: run again with `--without=mail` on a server that already has mail, the key says mail although Postfix and Dovecot stay. The install report does not count a left-out step as failed.

The panel shows every left-out service as not installed on Health > Services. Install there sets up the package only, not the profiles that make it serve, so a component is added later with the commands the installer skipped, as root, in this order (the end of the install prints them):

- `mail`: `bolt-cli manage-postfix --action=install`, `bolt-cli manage-dovecot --action=install`, `bolt-cli manage-rspamd --action=install`, `bolt-cli manage-mlmmj --action=install`, `bolt-php /usr/local/bolt/web/artisan bolt:manage-app --action=install --app-name=roundcube`, `bolt-cli manage-postfix-profiles --action=install`, `bolt-cli manage-dovecot-profiles --action=install`, `bolt-cli manage-rspamd-profiles --action=install`, `bolt-cli manage-system-email-account --action=install`, `systemctl restart rspamd`
- `dns`: `bolt-cli manage-powerdns --action=install`
- `ftp`: `bolt-cli manage-vsftpd --action=install`, `bolt-cli manage-vsftpd-profiles --action=install`

The panel does not read `BOLT_INSTALL_WITHOUT` yet and does not hide left-out components: Health shows Postfix, Dovecot, Rspamd and PowerDNS as not installed, with a warning; the default DNS template still adds the mail records (MX, SPF, DMARC, webmail) to new domains; creating a mailbox or an FTP account ends with a message that the server could not do it; a hostname change ends with a warning for the mail steps. The firewall still opens the mail, DNS and FTP ports, with nothing listening on them.

PHP 8.4, Apache, MariaDB, Redis, nftables and SSH are always installed: the panel and the hosting accounts need them. So is Fail2Ban, which protects SSH and the panel login. Antivirus (ImunifyAV, Imunify360, cPGuard) is never installed by the installer; it is a module added in the panel.

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
