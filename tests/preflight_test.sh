#!/usr/bin/env bash
#
# Tests for the existing-server check and the --force-existing-server backup
# in install.sh. No network, no root: rpm, systemctl, ss, nft, firewall-cmd,
# getenforce and df are shell functions fed from files, every path the check
# reads or the backup writes points into a temporary directory, and install.sh
# is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install never runs.
#
# Needs bash 4+, GNU coreutils, GNU tar and GNU find.
#   bash tests/preflight_test.sh
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")

# The lists the check uses, for the README comparison.
ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
set +e
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export LC_ALL=C

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else nok "$1" "no '$2' in output"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then nok "$1" "unexpected '$2' in output"; else ok "$1"; fi; }

# A server as a directory tree plus answers for the commands, $S/fake/<name>:
# rpm (installed package names), units (active units), ss (ss -Htlnp lines),
# nft (nft list tables lines), fw_state (0 = running), fw_<zone>_<opt>
# (firewall-cmd --zone=<zone> --list-<opt>), fw_direct, selinux, df_avail.
#
# new_server <name>: the fresh Vultr Rocky Linux 9 image as calibrated: sshd
# on 22, firewalld running with its default zone (cockpit dhcpv6-client ssh),
# SELinux enforcing, cloud user linuxuser (uid 1000) with the skeleton files,
# ~/.ssh/authorized_keys and an empty ~/.ansible/tmp, no /var/www.
new_server() {
    S="$T/$1"
    mkdir -p "$S/fake" "$S/etc/skel" "$S/etc/selinux" "$S/home/linuxuser/.ssh" "$S/home/linuxuser/.ansible/tmp" "$S/root"
    printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:Kernel Overflow User:/:/sbin/nologin\nlinuxuser:x:1000:1000::%s/home/linuxuser:/bin/bash\n' "$S" >"$S/etc/passwd"
    for f in .bash_logout .bash_profile .bashrc; do
        echo "# $f" >"$S/etc/skel/$f"
        cp "$S/etc/skel/$f" "$S/home/linuxuser/$f"
    done
    echo "ssh-ed25519 AAAA test" >"$S/home/linuxuser/.ssh/authorized_keys"
    echo "SELINUX=enforcing" >"$S/etc/selinux/config"
    printf 'LISTEN 0      128    0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1239,fd=7))\nLISTEN 0      128       [::]:22    [::]:* users:(("sshd",pid=1239,fd=8))\n' >"$S/fake/ss"
    echo "table inet firewalld" >"$S/fake/nft"
    echo 0 >"$S/fake/fw_state"
    printf 'public\n  interfaces: enp1s0\n' >"$S/fake/fw_active"
    echo "cockpit dhcpv6-client ssh" >"$S/fake/fw_public_services"
    echo Enforcing >"$S/fake/selinux"
    : >"$S/fake/rpm"
    : >"$S/fake/units"
}

