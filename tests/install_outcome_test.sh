#!/usr/bin/env bash
#
# Tests for what the end of an install says and how it exits (AB-1379), and
# for steps that wait for an external repository (AB-472). No network, no
# root: bolt-cli, semanage, curl and the rest are fakes on PATH, and
# install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install
# itself never runs; single functions and stage_configuration are called.
#
#   Linux:  bash tests/install_outcome_test.sh
#   macOS:  "$(brew --prefix)/bin/bash" tests/install_outcome_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
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
hasnt() { if grep -qF -- "$2" <<<"$3"; then nok "$1" "'$2' in output"; else ok "$1"; fi; }

strip() { sed 's/\x1b\[[0-9;]*m//g'; }

mkdir -p "$T/bin"
# bolt-cli: records its arguments; a command listed in $FAKE_DIR/fail fails
# with the text after the first tab of its line, on stderr.
cat >"$T/bin/bolt-cli" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/bolt-cli.log"
while IFS=$'\t' read -r pattern message; do
    [[ -n "$pattern" && "$*" == *"$pattern"* ]] || continue
    printf '%s\n' "$message" >&2
    exit 1
done <"$FAKE_DIR/fail"
[[ "$1" == admin-sso-generate ]] && echo "https://203.0.113.5:8443/sso/token"
exit 0
EOF
# rpm: nothing is installed. curl: every repository answers unless
# $FAKE_DIR/curl-down lists a pattern of its URL.
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/rpm"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do url="$a"; done
while read -r p; do [[ -n "$p" && "$url" == *"$p"* ]] && exit 7; done <"$FAKE_DIR/curl-down"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/systemctl"
printf "#!/usr/bin/env bash\nexit 0\n" >"$T/bin/bolt-php"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/mysqladmin"
cp "$T/bin/mysqladmin" "$T/bin/mariadb-admin"
chmod +x "$T/bin/"*

# Runs stage_configuration; $1 = lines "<bolt-cli pattern>\t<error>", $2 =
# URL patterns that do not answer. Leaves out, err, bolt-cli.log and vars in
# the run directory, whose path it prints.
run_stage3() {
    local dir; dir=$(mktemp -d "$T/run.XXXX")
    printf '%b' "${1:-}" >"$dir/fail"
    printf '%b' "${2:-}" >"$dir/curl-down"
    : >"$dir/bolt-cli.log"
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
        ssh_password_login_off() { :; }
        sleep() { :; }
        ADMIN_EMAIL="${TEST_EMAIL:-}"
        ROOT_MY_CNF="$dir/my.cnf" AGENT_CONF="$dir/agent.conf"
        stage_configuration >"$dir/out" 2>&1
        {
            echo "CRITICAL_FAILED=$CRITICAL_FAILED"
            echo "FAILED=${#FAILED_STEPS[@]}"
            echo "DEFERRED=${DEFERRED_STEPS[*]:-}"
            echo "REPORT_FAILED_OPTIONAL=${REPORT_FAILED_OPTIONAL:-}"
        } >"$dir/vars"
    )
    echo "$dir"
}

# ---------------------------------------------------------------- AB-1379
echo "# a clean install"
d=$(run_stage3)
out=$(strip <"$d/out")
has "says completed successfully" "Installation Completed Successfully" "$out"
hasnt "lists no failed steps" "Failed steps" "$out"
has "no critical failure" "CRITICAL_FAILED=0" "$(cat "$d/vars")"

echo "# a critical component fails"
d=$(run_stage3 'manage-postfix --action=install\tError: Unable to find a match: postfix\n')
out=$(strip <"$d/out")
has "lists the failed step with its error" "CRITICAL Postfix: Error: Unable to find a match: postfix" "$out"
has "says incomplete" "Installation Incomplete: critical components failed" "$out"
hasnt "does not say completed successfully" "Installation Completed Successfully" "$out"
has "marks the install as failed" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# a non-critical step fails"
d=$(run_stage3 'manage-redis --action=install\tredis: failed to start\n')
out=$(strip <"$d/out")
has "completes with warnings" "Installation Completed With Warnings" "$out"
has "lists it as a warning" "WARNING  Redis: redis: failed to start" "$out"
has "exit status stays 0" "CRITICAL_FAILED=0" "$(cat "$d/vars")"

