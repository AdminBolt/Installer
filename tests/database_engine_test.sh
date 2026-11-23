#!/usr/bin/env bash
#
# Tests for AB-2339 in install.sh: --database=<mariadb|mysql8.0|mysql8.4>,
# MySQL from AppStream instead of MariaDB. No network, no root: rpm, dnf,
# systemctl, mysql, mysqladmin and bolt-cli are fakes on PATH, and install.sh
# is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install never runs.
#
# Needs bash 4+.
#   Linux:  bash tests/database_engine_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/database_engine_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")

if ((BASH_VERSINFO[0] < 4)); then echo "bash 4 or newer required (this is $BASH_VERSION)" >&2; exit 2; fi

T=$(mktemp -d)
trap '[[ -n "${KEEP_T:-}" ]] || rm -rf "$T"' EXIT
export LC_ALL=C

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else nok "$1" "'$2' not in output"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then nok "$1" "'$2' in output"; else ok "$1"; fi; }

check_syntax() {
    if "$BASH" -n "$INSTALL_SH"; then ok "bash -n install.sh"; else nok "bash -n install.sh"; fi
}
check_syntax

# ---------------------------------------------------------------------------
# Fakes. Each child has its own $FAKE_DIR:
#   rpm        installed package names, one per line (rpm -q, rpm -qa <glob>)
#   ping       present = a database server answers mysqladmin ping
#   repolist   what `dnf repolist --all` prints
#   avail      package specs `dnf list` finds
#   inactive   systemd units that are not active
# bolt-cli, dnf install and systemctl calls are logged.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
pkg="${*: -1}"
if [[ "$1" == -qa ]]; then
    while read -r p; do [[ -n "$p" && "$p" == $pkg ]] && echo "$p-8.0.46-1.el9.x86_64"; done <"$FAKE_DIR/rpm" 2>/dev/null
    exit 0
fi
grep -qxF -- "$pkg" "$FAKE_DIR/rpm" 2>/dev/null && { echo "$pkg-1-1.el9.x86_64"; exit 0; }
echo "package $pkg is not installed"
exit 1
EOF
# stale_cnf present = ROOT_MY_CNF holds a password the new server does not
# have: a client that reads it is refused (mysqladmin ping still exits 0, as
# the real one does), one started with --no-defaults or --defaults-file is not.
cat >"$T/bin/mysqladmin" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/mysqladmin.log"
if [[ -e "$FAKE_DIR/ping" ]]; then
    [[ -e "$FAKE_DIR/stale_cnf" && "$1" != --no-defaults ]] && echo "mysqladmin: connect to server at 'localhost' failed: Access denied for user 'root'@'localhost' (using password: YES)" >&2
    echo "mysqld is alive"; exit 0
fi
exit 1
EOF
cp "$T/bin/mysqladmin" "$T/bin/mariadb-admin"
cat >"$T/bin/dnf" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/dnf.log"
case " $* " in
    *" repolist "*) cat "$FAKE_DIR/repolist" 2>/dev/null; exit 0 ;;
    *" list "*) grep -qxF -- "${*: -1}" "$FAKE_DIR/avail" 2>/dev/null; exit ;;
esac
exit 0
EOF
cat >"$T/bin/bolt-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/bolt-cli.log"
exit 0
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/systemctl.log"
if [[ "$1" == is-active ]]; then
    shift
    for u in "$@"; do
        if grep -qxF -- "$u" "$FAKE_DIR/inactive" 2>/dev/null; then echo inactive; else echo active; fi
    done
fi
exit 0
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 302
EOF
chmod +x "$T/bin/"*
cat >"$T/bin/mysql" <<'EOF'
#!/usr/bin/env bash
# The command line and, for a call without -e, what came on stdin, each on
# its own ARGS / STDIN line.
echo "ARGS: $*" >>"$FAKE_DIR/mysql.log"
[[ " $* " == *" --no-defaults "* ]] && printf '%s' "${MYSQL_TEST_LOGIN_FILE:-unset}" >"$FAKE_DIR/login-file"
stdin=""
if [[ " $* " != *" -NBe "* && " $* " != *" -e "* ]]; then
    stdin=$(cat)
    echo "STDIN: $stdin" >>"$FAKE_DIR/mysql.log"
fi
if [[ -e "$FAKE_DIR/stale_cnf" && "$1" != --no-defaults && "$1" != --defaults-file=* ]]; then
    echo "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)" >&2
    exit 1
fi
if [[ -e "$FAKE_DIR/no_connect" ]]; then
    echo "ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/var/lib/mysql/mysql.sock' (2)" >&2
    exit 1