# run <script>: runs the script in a child with install.sh loaded against $S.
# Output in $OUT, exit code in $RC.
run() {
    cat >"$S/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "${CHILD_INSTALL_SH:-$INSTALL_SH}"
S="$S"
F="$S/fake"
rpm() {
    local n rc=0
    [[ "\$1" == -q ]] && shift
    [[ "\$1" == --qf ]] && shift 2
    for n in "\$@"; do
        if grep -qx "\$n" "\$F/rpm"; then echo "\$n"; else echo "package \$n is not installed"; rc=1; fi
    done
    return \$rc
}
systemctl() {
    case "\$1" in
        is-active) grep -qx "\$3" "\$F/units" ;;
        show) if [[ -f "\$F/unit_id_\$5" ]]; then cat "\$F/unit_id_\$5"; else echo "\$5.service"; fi ;;
    esac
}
ss() { cat "\$F/ss"; }
nft() { case "\$*" in "list tables") cat "\$F/nft" ;; "list ruleset") echo "ruleset" ;; esac; }
firewall-cmd() {
    case "\$1" in
        --state) return "\$(cat "\$F/fw_state")" ;;
        --get-active-zones) cat "\$F/fw_active" ;;
        --get-default-zone) cat "\$F/fw_default" 2>/dev/null || echo public ;;
        --direct) cat "\$F/fw_direct" 2>/dev/null ;;
        --zone=*) local z="\${1#--zone=}" o="\${2#--list-}"; cat "\$F/fw_\${z}_\${o}" 2>/dev/null ;;
    esac
    return 0
}
getenforce() { cat "\$F/selinux"; }
if [[ -f "\$F/df_avail" ]]; then df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfake 1 1 %s 1%% /\n' "\$(cat "\$F/df_avail")"; }; fi
EXISTING_HOME_DIR="$S/home"
EXISTING_WWW_DIR="$S/var/www"
EXISTING_DATABASE_DIRS="$S/var/lib/mysql $S/var/lib/pgsql/data"
EXISTING_SKEL_DIR="$S/etc/skel"
EXISTING_PASSWD="$S/etc/passwd"
SELINUX_CONFIG="$S/etc/selinux/config"
BACKUP_PARENT="$S/root"
BACKUP_PATHS="$S/etc $S/var/spool/cron $S/root/.my.cnf $S/var/www/html/index.html"
trap 'echo "STEP=\$REPORT_FAILED_STEP REASON=\$REPORT_REASON"' EXIT
set -e
$1
EOF
    OUT=$(cd "$S" && "$BASH" "$S/child.sh" 2>&1)
    RC=$?
}

# ---------------------------------------------------------------------------
echo "# a fresh cloud image passes"
# ---------------------------------------------------------------------------
new_server fresh
run 'existing_server_findings'
eq "fresh Rocky/Alma image: no findings" "STEP= REASON=" "$OUT"
run 'check_existing_server; echo PASSED'
eq "fresh image: check passes" 0 "$RC"
has "fresh image: says nothing was found" "No existing web, mail, DNS or database server" "$OUT"
has "fresh image: install goes on" PASSED "$OUT"

new_server used_cloud_user
echo "ls" >"$S/home/linuxuser/.bash_history"
mkdir -p "$S/home/linuxuser/.cache/dnf"
echo x >"$S/home/linuxuser/.cache/dnf/cache"
echo x >"$S/home/linuxuser/.ansible/tmp/run"
mkdir -p "$S/home/lost+found"
run 'existing_server_findings'
eq "cloud user after logins (history, caches), empty lost+found: no findings" "STEP= REASON=" "$OUT"

# A sudo user (rocky, almalinux, ec2-user) downloads or clones the installer
# into their own home and runs it from there.
new_server sudo_download
cp "$INSTALL_SH" "$S/home/linuxuser/install.sh"
CHILD_INSTALL_SH="$S/home/linuxuser/install.sh" run 'existing_server_findings'
eq "install.sh downloaded into the cloud user's home: no findings" "STEP= REASON=" "$OUT"
new_server sudo_clone
mkdir -p "$S/home/linuxuser/Installer/.git" "$S/home/linuxuser/Installer/tests"
cp "$INSTALL_SH" "$S/home/linuxuser/Installer/install.sh"
echo x >"$S/home/linuxuser/Installer/README.md"
echo x >"$S/home/linuxuser/Installer/.git/HEAD"
CHILD_INSTALL_SH="$S/home/linuxuser/Installer/install.sh" run 'existing_server_findings'
eq "repository cloned into the cloud user's home: no findings" "STEP= REASON=" "$OUT"
echo data >"$S/home/linuxuser/site.sql"
CHILD_INSTALL_SH="$S/home/linuxuser/Installer/install.sh" run 'existing_server_findings'
has "a file of the user's own beside the clone still counts" "user linuxuser (uid 1000) has files" "$OUT"
new_server not_installer
printf '#!/bin/bash\necho other\n' >"$S/home/linuxuser/install.sh"
cp "$INSTALL_SH" "$S/installer.sh"
CHILD_INSTALL_SH="$S/installer.sh" run 'existing_server_findings'
has "some other install.sh in the home still counts" "user linuxuser (uid 1000) has files" "$OUT"

