#!/usr/bin/env bash
#
# Tests for AB-2331 in install.sh: CloudLinux 9 detection, --skip-database /
# --skip-apache, the database auto-skip, the agent's database login, the
# readiness check's database unit, the CRB repository ids and the pinned
# versions (--agent-version, --package). No network, no root: rpm, dnf,
# systemctl, curl, mysqladmin and bolt-cli are fakes on PATH, and install.sh
# is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install never runs.
#
# Needs bash 4+.
#   Linux:  bash tests/skip_and_pin_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/skip_and_pin_test.sh
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
echo "# distribution"
# ---------------------------------------------------------------------------
distro() { # $1 ID, $2 VERSION_ID -> detect_distribution's output and exit code
    child distro 'r=$(detect_distribution); echo "$r rc=$? id=${ID:-unset}"'
    printf 'NAME="X"\nID="%s"\nID_LIKE="rhel fedora centos"\nVERSION_ID="%s"\n' "$1" "$2" >"$D/os-release"
    run
    out
}
eq "AlmaLinux 9.4" "almalinux|9.4 rc=0 id=unset" "$(distro almalinux 9.4)"
eq "Rocky Linux 9" "rocky|9 rc=0 id=unset" "$(distro rocky 9)"
eq "CloudLinux 9.8 takes the same path" "cloudlinux|9.8 rc=0 id=unset" "$(distro cloudlinux 9.8)"
eq "CloudLinux 8 refused" " rc=1 id=unset" "$(distro cloudlinux 8.10)"
eq "CentOS Stream 9 refused" " rc=1 id=unset" "$(distro centos 9)"
eq "AlmaLinux 10 refused" " rc=1 id=unset" "$(distro almalinux 10.0)"
child distro_missing 'detect_distribution; echo "rc=$?"'
run
eq "no os-release refused" "rc=1" "$(out)"
child stage1_msg 'grep -c "AlmaLinux 9, Rocky Linux 9 and CloudLinux 9 only" "'"$INSTALL_SH"'"'
run
eq "the refusal names CloudLinux 9" "1" "$(out)"

# ---------------------------------------------------------------------------
echo "# arguments"
# ---------------------------------------------------------------------------
parse() { # $@ = installer arguments; runs the real main up to a Stage 1 stub
    local a q=""
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    child parse 'stage_prerequisites() { echo "STAGE1 db=$SKIP_DATABASE apache=$SKIP_APACHE agent=$AGENT_VERSION pinned=$(pinned_specs | paste -sd, -) nginx=$(pinned_spec bolt-nginx) agentspec=$(pinned_spec bolt-agent)"; exit 0; }
main --no-telemetry'"$q"
    run
}
parse
has "no flags: nothing skipped, nothing pinned" "STAGE1 db=0 apache=0 agent= pinned= nginx=bolt-nginx agentspec=bolt-agent" "$(out)"
parse --skip-database
has "--skip-database" "STAGE1 db=1 apache=0" "$(out)"
parse --skip-apache
has "--skip-apache" "STAGE1 db=0 apache=1" "$(out)"
parse --skip-database --skip-apache --source=testing
has "both flags with --source" "STAGE1 db=1 apache=1" "$(out)"
parse --source=testing --agent-version=1.30.4-pr230.1.el9 --package=bolt-php=8.4.14-1.el9 --package=bolt-cloudlinux=1.2.0-3.el9
has "--agent-version and two --package" \
    "agent=1.30.4-pr230.1.el9 pinned=bolt-agent-1.30.4-pr230.1.el9,bolt-php-8.4.14-1.el9,bolt-cloudlinux-1.2.0-3.el9 nginx=bolt-nginx agentspec=bolt-agent-1.30.4-pr230.1.el9" "$(out)"
parse --package=bolt-nginx=1.27.3-2.el9
has "--package for bolt-nginx gives its spec" "nginx=bolt-nginx-1.27.3-2.el9" "$(out)"

