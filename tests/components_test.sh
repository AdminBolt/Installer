#!/usr/bin/env bash
#
# Tests for --without= (optional components) in install.sh. No network, no
# root: install.sh is loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1, and in each
# child shell bolt-cli, bolt-php, systemctl and sleep are replaced by shell
# functions that record what would have run.
#
# Needs bash 4+ and GNU coreutils.
#   bash tests/components_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")

if ((BASH_VERSINFO[0] < 4)); then echo "bash 4 or newer required (this is $BASH_VERSION)" >&2; exit 2; fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export LC_ALL=C ADMINBOLT_NO_TELEMETRY=1

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }

# Runs $2 in a child shell with install.sh loaded and the system commands
# faked, under install.sh's own set -e, as in a real run. Every faked call is one line in $CHILD_DIR/calls; output in $CHILD_DIR/out.
child() {
    CHILD_DIR="$T/$1"
    mkdir -p "$CHILD_DIR/etc"
    cat >"$CHILD_DIR/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_BOLT_CONFIG="$CHILD_DIR/etc/bolt-config.ini"
REPORT_MARKER="$CHILD_DIR/marker"
bolt-cli() {
    echo "bolt-cli \$*" >>"$CHILD_DIR/calls"
    [[ "\$1" == admin-sso-generate ]] && echo "https://panel.example.com/sso/x"
    return 0
}
bolt-php() { echo "bolt-php \$*" >>"$CHILD_DIR/calls"; }
systemctl() { echo "systemctl \$*" >>"$CHILD_DIR/calls"; }
sleep() { :; }
$2
EOF
    (cd "$CHILD_DIR" && "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
    CHILD_RC=$?
}
ran() { grep -qF -- "$1" "$CHILD_DIR/calls" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "# --without= values"
# ---------------------------------------------------------------------------
left_out() {
    child "parse-$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')" "set_left_out_components $(printf '%q' "$1") && printf 'OK[%s]\n' \"\$LEFT_OUT_COMPONENTS\"; true"
    sed -n 's/^OK\[\(.*\)\]$/\1/p' "$CHILD_DIR/out"
}
eq "one component" "mail" "$(left_out mail)"
eq "the components come out in a fixed order" "mail dns ftp" "$(left_out ftp,mail,dns)"
eq "a component named twice counts once" "dns" "$(left_out dns,dns)"
for bad in "" "bogus" "web" "Mail" "mail," ",mail" "mail,,dns" "mail dns" "mail,dns " $'mail\nftp' "mail;ftp" "*"; do
    eq "refused: '$(printf '%q' "$bad")'" "" "$(left_out "$bad")"
done
child refused-keeps "LEFT_OUT_COMPONENTS=dns; rc=0; set_left_out_components mail,bogus || rc=\$?; printf 'RC=%s LEFT=[%s]\n' \$rc \"\$LEFT_OUT_COMPONENTS\""
check "a refused list changes nothing" grep -qx 'RC=1 LEFT=\[dns\]' "$CHILD_DIR/out"

# ---------------------------------------------------------------------------
echo "# every step of a component exists in Stage 3"
# ---------------------------------------------------------------------------
# A renamed or removed step would otherwise run again although its component
# was left out. The step id is the third argument of run_or_warn/run_or_fail
# or the "app_" id of the apps loop.
stage3=$(sed -n '/^stage_configuration() {/,/^}/p' "$INSTALL_SH")
ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
set +e
for component in $OPTIONAL_COMPONENTS; do
    for step in $(component_steps "$component"); do
        case "$step" in
            app_*) check "$component: app ${step#app_} is in the apps loop" grep -Eq "for app in .*[[:space:]]${step#app_}([[:space:]]|;)" <<<"$stage3" ;;
            *) check "$component: step $step is in Stage 3" grep -Eq "\"[[:space:]]+${step}\$" <<<"$stage3" ;;
        esac
    done
done

# ---------------------------------------------------------------------------
echo "# Stage 3 with everything installed"
# ---------------------------------------------------------------------------
child stage-all 'stage_configuration'
eq "Stage 3 completes" 0 "$CHILD_RC"
for c in "manage-postfix --action=install" "manage-dovecot --action=install" "manage-rspamd --action=install" \
    "manage-mlmmj --action=install" "manage-powerdns --action=install" "manage-vsftpd --action=install" \
    "manage-vsftpd-profiles" "manage-system-email-account" "--app-name=roundcube" "systemctl restart rspamd"; do
    check "default install runs: $c" ran "$c"
done
check "default install mentions nothing left out" bash -c "! grep -q 'skipped (--without\|Left out at your request' '$CHILD_DIR/out'"