fi
if [[ -e "$FAKE_DIR/root_has_password" && "$1" == --no-defaults ]]; then
    echo "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)" >&2
    exit 1
fi
case "$* $stdin" in
    *"SELECT VERSION()"*) cat "$FAKE_DIR/version" 2>/dev/null; exit 0 ;;
    *"ALTER USER"*) [[ -e "$FAKE_DIR/alter_fails" ]] && exit 1; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/mysql"

# $1 name, $2 code to run after install.sh is loaded. Helpers called in
# $(...) set D in the subshell only; at() points D at a child's directory again.
at() { D="$T/$1"; }
child() {
    D="$T/$1"
    rm -rf "$D"
    mkdir -p "$D/fake"
    cat >"$D/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
set +e
REPORT_DIR="$D/spool"
REPORT_UNIT_DIR="$D/units"
REPORT_SENDER="$D/libexec/send"
REPORT_MARKER="$D/install-marker"
REPORT_EUID=0
OS_RELEASE_FILE="$D/os-release"
ROOT_MY_CNF="$D/my.cnf"
MYSQL_ROOT_OPEN_MARKER="$D/root-open-marker"
AGENT_CONF="$D/agent.conf"
$2
EOF
}
run() { (cd "$D" && FAKE_DIR="$D/fake" PATH="$T/bin:$PATH" "$BASH" child.sh >"$D/out" 2>&1); RC=$?; }
out() { cat "$D/out"; }


# ---------------------------------------------------------------------------
echo "# arguments"
# ---------------------------------------------------------------------------
parse() {
    local a q=""
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    child parse 'stage_prerequisites() { echo "STAGE1 engine=${DATABASE_ENGINE:-none} db=$SKIP_DATABASE"; exit 0; }
main --no-telemetry'"$q"
    run
}
parse --database=mysql8.4
has "--database=mysql8.4 accepted" "STAGE1 engine=mysql8.4 db=0" "$(out)"
parse --database=mysql8.0
has "--database=mysql8.0 accepted" "STAGE1 engine=mysql8.0 db=0" "$(out)"
parse --database=mariadb
has "--database=mariadb accepted" "STAGE1 engine=mariadb db=0" "$(out)"
parse --database=postgresql
eq "unknown engine refused" "1" "$RC"
has "unknown engine: says why" "Invalid --database=postgresql (supported: mariadb, mysql8.0, mysql8.4)" "$(out)"
parse --database=
eq "empty --database= refused" "1" "$RC"
has "empty --database=: says why" "Invalid --database= (supported: mariadb, mysql8.0, mysql8.4)" "$(out)"
hasnt "empty --database=: the install does not start" "STAGE1" "$(out)"
parse --database= --database=mysql8.4
has "the last --database wins: mysql8.4 after an empty one" "STAGE1 engine=mysql8.4 db=0" "$(out)"
parse
has "no --database: the default (MariaDB) install starts" "STAGE1 engine=none db=0" "$(out)"
parse --database=mysql8.4 --skip-database
eq "mysql with --skip-database refused" "1" "$RC"
has "mysql with --skip-database: says why" "cannot be combined with --skip-database or --mariadb-version" "$(out)"
parse --database=mysql8.0 --mariadb-version=11.4
eq "mysql with --mariadb-version refused" "1" "$RC"

# ---------------------------------------------------------------------------
echo "# the MySQL install"
# ---------------------------------------------------------------------------
STUBS='report_step_start() { :; }; report_step_result() { :; }; report_fail() { echo "FAIL $*"; }
sleep() { :; }'
mysql_install() { # $1 engine, $2 version the server reports
    child mysqlinst "$STUBS
DATABASE_ENGINE=$1
install_mysql_engine
echo \"DONE skip=\$SKIP_DATABASE reason=\$DATABASE_SKIP_REASON\""
    echo "$2" >"$D/fake/version"
    touch "$D/fake/ping"
    run
}
mysql_install mysql8.4 8.4.3
has "8.4: finished" "DONE skip=1 reason=MySQL 8.4 installed by --database=mysql8.4" "$(out)"
has "8.4: the module stream is enabled" "-y -q module enable mysql:8.4" "$(cat "$D/fake/dnf.log")"
has "8.4: mysql-server installed" "-y install mysql-server" "$(cat "$D/fake/dnf.log")"
has "8.4: mysqld started" "start mysqld" "$(cat "$D/fake/systemctl.log")"
has "8.4: mysqld enabled" "enable mysqld" "$(cat "$D/fake/systemctl.log")"
hasnt "8.4: never enabled with --now (before root's password)" "enable --now mysqld" "$(cat "$D/fake/systemctl.log")"
[[ ! -e "$D/root-open-marker" ]] && ok "8.4: no root-open marker once root has its password" || nok "8.4: no root-open marker once root has its password"
pw=$(sed -n 's/^password="\([0-9a-f]*\)"$/\1/p' "$D/my.cnf")
eq "8.4: a 48-hex root password in my.cnf" "48" "${#pw}"
has "8.4: root's password set to it, on stdin" "STDIN: ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw}'" "$(cat "$D/fake/mysql.log")"
hasnt "8.4: the password is not on the mysql command line" "$pw" "$(grep '^ARGS: ' "$D/fake/mysql.log")"
has "8.4: my.cnf names root" "user=root" "$(cat "$D/my.cnf")"
mode=$(stat -c %a "$D/my.cnf" 2>/dev/null || stat -f %Lp "$D/my.cnf")
eq "8.4: my.cnf is 0600" "600" "$mode"

