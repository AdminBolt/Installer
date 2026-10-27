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
# Fakes that hang record their PID in <child>/fake/pids; only those are stopped.
cleanup() {
    local f pid
    for f in "$T"/*/fake/pids; do
        [[ -f "$f" ]] || continue
        while read -r pid; do [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; done <"$f"
    done
    rm -rf "$T"
}
trap cleanup EXIT
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
case " $* " in
    *repodata/repomd.xml*)
        # metadata probe of a written repository: repomd_rc != 0 = unreachable;
        # repomd_sleep = a hanging mirror, cut off at --max-time like curl does
        mt="" prev=""
        for a in "$@"; do
            [[ "$a" == http* ]] && echo "$a" >>"$FAKE_DIR/repomd.log"
            [[ "$prev" == --max-time ]] && mt="$a"
            prev="$a"
        done
        if [[ -f "$FAKE_DIR/repomd_sleep" ]]; then
            sl=$(cat "$FAKE_DIR/repomd_sleep")
            if [[ -n "$mt" ]] && ((mt < sl)); then sleep "$mt"; exit 28; fi
            sleep "$sl"
        fi
        exit "$(cat "$FAKE_DIR/repomd_rc" 2>/dev/null || echo 0)" ;;
    *get.acme.sh*)
        # acme.sh download: acme_rc != 0 = the download fails with no output
        rc=$(cat "$FAKE_DIR/acme_rc" 2>/dev/null || echo 0)
        ((rc == 0)) && echo true
        exit "$rc" ;;
esac
data="" insecure=0 url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-binary) data="$2"; shift ;;
        -k) insecure=1 ;;
        http://*|https://*) url="$1" ;;
    esac
    shift
done
if ((insecure)); then
    printf '%s' "$(cat "$FAKE_DIR/panel_code" 2>/dev/null || echo 302)"
    exit 0
fi
# A receiver that never answers: the process is recorded so the test can stop it.
if [[ -f "$FAKE_DIR/curl_sleep" ]]; then
    echo "$$" >>"$FAKE_DIR/pids"
    exec sleep "$(cat "$FAKE_DIR/curl_sleep")"
fi
[[ -f "$FAKE_DIR/curl_delay" ]] && sleep "$(cat "$FAKE_DIR/curl_delay")"
mkdir -p "$FAKE_DIR/req"
out=$(mktemp "$FAKE_DIR/req/r.XXXXXX")
case "$data" in
    @-) cat >"$out" ;;
    @*) cat "${data#@}" >"$out" ;;
    *) printf '%s' "$data" >"$out" ;;
esac
# Which receiver each install's events went to.
printf '%s %s\n' "$(grep -o '"install_id":"[0-9a-f-]*"' "$out" | cut -d'"' -f4)" "$url" >>"$FAKE_DIR/urls"
code=$(cat "$FAKE_DIR/http_code" 2>/dev/null || echo 202)
printf '%s' "$code"
[[ "$code" == 000 ]] && exit 7
exit 0
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/systemctl.log"
# A hanging systemd: recorded so the test can stop it.
if [[ -f "$FAKE_DIR/slow" ]]; then echo "$$" >>"$FAKE_DIR/pids"; s=$(cat "$FAKE_DIR/slow"); exec sleep "${s:-6}"; fi
case "$1" in
    is-system-running)
        st=$(cat "$FAKE_DIR/system_state" 2>/dev/null || echo running)
        # "killed": systemd killing new processes in a stopping unit (E5 reboots)
        [[ "$st" == killed ]] && kill -KILL $$
        printf '%s\n' "$st" ;;
    is-active)
        shift
        rc=0 any=0
        for u in "$@"; do
            [[ "$u" == --* ]] && continue
            if grep -qx "$u" "$FAKE_DIR/inactive" 2>/dev/null; then echo inactive; rc=3; else echo active; any=1; fi
        done
        # like systemctl: 0 when at least one of the units is active
        ((any)) && exit 0
        exit "$rc" ;;
esac
exit 0
EOF
cat >"$T/bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$FAKE_DIR/slow" ]]; then echo "$$" >>"$FAKE_DIR/pids"; s=$(cat "$FAKE_DIR/slow"); exec sleep "${s:-6}"; fi
fmt=""
names=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) ;;
        --qf) fmt="$2"; shift ;;
        *) names+=("$1") ;;
    esac
    shift
done
rc=0
for n in "${names[@]}"; do
    case "$n" in
        bolt-panel) v=1.9.3-1.el9 ;;
        bolt-agent) v=2.4.0-1.el9 ;;
        *) echo "package $n is not installed"; rc=1; continue ;;
    esac
    if [[ "$fmt" == *NAME* ]]; then printf '%s %s\n' "$n" "$v"; else printf '%s' "$v"; fi
done
exit "$rc"
EOF
cat >"$T/bin/getenforce" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_DIR/selinux" 2>/dev/null || echo Enforcing
EOF
cat >"$T/bin/setenforce" <<'EOF'
#!/usr/bin/env bash
echo "setenforce $*" >>"$FAKE_DIR/setenforce.log"
exit "$(cat "$FAKE_DIR/setenforce_rc" 2>/dev/null || echo 0)"
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
    printf '4c4c4544004e3510804ab4c04f4e3332\n' >"$CHILD_DIR/machine-id"
    mkdir -p "$CHILD_DIR/etc/yum.repos.d"
    cat >"$CHILD_DIR/child.sh" <<EOF
ADMINBOLT_INSTALL_SOURCE_ONLY=1
. "$INSTALL_SH"
REPORT_DIR="$CHILD_DIR/spool/adminbolt-install-report"
REPORT_SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
REPORT_UNIT_DIR="$CHILD_DIR/units"
REPORT_BOLT_CONFIG="$CHILD_DIR/etc/bolt/bolt-config.ini"
REPORT_DMI_DIR="$CHILD_DIR/dmi"
REPORT_OS_RELEASE="$CHILD_DIR/os-release"
REPORT_MARKER="$CHILD_DIR/marker"
REPORT_SHUTDOWN_MARKERS="$CHILD_DIR/run/shutdown-scheduled $CHILD_DIR/run/nologin"
REPORT_UUID_FILE="$CHILD_DIR/no-such-uuid"
REPORT_MACHINE_ID_FILE="$CHILD_DIR/machine-id"
BOLT_REPO_FILE="$CHILD_DIR/etc/yum.repos.d/bolt.repo"
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
spool_events() { cat "$CHILD_DIR"/spool/adminbolt-install-report/*/events/*.json 2>/dev/null | jq -cs 'sort_by(.event_id)[]'; }
sent_events() { cat "$CHILD_DIR"/fake/req/* 2>/dev/null | jq -cs 'sort_by(.event_id)[]'; }
event() { spool_events | jq -c "select(.type == \"$1\")" | tail -n 1; }
sent_event() { sent_events | jq -c "select(.type == \"$1\")" | tail -n 1; }
field() { jq -r "$2 | if type == \"array\" then join(\",\") else tostring end" <<<"$1"; }

# Loaded here as well, for the pure functions.
ADMINBOLT_INSTALL_SOURCE_ONLY=1 . "$INSTALL_SH"
set +e
trap cleanup EXIT
trap - INT TERM HUP

# ---------------------------------------------------------------------------
echo "# loading and the curl | bash path"
# ---------------------------------------------------------------------------
check "sourcing does not run the install" test "${REPORT_MODE:-}" = off
# The panel's database install takes over the database directory recursively
# (chown -R boltweb), so the spool must not live under it.
eq "spool is its own directory under /var/lib" /var/lib/adminbolt-install-report "${REPORT_DIR:-}"
rd="${REPORT_DIR:-}"
check "spool is outside the panel database directory" test -n "$rd" -a "$rd" = "${rd#/var/lib/adminbolt/}"
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
all="$(cat "$CHILD_DIR"/spool/adminbolt-install-report/*/events/*.json "$CHILD_DIR"/fake/req/* 2>/dev/null)"
check "no e-mail address in any event" bash -c '! grep -q "@" <<<"$1"' _ "$all"
check "no hostname from os-release in any event" bash -c '! grep -q "host.example.com" <<<"$1"' _ "$all"
check "no hostname of this machine in any event" bash -c '! grep -qF -- "$(hostname)" <<<"$1"' _ "$all"
eq "every event was delivered" 6 "$(sent_events | jq -s 'map(.event_id) | unique | length')"
eq "all marked sent" 6 "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')"
check "marker removed by the EXIT trap" test ! -e "$CHILD_DIR/marker"
idir=$(echo "$CHILD_DIR"/spool/adminbolt-install-report/*/)
eq "spool root private" "700" "$(stat -c %a "$CHILD_DIR/spool/adminbolt-install-report")"
eq "install dir private" "700" "$(stat -c %a "$idir")"
eq "event file private" "600" "$(stat -c %a "$idir/events/1.json")"
check "spool keeps the install start time" grep -qE '^[0-9]+$' "$idir/started"
check "spool marks the install finished" test -e "$idir/finished"
check "timer enabled at start" grep -q 'enable --now adminbolt-install-report.timer' "$CHILD_DIR/fake/systemctl.log"
check "timer OnBootSec=5min" grep -qx 'OnBootSec=5min' "$CHILD_DIR/units/adminbolt-install-report.timer"
check "timer every 15 min" grep -qx 'OnUnitActiveSec=15min' "$CHILD_DIR/units/adminbolt-install-report.timer"
check "service runs the sender" grep -qx "ExecStart=$CHILD_DIR/libexec/adminbolt/install-report-send" "$CHILD_DIR/units/adminbolt-install-report.service"
for lim in TimeoutStartSec=300 MemoryMax=64M CPUQuota=20%; do
    check "service limited: $lim" grep -qx "$lim" "$CHILD_DIR/units/adminbolt-install-report.service"
