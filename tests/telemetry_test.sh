#!/usr/bin/env bash
#
# Tests for the install report in install.sh (AB-2067). No network, no root:
# curl, systemctl and rpm are replaced by fakes on PATH, every path the
# report writes to points into a temporary directory, and install.sh is
# loaded with ADMINBOLT_INSTALL_SOURCE_ONLY=1 so the install itself never runs.
#
# Needs bash 4+, GNU coreutils (stat -c, chown --reference) and jq.
#   Linux:  bash tests/telemetry_test.sh
#   macOS:  PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH" "$(brew --prefix)/bin/bash" tests/telemetry_test.sh
# INSTALL_SH=/path/to/install.sh runs the same tests against another copy.
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH=${INSTALL_SH:-$HERE/../install.sh}
INSTALL_SH=$(cd "$(dirname "$INSTALL_SH")" && pwd)/$(basename "$INSTALL_SH")
REAL_CURL=$(command -v curl || true)

if ((BASH_VERSINFO[0] < 4)); then echo "bash 4 or newer required (this is $BASH_VERSION)" >&2; exit 2; fi
if ! stat -c %u / >/dev/null 2>&1; then echo "GNU stat required (see the header for macOS)" >&2; exit 2; fi
if ! command -v jq >/dev/null 2>&1; then echo "jq required" >&2; exit 2; fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export LC_ALL=C

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
nok() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+  [$2]}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else nok "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi; }

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: records each POST body under $FAKE_DIR/req and answers with the
# status in $FAKE_DIR/http_code. -k (the readiness check) answers panel_code.
[[ -f "$FAKE_DIR/real_curl" ]] && exec "$(cat "$FAKE_DIR/real_curl")" "$@"
data="" insecure=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-binary) data="$2"; shift ;;
        -k) insecure=1 ;;
    esac
    shift
done
if ((insecure)); then
    printf '%s' "$(cat "$FAKE_DIR/panel_code" 2>/dev/null || echo 302)"
    exit 0
fi
[[ -f "$FAKE_DIR/curl_sleep" ]] && sleep "$(cat "$FAKE_DIR/curl_sleep")"
mkdir -p "$FAKE_DIR/req"
out=$(mktemp "$FAKE_DIR/req/r.XXXXXX")
case "$data" in
    @-) cat >"$out" ;;
    @*) cat "${data#@}" >"$out" ;;
    *) printf '%s' "$data" >"$out" ;;
esac
code=$(cat "$FAKE_DIR/http_code" 2>/dev/null || echo 202)
printf '%s' "$code"
[[ "$code" == 000 ]] && exit 7
exit 0
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/systemctl.log"
case "$1" in
    is-system-running) cat "$FAKE_DIR/system_state" 2>/dev/null || echo running ;;
    is-active) grep -qx "${@: -1}" "$FAKE_DIR/inactive" 2>/dev/null && exit 3; exit 0 ;;
esac
exit 0
EOF
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "${@: -1}" in
    bolt-panel) printf '1.9.3-1.el9' ;;
    bolt-agent) printf '2.4.0-1.el9' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/"*
FAKEPATH="$T/bin:$PATH"