echo "# QA finding 2: a refused trial next to a critical failure"
d=$(TEST_EMAIL=lukasz.n+ab1379@adminbolt.com run_stage3 'manage-mariadb\tError: Failed to download metadata for repo mariadb\nrequest-trial-license\trefused\n')
out=$(strip <"$d/out")
has "the trial note is there" "Trial licence not issued" "$out"
hasnt "and does not claim the installation succeeded" "The installation itself succeeded" "$out"
d=$(TEST_EMAIL=lukasz.n+ab1379@adminbolt.com run_stage3 'request-trial-license\trefused\n')
has "a complete install still says it succeeded" "The installation itself succeeded" "$(strip <"$d/out")"

echo "# QA finding 2: an install that stops early still lists what failed"
early() {
    (
        export FAKE_DIR="$1" PATH="$T/bin:$PATH"
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        REPORT_MODE=off
        report_fail() { :; }
        report_step_start() { :; }
        report_step_result() { :; }
        trap report_on_exit EXIT
        run_or_warn "bolt-cli manage-redis --action=install" "Redis" redis
        run_or_fail "bolt-cli connect-bolt-agent-with-panel" "Connect bolt-agent to panel" agent_panel_connect
        echo "not reached"
    ) >"$1/out" 2>&1
    echo $? >"$1/rc"
}
d=$(mktemp -d "$T/early.XXXX")
printf 'manage-redis\tredis: failed to start\nconnect-bolt-agent-with-panel\tagent unreachable\n' >"$d/fail"; : >"$d/curl-down"
early "$d"
out=$(strip <"$d/out")
eq "exits non-zero" "1" "$(cat "$d/rc")"
has "names the step that stopped it" "STOPPED  Connect bolt-agent to panel: failed, the installation cannot go on without it" "$out"
has "lists the step that failed before" "WARNING  Redis: redis: failed to start" "$out"
has "says it stopped early" "Installation stopped early (exit status 1)." "$out"
hasnt "nothing after the stop ran" "not reached" "$out"

echo "# QA finding 1: SELinux policy store"
selinux() {
    local mode="$1" semanage="$2" store="$3" dir; dir=$(mktemp -d "$T/se.XXXX")
    printf 'SELINUX=%s\nSELINUXTYPE=targeted\n' "$mode" >"$dir/config"
    mkdir -p "$dir/bin" "$dir/store"
    [[ "$store" == yes ]] && mkdir -p "$dir/store/targeted/active"
    case "$semanage" in
        ok) printf '#!/usr/bin/env bash\necho "Login Name  SELinux User"\nexit 0\n' >"$dir/bin/semanage" ;;
        nostore) printf '#!/usr/bin/env bash\necho "ValueError: SELinux policy is not managed or store cannot be accessed." >&2\nexit 1\n' >"$dir/bin/semanage" ;;
        other) printf '#!/usr/bin/env bash\necho "semanage: something else" >&2\nexit 1\n' >"$dir/bin/semanage" ;;
    esac
    [[ -f "$dir/bin/semanage" ]] && chmod +x "$dir/bin/semanage"
    (
        # Only the fakes and the coreutils the check uses: no semanage of the host.
        export PATH="$dir/bin:/usr/bin:/bin"
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        SELINUX_CONFIG_FILE="$dir/config" SELINUX_STORE_ROOT="$dir/store"
        export SELINUX_CONFIG_FILE SELINUX_STORE_ROOT
        check_selinux_state
    ) >"$dir/out" 2>&1
    echo "$?:$dir"
}
r=$(selinux enforcing ok yes); eq "enforcing with a usable store (selinux=0 on a stock image) installs" "0" "${r%%:*}"
r=$(selinux enforcing nostore no); eq "enforcing without a usable store is refused" "1" "${r%%:*}"
has "and says what to do" "set SELINUX=disabled" "$(cat "${r#*:}/out")"
r=$(selinux permissive nostore no); eq "permissive without a usable store is refused" "1" "${r%%:*}"
r=$(selinux enforcing other yes); eq "another semanage error is left to the package steps" "0" "${r%%:*}"
r=$(selinux disabled nostore no); eq "SELINUX=disabled needs no store" "0" "${r%%:*}"
r=$(selinux enforcing none yes); eq "without semanage, the store directory is enough" "0" "${r%%:*}"
r=$(selinux enforcing none no); eq "without semanage and without the store, refused" "1" "${r%%:*}"
hasnt "the kernel command line is not read" "selinux=0" "$(sed -n '/^check_selinux_state() {/,/^}/p' "$INSTALL_SH" | grep -v '^\s*#')"

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
