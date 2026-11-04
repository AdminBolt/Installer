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
trap 'rm -rf "$T"' EXIT
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
cat >"$T/bin/mysqladmin" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/mysqladmin.log"
[[ -e "$FAKE_DIR/ping" ]] && { echo "mysqld is alive"; exit 0; }
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
stdin=""
if [[ " $* " != *" -NBe "* && " $* " != *" -e "* ]]; then
    stdin=$(cat)
    echo "STDIN: $stdin" >>"$FAKE_DIR/mysql.log"
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
has "8.4: mysqld enabled and started" "enable --now mysqld" "$(cat "$D/fake/systemctl.log")"
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
