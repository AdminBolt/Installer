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
# rpm: nothing is installed, except the packages $FAKE_DIR/rpm-installed
# lists (rpm -q <name>). curl: every repository answers unless
# $FAKE_DIR/curl-down lists a pattern of its URL.
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do pkg="$a"; done
[[ -f "$FAKE_DIR/rpm-installed" ]] && grep -qxF -- "$pkg" "$FAKE_DIR/rpm-installed" && exit 0
exit 1
EOF
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
    printf '%b' "${TEST_RPM_INSTALLED:-}" >"$dir/rpm-installed"
    : >"$dir/bolt-cli.log"
    # AB-2480: TEST_CPANEL=1 puts cPanel on the fake server.
    [[ "${TEST_CPANEL:-0}" == 1 ]] && : >"$dir/cpanel"
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
        CPANEL_BINARY="$dir/cpanel"
        SKIP_APACHE="${TEST_SKIP_APACHE:-0}" CPANEL_CONVERSION="${TEST_CPANEL_CONVERSION:-0}"
        stage_configuration >"$dir/out" 2>&1
        {
            echo "CRITICAL_FAILED=$CRITICAL_FAILED"
            echo "FAILED=${#FAILED_STEPS[@]}"
            echo "DEFERRED=${DEFERRED_STEPS[*]:-}"
            echo "REPORT_FAILED_OPTIONAL=${REPORT_FAILED_OPTIONAL:-}"
            echo "CONVERSION=${#CONVERSION_STEPS[@]}"
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
        # shellcheck source=../install.sh
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

# ---------------------------------------------------------------- AB-472
echo "# PHP 8.4 while Remi cannot be reached (bolt-agent says so)"
d=$(run_stage3 'manage-php --action=install --php-version=8.4\tRemi repository unreachable: neither cdn.remirepo.net nor any of its fallback mirrors answered\n')
out=$(strip <"$d/out")
vars=$(cat "$d/vars")
has "PHP 8.4 is deferred, not failed" "NOTE: PHP 8.4 deferred: the Remi package repository cannot be reached right now." "$out"
has "the summary lists it as deferred" "DEFERRED  PHP 8.4: waits for the Remi package repository" "$out"
has "and says it finishes on its own" "finishes it as soon as the repository answers" "$out"
has "the install completes" "Installation Completed: deferred parts follow" "$out"
hasnt "nothing is critical" "CRITICAL" "$out"
has "exit status 0" "CRITICAL_FAILED=0" "$vars"
has "no failed step" "FAILED=0" "$vars"
has "reported as an optional failure" "REPORT_FAILED_OPTIONAL=php84" "$vars"
hasnt "the PHP 8.4 profile is not run" "manage-php-default-profile" "$(cat "$d/bolt-cli.log")"
has "the post-install setup is still queued" "post-install-provision" "$(cat "$d/bolt-cli.log")"

echo "# PHP 8.4 while Remi cannot be reached (an older agent: dnf's words, Remi down now)"
d=$(run_stage3 "manage-php --action=install --php-version=8.4\tError: Failed to download metadata for repo 'remi-safe': Cannot download repomd.xml\n" 'remirepo.net\nmirror.23m.com\nukfast\nteam-cymru\n')
has "deferred as well" "DEFERRED  PHP 8.4" "$(strip <"$d/out")"
has "exit status 0" "CRITICAL_FAILED=0" "$(cat "$d/vars")"
d=$(run_stage3 "manage-php --action=install --php-version=8.4\tError: Failed to download metadata for repo 'remi-safe': Cannot download repomd.xml\n")
has "but critical when Remi answers by now" "CRITICAL PHP 8.4" "$(strip <"$d/out")"

echo "# PHP 8.4: Remi answers but dnf failed on its metadata (review of AB-472)"
d=$(run_stage3 'manage-php --action=install --php-version=8.4\tThe Remi repository answers, but dnf could not load its metadata: rpmdb open failed\nReason code: remi_metadata_failed\n' 'remirepo.net\nmirror.23m.com\nukfast\nteam-cymru\n')
has "it is critical, not deferred" "CRITICAL PHP 8.4" "$(strip <"$d/out")"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# Stage 1 probe waits only for its own checks"
has "the probe waits for its own pids" 'wait "${pids[@]}"' "$(sed -n '/^probe_external_repositories() {/,/^}/p' "$INSTALL_SH")"
hasnt "no bare wait" "$(printf '    wait\n')" "$(sed -n '/^probe_external_repositories() {/,/^}/p' "$INSTALL_SH" | grep -x '    wait')"

echo "# PHP 8.4 fails for another reason"
d=$(run_stage3 'manage-php --action=install --php-version=8.4\tError: Unable to find a match: php84-php-fpm\n')
out=$(strip <"$d/out")
has "it stays critical" "CRITICAL PHP 8.4: Error: Unable to find a match: php84-php-fpm" "$out"
has "the install is incomplete" "Installation Incomplete" "$out"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"
hasnt "the profile is not applied to a missing PHP" "manage-php-default-profile" "$(cat "$d/bolt-cli.log")"

echo "# Remi only: another step mentioning a down repository is not deferred"
d=$(run_stage3 'manage-postfix --action=install\tRemi repository unreachable\n')
has "Postfix stays critical" "CRITICAL Postfix" "$(strip <"$d/out")"

echo "# Stage 1 probe"
probe() {
    local dir; dir=$(mktemp -d "$T/probe.XXXX")
    printf '%b' "$1" >"$dir/curl-down"
    (
        export FAKE_DIR="$dir" PATH="$T/bin:$PATH"
        # shellcheck source=../install.sh
        ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
        probe_external_repositories
        echo "rc=$?"
    ) 2>&1 | strip
}
out=$(probe '')
has "all answer" "External package repositories answer (Remi, EPEL, MariaDB)" "$out"
out=$(probe 'remirepo.net\nmirror.23m.com\nukfast\nteam-cymru\nmariadb\n')
has "Remi down is said" "The Remi package repository does not answer. The panel installs without it" "$out"
has "MariaDB down is said" "The MariaDB package repository does not answer." "$out"
hasnt "EPEL answers" "EPEL" "$out"
has "the probe never stops the install" "rc=0" "$out"
out=$(probe 'cdn.remirepo.net\n')
has "one Remi mirror is enough" "External package repositories answer" "$out"

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
        # shellcheck source=../install.sh
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

# ---------------------------------------------------------------- AB-2480
# bolt-migrate converts a live cPanel server in place by running this
# installer next to cPanel, whose packages still own mail and DNS. The dnf
# errors are the ones of the AB-2338 live run.
conv_fail='manage-powerdns --action=install\tProblem: package cpanel-pdns-5.1.5-1.cp138~el9.x86_64 from @System conflicts with pdns provided by pdns-5.0.8-1pdns.el9.x86_64\n'
conv_fail+='manage-postfix --action=install\t- installed package cpanel-exim-4.100.1-1.cp130~el9.x86_64 obsoletes postfix provided by postfix-2:3.5.25-3.el9_8.x86_64 from appstream\n'
conv_fail+='manage-dovecot --action=install\tfile /etc/dovecot/dovecot.conf from install of dovecot-1:2.3.16-18.el9_8.8.x86_64 conflicts with file from package cpanel-dovecot-2.4.5-1.cp132~el9.x86_64\n'
conv_fail+='manage-postfix-profiles --action=install\tFailed to apply Postfix default settings: postfix: command not found\n'
cpanel_pkgs='cpanel-pdns\ncpanel-exim\ncpanel-dovecot\n'

echo "# a conversion of a live cPanel server (cPanel installed, --skip-apache as every bolt-migrate passes)"
d=$(TEST_CPANEL=1 TEST_SKIP_APACHE=1 TEST_RPM_INSTALLED="$cpanel_pkgs" run_stage3 "$conv_fail")
out=$(strip <"$d/out")
vars=$(cat "$d/vars")
has "Postfix is left to the conversion" "CONVERSION  Postfix: cPanel's cpanel-exim still owns it, installed at the cutover" "$out"
has "Dovecot is left to the conversion" "CONVERSION  Dovecot: cPanel's cpanel-dovecot still owns it, installed at the cutover" "$out"
has "PowerDNS is left to the conversion" "CONVERSION  PowerDNS: cPanel's cpanel-pdns still owns it, installed at the cutover" "$out"
has "the Postfix profiles follow Postfix" "CONVERSION  Postfix profiles: cPanel's cpanel-exim still owns it" "$out"
has "each step says so as it happens" "NOTE: Postfix is not installed now: cPanel's cpanel-exim still owns it on this server." "$out"
has "the summary names the section" "Left to the conversion: cPanel still owns them (4)" "$out"
has "the install completes" "Installation Completed: mail and DNS follow at cutover" "$out"
hasnt "nothing is critical" "CRITICAL" "$out"
hasnt "nothing is listed as failed" "Failed steps" "$out"
has "exit status 0" "CRITICAL_FAILED=0" "$vars"
has "no failed step" "FAILED=0" "$vars"
has "four steps left to the conversion" "CONVERSION=4" "$vars"
has "reported as optional failures" "REPORT_FAILED_OPTIONAL=powerdns postfix dovecot postfix_profiles" "$vars"
has "the Stage 3 line says it completed" "Stage 3 completed: all post-install actions done" "$out"

echo "# the same with --cpanel-conversion (bolt-migrate with AB-2480 passes it)"
d=$(TEST_CPANEL=1 TEST_CPANEL_CONVERSION=1 TEST_RPM_INSTALLED="$cpanel_pkgs" run_stage3 "$conv_fail")
has "Postfix is left to the conversion" "CONVERSION  Postfix: cPanel's cpanel-exim" "$(strip <"$d/out")"
has "exit status 0" "CRITICAL_FAILED=0" "$(cat "$d/vars")"

echo "# a fresh install without cPanel: a failed Postfix still fails the install (AB-1379)"
d=$(TEST_SKIP_APACHE=1 run_stage3 "$conv_fail")
out=$(strip <"$d/out")
has "Postfix is critical" "CRITICAL Postfix: - installed package cpanel-exim" "$out"
has "Dovecot is critical" "CRITICAL Dovecot:" "$out"
has "the install is incomplete" "Installation Incomplete: critical components failed" "$out"
hasnt "nothing is left to a conversion" "CONVERSION" "$out"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"
d=$(TEST_CPANEL_CONVERSION=1 run_stage3 'manage-postfix --action=install\tError: Unable to find a match: postfix\n')
has "--cpanel-conversion on a server without cPanel's packages changes nothing" "CRITICAL Postfix: Error: Unable to find a match: postfix" "$(strip <"$d/out")"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# a conversion where cPanel does not own the failed component"
d=$(TEST_CPANEL=1 TEST_SKIP_APACHE=1 TEST_RPM_INSTALLED='cpanel-pdns\ncpanel-dovecot\n' run_stage3 'manage-postfix --action=install\tError: Unable to find a match: postfix\n')
has "Postfix is critical without cpanel-exim" "CRITICAL Postfix: Error: Unable to find a match: postfix" "$(strip <"$d/out")"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# cPanel installed but no conversion (no --skip-apache, no --cpanel-conversion)"
d=$(TEST_CPANEL=1 TEST_RPM_INSTALLED="$cpanel_pkgs" run_stage3 "$conv_fail")
has "Postfix stays critical" "CRITICAL Postfix" "$(strip <"$d/out")"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# a conversion where a component cPanel does not own fails"
d=$(TEST_CPANEL=1 TEST_SKIP_APACHE=1 TEST_RPM_INSTALLED="$cpanel_pkgs" run_stage3 "${conv_fail}manage-php --action=install --php-version=8.4\tError: Unable to find a match: php84-php-fpm\nmanage-redis --action=install\tredis: failed to start\n")
out=$(strip <"$d/out")
has "PHP 8.4 stays critical" "CRITICAL PHP 8.4: Error: Unable to find a match: php84-php-fpm" "$out"
has "Redis stays a warning" "WARNING  Redis: redis: failed to start" "$out"
has "Postfix is still left to the conversion" "CONVERSION  Postfix:" "$out"
has "the install is incomplete" "Installation Incomplete: critical components failed" "$out"
has "exit status 1" "CRITICAL_FAILED=1" "$(cat "$d/vars")"

echo "# $PASS passed, $FAIL failed"
((FAIL == 0))
