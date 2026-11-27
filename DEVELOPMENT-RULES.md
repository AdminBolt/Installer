# Development rules for the Installer

How `install.sh` is expected to be written. These come from code review: a
pull request that breaks one of them is sent back, whoever wrote it. They
apply to people and to AI coding agents alike.

The installer runs as root on a fresh server, and also inside a cPanel
conversion (bolt-migrate runs it on the server being converted) and on a
server where an earlier run stopped half way. Its last line decides whether
the administrator trusts the server. The panel's rules apply where the
installer calls the panel: `Panel/DEVELOPMENT-RULES.md`, section 11 (a step
on the server is a `bolt-cli` command of the panel, not logic copied into
the script) and sections 20 to 25.

## 1. No server is left half installed with an open service

Every exit of the installer (an error, a failed step, `report_fail`, Ctrl-C,
a signal, a check that refuses) leaves the server in a state that is safe
to leave on the internet.

- **Nothing listens without its protection.** A service the installer
  started (a database, a web server, FTP, mail) does not stay running
  without its password, its firewall rules or its configuration. Either the
  step that secures it ran, or the service is stopped again.
- **The exit says what state the server is in** and what to do next, and
  the advice is checked: following it must not finish the install on top of
  the unsafe state.
- **A rerun after a stop is a case of its own.** The installer that runs
  next finds what the first one left, and handles it, or refuses with a
  sentence.
- **Test each exit** you add or touch in `tests/`: make the step fail, and
  check what is left running and what the exit says. A new test file also
  gets its own step in `.github/workflows/ci.yml`: CI runs only the files
  named there, so a file that is not listed never runs.

What the reviewer checks: for every new or changed step, what runs when it
fails half way, and what the next run of the installer does then.

Example (AB-2339, code review 23 November): when the MySQL install failed
after mysqld had started (for example a stale `/root/.my.cnf` failed the
version check),
the installer exited with MySQL running and an empty root password, and its
advice to rerun without `--database` finished the install in that state.

## 2. MySQL and MariaDB clients run with --no-defaults

A `mysql`, `mysqladmin`, `mysqldump`, `mariadb` or `mariadb-admin` call
reads `/etc/my.cnf`, the files it includes and `/root/.my.cnf` unless told
not to. On a converted server, a reused server or a rerun these hold a
stale password, another user, or options the other engine does not know,
and the check fails for a reason that has nothing to do with what it
checks.

- **Give `--no-defaults` as the first option** of every client call that
  needs no password, and pass the socket, the user and `--connect-timeout`
  explicitly.
- **A call that needs a password uses `--defaults-file=<file>` instead**
  (also the first option, never together with `--no-defaults`), with a
  root only file the installer wrote, never the administrator's
  `/root/.my.cnf`.