# A child shell with install.sh loaded and every report path inside $T/<name>.
# $1 = name, $2 = script body. Sets CHILD_RC and CHILD_DIR; output in $CHILD_DIR/out.
new_child() {
    CHILD_DIR="$T/$1"
    mkdir -p "$CHILD_DIR/fake" "$CHILD_DIR/units" "$CHILD_DIR/dmi" "$CHILD_DIR/etc"
    printf 'ID="almalinux"\nVERSION_ID="9.4"\nPRETTY_NAME="host.example.com"\n' >"$CHILD_DIR/os-release"
    printf 'Hetzner\n' >"$CHILD_DIR/dmi/sys_vendor"
    printf 'vServer\n' >"$CHILD_DIR/dmi/product_name"
    cat >"$CHILD_DIR/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_DIR="$CHILD_DIR/spool/install-report"
REPORT_SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
REPORT_UNIT_DIR="$CHILD_DIR/units"
REPORT_BOLT_CONFIG="$CHILD_DIR/etc/bolt/bolt-config.ini"
REPORT_DMI_DIR="$CHILD_DIR/dmi"
REPORT_OS_RELEASE="$CHILD_DIR/os-release"
REPORT_MARKER="$CHILD_DIR/marker"
REPORT_UUID_FILE="$CHILD_DIR/no-such-uuid"
REPORT_EUID=\${TEST_EUID:-0}
$2
EOF
}
run_child() {
    (cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
    CHILD_RC=$?
}
child() { new_child "$1" "$2"; run_child; }

# Events of the last child: the spool copy when there is one, otherwise what the fake curl received.
spool_events() { cat "$CHILD_DIR"/spool/install-report/*/events/*.json 2>/dev/null | jq -cs 'sort_by(.event_id)[]'; }
sent_events() { cat "$CHILD_DIR"/fake/req/* 2>/dev/null | jq -cs 'sort_by(.event_id)[]'; }
event() { spool_events | jq -c "select(.type == \"$1\")" | tail -n 1; }
sent_event() { sent_events | jq -c "select(.type == \"$1\")" | tail -n 1; }
field() { jq -r "$2 | if type == \"array\" then join(\",\") else tostring end" <<<"$1"; }

# Loaded here as well, for the pure functions.
ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
set +e
trap 'rm -rf "$T"' EXIT
trap - INT TERM HUP

# ---------------------------------------------------------------------------
echo "# loading and the curl | bash path"
# ---------------------------------------------------------------------------
check "sourcing does not run the install" test "${REPORT_MODE:-}" = off
out=$( { cat "$INSTALL_SH"; } | PATH="$FAKEPATH" "$BASH" -s -- --help 2>&1)
check "piped to bash (curl | bash), main still runs" grep -q '^Usage:' <<<"$out"
check "usage lists --channel and --no-telemetry" grep -q -- '--channel=<name>\] \[--no-telemetry\]' <<<"$out"

# ---------------------------------------------------------------------------
echo "# installer_rev"
# ---------------------------------------------------------------------------
eq "installer_rev = sha256 of install.sh" "$(sha256sum <"$INSTALL_SH" | cut -c1-64)" "$(_report_installer_rev)"
rev_piped=$( { cat "$INSTALL_SH"; printf '\n_report_installer_rev\n'; } | ADMINBOLT_INSTALL_SOURCE_ONLY=1 "$BASH" -s 2>/dev/null)
eq "installer_rev unknown (64 zeros) when read from a pipe" "$(printf '0%.0s' {1..64})" "$rev_piped"

# ---------------------------------------------------------------------------
echo "# install ID"
# ---------------------------------------------------------------------------
REPORT_UUID_FILE="$T/none"
u1=$(_report_new_uuid); u2=$(_report_new_uuid)
check "fallback UUID is v4, lower case" _report_valid_uuid "$u1"
check "two IDs differ" test "$u1" != "$u2"
printf 'A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D\n' >"$T/uuid"
REPORT_UUID_FILE="$T/uuid"
eq "kernel UUID used, lower-cased" "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d" "$(_report_new_uuid)"

# ---------------------------------------------------------------------------
echo "# JSON escaping and value checks"
# ---------------------------------------------------------------------------
raw=$'a"b\\c\nd\te\x01f'
eq "JSON string escaping round-trips" "$raw" "$(_report_json_str "$raw" | jq -j .)"
eq "pattern check keeps a valid version" "1.9.3-1.el9" "$(_report_clean "1.9.3-1.el9" '^[0-9A-Za-z.+~_-]{0,40}$' "")"
eq "pattern check drops an injection attempt" "" "$(_report_clean '1.0","x":"y' '^[0-9A-Za-z.+~_-]{0,40}$' "")"
eq "step list drops unknown ids" '["app_git","mariadb"]' "$(_report_json_steps "app_git bogus mariadb")"

# ---------------------------------------------------------------------------
echo "# steps: class and reason code (KONTRAKT list)"
# ---------------------------------------------------------------------------
declare -A WANT=(
    [check_root]="required not_root" [check_os]="required unsupported_os" [check_commands]="required missing_command"
    [check_port_8443]="required port_in_use" [parse_arguments]="required invalid_argument"
    [repo_setup]="required repo_download_failed" [prerequisite_packages]="required package_install_failed"
    [agent_install]="required agent_install_failed" [agent_scriptlet]="required agent_install_failed"
    [panel_install]="required package_install_failed" [panel_scriptlet]="required panel_scriptlet_failed"
    [web_services_enable]="required required_step_failed" [agent_panel_connect]="required agent_panel_connect_failed"
    [readiness]="required readiness_check_failed"
)
for s in nftables ssh_server powerdns mariadb postfix dovecot redis php84 myapache firewall_setup mariadb_profile myapache_profile php84_profile postinstall_queue; do
    WANT[$s]="required required_step_failed"
done
for s in selinux_enforce selinux_config crb_repo chronyd acme_sh greeting rspamd mlmmj vsftpd disk_quota fail2ban \
    ssh_profiles postfix_profiles dovecot_profiles redis_profiles rspamd_profiles system_email dns_template vsftpd_profile \
    fail2ban_profile cron_jobs hidepid rspamd_restart app_local-api app_filemanager app_phpmyadmin app_roundcube app_git app_metrics app_adminer; do
    WANT[$s]="optional unclassified"
done
bad=""
for s in "${!WANT[@]}"; do
    got="$(report_step_class "$s") $(report_reason_for_step "$s")"
    [[ "$got" == "${WANT[$s]}" ]] || bad+=" $s($got)"
done
eq "all ${#WANT[@]} step ids: class and reason as in KONTRAKT" "" "$bad"
eq "unknown step id is unknown" "unknown" "$(report_step_class trial_licence)"
used=$( { grep -E '^[[:space:]]*run_or_(warn|fail) "' "$INSTALL_SH" | awk '{print $NF}'
          grep -oE '\breport_(step_start|step_result|fail) [a-z][a-z0-9_]*' "$INSTALL_SH" | awk '{print $2}'; } \
        | grep -E '^[a-z][a-z0-9_]*$' | sort -u)
bad=""
for s in $used; do
    [[ -n "${WANT[$s]:-}" ]] || bad+=" $s"
done
check "found the step ids used in install.sh ($(wc -w <<<"$used"))" test "$(wc -w <<<"$used")" -gt 40
eq "every step id used in install.sh is in the list" "" "$bad"
bad=""
for s in "${!WANT[@]}"; do
    case "$s" in app_*) s='"app_${app}"' ;; esac
    grep -qF -- "$s" "$INSTALL_SH" || bad+=" $s"
done
eq "every listed step id is used in install.sh" "" "$bad"

# The receiver refuses any step id that is not in KONTRAKT.md, character for
# character. KONTRAKT_MD=/path/to/KONTRAKT.md compares the ids and their
# class with the contract's "Kroki instalatora" section.
if [[ -n "${KONTRAKT_MD:-}" && -r "${KONTRAKT_MD}" ]]; then
    section=$(sed -n '/^## Kroki instalatora/,/^## [^K]/p' "$KONTRAKT_MD")
    ids_of() { grep -oE '`[a-z0-9_<>]+`' | tr -d '`' | grep -vxE 'prerequisites|packages|configuration|ss|trial_licence|failed_step|unclassified' \
        | sed 's/^app_<nazwa>$/app_local-api app_filemanager app_phpmyadmin app_roundcube app_git app_metrics app_adminer/' | tr ' ' '\n' | sort -u; }
    optional=$(grep -E '^- opcjonalne:' <<<"$section" | ids_of)
    all=$(ids_of <<<"$section")
    contract=""
    for s in $all; do
        if grep -qx "$s" <<<"$optional"; then contract+="$s optional"$'\n'; else contract+="$s required"$'\n'; fi
    done
    mine=""
    for s in $all ${!WANT[@]}; do echo "$s"; done | sort -u >"$T/ids"
    while read -r s; do mine+="$s $(report_step_class "$s")"$'\n'; done <"$T/ids"
    eq "step ids and classes identical to KONTRAKT.md ($(wc -w <<<"$all") ids)" "$(sort <<<"$contract")" "$(sort <<<"$mine")"
    bad=""
    for s in $used; do grep -qx "$s" <<<"$all" || bad+=" $s"; done
    eq "every step id used in install.sh is in KONTRAKT.md" "" "$bad"
else
    echo "# skipped: KONTRAKT_MD not set (step ids against KONTRAKT.md)"
fi

# ---------------------------------------------------------------------------
echo "# platform from DMI"
# ---------------------------------------------------------------------------
dmi_case() {
    rm -rf "$T/dmi"; mkdir -p "$T/dmi"
    printf '%s\n' "$2" >"$T/dmi/sys_vendor"; printf '%s\n' "$3" >"$T/dmi/product_name"
    [[ -n "${4:-}" ]] && printf '%s\n' "$4" >"$T/dmi/chassis_asset_tag"
    REPORT_DMI_DIR="$T/dmi"
    eq "platform $1" "$1" "$(_report_platform)"
}
dmi_case hetzner "Hetzner" "vServer"
dmi_case vultr "Vultr" "VC2"
dmi_case akamai "Linode" "Compute Instance"
dmi_case digitalocean "DigitalOcean" "Droplet"
dmi_case aws "Amazon EC2" "t3.micro"
dmi_case azure "Microsoft Corporation" "Virtual Machine" "7783-7084-3265-9085-8269-3286-77"
dmi_case gcp "Google" "Google Compute Engine"
dmi_case kvm "QEMU" "Standard PC (Q35 + ICH9, 2009)"
dmi_case vmware "VMware, Inc." "VMware Virtual Platform"
dmi_case other "Supermicro" "X11SSL"
REPORT_DMI_DIR="$T/no-dmi"
eq "platform unknown without DMI" "unknown" "$(_report_platform)"

# ---------------------------------------------------------------------------
echo "# a complete successful install"
# ---------------------------------------------------------------------------
child ok '
REPORT_CHANNEL_ARG=get-script; ADMIN_EMAIL=owner.secret@example.com; PANEL_VERSION=1.9.3-1.el9; BOLT_SOURCE=stable
report_init
report_step_start parse_arguments; report_step_result parse_arguments ok
INSTALL_MARKER_CREATED=1; touch "$REPORT_MARKER"
report_stage_begin packages
run_or_warn true "SELinux enforce" selinux_enforce
report_stage_begin configuration
run_or_fail true "Connect" agent_panel_connect
run_or_warn true "App roundcube" app_roundcube
report_trial_licence ok
report_stage_end
report_readiness_check
exit 0'
eq "exit code unchanged (0)" 0 "$CHILD_RC"
check "start line says what is sent and how to turn it off" grep -q 'turn this off, rerun with --no-telemetry or ADMINBOLT_NO_TELEMETRY=1' "$CHILD_DIR/out"
eq "start line printed once" 1 "$(grep -c 'no-telemetry' "$CHILD_DIR/out")"
fin=$(event install_finished)
eq "result succeeded" succeeded "$(field "$fin" .result)"
eq "reason empty" "" "$(field "$fin" .reason)"
eq "trial licence its own field" ok "$(field "$fin" .trial_licence)"
eq "panel version" 1.9.3-1.el9 "$(field "$fin" .panel_version)"
eq "agent version" 2.4.0-1.el9 "$(field "$fin" .agent_version)"
st=$(event install_started)
eq "install_started fields" '["arch","channel","event_id","install_id","installer_rev","os_name","os_version","platform","requested_version","schema","sent_at","source","telemetry_notice","type"]' "$(jq -c 'keys' <<<"$st")"
eq "stage_finished fields" '["duration_s","event_id","install_id","result","schema","sent_at","stage","type"]' "$(spool_events | jq -c 'select(.type=="stage_finished") | keys' | sort -u | tr -d '\n')"
eq "install_finished fields" '["agent_version","duration_s","event_id","exit_code","failed_optional_steps","failed_required_steps","failed_step","install_id","panel_version","reason","result","schema","sent_at","signal","trial_licence","type"]' "$(jq -c 'keys' <<<"$fin")"
eq "channel" get-script "$(field "$st" .channel)"
eq "platform" hetzner "$(field "$st" .platform)"
eq "os" "almalinux 9.4" "$(field "$st" .os_name) $(field "$st" .os_version)"
eq "source" stable "$(field "$st" .source)"
eq "installer_rev" "$(sha256sum <"$INSTALL_SH" | cut -c1-64)" "$(field "$st" .installer_rev)"
eq "stages reported in order" "prerequisites:ok packages:ok configuration:ok readiness:ok" "$(spool_events | jq -r 'select(.type=="stage_finished") | "\(.stage):\(.result)"' | tr '\n' ' ' | sed 's/ $//')"
eq "event ids 1..n without gaps" "1 2 3 4 5 6" "$(spool_events | jq -r .event_id | tr '\n' ' ' | sed 's/ $//')"
check "install_id is a v4 UUID" _report_valid_uuid "$(field "$st" .install_id)"
all="$(cat "$CHILD_DIR"/spool/install-report/*/events/*.json "$CHILD_DIR"/fake/req/* 2>/dev/null)"
check "no e-mail address in any event" bash -c '! grep -q "@" <<<"$1"' _ "$all"
check "no hostname from os-release in any event" bash -c '! grep -q "host.example.com" <<<"$1"' _ "$all"
check "no hostname of this machine in any event" bash -c '! grep -qF -- "$(hostname)" <<<"$1"' _ "$all"
eq "every event was delivered" 6 "$(sent_events | jq -s 'map(.event_id) | unique | length')"
eq "all marked sent" 6 "$(ls "$CHILD_DIR"/spool/install-report/*/sent | wc -l | tr -d ' ')"
check "marker removed by the EXIT trap" test ! -e "$CHILD_DIR/marker"
idir=$(echo "$CHILD_DIR"/spool/install-report/*/)
eq "spool root private" "700" "$(stat -c %a "$CHILD_DIR/spool/install-report")"
eq "install dir private" "700" "$(stat -c %a "$idir")"
eq "event file private" "600" "$(stat -c %a "$idir/events/1.json")"
check "spool keeps the install start time" grep -qE '^[0-9]+$' "$idir/started"
check "spool marks the install finished" test -e "$idir/finished"
check "timer enabled at start" grep -q 'enable --now adminbolt-install-report.timer' "$CHILD_DIR/fake/systemctl.log"
check "timer OnBootSec=5min" grep -qx 'OnBootSec=5min' "$CHILD_DIR/units/adminbolt-install-report.timer"
check "timer every 15 min" grep -qx 'OnUnitActiveSec=15min' "$CHILD_DIR/units/adminbolt-install-report.timer"
check "service runs the sender" grep -qx "ExecStart=$CHILD_DIR/libexec/adminbolt/install-report-send" "$CHILD_DIR/units/adminbolt-install-report.service"
check "sender is executable" test -x "$CHILD_DIR/libexec/adminbolt/install-report-send"
check "sender passes bash -n" bash -n "$CHILD_DIR/libexec/adminbolt/install-report-send"
if command -v shellcheck >/dev/null 2>&1; then
    check "sender passes shellcheck" shellcheck -s bash "$CHILD_DIR/libexec/adminbolt/install-report-send"
fi

# ---------------------------------------------------------------------------
echo "# result rules"
# ---------------------------------------------------------------------------
child warn '
report_init
report_stage_begin configuration
run_or_warn false "App roundcube" app_roundcube
run_or_warn true "Postfix" postfix
report_stage_end
report_readiness_check
exit 0'
fin=$(event install_finished)
eq "only an optional step failed: succeeded_with_warnings" succeeded_with_warnings "$(field "$fin" .result)"
eq "names the optional step" app_roundcube "$(field "$fin" .failed_optional_steps)"
eq "stage result warnings" warnings "$(spool_events | jq -r 'select(.type=="stage_finished" and .stage=="configuration") | .result')"

child required '
report_init
report_stage_begin configuration
run_or_warn false "Postfix" postfix
run_or_warn false "Redis" redis
report_stage_end
report_readiness_check
exit 0'
fin=$(event install_finished)
eq "required step failed but script went on: failed" failed "$(field "$fin" .result)"
eq "first required failure is failed_step" postfix "$(field "$fin" .failed_step)"
eq "reason from the step" required_step_failed "$(field "$fin" .reason)"
eq "all failed required steps listed" postfix,redis "$(field "$fin" .failed_required_steps)"
eq "exit code still 0" 0 "$CHILD_RC"

child readiness '
report_init
report_stage_begin configuration; report_stage_end
echo dovecot >"$FAKE_DIR/inactive"
report_readiness_check
exit 0'
fin=$(event install_finished)
eq "readiness failed: failed" "failed readiness readiness_check_failed" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason)"

child panel_down '
report_init
echo 000 >"$FAKE_DIR/panel_code"
report_readiness_check
exit 0'
eq "panel not answering: readiness_check_failed" readiness_check_failed "$(field "$(event install_finished)" .reason)"

child port '
report_init
report_step_result parse_arguments ok
ss() { printf "tcp LISTEN 0 128 0.0.0.0:8443 0.0.0.0:* users:((\"httpd\",pid=1,fd=3))\n"; }
check_port_8443'
fin=$(event install_finished)
eq "port 8443 taken: port_in_use" "failed check_port_8443 port_in_use 1" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code)"
eq "exit code unchanged (1)" 1 "$CHILD_RC"
eq "stage prerequisites closed as failed" failed "$(spool_events | jq -r 'select(.type=="stage_finished") | .result')"

child repo '
report_init
report_stage_begin packages
report_step_start repo_setup
curl() { return 7; }
install_repo_rhel 9'
eq "mirror unreachable: repo_download_failed" "repo_setup repo_download_failed" "$(field "$(event install_finished)" .failed_step) $(field "$(event install_finished)" .reason)"

child sete '
report_init
report_stage_begin packages
report_step_start web_services_enable
false'
fin=$(event install_finished)
eq "set -e exit inside a step: that step and its code" "failed web_services_enable required_step_failed 1" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code)"

child sete2 '
report_init
report_stage_begin configuration
false'
fin=$(event install_finished)
eq "set -e exit outside any step: unclassified" "failed  unclassified" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason)"

child connect '
report_init
report_stage_begin configuration
run_or_fail false "Connect bolt-agent to panel" agent_panel_connect'
eq "agent connection: agent_panel_connect_failed" "agent_panel_connect agent_panel_connect_failed" "$(field "$(event install_finished)" .failed_step) $(field "$(event install_finished)" .reason)"

child trial '
report_init
report_stage_begin configuration
ADMIN_EMAIL=a@b.cd; TRIAL_LICENCE_OK=0
run_or_warn "false && TRIAL_LICENCE_OK=1" "Request trial licence"
if [[ "${TRIAL_LICENCE_OK}" -eq 1 ]]; then report_trial_licence ok; else report_trial_licence failed; fi
report_stage_end
report_readiness_check
exit 0'
fin=$(event install_finished)
eq "failed trial licence does not change the result" "succeeded failed" "$(field "$fin" .result) $(field "$fin" .trial_licence)"

# ---------------------------------------------------------------------------
echo "# bolt-panel %post (detected like AB-1652 detects bolt-agent)"
# ---------------------------------------------------------------------------
child panel_post '
report_init
report_stage_begin packages
install_packages() { echo "Running scriptlet: bolt-panel-1.9.3-1.el9.noarch"; echo "warning: %post(bolt-panel-1.9.3-1.el9.noarch) scriptlet failed, exit status 1"; }
install_bolt_panel_and_check_post bolt-panel
echo "CONTINUED"
report_stage_begin configuration; report_stage_end
report_readiness_check
exit 0'
fin=$(event install_finished)
eq "panel %post failure: failed panel_scriptlet panel_scriptlet_failed" "failed panel_scriptlet panel_scriptlet_failed" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason)"
check "script continues after it" grep -q CONTINUED "$CHILD_DIR/out"
eq "one install_finished only" 1 "$(spool_events | jq -s 'map(select(.type=="install_finished")) | length')"

child panel_worker '
report_init
report_stage_begin packages
install_packages() { echo "warning: %post(bolt-panel-worker-1.0-1.el9.noarch) scriptlet failed, exit status 1"; }
install_bolt_panel_and_check_post bolt-panel
report_stage_end
report_readiness_check
exit 0'
eq "another package named bolt-panel-* is not bolt-panel" succeeded "$(field "$(event install_finished)" .result)"

child panel_dnf '
report_init
report_stage_begin packages
install_packages() { echo "Error: nothing provides"; exit 1; }
install_bolt_panel_and_check_post bolt-panel
echo NOT-REACHED'
eq "dnf failure on bolt-panel: package_install_failed, exit 1" "panel_install package_install_failed 1" "$(field "$(event install_finished)" .failed_step) $(field "$(event install_finished)" .reason) $CHILD_RC"
check "script stops there as before" bash -c '! grep -q NOT-REACHED "$1"' _ "$CHILD_DIR/out"

# ---------------------------------------------------------------------------
echo "# signals"
# ---------------------------------------------------------------------------
set -m
sig_child() { # $1 name, $2 signal, $3 system state
    new_child "$1" '
report_init
report_stage_begin packages
report_step_start agent_install
INSTALL_MARKER_CREATED=1; touch "$REPORT_MARKER"
sleep 20 & wait $!
echo NOT-REACHED'
    [[ -n "${3:-}" ]] && echo "$3" >"$CHILD_DIR/fake/system_state"
    (cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" exec "$BASH" child.sh >"$CHILD_DIR/out" 2>&1) &
    local pid=$!
    for _ in $(seq 1 50); do [[ -e "$CHILD_DIR/marker" ]] && break; sleep 0.1; done
    sleep 0.3
    kill -s "$2" "$pid"
    wait "$pid"
    CHILD_RC=$?
}
sig_child int INT
fin=$(event install_finished)
eq "Ctrl+C: cancelled, INT, interrupted" "cancelled INT interrupted agent_install 130" "$(field "$fin" .result) $(field "$fin" .signal) $(field "$fin" .reason) $(field "$fin" .failed_step) $(field "$fin" .exit_code)"
eq "Ctrl+C: script still ends by SIGINT (130)" 130 "$CHILD_RC"
check "Ctrl+C: marker removed" test ! -e "$CHILD_DIR/marker"
eq "Ctrl+C: open stage closed as failed" failed "$(spool_events | jq -r 'select(.type=="stage_finished" and .stage=="packages") | .result')"
sig_child term TERM
eq "TERM: cancelled, exit 143" "cancelled TERM 143" "$(field "$(event install_finished)" .result) $(field "$(event install_finished)" .signal) $CHILD_RC"
sig_child shutdown TERM stopping
eq "TERM during shutdown: no install_finished at all" "" "$(event install_finished)"
eq "TERM during shutdown: nothing like it sent" "" "$(sent_event install_finished)"
eq "TERM during shutdown: exit 143 as before" 143 "$CHILD_RC"
check "TERM during shutdown: marker removed" test ! -e "$CHILD_DIR/marker"
sig_child hup HUP
eq "HUP: cancelled, exit 129" "cancelled HUP 129" "$(field "$(event install_finished)" .result) $(field "$(event install_finished)" .signal) $CHILD_RC"
sig_child hup_shutdown HUP stopping
eq "HUP during shutdown: no install_finished" "" "$(event install_finished)"
set +m

# ---------------------------------------------------------------------------
echo "# not root"
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    new_child nonroot '
report_init
report_step_result parse_arguments ok
stage_prerequisites'
    TEST_EUID=$EUID run_child
    eq "not root: exit code 1 as before" 1 "$CHILD_RC"
    check "not root: no spool" test ! -e "$CHILD_DIR/spool"
    check "not root: no timer" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer"
    check "not root: systemctl never enabled anything" bash -c '! grep -q enable "$1" 2>/dev/null' _ "$CHILD_DIR/fake/systemctl.log"
    eq "not root: exactly install_started + install_finished sent" "install_started install_finished" "$(sent_events | jq -r .type | tr '\n' ' ' | sed 's/ $//')"
    eq "not root: failed check_root not_root" "failed check_root not_root" "$(field "$(sent_event install_finished)" .result) $(field "$(sent_event install_finished)" .failed_step) $(field "$(sent_event install_finished)" .reason)"
    new_child nonroot_mkdir '
report_init
exit 1'
    TEST_EUID=1000 run_child
    eq "not root, stopped before the root check: still not_root" not_root "$(field "$(sent_event install_finished)" .reason)"
else
    echo "# skipped: running as root"
fi

# ---------------------------------------------------------------------------
echo "# arguments (real main)"
# ---------------------------------------------------------------------------
child badchannel 'main --channel=bogus'
eq "invalid --channel: exit 1" 1 "$CHILD_RC"
fin=$(event install_finished)
eq "invalid --channel: invalid_argument" "failed parse_arguments invalid_argument" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason)"
eq "invalid --channel reported as direct" direct "$(field "$(event install_started)" .channel)"
child badsource 'main --channel=web-installer --source=nope'
eq "invalid --source: invalid_argument, channel kept" "invalid_argument web-installer" "$(field "$(event install_finished)" .reason) $(field "$(event install_started)" .channel)"
child help 'main --help'
check "--help: nothing reported" test ! -e "$CHILD_DIR/spool"
child unknownflag 'main --whatever=1 --source=nope'
eq "unknown flags still ignored" invalid_argument "$(field "$(event install_finished)" .reason)"
echo test >"$T/marker-other"
child othermarker "REPORT_MARKER=$T/marker-other; main --source=nope"
check "an exit before this run creates the marker leaves another run's marker alone" test -e "$T/marker-other"

# ---------------------------------------------------------------------------
echo "# --no-telemetry"
# ---------------------------------------------------------------------------
child notel 'main --no-telemetry --source=nope'
check "--no-telemetry: says it is off" grep -q 'Install report is off' "$CHILD_DIR/out"
check "--no-telemetry: no spool" test ! -e "$CHILD_DIR/spool"
check "--no-telemetry: nothing sent" test ! -e "$CHILD_DIR/fake/req"
check "--no-telemetry: no timer, no sender" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer" -a ! -e "$CHILD_DIR/libexec"
check "--no-telemetry: systemctl not called" test ! -e "$CHILD_DIR/fake/systemctl.log"
new_child notel_env 'main --source=nope'
(cd "$CHILD_DIR" && ADMINBOLT_NO_TELEMETRY=1 FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
check "ADMINBOLT_NO_TELEMETRY=1: nothing sent, no spool" test ! -e "$CHILD_DIR/fake/req" -a ! -e "$CHILD_DIR/spool"
child notel_ini '
REPORT_NO_TELEMETRY=1
report_init
mkdir -p "$(dirname "$REPORT_BOLT_CONFIG")"
printf "[bolt]\nAPP_KEY=\"base64:abc=\"\n\n[log]\nLOG_LEVEL=debug\n" >"$REPORT_BOLT_CONFIG"
chmod 0640 "$REPORT_BOLT_CONFIG"
report_write_panel_settings'
eq "--no-telemetry: BOLT_INSTALL_TELEMETRY=0 written into [bolt]" $'[bolt]\nAPP_KEY="base64:abc="\n\nBOLT_INSTALL_TELEMETRY=0\n[log]\nLOG_LEVEL=debug' "$(cat "$CHILD_DIR/etc/bolt/bolt-config.ini")"
eq "--no-telemetry: no install ID written" 0 "$(grep -c BOLT_INSTALL_ID "$CHILD_DIR/etc/bolt/bolt-config.ini")"
child id_ini '
report_init
report_write_panel_settings
grep -q "^BOLT_INSTALL_ID=$INSTALL_ID\$" "$REPORT_BOLT_CONFIG" && echo ID-MATCHES
exit 0'
check "BOLT_INSTALL_ID written, same ID as the events" grep -q ID-MATCHES "$CHILD_DIR/out"
eq "created config file is 0640" 640 "$(stat -c %a "$CHILD_DIR/etc/bolt/bolt-config.ini")"

# ---------------------------------------------------------------------------
echo "# INI writer"
# ---------------------------------------------------------------------------
ini="$T/ini/bolt-config.ini"; mkdir -p "$T/ini"
printf '[bolt]\nAPP_KEY="k"\nBOLT_INSTALL_ID=old\n[database]\nDB_PASSWORD="p;w"\n' >"$ini"; chmod 0604 "$ini"
_report_ini_set "$ini" BOLT_INSTALL_ID new
eq "replaces an existing key in place, rest untouched" $'[bolt]\nAPP_KEY="k"\nBOLT_INSTALL_ID=new\n[database]\nDB_PASSWORD="p;w"' "$(cat "$ini")"
eq "keeps the file mode" 604 "$(stat -c %a "$ini")"
printf 'TOP=1\n[database]\nX=1' >"$ini"
_report_ini_set "$ini" BOLT_INSTALL_TELEMETRY 0
eq "no [bolt] section: adds one" $'TOP=1\n[database]\nX=1\n[bolt]\nBOLT_INSTALL_TELEMETRY=0' "$(cat "$ini")"
printf '[bolt]\nA=1\n' >"$ini"
_report_ini_set "$ini" BOLT_INSTALL_TELEMETRY 0
_report_ini_set "$ini" BOLT_INSTALL_TELEMETRY 0
eq "idempotent" $'[bolt]\nA=1\nBOLT_INSTALL_TELEMETRY=0' "$(cat "$ini")"
ln -s "$T/ini/target" "$T/ini/link.ini"; printf 'x\n' >"$T/ini/target"
_report_ini_set "$T/ini/link.ini" K V
check "refuses a symlink" test $? -ne 0
eq "symlink target untouched" x "$(cat "$T/ini/target")"
eq "no temporary files left" 3 "$(ls -A "$T/ini" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "# delivery marks: 2xx and 400/409/413 delivered; 429, 507, 5xx and no answer resent"
# ---------------------------------------------------------------------------
for code in 202 200 400 409 413 429 507 500 503 000; do
    new_child "code$code" '
report_init
report_stage_begin configuration; report_stage_end
report_readiness_check
exit 0'
    echo "$code" >"$CHILD_DIR/fake/http_code"
    run_child
    n=$(ls "$CHILD_DIR"/spool/install-report/*/sent | wc -l | tr -d ' ')
    case "$code" in 2*|400|409|413) eq "HTTP $code: all events marked sent" 5 "$n" ;; *) eq "HTTP $code: nothing marked sent" 0 "$n" ;; esac