new_server no_firewalld
echo 1 >"$S/fake/fw_state"
: >"$S/fake/nft"
rm -rf "$S/home/linuxuser" "$S/etc/selinux/config"
run 'existing_server_findings'
eq "image without firewalld or a cloud user: no findings" "STEP= REASON=" "$OUT"

# ---------------------------------------------------------------------------
echo "# each sign of a server in use is found"
# ---------------------------------------------------------------------------
finding() { # $1 description, $2 setup run against $S, $3 expected line
    new_server "f$((++N))"
    eval "$2"
    run 'existing_server_findings'
    has "$1" "$(eval "echo \"$3\"")" "$OUT"
}
N=0
finding "installed package" 'printf "httpd\nmariadb-server\n" >"$S/fake/rpm"' "package mariadb-server is installed"
finding "running service" 'echo postfix >"$S/fake/units"' "service postfix is running"
finding "nginx on 443" 'echo "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=9,fd=6))" >>"$S/fake/ss"' "port 443 is in use by nginx"
finding "mail port on IPv6 only" 'echo "LISTEN 0 100 [::1]:25 [::]:* users:((\"master\",pid=9,fd=13))" >>"$S/fake/ss"' "port 25 is in use by master"
finding "nftables table of its own" 'echo "table inet f2b-table" >>"$S/fake/nft"' "nftables table inet f2b-table is set up (not by firewalld)"
finding "firewalld service beyond the image's" 'echo "cockpit dhcpv6-client http ssh" >"$S/fake/fw_public_services"' "firewalld: zone public allows the services http"
finding "firewalld open port" 'echo "8080/tcp" >"$S/fake/fw_public_ports"' "firewalld: zone public ports: 8080/tcp"
finding "firewalld rich rule" 'echo "rule family=ipv4 source address=10.0.0.0/8 accept" >"$S/fake/fw_public_rich-rules"' "firewalld: zone public has 1 rich rule(s)"
finding "firewalld direct rule" 'echo "ipv4 filter INPUT 0 -j ACCEPT" >"$S/fake/fw_direct"' "firewalld: 1 direct rule(s)"
finding "user with files of their own" 'mkdir -p "$S/home/alice/public_html" && echo hi >"$S/home/alice/public_html/index.html" && echo "alice:x:1001:1001::$S/home/alice:/bin/bash" >>"$S/etc/passwd"' 'user alice (uid 1001) has files in $S/home/alice'
finding "cloud user with a file outside the ignored ones" 'echo data >"$S/home/linuxuser/notes.txt"' 'user linuxuser (uid 1000) has files in $S/home/linuxuser'
finding "user home outside /home" 'mkdir -p "$S/srv/app" && echo x >"$S/srv/app/app.py" && echo "app:x:1002:1002::$S/srv/app:/bin/bash" >>"$S/etc/passwd"' 'user app (uid 1002) has files in $S/srv/app'
finding "/home entry that is no user's home" 'mkdir -p "$S/home/old" && echo x >"$S/home/old/site.tar"' '$S/home/old holds files'
finding "plain file in /home" 'echo x >"$S/home/backup.tar"' '$S/home/backup.tar holds files'
finding "/var/www with a site" 'mkdir -p "$S/var/www/html" && echo hi >"$S/var/www/html/index.html" && echo hi >"$S/var/www/html/a.css"' '$S/var/www holds 2 file(s)'
finding "PostgreSQL data" 'mkdir -p "$S/var/lib/pgsql/data/base" && echo x >"$S/var/lib/pgsql/data/PG_VERSION"' '$S/var/lib/pgsql/data holds database files'
finding "MariaDB from mariadb.org" 'echo MariaDB-server >"$S/fake/rpm"' "package MariaDB-server is installed"
finding "home that is a symlink to data" 'mkdir -p "$S/data/alice" && echo x >"$S/data/alice/site.php" && ln -s "$S/data/alice" "$S/home/alice" && echo "alice:x:1001:1001::$S/home/alice:/bin/bash" >>"$S/etc/passwd"' 'user alice (uid 1001) has files in $S/home/alice'
finding "custom rules in a default zone no interface is bound to" ': >"$S/fake/fw_active"; echo work >"$S/fake/fw_default"; echo "8443/tcp" >"$S/fake/fw_work_ports"' "firewalld: zone work ports: 8443/tcp"
finding "database files" 'mkdir -p "$S/var/lib/mysql" && echo x >"$S/var/lib/mysql/ibdata1"' '$S/var/lib/mysql holds database files'