mysql_install mysql8.0 8.0.46
has "8.0: finished" "DONE skip=1" "$(out)"
hasnt "8.0: no module stream" "module enable" "$(cat "$D/fake/dnf.log")"

mysql_install mysql8.4 8.0.46
eq "a server reporting another version stops the install" "1" "$RC"
has "the wrong version is named" "the server reports version '8.0.46', not MySQL 8.4" "$(out)"
has "reported as a failed database step" "FAIL mariadb package_install_failed" "$(out)"

child mysqlalter "$STUBS
DATABASE_ENGINE=mysql8.4
install_mysql_engine
echo DONE"
echo 8.4.3 >"$D/fake/version"; touch "$D/fake/ping" "$D/fake/alter_fails"
run
eq "a root password that cannot be set stops the install" "1" "$RC"
[[ ! -e "$D/my.cnf" ]] && ok "no my.cnf is written then" || nok "no my.cnf is written then"

child mysqlnoping "$STUBS
MYSQL_READY_WAIT_SECONDS=2
DATABASE_ENGINE=mysql8.0
install_mysql_engine
echo DONE"
echo 8.0.46 >"$D/fake/version"
run
eq "a server that never answers stops the install" "1" "$RC"
has "says it did not answer" "mysqld did not answer within 2 seconds" "$(out)"

# Code review blocker (AB-2339 CR): mysqld must never be left running with
# root's empty password, on any way out of the install.
stopped() { grep -qxF "disable --now mysqld" "$D/fake/systemctl.log" 2>/dev/null; }
altered() { grep -q "^STDIN: ALTER USER 'root'@'localhost'" "$D/fake/mysql.log" 2>/dev/null; }

child mysqlstale "$STUBS
DATABASE_ENGINE=mysql8.4
install_mysql_engine
echo \"DONE skip=\$SKIP_DATABASE\""
echo 8.4.3 >"$D/fake/version"; touch "$D/fake/ping" "$D/fake/stale_cnf"
printf '[client]\nuser=root\npassword="stale"\n' >"$D/my.cnf"
run
eq "stale my.cnf: the install goes on" "0" "$RC"
has "stale my.cnf: finished" "DONE skip=1" "$(out)"
altered && ok "stale my.cnf: root gets its password" || nok "stale my.cnf: root gets its password" "$(cat "$D/fake/mysql.log")"
has "stale my.cnf: the password is set with --no-defaults" "ARGS: --no-defaults --socket=/var/lib/mysql/mysql.sock -uroot --connect-timeout=10 -NB" "$(cat "$D/fake/mysql.log")"
has "stale my.cnf: the ping skips it" "--no-defaults --socket=/var/lib/mysql/mysql.sock -uroot --connect-timeout=5 ping" "$(cat "$D/fake/mysqladmin.log")"
eq "stale my.cnf: ~/.mylogin.cnf is not read either" "/dev/null" "$(cat "$D/fake/login-file" 2>/dev/null)"
pw=$(sed -n 's/^password="\([0-9a-f]*\)"$/\1/p' "$D/my.cnf")
eq "stale my.cnf: replaced by the new login" "48" "${#pw}"
ls "$D"/my.cnf.bak-* >/dev/null 2>&1 && ok "stale my.cnf: the old file is kept" || nok "stale my.cnf: the old file is kept"
grep -q 'password="stale"' "$D"/my.cnf.bak-* 2>/dev/null && ok "stale my.cnf: the copy holds the old login" || nok "stale my.cnf: the copy holds the old login"
stopped && nok "stale my.cnf: mysqld keeps running" || ok "stale my.cnf: mysqld keeps running"