done
for code in 429 507 409; do
    new_child "sender$code" '
report_init
exit 1'
    echo 503 >"$CHILD_DIR/fake/http_code"
    run_child
    echo "$code" >"$CHILD_DIR/fake/http_code"
    SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
    (cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$SENDER")
    n=$(ls "$CHILD_DIR"/spool/install-report/*/sent | wc -l | tr -d ' ')
    if [[ "$code" == 409 ]]; then
        eq "timer, HTTP 409: delivered, sender removed" "3 gone" "$n $([[ -e "$SENDER" ]] && echo kept || echo gone)"
    else
        eq "timer, HTTP $code: retried later, sender kept" "0 kept" "$n $([[ -e "$SENDER" ]] && echo kept || echo gone)"
    fi
done

# ---------------------------------------------------------------------------
echo "# resend timer script"
# ---------------------------------------------------------------------------
child sender '
report_init
report_stage_begin packages
report_step_start repo_setup
report_fail repo_setup repo_download_failed
exit 1'
echo 503 >"$CHILD_DIR/fake/http_code"
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/install-report/*/sent/*
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender() { (cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$@" "$SENDER"); }
run_sender env
eq "receiver down: nothing marked sent" 0 "$(ls "$CHILD_DIR"/spool/install-report/*/sent | wc -l | tr -d ' ')"
check "receiver down: sender keeps itself" test -x "$SENDER"
check "receiver down: timer kept" test -e "$CHILD_DIR/units/adminbolt-install-report.timer"
echo 202 >"$CHILD_DIR/fake/http_code"
rm -rf "$CHILD_DIR/fake/req"
run_sender env
eq "receiver back: every saved event arrives" "install_started stage_finished stage_finished install_finished" "$(sent_events | jq -r .type | tr '\n' ' ' | sed 's/ $//')"
eq "receiver back: the failure arrives with its reason" repo_download_failed "$(field "$(sent_event install_finished)" .reason)"
check "all delivered and finished: sender removed" test ! -e "$SENDER"
check "timer unit removed" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer"
check "service unit removed" test ! -e "$CHILD_DIR/units/adminbolt-install-report.service"
check "timer disabled" grep -q 'disable --now adminbolt-install-report.timer' "$CHILD_DIR/fake/systemctl.log"
check "spool kept" test -n "$(ls "$CHILD_DIR"/spool/install-report/*/events/*.json)"

child sender_old '
report_init
exit 1'
echo 503 >"$CHILD_DIR/fake/http_code"
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/install-report/*/sent/*
echo 202 >"$CHILD_DIR/fake/http_code"
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender env ADMINBOLT_REPORT_NOW=$(($(date +%s) + 25 * 3600))
check "after 24 h: nothing sent any more" test ! -e "$CHILD_DIR/fake/req"
check "after 24 h: sender removed itself" test ! -e "$SENDER"
check "after 24 h: timer removed" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer"
check "after 24 h: spool kept" test -n "$(ls "$CHILD_DIR"/spool/install-report/*/events/*.json)"

child sender_running '
report_init
exit 0'
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
rm -f "$CHILD_DIR"/spool/install-report/*/finished
run_sender env
check "install not finished (killed, rebooted): sender stays for the 24 h" test -x "$SENDER"

child sender_unsafe '
report_init
exit 1'
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/install-report/*/sent/*
chmod 0755 "$CHILD_DIR/spool/install-report"
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender env
check "spool not private (not 0700): sender sends nothing from it" test ! -e "$CHILD_DIR/fake/req"
child sender_swapped '
report_init
id=$INSTALL_ID
mv "$REPORT_DIR" "$REPORT_DIR.moved"
mkdir -m 0755 "$REPORT_DIR"; mkdir -m 0700 "$REPORT_DIR/$id" "$REPORT_DIR/$id/events"
report_stage_begin packages
report_stage_end
exit 0'
check "spool swapped for a non-private directory: installer writes nothing into it" test -z "$(ls -A "$CHILD_DIR"/spool/install-report/*/events)"