new_server unit_alias
printf "mariadb\nmysqld\n" >"$S/fake/units"
echo mariadb.service >"$S/fake/unit_id_mysqld"
run 'existing_server_findings'
eq "a unit and its alias (mysqld = mariadb) are listed once" "service mariadb is running|STEP= REASON=" "$(tr '\n' '|' <<<"$OUT" | sed 's/|$//')"

new_server empty_www
mkdir -p "$S/var/www/html" "$S/var/www/cgi-bin" "$S/var/lib/mysql"
run 'existing_server_findings'
eq "empty /var/www/html and cgi-bin (httpd's package) and empty mysql dir: no findings" "STEP= REASON=" "$OUT"

new_server bracket_home
mkdir -p "$S/home/x[1]/.ssh"
cp "$S/etc/skel/.bashrc" "$S/home/x[1]/.bashrc"
echo key >"$S/home/x[1]/.ssh/authorized_keys"
run 'existing_server_findings'
eq "a home whose name holds pattern characters is matched literally" "STEP= REASON=" "$OUT"

new_server dotfile_user
echo x >"$S/home/linuxuser/.bashrc.orig"
run 'existing_server_findings'
has "a file named like a skeleton file but not one counts" "user linuxuser (uid 1000) has files" "$OUT"

# ---------------------------------------------------------------------------
echo "# refusal"
# ---------------------------------------------------------------------------
in_use() {
    new_server "$1"
    printf "httpd\nmariadb-server\npostfix\n" >"$S/fake/rpm"
    printf "httpd\nmariadb\npostfix\n" >"$S/fake/units"
    echo 'LISTEN 0 511 *:80 *:* users:(("httpd",pid=9,fd=4))' >>"$S/fake/ss"
    mkdir -p "$S/var/www/html"
    echo "<h1>my site</h1>" >"$S/var/www/html/index.html"
}
in_use refused
run 'check_existing_server; echo PASSED'
eq "server in use: exit 1" 1 "$RC"
hasnt "server in use: install does not go on" PASSED "$OUT"
has "server in use: reported as check_existing_server / existing_server" "STEP=check_existing_server REASON=existing_server" "$OUT"
has "says the server is in use" "This server is already in use" "$OUT"
has "lists the package" "  - package httpd is installed" "$OUT"
has "lists the running database" "  - service mariadb is running" "$OUT"
has "lists the port" "  - port 80 is in use by httpd" "$OUT"
has "lists the site files" "  - $S/var/www holds 1 file(s)" "$OUT"
has "lists the SELinux change" "  - SELinux: enforcement is switched off now" "$OUT"
has "lists the policy drop firewall tables" 'the nftables tables "ip filter" and "ip6 filter" are replaced by AdminBolt'"'"'s, whose INPUT and forward chains have policy drop' "$OUT"
has "lists the configuration files written over" "/etc/postfix/main.cf and master.cf" "$OUT"
has "lists what happens to MariaDB" "the database root password is reset" "$OUT"
has "names the flag" "rerun with --force-existing-server" "$OUT"

