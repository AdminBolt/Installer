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
| `sudo ./install.sh --without=<mail,dns,ftp>` | Leave optional components out, for servers with little memory (see [Optional components](#optional-components)) |
| `sudo ./install.sh --skip-database` | Run no database step: no MariaDB package, series, root password reset or MariaDB profile. The panel uses the database server already on this server (see below) |
| `sudo ./install.sh --skip-apache` | Run no Apache step (`manage-my-apache` and the default Apache profile); the web server is then set up by whoever runs the installer |
| `sudo ./install.sh --cpanel-conversion` | Passed by bolt-migrate when it converts a live cPanel server in place: the mail and DNS steps that cPanel's packages still own are left to the conversion instead of failing the install (see [How the install ends](#how-the-install-ends)) |
| `sudo ./install.sh --agent-version=<version-release>` | Install exactly this bolt-agent build (for example `1.30.4-1.el9`) instead of the latest |
| `sudo ./install.sh --package=<bolt-name>=<version-release>` | Install exactly this build of another `bolt-*` package (for example `--package=bolt-php=8.4.14-1.el9`); repeatable, one package per option |
| `sudo ./install.sh --channel=<name>` | Name what started the install (`direct` by default; `get-script`, `web-installer`, `vultr`, `akamai`, `node`, `image-build`, `test`, `hostinger`, `digitalocean`, `aws`, `azure`, `convert`); any other value prints a warning and the install is reported as `direct` |
| `sudo ./install.sh --no-telemetry` | Do not send the install report (same as `ADMINBOLT_NO_TELEMETRY=1`) |
| `sudo ./install.sh --admin-username=<name\|random>` | Name the first panel administrator (default `admin`; `random` = `admin-` plus 6 random characters) |
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

### How the install ends

The end of the install lists every step that failed, with the line of its output that says why, and the exit status follows it:

- MariaDB, Postfix, Dovecot or PHP 8.4 failed (critical components): `Installation Incomplete`, exit status 1.
- Only other steps failed: `Installation Completed With Warnings`, exit status 0.
- In-place conversion of a live cPanel server by bolt-migrate (`--cpanel-conversion`, or cPanel installed and `--skip-apache` given): PowerDNS, Postfix and Dovecot, and the Postfix and Dovecot profiles, cannot install while cPanel's `cpanel-pdns`, `cpanel-exim` and `cpanel-dovecot` own them. They are listed as `CONVERSION` under `Left to the conversion`, not failed, and the install ends with `Installation Completed: mail and DNS follow at cutover`, exit status 0; bolt-migrate installs them at the cutover, after it stops cPanel's services. Without cPanel's package installed the step is a failure like on any other server.
- The install stopped early (a Stage 2 package, bolt-agent, bolt-panel, connecting the agent to the panel): the step that stopped it and the steps that failed before it, then `Installation stopped early`.

Stage 1 checks that the external package repositories answer (Remi for PHP, EPEL, MariaDB) and says which do not; that never stops the install. PHP 8.4 comes from Remi: while Remi cannot be reached it is listed as `DEFERRED`, not failed, and the install ends with exit status 0. The panel installs it (and its default profile) on its own as soon as Remi answers again: its dashboard shows PHP 8.4 waiting for the Remi repository, tries again every few minutes and offers `Try now`.

Stage 1 also refuses to start when `/etc/selinux/config` sets `SELINUX=enforcing` or `permissive` and `semanage` cannot use the SELinux policy store: the Postfix, Dovecot and Rspamd steps would fail. Install the policy (`dnf install selinux-policy-targeted`) or set `SELINUX=disabled`.

## Install flow

The installer runs in 3 stages:

1. Check prerequisites (root, supported OS, required commands, port 8443 availability, an existing database server)
2. Prepare system and install prerequisite/Bolt packages
3. Run `bolt-cli` post-install actions and print access details

### When the bolt-agent setup did not finish

The installer stops with an error when the bolt-agent package's setup did not finish (for example on a full disk), and again at the end of the install if the agent is no longer fully set up. Fix the cause it names, then run the installer again: it installs the agent again and connects the panel to it anew, which also updates the agent address the panel has saved.

A damaged `/etc/bolt-agent/agent.conf` that the agent's setup cannot repair is moved to `/var/lib/adminbolt/agent-conf-backup/<date>/` with a `MANIFEST` file, and a new one is written.

If you know the agent's setup failed but the installer says "bolt-agent already installed", run `mkdir -p /var/lib/adminbolt && touch /var/lib/adminbolt/agent-post-failed` and run the installer again. Reinstalling the agent by hand (`dnf reinstall bolt-agent`) does not update the address the panel has saved; run `bolt-cli connect-bolt-agent-with-panel` after it.

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

The panel reads `BOLT_INSTALL_WITHOUT` together with what is installed now, so a component counts as left out only until it is installed: Health raises no warning for its services and lists them on Health > Services, in grey, as not installed by choice; the client screens and Client API routes of the component (and its entries on the Feature List) are withheld, and the API answers `This feature is not installed on this server`; creating a mailbox or an FTP account is refused before anything is stored; new domains get no mail records (MX, SPF, DMARC, DKIM, mail service records, `mail`, `webmail`, `autoconfig`, `autodiscover`) while mail is left out, and no `ftp` name while FTP is. Once the commands above have run, all of it comes back on its own; the key needs no editing. Domains created in the meantime get their mail records when the DNS template is applied again in the panel. A hostname change still ends with a warning for the mail steps, and the firewall still opens the mail, DNS and FTP ports, with nothing listening on them.

PHP 8.4, Apache, MariaDB, Redis, nftables and SSH are always installed: the panel and the hosting accounts need them. So is Fail2Ban, which protects SSH and the panel login. Antivirus (ImunifyAV, Imunify360, cPGuard) is never installed by the installer; it is a module added in the panel. Backup and the AI agent are not optional either, because leaving them out would save no memory: restic and rclone are two programs that run only while a backup runs, and the AI agent is part of the panel itself, with no service of its own on the server.

## Install report

Every run reports its progress and result to `https://ai-hub.adminbolt.com/install-events`, so failed installs can be counted and fixed:

- `install_started`: random install ID, channel, cloud platform (from DMI, mapped to a fixed list), OS name and version, architecture, requested bolt-panel version, package source, and the SHA-256 of the running `install.sh`;
- `stage_finished`: stage, duration, result;
- `install_finished`: result (`succeeded`, `succeeded_with_warnings`, `failed`, `cancelled`), the failed step and its reason code, exit code, signal, failed optional and required steps, installed bolt-panel and bolt-agent versions, trial licence result, total duration; in a cPanel conversion also `cutover_steps`, the steps left to the cutover.

A cPanel conversion (`--cpanel-conversion`, or cPanel installed and `--skip-apache` given) is reported with the channel `convert` when the caller names no other channel; bolt-migrate passes `--channel=convert`. The steps it leaves to the cutover (PowerDNS, Postfix, Dovecot and their profiles while cPanel's packages own them) are listed as `cutover_steps`, not as failed steps, and the readiness check does not wait for Postfix or Dovecot when their step is among them; it still checks bolt-agent, bolt-nginx, bolt-php, the database server and the panel on port 8443. Such an install ends `succeeded` (or `succeeded_with_warnings` for another optional step); any other failure is reported as failed, as on any other server.

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