mysql_install mysql8.4 8.0.46
stopped && nok "wrong version: mysqld with root's password is not stopped" || ok "wrong version: mysqld with root's password is not stopped"
altered && ok "wrong version: root got its password before the check" || nok "wrong version: root got its password before the check"
pw=$(sed -n 's/^password="\([0-9a-f]*\)"$/\1/p' "$D/my.cnf")
eq "wrong version: the login is in my.cnf" "48" "${#pw}"

at mysqlalter
stopped && ok "ALTER USER fails: mysqld is stopped and disabled" || nok "ALTER USER fails: mysqld is stopped and disabled" "$(cat "$D/fake/systemctl.log")"
grep -qxF "enable mysqld" "$D/fake/systemctl.log" && nok "ALTER USER fails: mysqld was never enabled" || ok "ALTER USER fails: mysqld was never enabled"
[[ -e "$D/root-open-marker" ]] && ok "ALTER USER fails: the root-open marker stays" || nok "ALTER USER fails: the root-open marker stays"
has "ALTER USER fails: says how to go on" "dnf -y remove mysql-server" "$(out)"

# The next run, with or without --database, refuses that server while the
# marker is there; once the package is gone it goes on.
decide() { # $1: rpm list
    child decide "report_fail() { echo \"FAIL \$*\"; }
database_skip_decide
echo \"DECIDED skip=\$SKIP_DATABASE\""
    touch "$D/root-open-marker"
    printf '%s\n' "$1" >"$D/fake/rpm"
    run
}
decide mysql-server
eq "marker and mysql-server: the next run is refused" "1" "$RC"
has "marker and mysql-server: says why" "stopped before root had a password" "$(out)"
hasnt "marker and mysql-server: the server is not kept" "DECIDED" "$(out)"
decide ""
has "marker, server removed: the run goes on" "DECIDED skip=0" "$(out)"
[[ ! -e "$D/root-open-marker" ]] && ok "marker, server removed: the marker is cleared" || nok "marker, server removed: the marker is cleared"

# A kill no trap sees, while mysqld waits to answer: the marker stays, and
# mysqld was only started, never enabled.
child mysqlkill "$STUBS
DATABASE_ENGINE=mysql8.0
sleep() { kill -9 \$\$; }
install_mysql_engine
echo DONE"
run
hasnt "killed while waiting: did not finish" "DONE" "$(out)"
[[ -e "$D/root-open-marker" ]] && ok "killed while waiting: the root-open marker stays" || nok "killed while waiting: the root-open marker stays"
grep -qxF "enable mysqld" "$D/fake/systemctl.log" && nok "killed while waiting: mysqld not enabled" || ok "killed while waiting: mysqld not enabled"

# root already has a password (a data directory kept from an earlier install):
# root is not open, mysqld keeps running, the message says why.
child mysqlkept "$STUBS
DATABASE_ENGINE=mysql8.0
install_mysql_engine
echo DONE"
echo 8.0.46 >"$D/fake/version"; touch "$D/fake/ping" "$D/fake/root_has_password"
run
eq "kept data directory: the install stops" "1" "$RC"
has "kept data directory: says why" "root already has a password on this server's data directory" "$(out)"
stopped && nok "kept data directory: mysqld is not stopped" || ok "kept data directory: mysqld is not stopped"
[[ ! -e "$D/root-open-marker" ]] && ok "kept data directory: no root-open marker" || nok "kept data directory: no root-open marker"

# mysqld gone between the ping and the ALTER (ERROR 2002 to every client):
# that is no password on root, so mysqld is stopped and the marker stays.
child mysqlgone "$STUBS
DATABASE_ENGINE=mysql8.0
install_mysql_engine
echo DONE"
echo 8.0.46 >"$D/fake/version"; touch "$D/fake/ping" "$D/fake/no_connect"
run
eq "mysqld gone before the ALTER: the install stops" "1" "$RC"
stopped && ok "mysqld gone before the ALTER: mysqld is stopped and disabled" || nok "mysqld gone before the ALTER: mysqld is stopped and disabled"
[[ -e "$D/root-open-marker" ]] && ok "mysqld gone before the ALTER: the root-open marker stays" || nok "mysqld gone before the ALTER: the root-open marker stays"