# ---------------------------------------------------------------------------
echo "# Stage 3 without mail, dns and ftp"
# ---------------------------------------------------------------------------
child stage-none 'LEFT_OUT_COMPONENTS="mail dns ftp"; stage_configuration'
eq "Stage 3 completes" 0 "$CHILD_RC"
for c in "manage-postfix " "manage-dovecot " "manage-rspamd " "manage-mlmmj " "manage-postfix-profiles" \
    "manage-dovecot-profiles" "manage-rspamd-profiles" "manage-system-email-account" "--app-name=roundcube" \
    "systemctl restart rspamd" "manage-powerdns " "manage-vsftpd " "manage-vsftpd-profiles"; do
    check "left out, not run: $c" bash -c "! grep -qF -- '$c' '$CHILD_DIR/calls'"
done
for c in "connect-bolt-agent-with-panel" "manage-nftable --action=install" "manage-sshd --action=install" \
    "manage-mariadb --action=install" "manage-redis --action=install" "manage-php --action=install --php-version=8.4" \
    "manage-my-apache --action=install" "manage-disk-quota" "manage-fail2ban --action=install" \
    "manage-fail2ban-profiles" "setup-firewall" "manage-dns-records-default-template" "setup-cron-jobs" \
    "post-install-provision" "setup-hidepid" "--app-name=phpmyadmin" "--app-name=filemanager" "admin-sso-generate"; do
    check "still runs: $c" ran "$c"
done
check "each skipped step says why" grep -q '^.*Postfix: skipped (--without=mail)' "$CHILD_DIR/out"
check "PowerDNS skipped for dns" grep -q 'PowerDNS: skipped (--without=dns)' "$CHILD_DIR/out"
check "vsftpd skipped for ftp" grep -q 'Vsftpd: skipped (--without=ftp)' "$CHILD_DIR/out"
check "the end of the install lists what was left out" grep -q 'Left out at your request (--without)' "$CHILD_DIR/out"
# Nothing of a left-out component ran, including a step added to Stage 3
# later but not to component_steps.
check "no mail, DNS or FTP command ran" bash -c "! grep -Ei 'postfix|dovecot|rspamd|mlmmj|roundcube|system-email|powerdns|pdns|vsftpd|ftp' '$CHILD_DIR/calls'"
# The commands printed for adding each component later are the ones skipped,
# in Stage 3 order, and the README lists the same ones in the same order.
printed() { sed -n "/^  $1:\$/,/^  [a-z]*:\$\|^\$/p" "$CHILD_DIR/out" | sed -n 's/^    //p'; }
readme_listed() { grep -E "^- \`$1\`: " "$(dirname "$INSTALL_SH")/README.md" | sed -e "s/^- \`$1\`: //" -e 's/`, `/\n/g' -e 's/`//g'; }
eq "mail: one printed command per skipped step" 10 "$(printed mail | wc -l)"
check "mail: printed in Stage 3 order" diff <(printed mail) <(printf '%s\n' "bolt-cli manage-postfix --action=install" "bolt-cli manage-dovecot --action=install" "bolt-cli manage-rspamd --action=install" "bolt-cli manage-mlmmj --action=install" "bolt-php /usr/local/bolt/web/artisan bolt:manage-app --action=install --app-name=roundcube" "bolt-cli manage-postfix-profiles --action=install" "bolt-cli manage-dovecot-profiles --action=install" "bolt-cli manage-rspamd-profiles --action=install" "bolt-cli manage-system-email-account --action=install" "systemctl restart rspamd")
for component in mail dns ftp; do
    check "$component: some commands printed" test -n "$(printed $component)"
    check "$component: the README lists the printed commands" diff <(printed $component) <(readme_listed $component)
done

child stage-ftp 'LEFT_OUT_COMPONENTS="ftp"; stage_configuration'
check "without ftp only: Postfix still installed" ran "manage-postfix --action=install"
check "without ftp only: PowerDNS still installed" ran "manage-powerdns --action=install"
check "without ftp only: vsftpd left out" bash -c "! grep -qF 'manage-vsftpd ' '$CHILD_DIR/calls'"

# A skipped required step is no failure: run_or_fail returns without running it.
child fail-skip 'LEFT_OUT_COMPONENTS="mail"; run_or_fail "echo RAN" "Postfix" postfix; echo "RC=$?"'
check "run_or_fail skips a left-out step" grep -qx 'RC=0' "$CHILD_DIR/out"
check "run_or_fail does not run it" bash -c "! grep -qx RAN '$CHILD_DIR/out'"
child report-skip 'LEFT_OUT_COMPONENTS="mail dns"; run_or_warn false "Postfix" postfix; run_or_warn false "PowerDNS" powerdns; printf "REQ=[%s] OPT=[%s]\n" "$REPORT_FAILED_REQUIRED" "$REPORT_FAILED_OPTIONAL"'
check "a skipped step is not reported as failed" grep -qx 'REQ=\[\] OPT=\[\]' "$CHILD_DIR/out"