refused() { # $1 label, $2 expected message, rest = arguments
    local label="$1" msg="$2"; shift 2
    parse "$@"
    eq "$label: refused before Stage 1" "1 no" "$RC $(grep -q STAGE1 "$D/out" && echo yes || echo no)"
    has "$label: says why" "$msg" "$(out)"
    [[ ! -e "$D/pwned" ]] && ok "$label: nothing executed" || nok "$label: nothing executed"
}
refused "--package outside bolt-*" "Invalid --package=httpd=2.4.62-1.el9" --package=httpd=2.4.62-1.el9
refused "--package with upper case" "Invalid --package=bolt-PHP=8.4.14-1.el9" --package=bolt-PHP=8.4.14-1.el9
refused "--package without a version" "Invalid --package=bolt-php" --package=bolt-php
refused "--package without a release" "Invalid --package=bolt-php=8.4.14" --package=bolt-php=8.4.14
refused "--package with shell code" "Invalid --package=bolt-php=8.4-1;touch pwned" "--package=bolt-php=8.4-1;touch pwned"
refused "--package for bolt-agent" "use --agent-version= for bolt-agent" --package=bolt-agent=1.30.4-1.el9
refused "--package for bolt-panel" "use --version= for bolt-panel" --package=bolt-panel=1.9.0-1.el9
refused "--package twice for one name" "--package=bolt-php= given twice" --package=bolt-php=8.4.14-1.el9 --package=bolt-php=8.4.15-1.el9
refused "empty --agent-version" "Invalid --agent-version=" --agent-version=
refused "--agent-version without a release" "Invalid --agent-version=1.30.4" --agent-version=1.30.4

help=$(PATH="$T/bin:$PATH" "$BASH" "$INSTALL_SH" --help 2>&1)
for opt in "[--skip-database]" "[--skip-apache]" "[--agent-version=<version-release>]" "[--package=<bolt-name>=<version-release> ...]" "CloudLinux 9"; do
    has "--help lists $opt" "$opt" "$help"
done
readme=$(cat "$HERE/../README.md")
for opt in "--skip-database" "--skip-apache" "--agent-version=<version-release>" "--package=<bolt-name>=<version-release>" "CloudLinux 9" "/root/.my.cnf"; do
    has "README documents $opt" "$opt" "$readme"
done

# ---------------------------------------------------------------------------
echo "# database server already on the box"
# ---------------------------------------------------------------------------
decide() { # $@ = installed packages; prints SKIP_DATABASE and the reason
    child decide 'database_skip_decide; echo "skip=$SKIP_DATABASE reason=$DATABASE_SKIP_REASON"'
    printf '%s\n' "$@" >"$D/fake/rpm"
    [[ -n "${PING:-}" ]] && touch "$D/fake/ping"
    run
    tail -n 1 "$D/out"
}
eq "new box: database installed" "skip=0 reason=" "$(decide)"
eq "a server answers mysqladmin ping" "skip=1 reason=a database server answers (mysqladmin ping)" "$(PING=1 decide)"
eq "cl-MySQL80 under Governor (CloudLinux)" "skip=1 reason=cl-MySQL80-server-8.0.46-1.el9.x86_64 is installed" "$(decide cl-MySQL80-server governor-mysql)"
eq "cl-MariaDB" "skip=1 reason=cl-MariaDB106-server-8.0.46-1.el9.x86_64 is installed" "$(decide cl-MariaDB106-server)"
eq "mysql-server" "skip=1 reason=mysql-server is installed" "$(decide mysql-server)"
eq "MariaDB-server (the installer run again)" "skip=1 reason=MariaDB-server is installed" "$(decide MariaDB-server)"
eq "mariadb-server" "skip=1 reason=mariadb-server is installed" "$(decide mariadb-server)"
eq "a client package alone is no server" "skip=0 reason=" "$(decide MariaDB-client mysql)"
child glob 'database_skip_decide; echo "skip=$SKIP_DATABASE"'
# Expanded by the shell, cl-MySQL* would become the file name and miss the package.
touch "$D/cl-MySQL-file"
echo cl-MySQL80-server >"$D/fake/rpm"
run
eq "the package globs reach rpm unexpanded (a matching file in the current directory)" "skip=1" "$(tail -n 1 "$D/out")"
child explicit 'database_skip_decide; echo "skip=$SKIP_DATABASE reason=$DATABASE_SKIP_REASON"'
sed -i.bak 's/^database_skip_decide/SKIP_DATABASE=1; MARIADB_SERIES=11.4; database_skip_decide/' "$D/child.sh"
run
eq "--skip-database is the reason when given" "skip=1 reason=--skip-database" "$(tail -n 1 "$D/out")"
has "--skip-database: the reason is logged" "Database steps skipped (--skip-database)" "$(out)"
has "--mariadb-version with the database skipped: said to be ignored" "--mariadb-version=11.4 ignored" "$(out)"
[[ ! -e "$D/fake/mysqladmin.log" ]] && ok "--skip-database: no probe at all" || nok "--skip-database: no probe at all"