done
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

# --source writes the repository file without downloading anything; its
# metadata is probed so an unreachable mirror is reported as one when a
# package step then fails. The probe never stops the install by itself.
src_child() { # $1 name, $2 repomd_rc, $3 what happens after the repository step, $4 extra setup, $5 mirror hang in seconds
    new_child "$1" "
BOLT_SOURCE=stable
${4:-}
report_init
report_stage_begin packages
report_step_start repo_setup
install_repo_rhel 9
echo AFTER-REPO
$3"
    echo "$2" >"$CHILD_DIR/fake/repomd_rc"
    [[ -z "${5:-}" ]] || echo "$5" >"$CHILD_DIR/fake/repomd_sleep"
    run_child
}
src_child src_down 7 'report_step_start agent_install
report_fail agent_install agent_install_failed
exit 1'
fin=$(event install_finished)
eq "--source, mirror unreachable, bolt-agent install fails: repo_setup repo_download_failed, exit 1" "failed repo_setup repo_download_failed 1" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $CHILD_RC"
eq "--source, mirror unreachable: both steps listed as failed" "repo_setup,agent_install" "$(field "$fin" .failed_required_steps)"
check "--source, mirror unreachable: the probe does not stop the install" grep -q AFTER-REPO "$CHILD_DIR/out"
src_child src_up 0 'report_step_start agent_install
report_fail agent_install agent_install_failed
exit 1'
fin=$(event install_finished)
eq "--source, mirror reachable, bolt-agent install fails: agent_install agent_install_failed" "agent_install agent_install_failed" "$(field "$fin" .failed_step) $(field "$fin" .reason)"
# The probe reads the addresses from the repository file it just wrote.
expected=$(sed -n 's/^baseurl = //p' "$CHILD_DIR/etc/yum.repos.d/bolt.repo" | sed -e 's/\$releasever/9/' -e "s/\\\$basearch/$(uname -m)/" -e 's#$#/repodata/repomd.xml#')
eq "--source, mirror reachable: probes exactly the baseurls of the written bolt.repo" "$expected" "$(cat "$CHILD_DIR/fake/repomd.log")"
eq "--source: two repositories in the file" 2 "$(printf '%s\n' "$expected" | grep -c 'pulp/content/stable/rhel/9/.*/repodata/repomd.xml')"
src_child src_notel 7 'report_step_start agent_install
report_fail agent_install agent_install_failed
exit 1' 'REPORT_NO_TELEMETRY=1'
check "--no-telemetry: no repository probe" test ! -e "$CHILD_DIR/fake/repomd.log"
check "--no-telemetry: repository file still written" grep -q '^\[bolt\]' "$CHILD_DIR/etc/yum.repos.d/bolt.repo"
# One run only, with the mirror hanging from the start: a second run in the
# same directory would leave two installs in the spool.
start=$(date +%s.%N)
src_child src_hang 0 'report_step_start agent_install
report_fail agent_install agent_install_failed
exit 1' 'REPORT_PROBE_CAP=2' 30
ELAPSED=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
check "--source, hanging mirror: the probe keeps to its total cap (2 s, took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 4.5) }'
eq "--source, hanging mirror: reported as repo_download_failed" "repo_setup repo_download_failed" "$(field "$(event install_finished)" .failed_step) $(field "$(event install_finished)" .reason)"
src_child src_flaky 7 'report_step_start agent_install
report_step_result agent_install ok
report_stage_begin configuration; report_stage_end
report_readiness_check
exit 0'
eq "--source, probe failed but the install succeeds: succeeded" "succeeded 0" "$(field "$(event install_finished)" .result) $CHILD_RC"