# ---------------------------------------------------------------------------
echo "# event ids stay within 1..48"
# ---------------------------------------------------------------------------
child cap '
report_init
for i in $(seq 1 60); do _report_emit stage_finished "\"stage\":\"packages\",\"duration_s\":0,\"result\":\"ok\""; done
exit 0'
eq "highest event id 48" 48 "$(spool_events | jq -s 'map(.event_id) | max')"
eq "install_finished still recorded" 1 "$(spool_events | jq -s 'map(select(.type=="install_finished")) | length')"
eq "ids unique" "$(spool_events | jq -s 'length')" "$(spool_events | jq -s 'map(.event_id) | unique | length')"

# ---------------------------------------------------------------------------
echo "# time added with the receiver blocked"
# ---------------------------------------------------------------------------
timed_child() { # $1 name; uses $CHILD_DIR/fake setup by caller
    local start end
    start=$(date +%s.%N)
    run_child
    end=$(date +%s.%N)
    ELAPSED=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }')
}
flow='
report_init
report_stage_begin packages; report_stage_end
report_stage_begin configuration; report_stage_end
report_fail agent_panel_connect
exit 1'
new_child hang "$flow"
echo 30 >"$CHILD_DIR/fake/curl_sleep"
timed_child
check "receiver hangs: final wait capped at 5 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 7) }'
eq "receiver hangs: exit code unchanged" 1 "$CHILD_RC"
pkill -f "sleep 30" 2>/dev/null
if [[ -n "$REAL_CURL" ]]; then
    new_child refused "ADMINBOLT_INSTALL_REPORT_URL=http://127.0.0.1:9/install-events; $flow"
    echo "$REAL_CURL" >"$CHILD_DIR/fake/real_curl"
    timed_child
    check "real curl, port closed: adds under 10 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'
    eq "real curl, port closed: events stay unsent for the timer" 0 "$(ls "$CHILD_DIR"/spool/install-report/*/sent | wc -l | tr -d ' ')"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(64)