# ---------------------------------------------------------------------------
echo "# Stage 3 with steps skipped"
# ---------------------------------------------------------------------------
stage3() { # $1 SKIP_DATABASE, $2 SKIP_APACHE, rest = installed packages
    local db="$1" ap="$2"; shift 2
    child stage3 "report_step_start() { :; }; report_step_result() { :; }; report_fail() { :; }
set +e
sleep() { :; }
ssh_password_login_off() { :; }
# The agent end-state check (AB-2277) reads the real agent.conf and service.
check_agent_setup_at_end() { :; }
SKIP_DATABASE=$db SKIP_APACHE=$ap
stage_configuration"
    printf '%s\n' "$@" >"$D/fake/rpm"
    printf '[client]\nuser=root\npassword=secret\n' >"$D/my.cnf"
    printf '[security]\ntoken=abc\n\n[dbservers.mariadb]\ntype=mysql\nhost=localhost\nport=3306\nuser=root\npassword=mariadb_root_password\n' >"$D/agent.conf"
    run
    cat "$D/fake/bolt-cli.log"
}
calls=$(stage3 0 0)
has "plain install: MariaDB" "manage-mariadb --action=install --series=11.4" "$calls"
has "plain install: MariaDB profile" "manage-mariadb-default-profile --action=install" "$calls"
has "plain install: MyApache" "manage-my-apache --action=install" "$calls"
has "plain install: MyApache profile" "manage-my-apache-default-profile --action=install" "$calls"
calls=$(stage3 1 0)
hasnt "--skip-database: no MariaDB step" "manage-mariadb" "$calls"
has "--skip-database: MyApache still installed" "manage-my-apache --action=install" "$calls"
has "--skip-database: the rest still runs (postfix)" "manage-postfix --action=install" "$calls"
has "--skip-database: the rest still runs (apps)" "setup-cron-jobs" "$calls"
at stage3
has "--skip-database: the agent gets the login from my.cnf" 'password="secret"' "$(cat "$D/agent.conf")"
calls=$(stage3 0 1)
has "--skip-apache: MariaDB still installed" "manage-mariadb --action=install" "$calls"
hasnt "--skip-apache: no MyApache step" "manage-my-apache" "$calls"
has "--skip-apache: the rest still runs" "manage-vsftpd --action=install" "$calls"
calls=$(stage3 0 0 cl-MySQL80-server)
at stage3
hasnt "cl-MySQL80 on the box: no MariaDB step at all" "manage-mariadb" "$calls"
has "cl-MySQL80 on the box: the reason is logged" "Database steps skipped (cl-MySQL80-server-8.0.46-1.el9.x86_64 is installed)" "$(out)"
calls=$(stage3 1 1)
at stage3
hasnt "both skipped: no MariaDB step" "manage-mariadb" "$calls"
hasnt "both skipped: no MyApache step" "manage-my-apache" "$calls"
has "both skipped: the install still finishes" "Stage 3 completed" "$(out)"

# ---------------------------------------------------------------------------
echo "# the agent's database login"
# ---------------------------------------------------------------------------
creds() { # $1 my.cnf content (or - for none), $2 agent.conf content
    child creds 'agent_db_credentials_from_my_cnf'
    [[ "$1" != - ]] && printf '%s' "$1" >"$D/my.cnf"
    printf '%s' "$2" >"$D/agent.conf"
    run
    cat "$D/agent.conf"
}
AGENT=$'[security]\ntoken=abc\n\n[dbservers.mariadb]\ntype=mysql\nhost=localhost\nport=3306\nuser=root\npassword=mariadb_root_password\n\n[dns]\ntype=sqlite\n'
got=$(creds $'[client]\nuser = "admin"\npassword = "p&ss\\w0rd ~(x)"\n' "$AGENT")
eq "login copied from [client], quoted like bolt-migrate, the rest untouched" \
    $'[security]\ntoken=abc\n\n[dbservers.mariadb]\ntype=mysql\nhost=localhost\nport=3306\nuser="admin"\npassword="p&ss\\w0rd ~(x)"\n\n[dns]\ntype=sqlite' "$got"