# ---------------------------------------------------------------------------
echo "# main: the option"
# ---------------------------------------------------------------------------
# The stages are replaced, so main stops right after parsing.
stub='stage_prerequisites() { printf "LEFT=[%s]\n" "$LEFT_OUT_COMPONENTS"; exit 0; }'
child main-ok "$stub"$'\n''main --without=ftp,mail'
check "main accepts --without=ftp,mail" grep -qx 'LEFT=\[mail ftp\]' "$CHILD_DIR/out"
child main-twice "$stub"$'\n''main --without=dns --without=mail'
check "--without can be given twice" grep -qx 'LEFT=\[mail dns\]' "$CHILD_DIR/out"
child main-none "$stub"$'\n''main'
check "without the option nothing is left out" grep -qx 'LEFT=\[\]' "$CHILD_DIR/out"
for bad in "--without=" "--without=bogus" "--without=mail,web" "--without= --without=mail" "--without mail" "--without=mail --without" "--without-mail" "--Without=mail" "--WITHOUT=dns"; do
    # shellcheck disable=SC2086
    child main-bad "$stub"$'\n'"main $bad"
    eq "refused: $bad (exit 1)" 1 "$CHILD_RC"
    check "refused: $bad, says why" grep -q 'ERROR:.*Invalid --without=' "$CHILD_DIR/out"
    check "refused: $bad, before any stage" bash -c "! grep -q '^LEFT=' '$CHILD_DIR/out'"
done
child main-long "$stub"$'\n''main "--without=$(printf "x%.0s" {1..80})"'
check "a long refused value is shown cut to 40 characters" grep -q "Invalid --without=$(printf 'x%.0s' {1..40}) " "$CHILD_DIR/out"
out=$(ADMINBOLT_NO_TELEMETRY=1 "$BASH" "$INSTALL_SH" --help 2>&1)
check "--help names the option" grep -q -- '\[--without=<mail,dns,ftp>\]' <<<"$out"
for component in mail dns ftp; do
    check "--help describes $component" grep -q "^  ${component}: " <<<"$out"
done

# ---------------------------------------------------------------------------
echo "# bolt-config.ini"
# ---------------------------------------------------------------------------
child ini-write 'printf "[bolt]\nBOLT_INSTALL_ID=abc\n" >"$REPORT_BOLT_CONFIG"; LEFT_OUT_COMPONENTS="mail dns"; write_left_out_components'
check "the choice is written" grep -qx 'BOLT_INSTALL_WITHOUT=mail,dns' "$CHILD_DIR/etc/bolt-config.ini"
check "other settings are kept" grep -qx 'BOLT_INSTALL_ID=abc' "$CHILD_DIR/etc/bolt-config.ini"
child ini-reset 'printf "[bolt]\nBOLT_INSTALL_WITHOUT=mail\n" >"$REPORT_BOLT_CONFIG"; LEFT_OUT_COMPONENTS=""; write_left_out_components'
check "an install with everything clears an old list" grep -qx 'BOLT_INSTALL_WITHOUT=' "$CHILD_DIR/etc/bolt-config.ini"
eq "and leaves one line for it" 1 "$(grep -c '^BOLT_INSTALL_WITHOUT' "$CHILD_DIR/etc/bolt-config.ini")"
child ini-fail 'REPORT_BOLT_CONFIG=/proc/no-such-dir/bolt-config.ini; LEFT_OUT_COMPONENTS="ftp"; write_left_out_components; echo "RC=$?"'
check "a config that cannot be written only warns" grep -q 'WARNING:.*could not write BOLT_INSTALL_WITHOUT=ftp' "$CHILD_DIR/out"
check "and the install goes on" grep -qx 'RC=0' "$CHILD_DIR/out"

# ---------------------------------------------------------------------------
echo "# readiness (install report)"
# ---------------------------------------------------------------------------
# _report_ready calls systemctl through timeout(1), which runs programs, not
# shell functions: systemctl and curl are fakes on PATH here. systemctl
# is-active answers "inactive" for the units in $INACTIVE.
mkdir -p "$T/bin"
cat >"$T/bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
shift
for u in "$@"; do if [[ " $INACTIVE " == *" $u "* ]]; then echo inactive; else echo active; fi; done
EOF2
printf '#!/usr/bin/env bash\nprintf 302\n' >"$T/bin/curl"
chmod +x "$T/bin/systemctl" "$T/bin/curl"
ready() {
    child "ready-$1" "unset -f systemctl; export INACTIVE='$2'; PATH='$T/bin':\$PATH; LEFT_OUT_COMPONENTS='$3'
_report_ready && echo RC=0 || echo \"RC=\$?\""
    sed -n 's/^RC=//p' "$CHILD_DIR/out"
}
eq "everything installed and running: ready" 0 "$(ready all '' '')"
eq "mail installed but Postfix down: not ready" 1 "$(ready postfix-down 'postfix' '')"
eq "mail left out, Postfix and Dovecot absent: ready" 0 "$(ready no-mail 'postfix dovecot' 'mail')"
eq "mail left out, MariaDB down: not ready" 1 "$(ready no-mail-db-down 'postfix dovecot mariadb' 'mail')"
eq "dns left out does not drop mail from the check" 1 "$(ready dns-only 'dovecot' 'dns')"

echo
echo "passed: $PASS, failed: $FAIL"
((FAIL == 0))