in_use selinux_off
echo Disabled >"$S/fake/selinux"
echo "SELINUX=disabled" >"$S/etc/selinux/config"
run 'check_existing_server'
hasnt "SELinux already disabled: no SELinux line" "SELinux: enforcement" "$OUT"
in_use selinux_permissive_config
echo Permissive >"$S/fake/selinux"
echo "SELINUX=permissive" >"$S/etc/selinux/config"
run 'check_existing_server'
has "SELinux permissive in the config: SELinux line" "SELinux: enforcement" "$OUT"

in_use reinstall
echo bolt-agent >>"$S/fake/rpm"
run 'check_existing_server; echo PASSED'
eq "AdminBolt already installed (reinstall, rerun): passes" 0 "$RC"
has "reinstall: says why it is not checked" "AdminBolt is already installed on this server" "$OUT"
hasnt "reinstall: nothing listed" "package httpd" "$OUT"

in_use reinstall_forced
echo bolt-panel >>"$S/fake/rpm"
run 'FORCE_EXISTING_SERVER=1; check_existing_server; if ((FORCE_EXISTING_SERVER && !ADMINBOLT_ALREADY_INSTALLED)); then echo WOULD-BACKUP; fi'
hasnt "reinstall with the flag: no backup (the configuration is the panel's own)" WOULD-BACKUP "$OUT"

in_use forced
run 'FORCE_EXISTING_SERVER=1; check_existing_server; echo PASSED'
eq "--force-existing-server: passes" 0 "$RC"
has "--force-existing-server: install goes on" PASSED "$OUT"
has "--force-existing-server: still lists what it found" "  - package httpd is installed" "$OUT"
has "--force-existing-server: says it installs anyway" "--force-existing-server given: installing anyway" "$OUT"
has "--force-existing-server: no failure reported" "STEP= REASON=" "$OUT"

# ---------------------------------------------------------------------------
echo "# the flag"
# ---------------------------------------------------------------------------
new_server args
run 'report_init() { :; }; REPORT_MARKER="$S/marker"; stage_prerequisites() { echo "FORCE=$FORCE_EXISTING_SERVER"; exit 0; }; main --force-existing-server'
has "--force-existing-server sets the flag" "FORCE=1" "$OUT"
run 'report_init() { :; }; REPORT_MARKER="$S/marker"; stage_prerequisites() { echo "FORCE=$FORCE_EXISTING_SERVER"; exit 0; }; main'
has "without it the flag is off" "FORCE=0" "$OUT"
run 'print_usage'
has "usage names the flag" "[--force-existing-server]" "$OUT"
grep -q -- '--force-existing-server' "$HERE/../README.md" && ok "README documents the flag" || nok "README documents the flag"
# The README lists what the check looks for; it must not drift from the code.
missing=""
section=$(sed -n '/^## Servers already in use/,/^## Install report/p' "$HERE/../README.md")
for name in $EXISTING_PACKAGES $FIREWALLD_IMAGE_SERVICES; do grep -qF -- "\`$name\`" <<<"$section" || missing+=" $name"; done
for name in $EXISTING_PORTS; do grep -qE -- "[ (]$name[,)]" <<<"$section" || missing+=" $name"; done
for name in $BACKUP_PATHS; do grep -qF -- "${name##*/}" <<<"$section" || missing+=" $name"; done
eq "README lists every package, port, default firewalld service and backed-up path the code uses" "" "$missing"
extra=""
for name in $(grep -F 'server package (' <<<"$section" | grep -oE '`[A-Za-z0-9-]+`' | tr -d '`'); do
    _report_in_list "$name" "$EXISTING_PACKAGES" || extra+=" $name"
done
eq "README lists no package the code does not check" "" "$extra"