got=$(creds $'[mysql]\npassword=onlypass\n' "$AGENT")
has "password alone: user root" $'user="root"\npassword="onlypass"' "$got"
got=$(creds $'[client]\nuser=a\npassword=one\n[mysql]\npassword=two\n' "$AGENT")
has "[mysql] wins over [client], as in bolt-migrate" 'password="two"' "$got"
got=$(creds $'[client]\npassword=x\n' $'[security]\ntoken=abc\n')
eq "no section: appended whole" $'[security]\ntoken=abc\n\n[dbservers.mariadb]\ntype=mysql\nhost=localhost\nport=3306\nuser="root"\npassword="x"' "$got"
got=$(creds $'[client]\npassword=x\n' $'[dbservers.mariadb]\ntype=mysql\n[dns]\ntype=sqlite\n')
eq "section without the keys: added to it" $'[dbservers.mariadb]\ntype=mysql\nuser="root"\npassword="x"\n[dns]\ntype=sqlite' "$got"
got=$(creds - "$AGENT")
at creds
eq "no my.cnf: agent.conf left as it is" "${AGENT%$'\n'}" "$got"
has "no my.cnf: says what to set" "set user= and password= of the database administrator in [dbservers.mariadb]" "$(out)"
got=$(creds $'[client]\npassword=a"b\n' "$AGENT")
eq "a double quote in the password: agent.conf left as it is" "${AGENT%$'\n'}" "$got"
creds $'[client]\nuser=root\npassword=mariadb_root_password\n' "$AGENT" >/dev/null
has "same login already there: not rewritten" "already uses the database login" "$(out)"
child perms 'agent_db_credentials_from_my_cnf; stat -c %a "$AGENT_CONF" 2>/dev/null || stat -f %Lp "$AGENT_CONF"; ls "$(dirname "$AGENT_CONF")" | grep -c "agent.conf."'
printf '[client]\npassword=x\n' >"$D/my.cnf"
printf '%s' "$AGENT" >"$D/agent.conf"
chmod 600 "$D/agent.conf"
run
eq "rewritten in place: mode kept, no temporary file left" $'600\n0' "$(tail -n 2 "$D/out")"

# ---------------------------------------------------------------------------
echo "# readiness: the database under any of its unit names"
# ---------------------------------------------------------------------------
ready() { # $@ = inactive units
    child ready 'REPORT_PANEL_URL=https://127.0.0.1:8443; if _report_ready; then echo ready; else echo not-ready; fi'
    printf '%s\n' "$@" >"$D/fake/inactive"
    run
    tail -n 1 "$D/out"
}
eq "MariaDB (mariadb unit)" "ready" "$(ready)"
eq "MySQL under mysqld (cl-MySQL80), no mariadb unit" "ready" "$(ready mariadb mysql)"
eq "MySQL under mysql" "ready" "$(ready mariadb mysqld)"
eq "no database unit active" "not-ready" "$(ready mariadb mysqld mysql)"
eq "a service other than the database down" "not-ready" "$(ready postfix)"
ready >/dev/null
eq "one systemctl call for every unit" "is-active bolt-agent bolt-nginx bolt-php postfix dovecot mariadb mysqld mysql" "$(cat "$D/fake/systemctl.log")"

# ---------------------------------------------------------------------------
echo "# CRB repository ids"
# ---------------------------------------------------------------------------
crb() { # $1 = repolist output
    child crb 'crb_repo_ids'
    printf '%s' "$1" >"$D/fake/repolist"
    run
    out
}
eq "AlmaLinux / Rocky" "crb" "$(crb $'repo id                repo name                         status\nappstream              AlmaLinux 9 - AppStream           enabled\nbaseos                 AlmaLinux 9 - BaseOS              enabled\ncrb                    AlmaLinux 9 - CRB                 disabled\ncrb-debuginfo          AlmaLinux 9 - CRB - Debug         disabled\ncrb-source             AlmaLinux 9 - CRB - Source        disabled\n')"
eq "CloudLinux: its own id" "cloudlinux-crb" "$(crb $'repo id                      repo name                       status\ncloudlinux-appstream         CloudLinux 9 - AppStream        enabled\ncloudlinux-baseos            CloudLinux 9 - BaseOS           enabled\ncloudlinux-crb               CloudLinux 9 - CRB              disabled\ncloudlinux-crb-debuginfo     CloudLinux 9 - CRB debuginfo    disabled\ncloudlinux-rollout-1         CloudLinux 9 - rollout          disabled\n')"
eq "nothing listed: crb, as before" "crb" "$(crb "")"