child repo_rpm '
report_init
report_stage_begin packages
report_step_start repo_setup
dnf() { return 1; }
yum() { return 1; }
rpm() { [[ "$1" == -ivh ]] && return 3; command rpm "$@"; }
install_repo_rhel 9
echo NOT-REACHED'
fin=$(event install_finished)
eq "bolt-repo package install fails: repo_setup package_install_failed, rpm exit code kept" "failed repo_setup package_install_failed 3 3" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code) $CHILD_RC"
check "bolt-repo package install fails: script stops there as before" bash -c '! grep -q NOT-REACHED "$1"' _ "$CHILD_DIR/out"

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
sig_child() { # $1 name, $2 signal, $3 system state, $4 shutdown marker to create before the signal
    new_child "$1" '
report_init
report_stage_begin packages
report_step_start agent_install
INSTALL_MARKER_CREATED=1; touch "$REPORT_MARKER"
sleep 20 & wait $!
echo NOT-REACHED'
    if [[ $# -ge 3 ]]; then printf '%s' "$3" >"$CHILD_DIR/fake/system_state"; fi
    (cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" exec "$BASH" child.sh >"$CHILD_DIR/out" 2>&1) &
    local pid=$!
    for _ in $(seq 1 50); do [[ -e "$CHILD_DIR/marker" ]] && break; sleep 0.1; done
    sleep 0.3
    if [[ -n "${4:-}" ]]; then mkdir -p "$CHILD_DIR/run"; : >"$CHILD_DIR/run/$4"; fi
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
# E5 B2: on a reboot, systemd killed the systemctl started from the TERM
# trap before it answered, and the install showed as cancelled.
sig_child term_killed TERM killed
eq "TERM, state check killed (reboot): no install_finished" "" "$(event install_finished)"
eq "TERM, state check killed: nothing like it sent" "" "$(sent_event install_finished)"
eq "TERM, state check killed: exit 143 as before" 143 "$CHILD_RC"
sig_child term_empty TERM ""
eq "TERM, empty answer from systemd: no install_finished" "" "$(event install_finished)"
sig_child hup_killed HUP killed
eq "HUP, state check killed: no install_finished" "" "$(event install_finished)"
for m in shutdown-scheduled nologin; do
    sig_child "term_$m" TERM running "$m"
    eq "TERM with shutdown marker $m: no install_finished" "" "$(event install_finished)"
    check "TERM with shutdown marker $m: systemd not asked" bash -c '! grep -q is-system-running "$1"' _ "$CHILD_DIR/fake/systemctl.log"
done
sig_child term_degraded TERM degraded
eq "TERM, system up (degraded): cancelled" "cancelled TERM 143" "$(field "$(event install_finished)" .result) $(field "$(event install_finished)" .signal) $CHILD_RC"
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
# --channel only labels the report: an unknown, empty or missing value warns
# once, is reported as direct, and the install goes on (here up to Stage 1,
# replaced by a stub that ends the run).
chan_child() { # $1 name, $2 the --channel argument(s) as shell words
    child "$1" "stage_prerequisites() { echo REACHED-STAGE1; exit 0; }
main $2"
    CHAN_OUT="$CHILD_RC $(grep -q REACHED-STAGE1 "$CHILD_DIR/out" && echo continued || echo stopped) $(field "$(event install_started)" .channel) $(grep -c 'WARNING:.*unknown --channel=' "$CHILD_DIR/out")"
}
chan_child badchannel '--channel=bogus'
eq "unknown --channel: one warning, reported as direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
check "unknown --channel: not an invalid_argument" bash -c '! grep -q invalid_argument <<<"$1"' _ "$(field "$(event install_finished)" .reason)"
chan_child emptychannel '--channel='
eq "empty --channel=: one warning, direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
chan_child barechannel '--channel'
eq "--channel without a value: one warning, direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
chan_child twochannels "'--channel=direct get-script'"
eq "--channel with two names: one warning, direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
chan_child spacechannel "'--channel= direct'"
eq "--channel with a space: one warning, direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
chan_child goodchannel '--channel=web-installer'
eq "known --channel: no warning, kept" "0 continued web-installer 0" "$CHAN_OUT"
chan_child ctlchannel "\$'--channel=bo\\e[31mgus\\ttab\\\\n'"
eq "--channel with control characters: one warning, direct, install goes on" "0 continued direct 1" "$CHAN_OUT"
check "control characters shown as '?', backslash as typed" grep -qF 'unknown --channel=bo?[31mgus?tab\n,' "$CHILD_DIR/out"
check "no raw escape from the value reaches the screen" bash -c '! grep -q $'"'"'bo\e\[31m'"'"' "$1"' _ "$CHILD_DIR/out"
chan_child longchannel "--channel=$(printf 'x%.0s' {1..300})"
check "long --channel cut to 40 characters in the warning" grep -qE 'unknown --channel=x{40},' "$CHILD_DIR/out"
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
# sha256 of the machine ID without its trailing newline; the panel computes
# the same value (AB2067InstallReportServiceTest uses the same vector).
eq "machine fingerprint written next to the ID (sha256 of the trimmed machine-id)" "06962624eca6f46cd820de44ed3b4241ff66c5cde655891fb4ef86e306e187ad" "$(sed -n 's/^BOLT_INSTALL_MACHINE=//p' "$CHILD_DIR/etc/bolt/bolt-config.ini")"
child id_ini_nomachine '
rm -f "$REPORT_MACHINE_ID_FILE"
report_init
report_write_panel_settings
exit 0'
eq "no machine-id: ID written, no fingerprint" "1 0" "$(grep -c '^BOLT_INSTALL_ID=' "$CHILD_DIR/etc/bolt/bolt-config.ini") $(grep -c '^BOLT_INSTALL_MACHINE' "$CHILD_DIR/etc/bolt/bolt-config.ini")"
# An image build: every server booted from the image would inherit what the
# build leaves on disk, so it leaves no install ID, spool or timer; its own
# events are only sent directly.
child imgbuild '
REPORT_CHANNEL_ARG=image-build
report_init
report_stage_begin configuration; report_stage_end
report_write_panel_settings
report_readiness_check
exit 0'
check "image build: no install ID in bolt-config.ini" bash -c '! grep -qs BOLT_INSTALL "$1"' _ "$CHILD_DIR/etc/bolt/bolt-config.ini"
check "image build: no spool" test ! -e "$CHILD_DIR/spool"
check "image build: no timer, no sender" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer" -a ! -e "$CHILD_DIR/libexec"
eq "image build: its events still sent, channel image-build" "image-build succeeded" "$(field "$(sent_event install_started)" .channel) $(field "$(sent_event install_finished)" .result)"

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
    n=$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')
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
    n=$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')
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
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/adminbolt-install-report/*/sent/*
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender() { (cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$@" "$SENDER"); }
run_sender env
eq "receiver down: nothing marked sent" 0 "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')"
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
check "spool kept" test -n "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/events/*.json)"

child sender_old '
report_init
exit 1'
echo 503 >"$CHILD_DIR/fake/http_code"
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/adminbolt-install-report/*/sent/*
echo 202 >"$CHILD_DIR/fake/http_code"
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender env ADMINBOLT_REPORT_NOW=$(($(date +%s) + 25 * 3600))
check "after 24 h: nothing sent any more" test ! -e "$CHILD_DIR/fake/req"
check "after 24 h: sender removed itself" test ! -e "$SENDER"
check "after 24 h: timer removed" test ! -e "$CHILD_DIR/units/adminbolt-install-report.timer"
check "after 24 h: spool kept" test -n "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/events/*.json)"

# One run sends for at most its run budget (the unit's TimeoutStartSec is the
# hard stop); what is left waits for the next run.
child sender_budget '
report_init
exit 1'
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/adminbolt-install-report/*/sent/*
echo 1 >"$CHILD_DIR/fake/curl_delay"
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
run_sender env ADMINBOLT_REPORT_RUN_BUDGET=1
rm -f "$CHILD_DIR/fake/curl_delay"
sent_n=$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')
all_n=$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/events | wc -l | tr -d ' ')
check "run budget spent: not every event sent in one run ($sent_n of $all_n)" test "$sent_n" -lt "$all_n"
check "run budget spent: timer kept for the rest" test -e "$CHILD_DIR/units/adminbolt-install-report.timer"
run_sender env
eq "next run sends the rest" "$all_n" "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')"

child sender_running '
report_init
exit 0'
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
rm -f "$CHILD_DIR"/spool/adminbolt-install-report/*/finished
run_sender env
check "install not finished (killed, rebooted): sender stays for the 24 h" test -x "$SENDER"

child sender_unsafe '
report_init
exit 1'
rm -rf "$CHILD_DIR/fake/req" "$CHILD_DIR"/spool/adminbolt-install-report/*/sent/*
chmod 0755 "$CHILD_DIR/spool/adminbolt-install-report"
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
check "spool swapped for a non-private directory: installer writes nothing into it" test -z "$(ls -A "$CHILD_DIR"/spool/adminbolt-install-report/*/events)"

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
while read -r pid; do kill "$pid" 2>/dev/null; done <"$CHILD_DIR/fake/pids"
if [[ -n "$REAL_CURL" ]]; then
    new_child refused "ADMINBOLT_INSTALL_REPORT_URL=http://127.0.0.1:9/install-events; $flow"
    echo "$REAL_CURL" >"$CHILD_DIR/fake/real_curl"
    timed_child
    check "real curl, port closed: adds under 10 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'
    eq "real curl, port closed: events stay unsent for the timer" 0 "$(ls "$CHILD_DIR"/spool/adminbolt-install-report/*/sent | wc -l | tr -d ' ')"
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
echo "# bolt-panel wrapper without a usable temporary file"
# ---------------------------------------------------------------------------
child nomktemp '
report_init
report_stage_begin packages
install_packages() { echo "Packages already installed"; }
mktemp() { return 1; }
install_bolt_panel_and_check_post bolt-panel
echo CONTINUED'
check "mktemp fails: install goes on as before" grep -q CONTINUED "$CHILD_DIR/out"
eq "mktemp fails: exit code 0" 0 "$CHILD_RC"
child notee '
report_init
report_stage_begin packages
install_packages() { echo "Packages installed"; }
tee() { cat >/dev/null; return 1; }
install_bolt_panel_and_check_post bolt-panel
echo CONTINUED'
check "tee fails: install goes on as before" grep -q CONTINUED "$CHILD_DIR/out"
eq "tee fails: exit code 0" 0 "$CHILD_RC"
child notee_dnf '
report_init
report_stage_begin packages
install_packages() { exit 1; }
tee() { cat >/dev/null; return 1; }
install_bolt_panel_and_check_post bolt-panel
echo NOT-REACHED'
eq "tee fails and dnf fails: still stops with dnf's code" "1 package_install_failed" "$CHILD_RC $(field "$(event install_finished)" .reason)"

# ---------------------------------------------------------------------------
echo "# acme.sh download"
# ---------------------------------------------------------------------------
acme_child() {
    new_child "acme$1" '
report_init
report_stage_begin packages
install_packages() { :; }
stage2_install_prerequisite_packages
report_stage_end
exit 0'
    echo "$1" >"$CHILD_DIR/fake/acme_rc"
    run_child
}
acme_child 7
check "download fails: acme_sh is a failed optional step" grep -qw acme_sh <<<"$(field "$(event install_finished)" .failed_optional_steps)"
acme_child 0
check "download works: acme_sh not failed" bash -c '! grep -qw acme_sh <<<"$1"' _ "$(field "$(event install_finished)" .failed_optional_steps)"

# ---------------------------------------------------------------------------
echo "# SELinux already off"
# ---------------------------------------------------------------------------
selinux_child() { # $1 getenforce output, $2 setenforce exit code
    new_child "selinux$1$2" '
report_init
report_stage_begin packages
stage2_prepare_settings
report_stage_end
exit 0'
    echo "$1" >"$CHILD_DIR/fake/selinux"
    echo "$2" >"$CHILD_DIR/fake/setenforce_rc"
    run_child
    SEL_FAILED=$(field "$(event install_finished)" .failed_optional_steps)
    SEL_CALLED=$([[ -e "$CHILD_DIR/fake/setenforce.log" ]] && echo called || echo not-called)
}
selinux_child Disabled 1
eq "SELinux Disabled: step ok, setenforce not called" "ok not-called" "$(grep -qw selinux_enforce <<<"$SEL_FAILED" && echo failed || echo ok) $SEL_CALLED"
selinux_child Permissive 1
eq "SELinux Permissive: step ok, setenforce not called" "ok not-called" "$(grep -qw selinux_enforce <<<"$SEL_FAILED" && echo failed || echo ok) $SEL_CALLED"
selinux_child Enforcing 0
eq "SELinux Enforcing: setenforce called, step ok" "ok called" "$(grep -qw selinux_enforce <<<"$SEL_FAILED" && echo failed || echo ok) $SEL_CALLED"
selinux_child Enforcing 1
eq "SELinux Enforcing, setenforce fails: step failed" "failed called" "$(grep -qw selinux_enforce <<<"$SEL_FAILED" && echo failed || echo ok) $SEL_CALLED"

# ---------------------------------------------------------------------------
echo "# Ctrl+C behaves as in bash without the report (base 59535f2 had no INT trap)"
# ---------------------------------------------------------------------------
set -m
# $1 name, $2 "report" or "plain", $3 body of the step script, $4 (optional)
# the install code that runs it. Sends SIGINT to the whole process group, as
# Ctrl+C in a terminal does.
int_child() {
    local init="" call="${4:-run_or_warn \"\$BASH step.sh\" \"Step\" greeting}"
    [[ "$2" == report ]] && init="report_init; report_stage_begin configuration"
    new_child "$1" "$init
touch \"\$FAKE_DIR/ready\"
$call
echo CONTINUED
exit 0"
    printf '%s\n' "$3" >"$CHILD_DIR/step.sh"
    (cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" exec "$BASH" child.sh >"$CHILD_DIR/out" 2>&1) &
    local pid=$!
    for _ in $(seq 1 50); do [[ -e "$CHILD_DIR/fake/ready" ]] && break; sleep 0.1; done
    sleep 0.5
    kill -INT -- "-$pid"
    wait "$pid"
    CHILD_RC=$?
    INT_OUTCOME="$CHILD_RC $(grep -q CONTINUED "$CHILD_DIR/out" && echo continued || echo stopped)"
}
dies='sleep 20'
handles='trap "exit 0" INT; sleep 20 & echo $! >>"$FAKE_DIR/pids"; wait $!'
int_child int_dies_plain plain "$dies"; base_dies="$INT_OUTCOME"
int_child int_dies_report report "$dies"
eq "child killed by Ctrl+C: same as without the report ($base_dies)" "$base_dies" "$INT_OUTCOME"
eq "child killed by Ctrl+C: cancelled, INT" "cancelled INT 130" "$(field "$(event install_finished)" .result) $(field "$(event install_finished)" .signal) $(field "$(event install_finished)" .exit_code)"
int_child int_handles_plain plain "$handles"; base_handles="$INT_OUTCOME"
int_child int_handles_report report "$handles"
eq "child handles Ctrl+C and returns 0: same as without the report ($base_handles)" "$base_handles" "$INT_OUTCOME"
eq "child handles Ctrl+C: install goes on, no signal recorded" "0 continued " "$INT_OUTCOME $(field "$(event install_finished)" .signal)"
# dnf catches Ctrl+C and exits 1; the step fails, the install goes on as before,
# and when the install then ends with an error it shows as cancelled.
handles1='trap "exit 1" INT; sleep 20 & echo $! >>"$FAKE_DIR/pids"; wait $!'
int_child int_handles1_plain plain "$handles1"; base_handles1="$INT_OUTCOME"
int_child int_handles1_report report "$handles1"
eq "child handles Ctrl+C and exits 1 (like dnf): same as without the report ($base_handles1)" "$base_handles1" "$INT_OUTCOME"
# bolt-panel: the package step behind the %post log copy (tee) handles Ctrl+C
# and keeps writing; base 59535f2 ran it directly, without the copy.
pkg_step='install_packages() { "$BASH" step.sh; echo after the interruption; echo more output; }'
int_child int_panel_plain plain "$handles" "$pkg_step
install_packages --enablerepo=bolt bolt-nginx bolt-php bolt-panel"; base_panel="$INT_OUTCOME"
int_child int_panel_report report "$handles" "report_stage_begin packages
$pkg_step
install_bolt_panel_and_check_post bolt-panel"
eq "bolt-panel step handles Ctrl+C and keeps writing: same as without the report ($base_panel)" "$base_panel" "$INT_OUTCOME"
check "bolt-panel step: its output after Ctrl+C still shown" grep -q 'more output' "$CHILD_DIR/out"
# _report_on_int is what the INT trap runs once the command that absorbed
# Ctrl+C has returned (here with 1, like dnf).
new_child int_then_fail '
report_init
report_stage_begin packages
report_step_start prerequisite_packages
_report_on_int 1
report_fail
exit 1'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed, that step then fails: cancelled, exit code kept" "cancelled INT interrupted prerequisite_packages 1 1" "$(field "$fin" .result) $(field "$fin" .signal) $(field "$fin" .reason) $(field "$fin" .failed_step) $(field "$fin" .exit_code) $CHILD_RC"
new_child int_then_other_fail '
report_init
report_stage_begin packages
report_step_start greeting
_report_on_int 1
report_step_result greeting failed
report_fail panel_scriptlet panel_scriptlet_failed
report_stage_begin configuration
report_step_start agent_panel_connect
report_fail
exit 1'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed by an optional step, required steps fail later: failed with the first real reason, exit code kept" "failed - panel_scriptlet_failed panel_scriptlet 1 1" "$(field "$fin" .result) -$(field "$fin" .signal) $(field "$fin" .reason) $(field "$fin" .failed_step) $(field "$fin" .exit_code) $CHILD_RC"
eq "same: failed steps listed" "greeting panel_scriptlet,agent_panel_connect" "$(field "$fin" .failed_optional_steps) $(field "$fin" .failed_required_steps)"
new_child int_then_sete '
report_init
report_stage_begin packages
report_step_start greeting
_report_on_int 1
report_step_result greeting failed
report_step_start web_services_enable
false'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed, later step stops the script (set -e): failed with that step" "failed web_services_enable required_step_failed 1" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code)"
new_child int_same_sete '
report_init
report_stage_begin packages
report_step_start prerequisite_packages
_report_on_int 1
false'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed, the same step stops the script (set -e): cancelled" "cancelled INT prerequisite_packages 1" "$(field "$fin" .result) $(field "$fin" .signal) $(field "$fin" .failed_step) $(field "$fin" .exit_code)"
# The Ctrl+C belongs to one run of a step, not to its name: stage 2.2 starts
# prerequisite_packages twice. dnf absorbs Ctrl+C while installing
# epel-release and the yum fallback succeeds; the second run then fails for
# real (mirror outage): failed, not cancelled.
new_child int_step_rerun_fails '
report_init
report_stage_begin packages
rpm() { return 1; }
dnf() { return 1; }
yum() { return 0; }
report_step_start prerequisite_packages
install_packages epel-release dnf-plugins-core
_report_on_int 1
report_step_start prerequisite_packages
yum() { return 1; }
install_packages restic rclone
echo NOT-REACHED'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed in the first run of a step, its second run fails: failed with the step's reason" "failed - prerequisite_packages package_install_failed 1 1" "$(field "$fin" .result) -$(field "$fin" .signal) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code) $CHILD_RC"
new_child int_step_rerun_sete '
report_init
report_stage_begin packages
report_step_start prerequisite_packages
_report_on_int 1
report_step_start prerequisite_packages
false'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed in the first run of a step, its second run stops the script (set -e): failed" "failed - prerequisite_packages package_install_failed 1" "$(field "$fin" .result) -$(field "$fin" .signal) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code)"
new_child int_required_then_other '
report_init
report_stage_begin configuration
report_step_start mariadb
_report_on_int 1
report_step_result mariadb failed
report_step_start postfix
report_step_result postfix failed
exit 1'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed by a required step, another fails later: the later step is the reason" "failed postfix required_step_failed mariadb,postfix" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .failed_required_steps)"
new_child int_claimed_then_optional '
report_init
report_stage_begin configuration
report_step_start mariadb
_report_on_int 1
report_step_result mariadb failed
report_step_start greeting
report_step_result greeting failed
exit 1'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed by a required step, an optional one fails later: still cancelled" "cancelled INT mariadb 1" "$(field "$fin" .result) $(field "$fin" .signal) $(field "$fin" .failed_step) $(field "$fin" .exit_code)"
new_child int_then_optional_sete '
report_init
report_stage_begin configuration
report_step_start mariadb
_report_on_int 1
report_step_result mariadb failed
report_step_start greeting
false'
run_child
fin=$(event install_finished)
eq "Ctrl+C absorbed, script then stops in an optional step (set -e): still cancelled" "cancelled INT mariadb 1" "$(field "$fin" .result) $(field "$fin" .signal) $(field "$fin" .failed_step) $(field "$fin" .exit_code)"
# The same with a real Ctrl+C: an optional step absorbs it, the bolt-panel
# scriptlet then fails and the script ends with 1.
int_child int_optional_then_fail report "$handles1" 'run_or_warn "$BASH step.sh" "Step" greeting
report_stage_begin packages
report_fail panel_scriptlet panel_scriptlet_failed
exit 1'
fin=$(event install_finished)
eq "real Ctrl+C absorbed by an optional step, scriptlet fails later: failed panel_scriptlet_failed, exit 1" "failed panel_scriptlet_failed - 1 1" "$(field "$fin" .result) $(field "$fin" .reason) -$(field "$fin" .signal) $(field "$fin" .exit_code) $CHILD_RC"
set +m

# ---------------------------------------------------------------------------
echo "# old resend run against a new install"
# ---------------------------------------------------------------------------
new_child race_old '
report_init
exit 1'
echo 503 >"$CHILD_DIR/fake/http_code"
run_child
echo 202 >"$CHILD_DIR/fake/http_code"
echo 1 >"$CHILD_DIR/fake/curl_delay"
SENDER="$CHILD_DIR/libexec/adminbolt/install-report-send"
(cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$SENDER") &
sender_pid=$!
sleep 0.5
# A new install starts while the old run is still sending, and is still going when it ends.
sed 's/^report_init$/report_init; sleep 5; exit 0/' "$CHILD_DIR/child.sh" >"$CHILD_DIR/child2.sh"
(cd "$CHILD_DIR" && rm -f fake/curl_delay.new; FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child2.sh >"$CHILD_DIR/out2" 2>&1) &
new_pid=$!
wait "$sender_pid"
check "new install running: old resend run keeps the sender" test -x "$SENDER"
check "new install running: old resend run keeps the timer" test -e "$CHILD_DIR/units/adminbolt-install-report.timer"
wait "$new_pid"
eq "two installs in the spool" 2 "$(ls -d "$CHILD_DIR"/spool/adminbolt-install-report/*/ | wc -l | tr -d ' ')"
if command -v flock >/dev/null 2>&1; then
    check "sender takes the lock file" test -e "$CHILD_DIR/spool/adminbolt-install-report/.lock"
    # A resend run in the middle of removing the timer (holding the lock) while
    # a new install starts: the install puts its timer back only afterwards.
    child lockrace '
report_init
exit 0'
    (
        flock 9
        touch "$CHILD_DIR/fake/locked"
        sleep 1.5
        rm -f "$CHILD_DIR/units/adminbolt-install-report.timer" "$CHILD_DIR/units/adminbolt-install-report.service" "$CHILD_DIR/libexec/adminbolt/install-report-send"
    ) 9>>"$CHILD_DIR/spool/adminbolt-install-report/.lock" &
    holder=$!
    for _ in $(seq 1 30); do [[ -e "$CHILD_DIR/fake/locked" ]] && break; sleep 0.1; done
    run_child
    wait "$holder"
    check "timer removal under the lock does not take the new install's timer" test -e "$CHILD_DIR/units/adminbolt-install-report.timer"
    check "nor its sender" test -x "$CHILD_DIR/libexec/adminbolt/install-report-send"
else
    echo "# skipped: flock not available (lock tests)"
fi

# ---------------------------------------------------------------------------
echo "# slow rpm and systemd"
# ---------------------------------------------------------------------------
new_child slow "$flow"
touch "$CHILD_DIR/fake/slow"
echo 30 >"$CHILD_DIR/fake/curl_sleep"
start=$(date +%s.%N)
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" timeout 60 "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
CHILD_RC=$?
ELAPSED=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
check "rpm, systemctl and receiver all hang: report adds under 10 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'
eq "rpm, systemctl and receiver all hang: exit code unchanged" 1 "$CHILD_RC"
new_child slow_ready '
report_init
report_stage_begin configuration; report_stage_end
report_readiness_check
exit 0'
touch "$CHILD_DIR/fake/slow"
echo 30 >"$CHILD_DIR/fake/curl_sleep"
start=$(date +%s.%N)
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" timeout 90 "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
ELAPSED=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
check "same with the readiness check: under 10 s (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'

# ---------------------------------------------------------------------------
echo "# bolt-panel wrapper: a tee that stops at once, reading nothing"
# ---------------------------------------------------------------------------
# The package step writes only after tee is gone, so nothing sits in the pipe buffer.
child tee_gone '
report_init
report_stage_begin packages
install_packages() { sleep 0.5; echo "first package line"; echo "last package line"; }
tee() { return 1; }
install_bolt_panel_and_check_post bolt-panel
echo CONTINUED'
eq "tee gone at once: install goes on with exit code 0" "0 continued" "$CHILD_RC $(grep -q CONTINUED "$CHILD_DIR/out" && echo continued || echo stopped)"
check "tee gone at once: package output still shown" grep -q 'last package line' "$CHILD_DIR/out"
child tee_gone_dnf '
report_init
report_stage_begin packages
install_packages() { sleep 0.5; echo "Error: transaction failed"; exit 5; }
tee() { return 127; }
install_bolt_panel_and_check_post bolt-panel
echo NOT-REACHED'
eq "tee gone at once and dnf fails: stops with dnf's own code" "5 package_install_failed" "$CHILD_RC $(field "$(event install_finished)" .reason)"

# ---------------------------------------------------------------------------
echo "# no timeout(1) on the machine, rpm and systemctl hang"
# ---------------------------------------------------------------------------
mkdir -p "$T/notimeout"
ln -sf "$BASH" "$T/notimeout/bash"
GUARD_TIMEOUT=$(command -v timeout)
for c in env cat date stat mkdir mv chmod chown chgrp rm rmdir touch sleep od tr cut sha256sum grep sed awk id \
    dirname basename uname mktemp ls head tail wc sort seq flock; do
    p=$(command -v "$c" 2>/dev/null) && [[ "$p" == /* ]] && ln -sf "$p" "$T/notimeout/$c"
done
NOTIMEOUT_PATH="$T/bin:$T/notimeout"
check "test PATH really has no timeout" bash -c '! PATH="$1" command -v timeout' _ "$NOTIMEOUT_PATH"
new_child notimeout '
report_init
report_step_start parse_arguments
report_fail parse_arguments invalid_argument
exit 1'
echo 30 >"$CHILD_DIR/fake/slow"
start=$(date +%s.%N)
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$NOTIMEOUT_PATH" "$GUARD_TIMEOUT" 60 "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
CHILD_RC=$?
ELAPSED=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
check "no timeout(1), rpm hangs: exit within the budget (took ${ELAPSED}s)" awk -v e="$ELAPSED" 'BEGIN { exit !(e < 10) }'
eq "no timeout(1), rpm hangs: exit code unchanged" 1 "$CHILD_RC"
eq "no timeout(1), rpm hangs: versions left empty" "invalid_argument  " "$(field "$(event install_finished)" .reason) $(field "$(event install_finished)" .panel_version) $(field "$(event install_finished)" .agent_version)"
# The timer is put in place in the background and may still be inside its own bounded call.
sleep 3.5
alive=0
while read -r pid; do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done <"$CHILD_DIR/fake/pids"
eq "no timeout(1): every hanging rpm/systemctl was stopped" 0 "$alive"
new_child notimeout_fast '
report_init
REPORT_PANEL_VERSION=""
_report_pkg_versions
echo "versions=$REPORT_PANEL_VERSION/$REPORT_AGENT_VERSION"
exit 0'
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$NOTIMEOUT_PATH" "$GUARD_TIMEOUT" 60 "$BASH" child.sh >"$CHILD_DIR/out" 2>&1)
check "no timeout(1), rpm answers: versions still read" grep -qx 'versions=1.9.3-1.el9/2.4.0-1.el9' "$CHILD_DIR/out"

# ---------------------------------------------------------------------------
echo "# each install keeps its own receiver"
# ---------------------------------------------------------------------------
new_child two_receivers 'ADMINBOLT_INSTALL_REPORT_URL=http://one.test/install-events
report_init
report_step_start repo_setup
report_fail repo_setup repo_download_failed
exit 1'
echo 503 >"$CHILD_DIR/fake/http_code"
run_child
ida=$(basename "$(echo "$CHILD_DIR"/spool/adminbolt-install-report/*/)")
sed 's#one\.test#two.test#' "$CHILD_DIR/child.sh" >"$CHILD_DIR/child2.sh"
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child2.sh >"$CHILD_DIR/out2" 2>&1)
idb=""
for d in "$CHILD_DIR"/spool/adminbolt-install-report/*/; do
    d=$(basename "$d")
    [[ "$d" == "$ida" ]] || idb=$d
done
check "two installs queued" test -n "$ida" -a -n "$idb" -a "$ida" != "$idb"
rm -f "$CHILD_DIR/fake/urls"
echo 202 >"$CHILD_DIR/fake/http_code"
(cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$CHILD_DIR/libexec/adminbolt/install-report-send")
eq "resend: first install's events go to its own receiver" "http://one.test/install-events" "$(awk -v i="$ida" '$1 == i { print $2 }' "$CHILD_DIR/fake/urls" | sort -u | tr '\n' ' ' | sed 's/ $//')"
eq "resend: second install's events go to its receiver" "http://two.test/install-events" "$(awk -v i="$idb" '$1 == i { print $2 }' "$CHILD_DIR/fake/urls" | sort -u | tr '\n' ' ' | sed 's/ $//')"
eq "resend: every queued event of both was sent" 6 "$(wc -l <"$CHILD_DIR/fake/urls" | tr -d ' ')"
rm -f "$CHILD_DIR"/spool/adminbolt-install-report/*/sent/* "$CHILD_DIR/fake/urls"
printf 'not a url; rm -rf /\n' >"$CHILD_DIR/spool/adminbolt-install-report/$ida/url"
echo 503 >"$CHILD_DIR/fake/http_code"
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child2.sh >"$CHILD_DIR/out3" 2>&1)
rm -f "$CHILD_DIR/fake/urls"
echo 202 >"$CHILD_DIR/fake/http_code"
(cd / && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$CHILD_DIR/libexec/adminbolt/install-report-send")
eq "resend: an unusable stored address falls back to the built-in receiver, not the latest install's" https://ai-hub.adminbolt.com/install-events "$(awk -v i="$ida" '$1 == i { print $2 }' "$CHILD_DIR/fake/urls" | sort -u)"

# ---------------------------------------------------------------------------
echo "# --email is a plain address, never shell code"
# ---------------------------------------------------------------------------
# --source=nope stops main right after the e-mail check either way.
for bad in 'a@b.com;touch${IFS}pwned' '$(touch${IFS}pwned)@example.com' 'a@b.com`id`' 'a@b.com|id' 'a b@example.com' 'a@b@example.com'; do
    child email_bad "main '--email=$bad' --source=nope"
    eq "--email=$bad refused as invalid" "1 yes" "$CHILD_RC $(grep -q 'Invalid --email' "$CHILD_DIR/out" && echo yes || echo no)"
    check "--email=$bad: nothing executed" test ! -e "$CHILD_DIR/pwned"
done
for good in 'first.last+tag@mail-1.example.co.uk' "o'brien@example.ie" 'jan&co@example.com' 'a!#$%*/=?^_`{|}~-z@example.com'; do
    printf '%s\n' "$good" >"$T/email.arg"
    child email_ok 'main "--email=$(cat "'"$T"'/email.arg")" --source=nope'
    eq "valid --email=$good passes the check (stops later, at --source)" "1 no" "$CHILD_RC $(grep -q 'Invalid --email' "$CHILD_DIR/out" && echo yes || echo no)"
done
# The trial licence request gets the address as one argument, whatever it holds.
for addr in "o'brien@example.ie" 'jan&co@example.com' 'a`touch${IFS}pwned`b@example.com' 'a$(touch${IFS}pwned)b@example.com' 'a|touch${IFS}pwned@example.com' "x'\$(touch\${IFS}pwned)'@example.com"; do
    printf '%s\n' "$addr" >"$T/email.arg"
    new_child trial_quoted '
bolt-cli() { printf "%s\n" "$@" >"$FAKE_DIR/trial.args"; }
ADMIN_EMAIL=$(cat "'"$T"'/email.arg")
TRIAL_LICENCE_OK=0
request_trial_licence
echo "ok=$TRIAL_LICENCE_OK"
exit 0'
    run_child
    eq "trial request, $addr: one argument, the address as given" "request-trial-license|--email=$addr|ok=1" "$(paste -sd'|' "$CHILD_DIR/fake/trial.args")|$(grep -o 'ok=[01]' "$CHILD_DIR/out")"
    check "trial request, $addr: nothing executed" test ! -e "$CHILD_DIR/pwned"
done

# ---------------------------------------------------------------------------
echo "# error excerpts of failed steps (AB-2233)"
# ---------------------------------------------------------------------------
child excerpts '
ADMIN_EMAIL=owner@customer-mail.org
report_init
report_stage_begin configuration
run_or_warn true "Nftable" nftables
run_or_warn "printf \"Installing MariaDB 11.4 on %s\\n\" \"$(uname -n)\"; echo \"connect to 203.0.113.9 as owner@customer-mail.org\" >&2; echo \"ERROR 2002 (HY000): Cant connect to server\"; (exit 3)" "MariaDB" mariadb
run_or_warn "echo postfix profile failed; (exit 1)" "Postfix profiles" postfix_profiles
run_or_warn "printf \"\\033[0;31mdovecot\\033[0m profile failed\\r\\n\"; (exit 2)" "Dovecot profiles" dovecot_profiles
echo "Admin Panel: https://203.0.113.9:8443/sso/abcdef0123456789abcdef0123456789"
report_stage_end
exit 0'
fin=$(event install_finished)
eq "excerpts: one entry per failed step, the decisive one first" "mariadb postfix_profiles dovecot_profiles" "$(jq -r '[.errors[].step] | join(" ")' <<<"$fin")"
eq "excerpts: exit code of each step's command" "3 1 2" "$(jq -r '[.errors[].exit_code] | map(tostring) | join(" ")' <<<"$fin")"
eq "excerpts: result and reason unchanged" "failed mariadb required_step_failed 0" "$(field "$fin" .result) $(field "$fin" .failed_step) $(field "$fin" .reason) $(field "$fin" .exit_code)"
m_out=$(jq -r '.errors[0].output' <<<"$fin")
check "excerpt: the final error line is there" grep -q 'ERROR 2002 (HY000): Cant connect to server$' <<<"$(jq -r '.errors[0].output' <<<"$fin" | sed -n '$p')"
check "excerpt: stderr of the step is in it" grep -q 'connect to <ip> as <email>' <<<"$m_out"
check "excerpt: ends with the command's error, not the runner's warning" bash -c '! grep -q "MariaDB failed (continuing)" <<<"$1"' _ "$m_out"
check "excerpt: this host's name replaced" grep -q 'Installing MariaDB 11.4 on <host>' <<<"$m_out"
check "excerpt: no host name, IP or e-mail left" bash -c '! grep -qiF -- "$(uname -n)" <<<"$1" && ! grep -q "203.0.113.9\|customer-mail" <<<"$1"' _ "$fin"
eq "excerpt: colour codes and the carriage return removed" "dovecot profile failed" "$(jq -r '.errors[2].output' <<<"$fin" | head -n 1)"
check "excerpt: output after the last step (the sign-in link) never sent" bash -c '! grep -q "sso" <<<"$1"' _ "$fin"
check "excerpt: output of a step that worked never sent" bash -c '! grep -q "Nftable" <<<"$1"' _ "$(jq -r '[.errors[].output] | join("\n")' <<<"$fin")"
check "terminal: the step output is printed as before" grep -q 'ERROR 2002 (HY000): Cant connect to server' "$CHILD_DIR/out"
check "terminal: colours still reach it" grep -q $'\033\\[0;31mdovecot' "$CHILD_DIR/out"
check "the step copies are removed at exit" bash -c '! ls -d "${TMPDIR:-/tmp}"/adminbolt-install-steps.* 2>/dev/null | grep -q .'

child excerpt_fail '
report_init
report_stage_begin configuration
run_or_fail "echo agent: connection refused; (exit 7)" "Connect bolt-agent to panel" agent_panel_connect'
fin=$(event install_finished)
eq "run_or_fail: the step that stopped the install, with its own exit code" "agent_panel_connect 7 1" "$(jq -r '"\(.errors[0].step) \(.errors[0].exit_code) \(.exit_code)"' <<<"$fin")"
eq "run_or_fail: the command's output, without the runner's message" 'agent: connection refused' "$(jq -r '.errors[0].output' <<<"$fin")"

child excerpt_sete '
report_init
report_stage_begin packages
report_step_start web_services_enable
echo "Failed to enable unit: Unit file bolt-nginx.service does not exist."
false'
fin=$(event install_finished)
eq "stopped by set -e: the running step, the script's exit code" "web_services_enable 1" "$(jq -r '"\(.errors[0].step) \(.errors[0].exit_code)"' <<<"$fin")"
check "stopped by set -e: its output" grep -q 'bolt-nginx.service does not exist' <<<"$(jq -r '.errors[0].output' <<<"$fin")"

child excerpt_limits '
report_init
report_stage_begin configuration
big() { for n in $(seq 1 100); do printf "line %03d %s\n" "$n" "$(printf "$1%.0s" $(seq 1 90))"; done; echo "final error $2"; return 1; }
run_or_warn "big y mariadb" "MariaDB" mariadb
run_or_warn "big z redis" "Redis" redis
run_or_warn "big x greeting" "Greeting" greeting
for s in rspamd mlmmj vsftpd disk_quota fail2ban ssh_profiles postfix_profiles dovecot_profiles redis_profiles rspamd_profiles \
    system_email dns_template vsftpd_profile fail2ban_profile cron_jobs hidepid rspamd_restart app_git app_metrics app_adminer app_roundcube; do
    run_or_warn "echo $s failed; false" "$s" "$s"
done
report_stage_end
exit 0'
fin=$(event install_finished)
eq "limits: required steps first" "mariadb redis" "$(jq -r '[.errors[0,1].step] | join(" ")' <<<"$fin")"
check "limits: 2 KB per step" jq -e 'all(.errors[]; (.output | length) <= 2048)' <<<"$fin"
check "limits: 6 KB in all" jq -e '([.errors[].output | length] | add) <= 6144' <<<"$fin"
eq "limits: at most 20 entries (24 steps failed)" 20 "$(jq '.errors | length' <<<"$fin")"
check "limits: at most 40 lines" jq -e 'all(.errors[]; (.output | split("\n") | length) <= 40)' <<<"$fin"
eq "limits: the oldest lines go, the final error stays" "final error mariadb" "$(jq -r '.errors[0].output' <<<"$fin" | tail -n 1)"
check "limits: whole lines kept" bash -c '[[ "$(jq -r ".errors[0].output" <<<"$1" | head -n 1)" =~ ^line\ [0-9]{3}\ y+$ ]]' _ "$fin"
check "limits: a step past the 6 KB budget is listed without output" jq -e '.errors[-1].output == "" and (.errors[-1].exit_code == 1)' <<<"$fin"
check "limits: no cut-off line from the budget" jq -e 'all(.errors[]; .output == "" or (.output | test("^(line|final|[a-z_0-9]+ failed)")))' <<<"$fin"
check "limits: event body fits the receiver's 16 KB" test "$(jq -c . <<<"$fin" | wc -c)" -le 16384

child excerpt_stderr_apart '
report_init
report_stage_begin configuration
run_or_warn "echo out-line; echo err-line >&2; (exit 1)" "Postfix" postfix
report_stage_end
exit 0'
# Run again with stderr to its own file: both still captured, each stays on its stream.
(cd "$CHILD_DIR" && FAKE_DIR="$CHILD_DIR/fake" PATH="$FAKEPATH" "$BASH" child.sh >"$CHILD_DIR/out1" 2>"$CHILD_DIR/err1")
fin=$(spool_events | jq -c 'select(.type == "install_finished")' | tail -n 1)
check "stdout and stderr apart: both in the excerpt" bash -c 'o=$(jq -r ".errors[0].output" <<<"$1"); grep -q out-line <<<"$o" && grep -q err-line <<<"$o"' _ "$fin"
check "stdout and stderr apart: stderr still on stderr" bash -c 'grep -q err-line "$1/err1" && ! grep -q err-line "$1/out1"' _ "$CHILD_DIR"

child excerpt_no_gawk '
_report_redact() { return 1; }
report_init
report_stage_begin configuration
run_or_warn "echo secret stuff; (exit 1)" "Postfix" postfix
report_stage_end
exit 0'
eq "redaction unavailable: the step is listed without output" "postfix||1" "$(jq -r '.errors[0] | "\(.step)|\(.output)|\(.exit_code)"' <<<"$(event install_finished)")"

child excerpt_off '
REPORT_NO_TELEMETRY=1
report_init
run_or_warn "echo boom; (exit 1)" "Postfix" postfix
exit 0'
eq "--no-telemetry: nothing sent" 0 "$(ls "$CHILD_DIR/fake/req" 2>/dev/null | wc -l | tr -d " ")"
check "--no-telemetry: the step output still on the terminal" grep -q boom "$CHILD_DIR/out"

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
    ((keys - ["errors"]) | sort) == (["schema","install_id","event_id","type","sent_at","result","failed_step","reason","exit_code","signal","failed_optional_steps","failed_required_steps","panel_version","agent_version","trial_licence","duration_s"] | sort)
    and ((has("errors") | not) or (.errors | type == "array" and length >= 1 and length <= 20
      and all(.[]; type == "object" and ((keys - ["step","exit_code","output"]) == []) and (.step | re("^[a-z0-9_-]{1,48}$"))
        and ((has("exit_code") | not) or (.exit_code | int(0; 255))) and (.output | type == "string" and (utf8bytelength <= 2048) and test("^[\t\n -~]*$")))
      and (map(.output | utf8bytelength) | add) <= 6144))
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
big=$(printf '%s\n' "$all_files" | while read -r f; do [[ $(wc -c <"$f") -le 16384 ]] || echo "$f"; done)
eq "every event under 16 KB" "" "$big"

echo
echo "# passed: $PASS, failed: $FAIL"
((FAIL == 0))