- MySQL clients (not MariaDB's) still read `~/.mylogin.cnf` under
  `--no-defaults`; do not rely on it being ignored.
- **A probe that only asks "is a server there"** (`ping`) uses
  `--no-defaults` too, with `--socket` and `--port` taken from the server's
  own configuration, or it relies on the package check, so a stale
  `my.cnf` does not decide whether a server is there.

What the reviewer checks: every new or changed client call starts with
`--no-defaults` or `--defaults-file=`.

Example (AB-2339, code review 23 November): the review's case for section
1 is a stale `/root/.my.cnf` that the version check read, which failed the
MySQL install after mysqld had started.

## 3. The oldest supported systems

The installer runs on AlmaLinux 9, Rocky Linux 9 and CloudLinux 9, from 9.0
(`detect_distribution` accepts every 9.x), on minimal and cloud images, and on
a cPanel server that bolt-migrate converts (with cPanel's MySQL 8.0 or
MariaDB, cl-MySQL under MySQL Governor).

- **Look up the version an option needs** (dnf, systemd, curl, openssl,
  firewalld, the database clients) on the oldest of these, and write it in
  the pull request.
- **Do not count on a package a minimal image lacks.** Hetzner's AlmaLinux 9
  and Rocky Linux 9 images have no tar; container and minimal images ship
  curl-minimal. Install only what is missing, and say why.
- **A database server already on the server stays as it is**
  (`--skip-database`, `database_server_found`): MySQL under Governor or a
  server being converted is never replaced.

What the reviewer checks: every new command or option has its version on
the oldest supported system, and the change was run on a minimal image.

Example (AB-2109, QA 28 October): `--force-existing-server` ran `tar` for
its backup in Stage 1, before Stage 2 installs the base packages, and the
stock Hetzner AlmaLinux 9 and Rocky Linux 9 images have no tar, so the
forced install stopped with "tar: command not found". The backup now
installs tar and gzip first when they are missing
(`_backup_install_archivers`).

## 4. The six kinds of return

Sections 20 to 25 of `Panel/DEVELOPMENT-RULES.md` describe each in full,
with their examples. What they mean for the installer:

**Silent success.** A step wrapped in `run_or_warn` that the server cannot
work without fails the install; a warning that is printed must also reach
the final summary and the install report. The last line never says the
install worked while a required step failed. Example (AB-2277, QA 2
November, comment 38346): a rerun after a failed bolt-agent `%post`, with
the disk still full, printed SUCCESS, cleared the rerun marker because an
error line did not match, and exited 0 with the agent's setup incomplete.
The marker is now cleared only on proof of the end state (dnf exit 0,
`agent.conf` with its token and HTTPS on, the certificate files, a running
service), and anything less exits 1.

**Neighbour regressions.** The installer is also run by a cPanel
conversion, by `--force-existing-server`, by a rerun and with `--source` of
an older channel. A change to a default or to the order of steps lists
these callers with what each got before (Panel section 21 has the
examples). Example (AB-1379, QA 27 September, comment 32281): the new
SELinux pre-check stopped in Stage 1 every server booted with `selinux=0`
whose `/etc/selinux/config` said enforcing, a stock AlmaLinux 9.8 image
that the installer on `main` installed with exit 0. The check now asks
`semanage` whether the policy store can be used.

**Root and links.** Where the installer works on a server in use (a
conversion, `--force-existing-server`), it does not chown, chmod or write
paths inside homes; that work belongs to bolt-agent, called through a
`bolt-cli` command of the panel (Panel sections 3 and 11). The installer
has had no return of this kind yet; the closest is in the conversion that
runs it. Example (AB-2331, bolt-migrate, code review 5 November, comment
38897): the conversion checked a customer's docroot with `os.Stat`, which
follows links, then renamed it and ran chmod and chown on it as root, so a
`public_html` the customer had replaced with a link to `/etc` would have
handed `/etc` to the customer. Any path under a home can be such a link,
which is why that work stays with bolt-agent.

**Secrets on every exit.** A password the installer creates or receives goes
to programs on stdin or into a root only file, never on a command line or
into the install log, and is not left behind in a temporary file after a
failed step. Example (AB-2339, code review 4 November, comment 38629): the
new MySQL root password of `--database=mysql8.0|mysql8.4` was passed on
the `mysql` command line, so it showed in the process list. Its fix, in
review in Installer #33, sends the `ALTER USER` to `mysql` on stdin, and
the test checks that the password is on no `mysql` command line.

**Started by the old release, finished by the new one.** A rerun finds the
state an older installer, or a stopped run, left. Section 1.

**Input types.** Every option value is checked before anything is
installed, an empty value included, and a wrong value stops with the list
of what is supported. Example (AB-2339, found in the package run of QA
round 2): an empty `--database=`, for example from an unset variable in a
script, was taken as the default, so a fresh server got MariaDB without a
word.

## 5. Before you ask for review

- Every exit of a new or changed step leaves no service open without its
  protection, and the advice it prints was followed once (section 1).
- Every MySQL or MariaDB client call starts with `--no-defaults` or
  `--defaults-file=` (section 2).
- Every new command or option has its version on the oldest supported
  system, and the change ran on a minimal image (section 3).
- The pull request lists the failure paths with what the summary shows,
  the other callers (conversion, rerun, `--force-existing-server`) with
  before and after, and where each secret goes (section 4).
- `tests/` covers the new behaviour, a new test file has its step in
  `.github/workflows/ci.yml` (section 1), `shellcheck` passes, and the pull
  request merges cleanly with `dev`.

## Known places that still break these rules

Fix them when you work in that area; do not copy them.

- `database_server_found()` runs `mysqladmin ping` (`mariadb-admin ping`
  only when mysqladmin is missing) without `--no-defaults` (section 2).