# ---------------------------------------------------------------------------
echo "# EPEL"
# ---------------------------------------------------------------------------
epel() { # $1 = what dnf list finds
    child epel 'install_packages() { echo "install_packages $*"; }; install_epel_release'
    printf '%s\n' "$1" >"$D/fake/avail"
    run
    grep '^install_packages' "$D/out"
}
eq "epel-release in the distribution's repositories (AlmaLinux, Rocky)" "install_packages epel-release" "$(epel epel-release)"
eq "not there (CloudLinux): the Fedora release package" \
    "install_packages https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm" "$(epel "")"
child epel_there 'install_packages() { echo "install_packages $*"; }; install_epel_release; echo done'
echo epel-release >"$D/fake/rpm"
run
eq "already installed: nothing to do" "done" "$(out)"

# ---------------------------------------------------------------------------
echo "# pinned versions"
# ---------------------------------------------------------------------------
pin() { # $1 = code, $2 = available specs
    child pin "report_step_start() { :; }; report_step_result() { :; }; report_fail() { :; }
$1"
    printf '%s\n' "$2" >"$D/fake/avail"
    run
}
pin 'AGENT_VERSION=1.30.4-pr230.1.el9; PINNED_PACKAGES=$'"'"'bolt-php=8.4.14-1.el9\n'"'"'; pinned_versions_available; echo GO-ON' \
    $'bolt-agent-1.30.4-pr230.1.el9\nbolt-php-8.4.14-1.el9'
eq "all pinned builds found: install goes on" "0 yes" "$RC $(grep -q GO-ON "$D/out" && echo yes || echo no)"
has "looked up in the bolt repositories" "--enablerepo=bolt --showduplicates list bolt-agent-1.30.4-pr230.1.el9" "$(cat "$D/fake/dnf.log")"
pin 'BOLT_SOURCE=testing; AGENT_VERSION=1.30.4-pr230.1.el9; PINNED_PACKAGES=$'"'"'bolt-php=8.4.14-1.el9\nbolt-cloudlinux=9.9-9.el9\n'"'"'; pinned_versions_available; echo GO-ON' \
    'bolt-agent-1.30.4-pr230.1.el9'
eq "a pinned build missing: stops" "1 no" "$RC $(grep -q GO-ON "$D/out" && echo yes || echo no)"
has "a pinned build missing: names every missing one and the source" \
    "Not found in the Bolt repositories (source=testing): bolt-php-8.4.14-1.el9 bolt-cloudlinux-9.9-9.el9" "$(out)"
pin 'pinned_versions_available; echo GO-ON' ''
eq "nothing pinned: dnf not asked" "0 no" "$RC $([[ -e "$D/fake/dnf.log" ]] && echo yes || echo no)"
pin 'install_packages() { echo "install_packages $*"; }
PINNED_PACKAGES=$'"'"'bolt-php=8.4.14-1.el9\nbolt-cloudlinux=1.2.0-3.el9\nbolt-git=1.0.5-1.el9\n'"'"'
install_pinned_extra_packages' ''
eq "extra pinned packages installed exactly, bolt-php left to the panel step" \
    "install_packages --enablerepo=bolt bolt-cloudlinux-1.2.0-3.el9 bolt-git-1.0.5-1.el9" "$(grep '^install_packages' "$D/out")"
pin 'AGENT_VERSION=1.30.4-pr230.1.el9
install_bolt_agent_and_check_post' ''
has "--agent-version: dnf installs that build" "install -y --enablerepo=bolt bolt-agent-1.30.4-pr230.1.el9" "$(cat "$D/fake/dnf.log")"
pin 'install_packages() { echo "install_packages $*"; }
PINNED_PACKAGES=$'"'"'bolt-php=8.4.14-1.el9\n'"'"'
install_bolt_panel_and_check_post bolt-panel-1.9.0-1.el9' ''
has "--package=bolt-php: the panel step installs that build" "install_packages --enablerepo=bolt bolt-nginx bolt-php-8.4.14-1.el9 bolt-panel-1.9.0-1.el9" "$(out)"

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