# A failed package install leaves the marker; with no server it is cleared
# by the next run, with a half-installed one that run refuses it.
child mysqlpkg "$STUBS
DATABASE_ENGINE=mysql8.0
dnf() { [[ \" \$* \" == *\" install \"* ]] && return 1; return 0; }
install_mysql_engine
echo DONE"
run
eq "package install fails: the install stops" "1" "$RC"
[[ -e "$D/root-open-marker" ]] && ok "package install fails: the marker was written before it" || nok "package install fails: the marker was written before it"
at mysqlalter
has "ALTER USER fails: says so" "mysqld was stopped and disabled" "$(out)"
ls "$D"/my.cnf.new.* >/dev/null 2>&1 && nok "ALTER USER fails: no new login file is left" || ok "ALTER USER fails: no new login file is left"

# A signal after the new login was written but before the ALTER: the EXIT
# trap stops mysqld and removes that login (its password was never set).
child mysqlsig "$STUBS
trap report_on_exit EXIT
REPORT_MODE=off
DATABASE_ENGINE=mysql8.0
mysql() { [[ \" \$* \" == *\" -NB \"* ]] && { kill -TERM \$\$; sleep 2; }; command mysql \"\$@\"; }
install_mysql_engine
echo DONE"
echo 8.0.46 >"$D/fake/version"; touch "$D/fake/ping"
run
stopped && ok "cut before the ALTER: mysqld is stopped" || nok "cut before the ALTER: mysqld is stopped"
ls "$D"/my.cnf.new.* >/dev/null 2>&1 && nok "cut before the ALTER: no new login file is left" || ok "cut before the ALTER: no new login file is left"

at mysqlnoping
stopped && ok "no answer: mysqld is stopped and disabled" || nok "no answer: mysqld is stopped and disabled" "$(cat "$D/fake/systemctl.log" 2>/dev/null)"

child mysqlbackup "$STUBS
DATABASE_ENGINE=mysql8.0
cp() { return 1; }
install_mysql_engine
echo DONE"
echo 8.0.46 >"$D/fake/version"; touch "$D/fake/ping"
printf '[client]\nuser=root\npassword="old"\n' >"$D/my.cnf"
run
eq "old my.cnf cannot be backed up: the install stops" "1" "$RC"
has "old my.cnf cannot be backed up: says so" "could not be backed up" "$(out)"
altered && nok "old my.cnf cannot be backed up: root's password is not changed" || ok "old my.cnf cannot be backed up: root's password is not changed"
grep -q 'password="old"' "$D/my.cnf" && ok "old my.cnf cannot be backed up: it is left as it was" || nok "old my.cnf cannot be backed up: it is left as it was"
stopped && ok "old my.cnf cannot be backed up: mysqld is stopped" || nok "old my.cnf cannot be backed up: mysqld is stopped"

# Any other way out (a signal, set -e) goes through the EXIT trap.
child mysqlexit "$STUBS
trap report_on_exit EXIT
REPORT_MODE=off
MYSQL_READY_WAIT_SECONDS=5
DATABASE_ENGINE=mysql8.0
sleep() { exit 130; }
install_mysql_engine
echo DONE"
run
hasnt "cut off while waiting: did not finish" "DONE" "$(out)"
stopped && ok "cut off while waiting: the EXIT trap stops mysqld" || nok "cut off while waiting: the EXIT trap stops mysqld" "$(cat "$D/fake/systemctl.log" 2>/dev/null)"

mysql_install mysql8.0 8.0.46
has "8.0: the mysql module is reset" "-y -q module reset mysql" "$(cat "$D/fake/dnf.log")"

# ---------------------------------------------------------------------------
echo "# Stage 3 with MySQL"
# ---------------------------------------------------------------------------
child stage3mysql 'report_step_start() { :; }; report_step_result() { :; }; report_fail() { :; }
set +e
sleep() { :; }
ssh_password_login_off() { :; }
check_agent_setup_at_end() { :; }
# Stage 1 decided on a box without a database server.
DATABASE_SKIP_DECIDED=1
DATABASE_ENGINE=mysql8.4
stage_configuration'
echo 8.4.3 >"$D/fake/version"; touch "$D/fake/ping"
printf '[security]\ntoken=abc\n\n[dbservers.mariadb]\ntype=mysql\nhost=localhost\nport=3306\nuser=root\npassword=old\n' >"$D/agent.conf"
run
log=$(cat "$D/fake/bolt-cli.log")
hasnt "no MariaDB install" "manage-mariadb --action=install" "$log"
hasnt "no MariaDB profile" "manage-mariadb-default-profile" "$log"
has "the panel reads the database server" "refresh-database-server" "$log"
pw=$(sed -n 's/^password="\([0-9a-f]*\)"$/\1/p' "$D/my.cnf")
has "the agent gets root's new login" "password=\"${pw}\"" "$(cat "$D/agent.conf")"

echo "# ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
