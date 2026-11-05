#!/usr/bin/env bash
#
# Tests for the MariaDB series install.sh asks the panel for (AB-2228). No
# network, no root: rpm and bolt-cli are replaced by fakes on PATH, and
# install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install
# itself never runs; only stage_configuration is called.
#
#   Linux:  bash tests/mariadb_default_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/mariadb_default_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
# The stubs and MARIADB_SERIES are read by the sourced install.sh, and PATH
# is changed on purpose inside the subshell only.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
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

# Fakes: rpm answers "installed" for the packages listed in $FAKE_DIR/rpm
# (rpm -qa <glob> lists the matching ones, like rpm), bolt-cli records its
# arguments, one call per line, and no database server answers a ping.
mkdir -p "$T/bin"
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
pkg="${*: -1}"
if [[ "$1" == -qa ]]; then
    while read -r p; do [[ -n "$p" && "$p" == $pkg ]] && echo "$p-8.0.46-1.el9.x86_64"; done <"$FAKE_DIR/rpm"
    exit 0
fi
grep -qxF -- "$pkg" "$FAKE_DIR/rpm" 2>/dev/null && { echo "$pkg-10.11.19-1.el9.x86_64"; exit 0; }
echo "package $pkg is not installed"
exit 1
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/mysqladmin"
cp "$T/bin/mysqladmin" "$T/bin/mariadb-admin"
chmod +x "$T/bin/mysqladmin" "$T/bin/mariadb-admin"
cat >"$T/bin/bolt-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/bolt-cli.log"
exit 0
EOF
chmod +x "$T/bin/rpm" "$T/bin/bolt-cli"

# Runs stage_configuration with the given --mariadb-version value (may be
# empty) and the given installed packages; prints the manage-mariadb calls.
mariadb_calls() {
    local series="$1"; shift
    local dir; dir=$(mktemp -d "$T/run.XXXX")
    printf '%s\n' "$@" >"$dir/rpm"
    (
        export FAKE_DIR="$dir" PATH="$T/bin:$PATH"
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        set +e
        report_step_start() { :; }
        report_step_result() { :; }
        report_fail() { :; }
        print_progress() { :; }
        check_agent_setup_at_end() { :; }
        MARIADB_SERIES="$series"
        ROOT_MY_CNF="$dir/my.cnf" AGENT_CONF="$dir/agent.conf"
        stage_configuration >"$dir/out" 2>&1
    )
    grep '^manage-mariadb ' "$dir/bolt-cli.log" 2>/dev/null
}

eq "a new box without --mariadb-version is asked for 11.4" \
    "manage-mariadb --action=install --series=11.4" "$(mariadb_calls "")"
eq "--mariadb-version=10.11 still asks for 10.11" \
    "manage-mariadb --action=install --series=10.11" "$(mariadb_calls "10.11")"
# AB-2331: a database server already on the box is never reinstalled.
eq "a box that already runs MariaDB gets no MariaDB step" \
    "" "$(mariadb_calls "" MariaDB-server)"
eq "the distribution package counts as installed MariaDB as well" \
    "" "$(mariadb_calls "" mariadb-server)"
eq "--mariadb-version on a box that runs MariaDB does not touch it" \
    "" "$(mariadb_calls "11.4" MariaDB-server)"

help=$( { cat "$INSTALL_SH"; } | PATH="$T/bin:$PATH" "$BASH" -s -- --help 2>&1)
has "--help names 11.4 as the default" "If --mariadb-version is not provided, MariaDB 11.4 is installed" "$help"
has "--help lists the option" "[--mariadb-version=<10.11|11.4>]" "$help"
has "README lists the option" "--mariadb-version=<10.11\|11.4>" "$(cat "$HERE/../README.md")"

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