print(s.getsockname()[1], flush=True); time.sleep(40)' >"$T/blackhole.port" &
        bh=$!
        for _ in $(seq 1 30); do [[ -s "$T/blackhole.port" ]] && break; sleep 0.1; done
        new_child blackhole "ADMINBOLT_INSTALL_REPORT_URL=http://127.0.0.1:$(cat "$T/blackhole.port")/install-events; $flow"
        echo "$REAL_CURL" >"$CHILD_DIR/fake/real_curl"
        timed_child
        check "real curl, receiver accepts and never answers: adds under 10 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'
        eq "real curl, silent receiver: exit code unchanged" 1 "$CHILD_RC"
        kill "$bh" 2>/dev/null
    fi
fi

# ---------------------------------------------------------------------------
echo "# every event of every run above against the KONTRAKT field rules"
# ---------------------------------------------------------------------------
SCHEMA='
def re(r): type == "string" and test(r);
def int(a; b): type == "number" and . == floor and . >= a and . <= b;
def steps: type == "array" and length <= 40 and all(.[]; re("^[a-z0-9_-]{1,48}$"));
def common: (keys - ["schema","install_id","event_id","type","sent_at"]) as $rest
  | .schema == 1 and (.install_id | re("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.event_id | int(1; 48)) and (.sent_at | re("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
common and (
  if .type == "install_started" then
    (keys | sort) == (["schema","install_id","event_id","type","sent_at","channel","platform","installer_rev","os_name","os_version","arch","requested_version","source","telemetry_notice"] | sort)
    and (.channel | IN("direct","get-script","web-installer","vultr","akamai","node","image-build","test","hostinger","digitalocean","aws","azure"))
    and (.platform | IN("hetzner","vultr","akamai","digitalocean","aws","azure","gcp","ovh","contabo","kvm","vmware","other","unknown"))
    and (.installer_rev | re("^[0-9a-f]{64}$")) and (.os_name | re("^[a-z0-9._-]{1,32}$")) and (.os_version | re("^[0-9A-Za-z._-]{1,16}$"))
    and (.arch | IN("x86_64","aarch64","other")) and (.requested_version | re("^[0-9A-Za-z.+~_-]{0,40}$"))
    and (.source | re("^[a-z0-9_-]{1,16}$")) and .telemetry_notice == true
  elif .type == "stage_finished" then
    (keys | sort) == (["schema","install_id","event_id","type","sent_at","stage","duration_s","result"] | sort)
    and (.stage | IN("prerequisites","packages","configuration","readiness")) and (.duration_s | int(0; 86400))
    and (.result | IN("ok","warnings","failed"))
  elif .type == "install_finished" then
    (keys | sort) == (["schema","install_id","event_id","type","sent_at","result","failed_step","reason","exit_code","signal","failed_optional_steps","failed_required_steps","panel_version","agent_version","trial_licence","duration_s"] | sort)
    and (.result | IN("succeeded","succeeded_with_warnings","failed","cancelled"))
    and (.failed_step | re("^[a-z0-9_-]{0,48}$"))
    and (.reason | IN("","not_root","unsupported_os","invalid_argument","missing_command","port_in_use","repo_download_failed","package_install_failed","agent_install_failed","panel_scriptlet_failed","agent_panel_connect_failed","required_step_failed","readiness_check_failed","interrupted","unclassified"))
    and ((.reason == "") == (.result | IN("succeeded","succeeded_with_warnings")))
    and (.exit_code | int(0; 255)) and (.signal | IN("INT","TERM","HUP",""))
    and (.failed_optional_steps | steps) and (.failed_required_steps | steps)
    and (.panel_version | re("^[0-9A-Za-z.+~_-]{0,40}$")) and (.agent_version | re("^[0-9A-Za-z.+~_-]{0,40}$"))
    and (.trial_licence | IN("ok","failed","skipped","")) and (.duration_s | int(0; 86400))
  else false end)'
all_files=$(find "$T" \( -path '*/events/*.json' -o -path '*/fake/req/*' \) -type f)
total=$(printf '%s\n' "$all_files" | grep -c .)
bad=$(printf '%s\n' "$all_files" | while read -r f; do jq -e "$SCHEMA" "$f" >/dev/null 2>&1 || echo "$f"; done)
eq "all $total stored or sent events match the field rules" "" "$bad"
check "no e-mail address in any of them" bash -c '! cat "$@" | grep -q "@"' _ $all_files
check "no os-release hostname in any of them" bash -c '! cat "$@" | grep -q "host.example.com"' _ $all_files
big=$(printf '%s\n' "$all_files" | while read -r f; do [[ $(wc -c <"$f") -le 8192 ]] || echo "$f"; done)
eq "every event under 8 KB" "" "$big"

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