# Stage 1 runs the check after the port check and makes the backup only with
# the flag (stage_prerequisites itself needs root, so its body is read).
body=$(ADMINBOLT_INSTALL_SOURCE_ONLY=1 "$BASH" -c ". '$INSTALL_SH'; declare -f stage_prerequisites" | grep -E 'check_port_8443|check_existing_server|FORCE_EXISTING_SERVER|backup_existing_configuration' | sed 's/^ *//')
eq "Stage 1: port check, existing-server check, backup only with the flag" "check_port_8443;
check_existing_server;
if ((FORCE_EXISTING_SERVER && !ADMINBOLT_ALREADY_INSTALLED)); then
backup_existing_configuration;" "$body"

end_call=$(ADMINBOLT_INSTALL_SOURCE_ONLY=1 "$BASH" -c ". '$INSTALL_SH'; declare -f stage_configuration" | grep -A1 'install_report_replaced_files' | sed 's/^ *//' | tr '\n' ' ')
eq "Stage 3 ends with the list of replaced files" 'install_report_replaced_files; print_progress "100% — post-install"; ' "$end_call"

# ---------------------------------------------------------------------------
echo "# backup with --force-existing-server"
# ---------------------------------------------------------------------------
in_use backup
mkdir -p "$S/etc/postfix" "$S/etc/httpd/conf" "$S/var/spool/cron"
echo "myhostname = mail.example.org" >"$S/etc/postfix/main.cf"
echo "Listen 80" >"$S/etc/httpd/conf/httpd.conf"
echo "secret" >"$S/etc/shadow-like"
chmod 640 "$S/etc/postfix/main.cf"
echo "*/5 * * * * /usr/local/bin/job" >"$S/var/spool/cron/alice"
echo "[client]" >"$S/root/.my.cnf"
run 'backup_existing_configuration; echo "DIR=$PREINSTALL_BACKUP_DIR"'
eq "backup: exit 0" 0 "$RC"
dir=$(sed -n 's/^DIR=//p' <<<"$OUT")
check_dir() { [[ -n "$dir" && -d "$dir" ]]; }
if check_dir; then ok "backup: directory created"; else nok "backup: directory created" "$OUT"; dir="$T/none"; fi
eq "backup: directory under BACKUP_PARENT, named with the date" 1 "$(grep -cE "^$S/root/adminbolt-preinstall-backup-[0-9]{8}-[0-9]{6}\$" <<<"$dir")"
eq "backup: directory is root-only (700)" 700 "$(stat -c %a "$dir" 2>/dev/null)"
eq "backup: archive is not readable by others" 600 "$(stat -c %a "$dir/files.tar.gz" 2>/dev/null)"
has "backup: prints where" "Current configuration backed up to $dir" "$OUT"
mkdir -p "$S/restore"
tar -xzpf "$dir/files.tar.gz" -C "$S/restore" 2>/dev/null
same=0
for f in etc/postfix/main.cf etc/httpd/conf/httpd.conf etc/shadow-like var/spool/cron/alice root/.my.cnf var/www/html/index.html; do
    cmp -s "$S/$f" "$S/restore$S/$f" && same=$((same + 1))
done
eq "backup: every backed-up file identical to the original" 6 "$same"
eq "backup: mode kept" 640 "$(stat -c %a "$S/restore$S/etc/postfix/main.cf" 2>/dev/null)"
has "backup: checksum list of the files" "$S/etc/postfix/main.cf" "$(cat "$dir/manifest.sha256" 2>/dev/null)"
eq "backup: firewall ruleset saved" ruleset "$(cat "$dir/nft-ruleset.nft" 2>/dev/null)"
eq "backup: SELinux mode saved" Enforcing "$(cat "$dir/selinux-mode.txt" 2>/dev/null)"
has "backup: README says how to restore one file" "tar -xzpf files.tar.gz -C /" "$(cat "$dir/README.txt" 2>/dev/null)"

# What the install then replaced: one file changed, one removed, one untouched.
echo "myhostname = adminbolt" >"$S/etc/postfix/main.cf"
rm -f "$S/var/www/html/index.html"
run "PREINSTALL_BACKUP_DIR='$dir'; install_report_replaced_files"
has "end: says where the originals are" "$dir/files.tar.gz holds the files as they were" "$OUT"
has "end: counts the replaced files" "The install changed or removed 2 of them" "$OUT"
eq "end: list of replaced files is exact and sorted" "$(printf '%s\n' "$S/etc/postfix/main.cf" "$S/var/www/html/index.html" | sort)" "$(cat "$dir/replaced-files.txt" 2>/dev/null)"
has "end: lists a replaced file" "  $S/etc/postfix/main.cf" "$OUT"
hasnt "end: an untouched file is not listed" "httpd.conf" "$OUT"

new_server backup_none_changed
mkdir -p "$S/var/spool/cron"
echo x >"$S/etc/a.conf"
run 'backup_existing_configuration; install_report_replaced_files'
has "end: nothing changed is said so" "None of them was changed by the install" "$OUT"

run "PREINSTALL_BACKUP_DIR='$dir'; rm -f '$dir/manifest.sha256'; install_report_replaced_files"
has "end: no checksum list is said so" "could not compare the files with the backup" "$OUT"
hasnt "end: no checksum list never reads as nothing changed" "None of them was changed" "$OUT"

run 'install_report_replaced_files; echo DONE'
eq "end without a backup: prints nothing" "DONE STEP= REASON=" "$(tr '\n' ' ' <<<"$OUT" | sed 's/ $//')"

run "trap report_on_exit EXIT; PREINSTALL_BACKUP_DIR='$dir'; exit 3"
has "failed install after a backup: the exit names the backup again" "The configuration from before this install is in $dir" "$OUT"
eq "failed install after a backup: exit code kept" 3 "$RC"
run "trap report_on_exit EXIT; PREINSTALL_BACKUP_DIR='$dir'; exit 0"
hasnt "successful install: the exit does not repeat it" "The configuration from before this install" "$OUT"

new_server backup_no_parent
run 'BACKUP_PARENT="$S/no/such/dir"; backup_existing_configuration; echo PASSED'
eq "backup directory cannot be created: exit 1" 1 "$RC"
hasnt "backup directory cannot be created: install stops" PASSED "$OUT"
has "backup directory cannot be created: reported as preinstall_backup" "STEP=preinstall_backup REASON=required_step_failed" "$OUT"

new_server backup_no_space
echo 10 >"$S/fake/df_avail"
run 'backup_existing_configuration; echo PASSED'
eq "not enough space: exit 1" 1 "$RC"
has "not enough space: says so" "Not enough free space" "$OUT"
has "not enough space: reported as preinstall_backup" "STEP=preinstall_backup" "$OUT"
eq "not enough space: no backup directory left" 0 "$(find "$S/root" -mindepth 1 -maxdepth 1 -name 'adminbolt-preinstall-backup-*' | wc -l)"

new_server backup_no_checksums
mkdir -p "$S/empty"
run 'BACKUP_PATHS="$S/empty"; backup_existing_configuration; echo PASSED'
eq "no checksums: exit 1" 1 "$RC"
has "no checksums: says so" "no checksums could be taken" "$OUT"
eq "no checksums: no backup directory left" 0 "$(find "$S/root" -mindepth 1 -maxdepth 1 -name 'adminbolt-preinstall-backup-*' | wc -l)"

new_server backup_tar_fails
run 'tar() { return 2; }; backup_existing_configuration; echo PASSED'
eq "tar fails: exit 1" 1 "$RC"
has "tar fails: says so" "The backup failed (tar exit 2)" "$OUT"
hasnt "tar fails: install stops" PASSED "$OUT"
eq "tar fails: no partial backup left" 0 "$(find "$S/root" -mindepth 1 -maxdepth 1 -name 'adminbolt-preinstall-backup-*' | wc -l)"

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
