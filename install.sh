#!/bin/bash
#
# AdminBolt Install Script (AlmaLinux 9, Rocky Linux 9)
#
# Reorganizes the installation into three stages:
#   Stage 1: Check that everything is in place and ready for installation
#   Stage 2: (2.1) Prepare settings → (2.2) Install prerequisite packages → (2.3) Install all Bolt packages
#   Stage 3: Execute bolt-cli / post-install actions (database, agent, services, profiles, etc.)
#
# Supported: AlmaLinux 9, Rocky Linux 9. Panel is installed from RPM; %pre/%post skipped.
# Usage:
#   sudo ./install.sh                          # install latest bolt-panel from repo
#   sudo ./install.sh --version=1.0.0.beta3-v46.el9 # install specific bolt-panel version from repo
#   sudo ./install.sh --source=staging         # use staging pulp repos (stable|staging|testing); default unchanged
#   sudo ./install.sh --email=user@example.com # activate a 24h trial license for this e-mail (confirmation link extends it to 30 days)
#
set -e

# ---------------------------------------------------------------------------
# bolt-panel install: from repo (latest by default; --version= selects a specific version)
# ---------------------------------------------------------------------------
PANEL_VERSION=""
# Empty = current behavior (bolt-repo RPM from adminbolt). stable|staging|testing = pulp content path segment.
BOLT_SOURCE=""
# E-mail for the trial license; empty = skip the trial request (activate manually on the License page).
ADMIN_EMAIL=""
MARIADB_SERIES=""
readonly WEB_INSTALL_ROOT="/usr/local/bolt/web"
readonly POST_INSTALL_DB_PATH="/var/lib/adminbolt/db.sqlite3"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REPO_BASE_URL="https://mirror.adminbolt.com/pulp/content/adminbolt"
REPO_PACKAGE="bolt-repo-1.0.7-1"

print_error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
print_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
print_info() { echo -e "${YELLOW}INFO:${NC} $1"; }
print_progress() { echo -e "${CYAN}PROGRESS:${NC} $1"; }

time_section_end() {
    local label="$1"
    echo -e "${CYAN}[TIMING]${NC} ${label}: $(($(date +%s) - SECTION_START))s"
}
time_total_end() {
    echo -e "\n${BOLD}${CYAN}[TIMING] Total install: $(($(date +%s) - TOTAL_START))s${NC}\n"
}

# ---------------------------------------------------------------------------
# Install report (AB-2067)
#
# Every run gets a random install ID and reports, to the AdminBolt install
# receiver, that it started (channel, platform, OS, requested version, package
# source, installer revision), how long each stage took, and how it ended
# (result, failed step, reason code, exit code, versions installed). Nothing
# else: no hostnames, e-mail addresses, passwords, licence keys or command
# output. Every value sent is checked against a fixed list or pattern first.
#
# Reporting never changes the install: every report_* call ignores its own
# errors, intermediate events go out in the background, and only the final
# event waits, at most REPORT_FINAL_WAIT seconds. As root, events are also
# kept in a root-only spool, and a systemd timer resends whatever did not get
# through, every 15 minutes for 24 hours, then removes itself (the spool stays).
# Not root: no spool and no timer; the start and the result are sent once, at
# exit. --no-telemetry or ADMINBOLT_NO_TELEMETRY=1: nothing is sent or kept,
# no timer, and BOLT_INSTALL_TELEMETRY=0 goes to bolt-config.ini for the panel.
#
# Every step has an id and is required or optional (report_step_class); a
# failed step's reason code comes from the step (report_reason_for_step),
# never from the message printed for it.
# ---------------------------------------------------------------------------
REPORT_URL="https://ai-hub.adminbolt.com/install-events"
REPORT_DIR="/var/lib/adminbolt/install-report"
REPORT_SENDER="/usr/local/libexec/adminbolt/install-report-send"
REPORT_UNIT_DIR="/etc/systemd/system"
REPORT_UNIT_NAME="adminbolt-install-report"
REPORT_BOLT_CONFIG="/etc/bolt/bolt-config.ini"
REPORT_DMI_DIR="/sys/class/dmi/id"
REPORT_OS_RELEASE="/etc/os-release"
REPORT_UUID_FILE="/proc/sys/kernel/random/uuid"
REPORT_PANEL_URL="https://127.0.0.1:8443/"
REPORT_MARKER="/var/lib/adminbolt/install-in-progress"
REPORT_FINAL_WAIT=5
# Event ids 49 and 50 belong to the panel and the hub.
REPORT_MAX_EVENT_ID=48
REPORT_EUID=$EUID
REPORT_OWNER_UID=0
REPORT_CHANNEL="direct"
REPORT_CHANNEL_ARG=""
REPORT_NO_TELEMETRY=0
# off | spool (root) | memory (root, spool unusable) | deferred (not root)
REPORT_MODE="off"
INSTALL_ID=""
REPORT_REV=""
REPORT_START=0
REPORT_EVENT_SEQ=0
REPORT_EVENTS=()
REPORT_LAUNCHED=()
REPORT_PIDS=""
REPORT_STAGE=""
REPORT_STAGE_START=0
REPORT_STAGE_RESULT="ok"
REPORT_STEP=""
REPORT_FAILED_STEP=""
REPORT_REASON=""
REPORT_FAILED_REQUIRED=""
REPORT_FAILED_OPTIONAL=""
REPORT_SIGNAL=""
REPORT_SUPPRESS=0
REPORT_TRIAL=""
REPORT_READINESS=""
INSTALL_MARKER_CREATED=0

REPORT_CHANNELS="direct get-script web-installer vultr akamai node image-build test hostinger digitalocean aws azure"
REPORT_REASONS="not_root unsupported_os invalid_argument missing_command port_in_use repo_download_failed package_install_failed agent_install_failed panel_scriptlet_failed agent_panel_connect_failed required_step_failed readiness_check_failed interrupted unclassified"

# required | optional | unknown
report_step_class() {
    case "$1" in
        check_root|check_os|check_commands|check_port_8443|parse_arguments) echo required ;;
        repo_setup|prerequisite_packages|agent_install|agent_scriptlet|panel_install|panel_scriptlet|web_services_enable) echo required ;;
        agent_panel_connect|nftables|ssh_server|powerdns|mariadb|postfix|dovecot|redis|php84|myapache) echo required ;;
        firewall_setup|mariadb_profile|myapache_profile|php84_profile|postinstall_queue|readiness) echo required ;;
        selinux_enforce|selinux_config|crb_repo|chronyd|acme_sh) echo optional ;;
        greeting|rspamd|mlmmj|vsftpd|disk_quota|fail2ban|ssh_profiles|postfix_profiles|dovecot_profiles) echo optional ;;
        redis_profiles|rspamd_profiles|system_email|dns_template|vsftpd_profile|fail2ban_profile) echo optional ;;
        cron_jobs|hidepid|rspamd_restart) echo optional ;;
        app_local-api|app_filemanager|app_phpmyadmin|app_roundcube|app_git|app_metrics|app_adminer) echo optional ;;
        *) echo unknown ;;
    esac
}

report_reason_for_step() {
    case "$1" in
        check_root) echo not_root ;;
        check_os) echo unsupported_os ;;
        check_commands) echo missing_command ;;
        check_port_8443) echo port_in_use ;;
        parse_arguments) echo invalid_argument ;;
        repo_setup) echo repo_download_failed ;;
        prerequisite_packages|panel_install) echo package_install_failed ;;
        agent_install|agent_scriptlet) echo agent_install_failed ;;
        panel_scriptlet) echo panel_scriptlet_failed ;;
        agent_panel_connect) echo agent_panel_connect_failed ;;
        readiness) echo readiness_check_failed ;;
        *)
            if [[ "$(report_step_class "$1")" == required ]]; then echo required_step_failed; else echo unclassified; fi
            ;;
    esac
}

_report_in_list() { [[ " $2 " == *" $1 "* ]]; }
_report_valid_uuid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; }
# Value if it matches the pattern, otherwise the fallback.
_report_clean() { if [[ "$1" =~ $2 ]]; then printf '%s' "$1"; else printf '%s' "${3:-}"; fi; }

# JSON string literal. Values are pattern-checked before they get here; this
# still escapes everything JSON requires, so a value can never break out.
_report_json_str() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            '"') out+='\"' ;;
            "\\") out+="\\\\" ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            [[:cntrl:]]) out+=$(printf '\\u%04x' "'$c") ;;
            *) out+="$c" ;;
        esac
    done
    printf '"%s"' "$out"
}

# JSON array of step ids (at most 40).
_report_json_steps() {
    local out="" step n=0
    for step in $1; do
        [[ "$(report_step_class "$step")" != unknown ]] || continue
        ((n < 40)) || break
        out+="${out:+,}$(_report_json_str "$step")"
        n=$((n + 1))
    done
    printf '[%s]' "$out"
}

_report_new_uuid() {
    local u="" h v
    [[ -r "$REPORT_UUID_FILE" ]] && u=$(tr 'A-F' 'a-f' <"$REPORT_UUID_FILE" 2>/dev/null)
    if ! _report_valid_uuid "$u"; then
        h=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        [[ "$h" =~ ^[0-9a-f]{32}$ ]] || return 1
        v=$(printf '%02x' $(((0x${h:16:2} & 0x3f) | 0x80)))
        u="${h:0:8}-${h:8:4}-4${h:13:3}-${v}${h:18:2}-${h:20:12}"
    fi
    _report_valid_uuid "$u" || return 1
    printf '%s' "$u"
}

# sha256 of the running install.sh. Unknown (64 zeros) when the script is
# read from a pipe (curl ... | bash): bash then holds no copy of it to hash.
# Under a pipe BASH_SOURCE names the bash binary, hence the header check.
_report_installer_rev() {
    local src="${BASH_SOURCE[0]:-}" sum=""
    if [[ -n "$src" && -f "$src" && -r "$src" ]] && grep -q '^# AdminBolt Install Script' "$src" 2>/dev/null; then
        sum=$(sha256sum <"$src" 2>/dev/null | cut -c1-64)
    fi
    _report_clean "$sum" '^[0-9a-f]{64}$' "0000000000000000000000000000000000000000000000000000000000000000"
}

# Cloud or hypervisor from DMI, mapped to a fixed list; the raw strings are never sent.
_report_platform() {
    local f all="" v
    for f in sys_vendor product_name product_version bios_vendor bios_version board_vendor chassis_asset_tag; do
        if [[ -r "$REPORT_DMI_DIR/$f" ]]; then
            v=$(tr -d '\0' <"$REPORT_DMI_DIR/$f" 2>/dev/null)
            all+=" ${v}|"
        fi
    done
    if [[ -z "${all//[ |]/}" ]]; then echo unknown; return 0; fi
    all="${all,,}"
    case "$all" in
        *hetzner*) echo hetzner ;;
        *vultr*) echo vultr ;;
        *linode*|*akamai*) echo akamai ;;
        *digitalocean*) echo digitalocean ;;
        *amazon*) echo aws ;;
        *7783-7084-3265-9085-8269-3286-77*) echo azure ;;
        *google*) echo gcp ;;
        *ovh*) echo ovh ;;
        *contabo*) echo contabo ;;
        *vmware*) echo vmware ;;
        *kvm*|*qemu*|*"red hat"*|*openstack*) echo kvm ;;
        *) echo other ;;
    esac
}

_report_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        *) echo other ;;
    esac
}

_report_os_field() {
    # $1 = ID | VERSION_ID; read in a subshell so nothing leaks into this shell
    [[ -r "$REPORT_OS_RELEASE" ]] || return 0
    (
        # shellcheck disable=SC1090
        . "$REPORT_OS_RELEASE" >/dev/null 2>&1
        if [[ "$1" == ID ]]; then printf '%s' "${ID:-}"; else printf '%s' "${VERSION_ID:-}"; fi
    )
}

_report_pkg_version() {
    command -v rpm >/dev/null 2>&1 || return 0
    _report_clean "$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null </dev/null)" '^[0-9A-Za-z.+~_-]{1,40}$' ""
}

# Subshell helper: cd into this install's spool directory and make sure it,
# and the spool root, are this user's and private. /var/lib/adminbolt is
# handed to the panel's web user once bolt-panel is installed, so the path
# alone is not trusted: the checks run on the directory actually entered.
_report_dir_private() { [[ "$(stat -c '%u %a' "$1" 2>/dev/null)" == "$REPORT_OWNER_UID 700" ]]; }
_report_cd_install_dir() {
    cd -P "$REPORT_DIR" 2>/dev/null && _report_dir_private . \
        && cd -P "./$INSTALL_ID" 2>/dev/null && _report_dir_private .
}

_report_spool_init() {
    local parent
    parent=$(dirname "$REPORT_DIR")
    mkdir -p "$parent" 2>/dev/null || return 1
    if [[ ! -e "$REPORT_DIR" && ! -L "$REPORT_DIR" ]]; then
        mkdir -m 0700 "$REPORT_DIR" 2>/dev/null || return 1
    fi
    (
        umask 077
        cd -P "$REPORT_DIR" 2>/dev/null && _report_dir_private . || exit 1
        mkdir -m 0700 "./$INSTALL_ID" && cd -P "./$INSTALL_ID" || exit 1
        mkdir -m 0700 events sent && printf '%s\n' "$REPORT_START" >started
    ) </dev/null >/dev/null 2>&1
}

_report_spool_write() {
    (
        umask 077
        _report_cd_install_dir || exit 1
        printf '%s\n' "$2" >"events/.$1.tmp" && mv -f "events/.$1.tmp" "events/$1.json"
    ) </dev/null >/dev/null 2>&1
}

_report_spool_mark_finished() {
    [[ "$REPORT_MODE" == spool ]] || return 0
    ( umask 077; _report_cd_install_dir && : >finished ) </dev/null >/dev/null 2>&1
}

# HTTP status of one POST ("000" when nothing came back). $1 = curl data argument.
_report_post() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
        -H 'Content-Type: application/json' --data-binary "$1" "$REPORT_URL" 2>/dev/null) || true
    printf '%s' "${code:-000}"
}
# Delivered: 2xx (stored or duplicate) and 400/409/413 (refused, and would be
# refused again). 429, 507, 5xx and no answer are retried by the timer.
_report_delivered() { [[ "$1" =~ ^(2[0-9][0-9]|400|409|413)$ ]]; }

_report_send_bg() {
    local id="$1" json="${REPORT_EVENTS[$1]}"
    REPORT_LAUNCHED[id]=1
    if [[ "$REPORT_MODE" == spool ]]; then
        (
            set +e
            _report_cd_install_dir || exit 0
            [[ -e "sent/$id" ]] && exit 0
            code=$(_report_post "@events/$id.json")
            _report_delivered "$code" && : >"sent/$id"
        ) </dev/null >/dev/null 2>&1 &
    else
        (
            set +e
            printf '%s' "$json" | _report_post @- >/dev/null
        ) </dev/null >/dev/null 2>&1 &
    fi
    REPORT_PIDS+=" $!"
}

# $1 = type, $2 = type-specific JSON members, $3 = "final" to store without
# sending (the exit handler sends it). The last two ids are kept for the
# exit handler's own two events, so install_finished always gets one.
_report_emit() {
    [[ "$REPORT_MODE" != off ]] || return 0
    local limit=$REPORT_MAX_EVENT_ID
    [[ "${3:-}" == final ]] || limit=$((REPORT_MAX_EVENT_ID - 2))
    ((REPORT_EVENT_SEQ < limit)) || return 0
    REPORT_EVENT_SEQ=$((REPORT_EVENT_SEQ + 1))
    local id=$REPORT_EVENT_SEQ json
    json="{\"schema\":1,\"install_id\":$(_report_json_str "$INSTALL_ID"),\"event_id\":${id},\"type\":$(_report_json_str "$1"),\"sent_at\":$(_report_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")${2:+,$2}}"
    REPORT_EVENTS[id]="$json"
    if [[ "$REPORT_MODE" == spool ]]; then _report_spool_write "$id" "$json" || true; fi
    if [[ "${3:-}" != final && "$REPORT_MODE" != deferred ]]; then _report_send_bg "$id"; fi
}

# Send everything not yet delivered (spool) or not yet sent (otherwise), in
# parallel, and wait for those sends - and any still running - at most
# REPORT_FINAL_WAIT seconds in total.
_report_flush() {
    local id pid i running
    for id in "${!REPORT_EVENTS[@]}"; do
        if [[ "$REPORT_MODE" == spool ]]; then
            [[ -e "$REPORT_DIR/$INSTALL_ID/sent/$id" ]] && continue
        else
            [[ -n "${REPORT_LAUNCHED[$id]:-}" ]] && continue
        fi
        _report_send_bg "$id"
    done
    for ((i = 0; i < REPORT_FINAL_WAIT * 10; i++)); do
        running=0
        for pid in $REPORT_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then running=1; break; fi
        done
        ((running)) || break
        sleep 0.1
    done
}

_report_stage_begin() {
    REPORT_STAGE="$1"
    REPORT_STAGE_START=$(date +%s)
    REPORT_STAGE_RESULT="ok"
    REPORT_STEP=""
}

# $1 = "final" from the exit handler.
_report_stage_end() {
    [[ -n "$REPORT_STAGE" ]] || return 0
    local stage="$REPORT_STAGE" duration
    REPORT_STAGE=""
    [[ "$REPORT_MODE" != deferred ]] || return 0
    duration=$(($(date +%s) - REPORT_STAGE_START))
    ((duration >= 0 && duration <= 86400)) || duration=0
    _report_emit stage_finished "\"stage\":$(_report_json_str "$stage"),\"duration_s\":${duration},\"result\":$(_report_json_str "$REPORT_STAGE_RESULT")" "${1:-}"
}

_report_step_result() {
    local step="$1" outcome="$2" reason="${3:-}" class
    [[ "$REPORT_STEP" == "$step" ]] && REPORT_STEP=""
    [[ -n "$step" && "$outcome" == failed ]] || return 0
    class=$(report_step_class "$step")
    if [[ "$class" == optional ]]; then
        _report_in_list "$step" "$REPORT_FAILED_OPTIONAL" || REPORT_FAILED_OPTIONAL+="${REPORT_FAILED_OPTIONAL:+ }$step"
        [[ "$REPORT_STAGE_RESULT" == failed ]] || REPORT_STAGE_RESULT="warnings"
        return 0
    fi
    [[ -n "$reason" ]] || reason=$(report_reason_for_step "$step")
    _report_in_list "$reason" "$REPORT_REASONS" || reason="unclassified"
    if [[ "$class" == required ]]; then
        _report_in_list "$step" "$REPORT_FAILED_REQUIRED" || REPORT_FAILED_REQUIRED+="${REPORT_FAILED_REQUIRED:+ }$step"
    else
        step=""
    fi
    if [[ -z "$REPORT_REASON" ]]; then
        REPORT_FAILED_STEP="$step"
        REPORT_REASON="$reason"
    fi
    REPORT_STAGE_RESULT="failed"
}

_report_system_stopping() {
    local state
    command -v systemctl >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        state=$(timeout 2 systemctl is-system-running 2>/dev/null </dev/null)
    else
        state=$(systemctl is-system-running 2>/dev/null </dev/null)
    fi
    [[ "$state" == stopping ]]
}

# The signal is recorded and the script exits through the EXIT trap, which
# reports it and then delivers the same signal again with its default action,
# so the script still ends killed by that signal, as it would without these
# traps. TERM or HUP while the system shuts down is not a cancellation:
# nothing is reported, and the attempt shows as no_result.
_report_on_signal() {
    local sig="$1"
    REPORT_SIGNAL="$sig"
    if [[ "$sig" != INT ]] && _report_system_stopping; then REPORT_SUPPRESS=1; fi
    case "$sig" in INT) exit 130 ;; TERM) exit 143 ;; *) exit 129 ;; esac
}

_report_finish() {
    local rc="$1" result failed_step reason sig_num=0
    case "$REPORT_SIGNAL" in INT) sig_num=2 ;; TERM) sig_num=15 ;; HUP) sig_num=1 ;; esac
    ((sig_num == 0)) || rc=$((128 + sig_num))
    if ((REPORT_SUPPRESS)); then
        _report_spool_mark_finished
        return 0
    fi
    if [[ -n "$REPORT_SIGNAL" ]]; then
        result="cancelled"
        failed_step="$REPORT_STEP"
        reason="interrupted"
    else
        if ((rc != 0)); then
            # Stopped by an error nothing reported (set -e, an unexpected
            # exit): the step running at the time, with its own reason code.
            local current="$REPORT_STEP"
            [[ -n "$current" ]] && _report_step_result "$current" failed
            if [[ "$REPORT_EUID" -ne 0 && -z "$REPORT_REASON" ]]; then
                REPORT_FAILED_STEP="check_root"
                REPORT_REASON="not_root"
            fi
            if [[ -z "$REPORT_REASON" ]]; then
                REPORT_FAILED_STEP="$current"
                REPORT_REASON="unclassified"
            fi
            result="failed"
        elif [[ -n "$REPORT_REASON" ]]; then
            result="failed"
        elif [[ "$REPORT_READINESS" != ok ]]; then
            REPORT_FAILED_STEP="readiness"
            REPORT_REASON="readiness_check_failed"
            result="failed"
        elif [[ -n "$REPORT_FAILED_OPTIONAL" ]]; then
            result="succeeded_with_warnings"
        else
            result="succeeded"
        fi
        failed_step="$REPORT_FAILED_STEP"
        reason="$REPORT_REASON"
    fi
    [[ "$(report_step_class "$failed_step")" != unknown ]] || failed_step=""
    ((rc >= 0 && rc <= 255)) || rc=255
    if [[ -n "$REPORT_STAGE" && ( "$result" == failed || "$result" == cancelled ) ]]; then
        REPORT_STAGE_RESULT="failed"
    fi
    _report_stage_end final
    local duration=$(($(date +%s) - REPORT_START))
    ((duration >= 0 && duration <= 86400)) || duration=0
    local trial
    trial=$(_report_clean "$REPORT_TRIAL" '^(ok|failed|skipped)$' "")
    _report_emit install_finished "\"result\":$(_report_json_str "$result"),\"failed_step\":$(_report_json_str "$failed_step"),\"reason\":$(_report_json_str "$reason"),\"exit_code\":${rc},\"signal\":$(_report_json_str "$REPORT_SIGNAL"),\"failed_optional_steps\":$(_report_json_steps "$REPORT_FAILED_OPTIONAL"),\"failed_required_steps\":$(_report_json_steps "$REPORT_FAILED_REQUIRED"),\"panel_version\":$(_report_json_str "$(_report_pkg_version bolt-panel)"),\"agent_version\":$(_report_json_str "$(_report_pkg_version bolt-agent)"),\"trial_licence\":$(_report_json_str "$trial"),\"duration_s\":${duration}" final
    _report_spool_mark_finished
    _report_flush
}

# The only EXIT trap: removes the install marker (when this run created it)
# and reports the result. Its own failures are ignored, a closed output pipe
# cannot kill it, and the exit code of the script stays what it was.
report_on_exit() {
    local rc=$?
    trap '' PIPE INT TERM HUP
    set +e
    if ((INSTALL_MARKER_CREATED)); then rm -f "$REPORT_MARKER"; fi
    [[ "$REPORT_MODE" == off ]] || _report_finish "$rc" </dev/null >/dev/null 2>&1
    if [[ -n "$REPORT_SIGNAL" ]]; then
        trap - "$REPORT_SIGNAL"
        kill -s "$REPORT_SIGNAL" "$$"
    fi
    return 0
}

# Writes the resend script. Paths and address are fixed in it at write time;
# it never trusts the spool path either, for the same reason as above.
_report_write_sender() {
    local dest="$1" tmp
    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "$dest.XXXXXX") || return 1
    {
        printf '#!/bin/bash\n'
        printf '# AdminBolt install report: resends undelivered install events (AB-2067).\n'
        printf '# Written by install.sh; removes itself, its timer and its service after 24 hours\n'
        printf '# or once everything is delivered. The spool directory is kept.\n'
        printf 'SPOOL=%q\nURL=%q\nUNIT_DIR=%q\nUNIT_NAME=%q\nSELF=%q\nOWNER_UID=%q\n' \
            "$REPORT_DIR" "$REPORT_URL" "$REPORT_UNIT_DIR" "$REPORT_UNIT_NAME" "$dest" "$REPORT_OWNER_UID"
        cat <<'SENDER'
umask 077
MAX_AGE=86400
now=${ADMINBOLT_REPORT_NOW:-$(date +%s)}
pending=0

private_dir() { [ "$(stat -c '%u %a' "$1" 2>/dev/null)" = "$OWNER_UID 700" ]; }

# Runs in a subshell from the spool directory; returns 1 while anything of
# this install may still need sending.
send_install() {
    local started f n code left=0
    cd -P "./$1" 2>/dev/null && private_dir . || return 0
    started=$(cat started 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] || return 0
    ((now - started <= MAX_AGE)) || return 0
    [ -e finished ] || left=1
    for f in events/*.json; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        n=${f#events/}
        n=${n%.json}
        [[ "$n" =~ ^[0-9]{1,2}$ ]] || continue
        [ -e "sent/$n" ] && continue
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
            -H 'Content-Type: application/json' --data-binary "@$f" "$URL" </dev/null 2>/dev/null) || true
        # 2xx and 400/409/413 are final; 429, 507, 5xx and no answer are retried.
        if [[ "$code" =~ ^(2[0-9][0-9]|400|409|413)$ ]]; then : >"sent/$n"; else left=1; fi
    done
    return "$left"
}

remove_self() {
    systemctl disable --now "$UNIT_NAME.timer" </dev/null >/dev/null 2>&1
    rm -f "$UNIT_DIR/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.service"
    systemctl daemon-reload </dev/null >/dev/null 2>&1
    rm -f "$SELF"
    rmdir "${SELF%/*}" 2>/dev/null
}

if cd -P "$SPOOL" 2>/dev/null && private_dir .; then
    for d in *; do
        [[ "$d" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || continue
        (send_install "$d") || pending=1
    done
fi
((pending)) || remove_self
exit 0
SENDER
    } >"$tmp" && chmod 0700 "$tmp" && mv -f "$tmp" "$dest" && return 0
    rm -f "$tmp"
    return 1
}

_report_install_timer() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -d "$REPORT_UNIT_DIR" ]] || return 1
    _report_write_sender "$REPORT_SENDER" || return 1
    local svc="$REPORT_UNIT_DIR/$REPORT_UNIT_NAME.service" tim="$REPORT_UNIT_DIR/$REPORT_UNIT_NAME.timer"
    printf '[Unit]\nDescription=AdminBolt install report: resend undelivered events\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=%s\n' \
        "$REPORT_SENDER" >"$svc.tmp" && chmod 0644 "$svc.tmp" && mv -f "$svc.tmp" "$svc" || return 1
    # OnActiveSec covers this boot, OnBootSec the boots after a restart.
    printf '[Unit]\nDescription=AdminBolt install report: resend undelivered events every 15 minutes for 24 hours\n\n[Timer]\nOnBootSec=5min\nOnActiveSec=15min\nOnUnitActiveSec=15min\n\n[Install]\nWantedBy=timers.target\n' \
        >"$tim.tmp" && chmod 0644 "$tim.tmp" && mv -f "$tim.tmp" "$tim" || return 1
    systemctl daemon-reload </dev/null >/dev/null 2>&1
    systemctl enable --now "$REPORT_UNIT_NAME.timer" </dev/null >/dev/null 2>&1
}

_report_init() {
    REPORT_START=$(date +%s)
    if _report_in_list "$REPORT_CHANNEL_ARG" "$REPORT_CHANNELS"; then REPORT_CHANNEL="$REPORT_CHANNEL_ARG"; fi
    case "${ADMINBOLT_NO_TELEMETRY:-}" in 1|true|TRUE|yes|YES) REPORT_NO_TELEMETRY=1 ;; esac
    if ((REPORT_NO_TELEMETRY)); then
        REPORT_MODE="off"
        print_info "Install report is off (--no-telemetry): nothing about this install is sent."
        return 0
    fi
    if [[ -n "${ADMINBOLT_INSTALL_REPORT_URL:-}" ]]; then
        REPORT_URL=$(_report_clean "$ADMINBOLT_INSTALL_REPORT_URL" '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' "$REPORT_URL")
    fi
    INSTALL_ID=$(_report_new_uuid) || { INSTALL_ID=""; return 0; }
    REPORT_REV=$(_report_installer_rev)
    if [[ "$REPORT_EUID" -ne 0 ]]; then
        REPORT_MODE="deferred"
    else
        REPORT_OWNER_UID=$(id -u)
        if _report_spool_init; then
            REPORT_MODE="spool"
            _report_install_timer || true
        else
            REPORT_MODE="memory"
        fi
    fi
    trap '_report_on_signal INT' INT
    trap '_report_on_signal TERM' TERM
    trap '_report_on_signal HUP' HUP
    local host="${REPORT_URL#*://}"
    host="${host%%/*}"
    print_info "This installer reports its progress and result to ${host} (install ID, OS, platform, versions, step results; no hostnames, e-mail addresses, passwords or command output). To turn this off, rerun with --no-telemetry or ADMINBOLT_NO_TELEMETRY=1."
    _report_stage_begin prerequisites
    _report_emit install_started "\"channel\":$(_report_json_str "$REPORT_CHANNEL"),\"platform\":$(_report_json_str "$(_report_platform)"),\"installer_rev\":$(_report_json_str "$REPORT_REV"),\"os_name\":$(_report_json_str "$(_report_clean "$(_report_os_field ID)" '^[a-z0-9._-]{1,32}$' "unknown")"),\"os_version\":$(_report_json_str "$(_report_clean "$(_report_os_field VERSION_ID)" '^[0-9A-Za-z._-]{1,16}$' "unknown")"),\"arch\":$(_report_json_str "$(_report_arch)"),\"requested_version\":$(_report_json_str "$(_report_clean "$PANEL_VERSION" '^[0-9A-Za-z.+~_-]{0,40}$' "")"),\"source\":$(_report_json_str "$(_report_clean "${BOLT_SOURCE:-default}" '^[a-z0-9_-]{1,16}$' "other")"),\"telemetry_notice\":true"
}

# Sets one key in the [bolt] section of an INI file. The file is replaced
# atomically and keeps its owner and mode, so a failure leaves it as it was;
# it is created (root:boltweb 0640) only when it does not exist yet.
_report_ini_set() {
    local file="$1" key="$2" value="$3" dir tmp
    dir=$(dirname "$file")
    [[ ! -L "$file" ]] || return 1
    if [[ ! -e "$file" ]]; then
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$(dirname "$dir")" && mkdir -m 0750 "$dir" || return 1
            chgrp boltweb "$dir" 2>/dev/null || true
        fi
        tmp=$(mktemp "$file.XXXXXX") || return 1
        if printf '[bolt]\n%s=%s\n' "$key" "$value" >"$tmp" && chmod 0640 "$tmp" \
            && { chgrp boltweb "$tmp" 2>/dev/null || true; } && mv -n "$tmp" "$file" && [[ ! -e "$tmp" ]]; then
            return 0
        fi
        rm -f "$tmp"
        return 1
    fi
    [[ -f "$file" ]] || return 1
    tmp=$(mktemp "$file.XXXXXX") || return 1
    if awk -v key="$key" -v val="$value" '
        function put() { if (!done) { print key "=" val; done = 1 } }
        /^[[:space:]]*\[/ {
            if (inbolt) put()
            inbolt = ($0 ~ /^[[:space:]]*\[bolt\][[:space:]]*$/)
            if (inbolt) seenbolt = 1
            print
            next
        }
        $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") { if (inbolt || !seenbolt) put(); next }
        { print }
        END {
            if (!done) {
                if (!inbolt) print "[bolt]"
                print key "=" val
            }
        }' "$file" >"$tmp" \
        && chown --reference="$file" "$tmp" && chmod --reference="$file" "$tmp" \
        && { ! command -v chcon >/dev/null 2>&1 || chcon --reference="$file" "$tmp" 2>/dev/null || true; } \
        && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

_report_write_panel_settings() {
    if ((REPORT_NO_TELEMETRY)); then
        _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_TELEMETRY 0 \
            || echo -e "${YELLOW}WARNING:${NC} could not write BOLT_INSTALL_TELEMETRY=0 to ${REPORT_BOLT_CONFIG}; set it with: bolt-cli set-ini-settings BOLT_INSTALL_TELEMETRY 0"
    elif [[ -n "$INSTALL_ID" ]]; then
        _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_ID "$INSTALL_ID" || true
    fi
}

_report_ready() {
    local svc code
    for svc in bolt-agent bolt-nginx bolt-php mariadb postfix dovecot; do
        systemctl is-active --quiet "$svc" </dev/null 2>/dev/null || return 1
    done
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$REPORT_PANEL_URL" </dev/null 2>/dev/null) || true
    [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}

_report_readiness_check() {
    [[ "$REPORT_MODE" != off ]] || return 0
    _report_stage_begin readiness
    REPORT_STEP="readiness"
    if _report_ready; then
        REPORT_READINESS="ok"
        _report_step_result readiness ok
    else
        REPORT_READINESS="failed"
        _report_step_result readiness failed readiness_check_failed
    fi
    _report_stage_end
}

# Hook points used by the install steps. None of them can fail or print
# (apart from the start notice and a --no-telemetry warning).
report_init() {
    _report_init 2>/dev/null || true
    trap report_on_exit EXIT
}
report_stage_begin() { [[ "$REPORT_MODE" == off ]] || { _report_stage_end 2>/dev/null; _report_stage_begin "$1"; } || true; }
report_stage_end() { _report_stage_end 2>/dev/null || true; }
report_step_start() { REPORT_STEP="${1:-}"; }
report_step_result() { _report_step_result "$@" 2>/dev/null || true; }
# report_fail [step] [reason]: the step failed (default: the current one).
report_fail() { _report_step_result "${1:-$REPORT_STEP}" failed "${2:-}" 2>/dev/null || true; }
report_trial_licence() { REPORT_TRIAL="$1"; }
report_write_panel_settings() { _report_write_panel_settings 2>/dev/null || true; }
report_readiness_check() { _report_readiness_check 2>/dev/null || true; }

# Check if port 8443 is free, or already used by an existing bolt-nginx.
# If used by some other service, abort installation early.
check_port_8443() {
    report_step_start check_port_8443
    # ss is part of iproute2 on AlmaLinux 9
    if ! command -v ss >/dev/null 2>&1; then
        print_error "ss command not found; cannot check port 8443 usage"
        report_fail check_port_8443 missing_command
        exit 1
    fi

    local line
    line=$(ss -tulpn 2>/dev/null | awk '$5 ~ /:8443$/ {print}')
    if [ -z "$line" ]; then
        # Port not in use
        return 0
    fi

    if echo "$line" | grep -q "nginx"; then
        print_info "Port 8443 is already used by an existing bolt-nginx; proceeding with reinstall"
        return 0
    fi

    print_error "Port 8443 is already in use by another service. Please free it before running this installer."
    echo "Current listener:"
    echo "$line"
    report_fail check_port_8443 port_in_use
    exit 1
}

# ---------- Stage 1: Check ready for installation ----------
stage_prerequisites() {
    print_info "Stage 1: Checking that everything is in place and ready for installation"
    # Root
    report_step_start check_root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        report_fail check_root not_root
        exit 1
    fi
    # Distro: AlmaLinux 9 or Rocky Linux 9
    local distro_info
    report_step_start check_os
    if ! distro_info=$(detect_distribution); then
        print_error "This script supports AlmaLinux 9 and Rocky Linux 9 only. Current system is not supported."
        report_fail check_os unsupported_os
        exit 1
    fi
    print_success "Detected: $distro_info"
    # Required commands
    report_step_start check_commands
    for cmd in curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_error "Required command not found: $cmd"
            report_fail check_commands missing_command
            exit 1
        fi
    done
    check_port_8443
    print_success "Stage 1 completed: ready for installation"
    print_progress "33% — prerequisites"
}

# Detect distribution: AlmaLinux 9 or Rocky Linux 9
detect_distribution() {
    if [ ! -f /etc/os-release ]; then
        return 1
    fi
    . /etc/os-release
    case "$ID" in
        almalinux|rocky) ;;
        *) return 1 ;;
    esac
    [[ "$VERSION_ID" =~ ^9(\.[0-9]*)?$ ]] || return 1
    echo "${ID}|${VERSION_ID}"
    return 0
}

# ---------- Stage 2: Install base packages ----------
# Write bolt / bolt-noarch repos for a pulp content tier (stable, staging, testing).
install_bolt_repos_from_source() {
    local tier="$1"
    local repofile="/etc/yum.repos.d/bolt.repo"
    print_info "Configuring Bolt repositories (source=${tier})..."
    cat >"$repofile" <<EOF
[bolt]
name = Adminbolt RHEL - \$releasever - \$basearch
baseurl = https://mirror.adminbolt.com/pulp/content/${tier}/rhel/\$releasever/\$basearch
enabled = 1
gpgcheck = 0
priority = 300
sslverify = 0

[bolt-noarch]
name = Adminbolt RHEL - \$releasever - noarch
baseurl = https://mirror.adminbolt.com/pulp/content/${tier}/rhel/\$releasever/noarch
enabled = 1
gpgcheck = 0
priority = 400
sslverify = 0
EOF
    print_success "Repository file written: ${repofile}"
}

install_repo_rhel() {
    local el_version=$1
    if [[ -n "$BOLT_SOURCE" ]]; then
        install_bolt_repos_from_source "$BOLT_SOURCE"
        return 0
    fi
    local rpm_url="${REPO_BASE_URL}/rhel/${el_version}/noarch/Packages/b/${REPO_PACKAGE}.el${el_version}.noarch.rpm"
    local temp_rpm="/tmp/bolt-repo-${el_version}.rpm"
    print_info "Downloading repository package..."
    curl -f -L -k -o "$temp_rpm" "$rpm_url" || { print_error "Failed to download repo"; report_fail repo_setup repo_download_failed; exit 1; }
    (command -v dnf >/dev/null 2>&1 && dnf install -y "$temp_rpm") || (command -v yum >/dev/null 2>&1 && yum install -y "$temp_rpm") || rpm -ivh "$temp_rpm"
    rm -f "$temp_rpm"
    print_success "Repository installed"
}

# Single package install helper: dnf or yum only (AlmaLinux). Skips already-installed. Optional leading args: dnf opts (e.g. --enablerepo=bolt, --exclude=bolt-bootstrap).
install_packages() {
    local dnf_opts=()
    while [[ $# -gt 0 && "$1" == --* ]]; do dnf_opts+=("$1"); shift; done
    [[ $# -eq 0 ]] && return 0
    local missing=()
    for p in "$@"; do rpm -q "$p" &>/dev/null || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && { print_success "Packages already installed"; return 0; }
    (command -v dnf >/dev/null 2>&1 && dnf install -y "${dnf_opts[@]}" "${missing[@]}") || (command -v yum >/dev/null 2>&1 && yum install -y "${dnf_opts[@]}" "${missing[@]}") || { print_error "dnf/yum not found"; report_fail; exit 1; }
    print_success "Packages installed"
}

# $3 (optional) = step id for the install report.
run_or_warn() {
    local cmd="$1" desc="${2:-Command}" step="${3:-}"
    print_info "$desc"
    report_step_start "$step"
    if eval "$cmd"; then print_success "$desc completed"; report_step_result "$step" ok; else echo -e "${YELLOW}WARNING:${NC} $desc failed (continuing)"; report_step_result "$step" failed; fi
    echo -e ""
}
run_or_fail() {
    local cmd="$1" desc="${2:-Command}" step="${3:-}"
    report_step_start "$step"
    if ! eval "$cmd"; then print_error "${desc} failed"; report_fail "$step"; exit 1; fi
    report_step_result "$step" ok
    print_success "${desc} completed"
    echo -e ""
}

# ---------- Stage 2: Prepare → Prerequisite packages → Bolt packages ----------
# Step 2.1: Prepare all settings (no package installs)
stage2_prepare_settings() {
    print_info "Stage 2.1: Preparing settings"
    run_or_warn "setenforce 0" "SELinux enforce" selinux_enforce
    run_or_warn "sed -i 's#^SELINUX=.*#SELINUX=disabled#' /etc/selinux/config" "SELinux config" selinux_config
    print_success "Stage 2.1 completed: settings prepared"
}

# Step 2.2: Install all prerequisite packages (EPEL, CRB, libsodium, traceroute, openssl, jq, etc.)
stage2_install_prerequisite_packages() {
    print_info "Stage 2.2: Installing prerequisite packages"
    print_info "Enabling CRB (CodeReady Builder) repository"
    report_step_start prerequisite_packages
    install_packages epel-release dnf-plugins-core
    run_or_warn "dnf config-manager --set-enabled crb" "Enable CRB repo" crb_repo
    report_step_start prerequisite_packages
    install_packages \
        libsodium traceroute openssl jq rsync ca-certificates wget curl tar gzip unzip zip sudo apg \
        systemd openssl-libs libcurl libzip zlib gmp freetype libjpeg-turbo libpng libwebp libXpm gd \
        gettext-libs libicu sqlite-libs oniguruma libxslt shadow-utils chrony restic rclone git
    run_or_warn "systemctl enable --now chronyd" "Time synchronization (chronyd)" chronyd
    run_or_warn "curl https://get.acme.sh | sh -s email=issue-ssl@adminbolt.com" "acme.sh" acme_sh
    print_success "Stage 2.2 completed: prerequisite packages installed"
}

# dnf reports a failed %post scriptlet as a warning but the package
# transaction still exits 0, so install_packages()'s exit-code check cannot
# see it - bolt-agent's %post ends with `systemctl enable/restart/start
# bolt-agent`, and a failure earlier in the script (permissions, disk space,
# a real certificate issuance failure the self-signed fallback did not
# catch) aborts before reaching that. Left undetected here, the only symptom
# shows up later in Stage 3 as a bare agent connection error, which does not
# name the actual cause. Kept separate from install_packages() (used by
# every other package install in this script) so this check only ever
# applies to bolt-agent, and every other install keeps its existing
# behavior unchanged.
install_bolt_agent_and_check_post() {
    report_step_start agent_install
    if rpm -q bolt-agent &>/dev/null; then
        print_success "bolt-agent already installed"
        return 0
    fi

    local log dnf_status
    log=$(mktemp)
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y --enablerepo=bolt bolt-agent 2>&1 | tee "$log"
        dnf_status=${PIPESTATUS[0]}
    elif command -v yum >/dev/null 2>&1; then
        yum install -y --enablerepo=bolt bolt-agent 2>&1 | tee "$log"
        dnf_status=${PIPESTATUS[0]}
    else
        rm -f "$log"
        print_error "dnf/yum not found"
        report_fail agent_install agent_install_failed
        exit 1
    fi

    if [[ "$dnf_status" -ne 0 ]]; then
        rm -f "$log"
        print_error "Installing bolt-agent failed"
        report_fail agent_install agent_install_failed
        exit 1
    fi
    if grep -Eq '%post\(bolt-agent[^)]*\) scriptlet failed' "$log"; then
        rm -f "$log"
        print_error "bolt-agent's post-install script (%post) failed. Check the output above (or 'journalctl -u bolt-agent') for the cause, fix it, then rerun this installer."
        report_fail agent_scriptlet agent_install_failed
        exit 1
    fi
    rm -f "$log"
    report_step_result agent_install ok
    print_success "bolt-agent installed"
}

# bolt-panel's %post (database install, base setup, marking the panel as
# installed) fails the same quiet way as bolt-agent's above, and is detected
# the same way. Unlike bolt-agent's, a failure here does not stop the
# installer - when to stop is a separate decision (AB-2067 reports, it does
# not change the flow) - it is reported as panel_scriptlet_failed and the
# install carries on exactly as before.
install_bolt_panel_and_check_post() {
    local log status
    report_step_start panel_install
    log=$(mktemp)
    install_packages --enablerepo=bolt bolt-nginx bolt-php "$1" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    if [[ "$status" -ne 0 ]]; then
        rm -f "$log"
        report_fail panel_install package_install_failed
        exit "$status"
    fi
    report_step_result panel_install ok
    if grep -Eq '%post\(bolt-panel-[0-9][^)]*\) scriptlet failed' "$log"; then
        echo -e "${YELLOW}WARNING:${NC} bolt-panel's post-install script (%post) failed; see /var/log/bolt-panel-package.log (continuing)"
        report_fail panel_scriptlet panel_scriptlet_failed
    fi
    rm -f "$log"
}

# Step 2.3: Install all Bolt packages (repo, bolt-nginx/php/agent, panel RPM)
stage2_install_bolt_packages() {
    print_info "Stage 2.3: Installing all Bolt packages"
    report_step_start repo_setup
    install_repo_rhel 9
    local panel_pkg="bolt-panel"
    if [[ -n "$PANEL_VERSION" ]]; then
        panel_pkg="bolt-panel-${PANEL_VERSION}"
        print_info "Installing specific bolt-panel version: ${PANEL_VERSION}"
    fi
    install_bolt_agent_and_check_post
    install_bolt_panel_and_check_post "$panel_pkg"
    report_write_panel_settings
    report_step_start web_services_enable
    systemctl enable --now bolt-nginx bolt-php
    report_step_result web_services_enable ok
    print_success "Stage 2.3 completed: all Bolt packages installed"
}

stage_install_base_packages() {
    print_info "Stage 2: Prepare settings → Prerequisite packages → Bolt packages"
    SECTION_START=$(date +%s)
    stage2_prepare_settings
    time_section_end "Stage 2.1: Prepare settings"
    SECTION_START=$(date +%s)
    stage2_install_prerequisite_packages
    time_section_end "Stage 2.2: Prerequisite packages"
    SECTION_START=$(date +%s)
    stage2_install_bolt_packages
    time_section_end "Stage 2.3: Bolt packages"
    print_success "Stage 2 completed"
    print_progress "66% — base packages"
}

# ---------- Stage 3: Execute bolt-cli / Install services ----------
stage_configuration() {
    print_info "Stage 3: Executing bolt-cli / post-install actions"
    run_or_fail "bolt-cli connect-bolt-agent-with-panel" "Connect bolt-agent to panel" agent_panel_connect
    run_or_warn "bolt-cli add-bolt-greeting-message" "Add bolt greeting message" greeting
    run_or_warn "bolt-cli manage-nftable --action=install" "Nftable" nftables
    run_or_warn "bolt-cli manage-sshd --action=install" "SSH server" ssh_server
    run_or_warn "bolt-cli manage-powerdns --action=install" "PowerDNS" powerdns
    # AB-1446: the MariaDB series is a choice; without --mariadb-version the
    # panel's default series is installed.
    if [[ -n "$MARIADB_SERIES" ]]; then
        # QA F1: a panel that predates the --series option (an older channel
        # head, a pinned older version) refused the flag and the box was left
        # without a database. Fall back to the panel's default series, loudly,
        # rather than install nothing.
        print_info "MariaDB ${MARIADB_SERIES}"
        local MARIADB_OUT
        report_step_start mariadb
        if MARIADB_OUT=$(bolt-cli manage-mariadb --action=install --series="${MARIADB_SERIES}" 2>&1); then
            echo "$MARIADB_OUT"
            report_step_result mariadb ok
            print_success "MariaDB ${MARIADB_SERIES} completed"
        elif grep -qi 'option does not exist' <<<"$MARIADB_OUT"; then
            echo "$MARIADB_OUT"
            echo -e "${YELLOW}WARNING:${NC} the installed panel does not support --mariadb-version yet; installing its default MariaDB series instead"
            run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB (default series)" mariadb
        else
            echo "$MARIADB_OUT"
            echo -e "${YELLOW}WARNING:${NC} MariaDB ${MARIADB_SERIES} failed (continuing)"
            report_step_result mariadb failed
        fi
        echo -e ""
    else
        run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB" mariadb
    fi
    run_or_warn "bolt-cli manage-postfix --action=install" "Postfix" postfix
    run_or_warn "bolt-cli manage-dovecot --action=install" "Dovecot" dovecot
    run_or_warn "bolt-cli manage-redis --action=install" "Redis" redis
    run_or_warn "bolt-cli manage-rspamd --action=install" "Rspamd" rspamd
    run_or_warn "bolt-cli manage-mlmmj --action=install" "MLMMJ" mlmmj
    run_or_warn "bolt-cli manage-php --action=install --php-version=8.4" "PHP 8.4" php84
    run_or_warn "bolt-cli manage-my-apache --action=install" "MyApache" myapache
    run_or_warn "bolt-cli manage-vsftpd --action=install" "Vsftpd" vsftpd
    # Disk quota, on a box that has no accounts yet: the accounting pass is
    # instant here and enforcement is on from the first account, rather than
    # being switched on later under accounts that are already over their
    # plans. Warn-only - a filesystem that cannot carry quota is a reason to
    # tell the administrator, not to fail the install.
    run_or_warn "bolt-cli manage-disk-quota --action=install" "Disk quota enforcement" disk_quota
    run_or_warn "bolt-cli manage-fail2ban --action=install" "Fail2Ban" fail2ban
    for app in local-api filemanager phpmyadmin roundcube git metrics adminer; do
        run_or_warn "bolt-php ${WEB_INSTALL_ROOT}/artisan bolt:manage-app --action=install --app-name=${app}" "App ${app}" "app_${app}"
    done
    sleep 5
    run_or_warn "bolt-cli manage-sshd-profiles --action=install" "SSH server profiles" ssh_profiles
    run_or_warn "bolt-cli manage-postfix-profiles --action=install" "Postfix profiles" postfix_profiles
    run_or_warn "bolt-cli manage-dovecot-profiles --action=install" "Dovecot profiles" dovecot_profiles
    run_or_warn "bolt-cli manage-redis-profiles --action=install" "Redis profiles" redis_profiles
    run_or_warn "bolt-cli manage-rspamd-profiles --action=install" "Rspamd profiles" rspamd_profiles
    run_or_warn "bolt-cli setup-firewall" "Firewall setup" firewall_setup
    run_or_warn "bolt-cli manage-mariadb-default-profile --action=install" "MariaDB profile" mariadb_profile
    run_or_warn "bolt-cli manage-my-apache-default-profile --action=install" "MyApache profile" myapache_profile
    run_or_warn "bolt-cli manage-system-email-account --action=install" "System email" system_email
    run_or_warn "bolt-cli manage-dns-records-default-template --action=install" "DNS template" dns_template
    run_or_warn "bolt-cli manage-php-default-profile --php-version=8.4 --action=install" "PHP 8.4 profile" php84_profile
    run_or_warn "bolt-cli manage-vsftpd-profiles --action=install" "Vsftpd profile" vsftpd_profile
    run_or_warn "bolt-cli manage-fail2ban-profiles --action=install" "Fail2Ban profile" fail2ban_profile
    run_or_warn "bolt-cli setup-cron-jobs" "Setup Cron jobs" cron_jobs
    # Only records a provisioning plan and returns; the panel scheduler (installed by setup-cron-jobs) executes it in the background.
    run_or_warn "bolt-cli post-install-provision" "Queue post-install provisioning (remaining PHP versions, SecureBox, SymLock)" postinstall_queue
    run_or_warn "bolt-cli setup-hidepid" "Harden /proc (hidepid)" hidepid
    # QA F2: a bare restart under set -e aborted the whole run (no trial
    # licence, no SSO URL, no banner) whenever rspamd was not installed.
    run_or_warn "systemctl restart rspamd" "Rspamd restart" rspamd_restart
    # Trial licence last: nothing in the install depends on it, and the licence server refuses repeats
    # per e-mail and per IP, which must never abort an otherwise complete installation.
    local TRIAL_LICENCE_OK=0
    if [[ -n "$ADMIN_EMAIL" ]]; then
        # run_or_warn evaluates the command in this shell, so the assignment records the outcome.
        run_or_warn "bolt-cli request-trial-license --email=${ADMIN_EMAIL} && TRIAL_LICENCE_OK=1" "Request trial licence"
        # Its own report field; never part of the install result.
        if [[ "${TRIAL_LICENCE_OK}" -eq 1 ]]; then report_trial_licence ok; else report_trial_licence failed; fi
    else
        report_trial_licence skipped
        print_info "No --email= provided; skipping trial licence request. Activate a licence later on the panel's License page."
    fi
    local SSO_URL=$(bolt-cli admin-sso-generate 2>/dev/null || echo "")
    [ -z "${SSO_URL}" ] && echo -e "${YELLOW}WARNING:${NC} SSO URL not generated" || print_success "SSO URL generated"
    echo -e "\n${BOLD}${GREEN}+----------------------------------------------------------+${NC}"
    echo -e "${BOLD}${GREEN}|          Installation Completed Successfully             |${NC}"
    echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}\n"
    [ -n "${ADMIN_EMAIL}" ] && [ "${TRIAL_LICENCE_OK}" -eq 0 ] && echo -e "${YELLOW}NOTE:${NC} Trial licence not issued (request refused or licence server unreachable). The installation itself succeeded and the panel is usable; activate a licence on its License page.\n"
    [ -n "${SSO_URL:-}" ] && echo -e "${BOLD}${CYAN}--- Access ---${NC}\n${GREEN}Admin Panel:${NC}\n${BOLD}${SSO_URL}${NC}\n"
    echo -e "${GREEN}New SSO URL:${NC}\n${BOLD}bolt-cli admin-sso-generate${NC}"
    print_progress "100% — post-install"
    print_success "Stage 3 completed: all post-install actions done"
}

# ---------- Main ----------
print_usage() {
    echo "Usage: sudo $0 [--help] [--version=<PANEL_VERSION>] [--source=<stable|staging|testing>] [--email=<address>] [--mariadb-version=<10.11|11.4>] [--channel=<name>] [--no-telemetry]"
    echo "AlmaLinux 9 / Rocky Linux 9. Stages: 1=ready check, 2=(2.1 settings, 2.2 prereq packages, 2.3 bolt packages), 3=post-install."
    echo "If --version is not provided, latest bolt-panel from repo is installed."
    echo "If --source is not provided, the bolt-repo RPM from adminbolt is used (default). Otherwise repos point at pulp content stable/staging/testing."
    echo "If --mariadb-version is not provided, MariaDB 10.11 is installed; 11.4 is the newer long-term series (supported until 2029)."
    echo "If --email is provided, a 24h trial licence is requested for that address at the very end of the install (clicking the e-mailed confirmation link extends it to the full trial period); the install completes even if the request is refused."
    echo "Without --email the install proceeds unlicensed; activate on the panel's License page."
    echo "--channel names what started the install (${REPORT_CHANNELS// /, }); default direct."
    echo "The installer reports its progress and result (no hostnames, e-mail addresses or passwords) to AdminBolt; --no-telemetry (or ADMINBOLT_NO_TELEMETRY=1) turns this off for the installer and the panel."
}

main() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                print_usage
                exit 0
                ;;
            --version=*)
                PANEL_VERSION="${arg#--version=}"
                ;;
            --source=*)
                BOLT_SOURCE="${arg#--source=}"
                ;;
            --email=*)
                ADMIN_EMAIL="${arg#--email=}"
                ;;
            --mariadb-version=*)
                MARIADB_SERIES="${arg#--mariadb-version=}"
                ;;
            --channel=*)
                REPORT_CHANNEL_ARG="${arg#--channel=}"
                ;;
            --no-telemetry)
                REPORT_NO_TELEMETRY=1
                ;;
        esac
    done

    # Install report: ID, start event, signal traps and the one EXIT trap.
    report_init
    report_step_start parse_arguments

    if [[ -n "$REPORT_CHANNEL_ARG" ]] && ! [[ " $REPORT_CHANNELS " == *" $REPORT_CHANNEL_ARG "* ]]; then
        print_error "Invalid --channel=${REPORT_CHANNEL_ARG} (allowed: ${REPORT_CHANNELS// /, })"
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    if [[ -n "$MARIADB_SERIES" ]]; then
        case "$MARIADB_SERIES" in
            10.11|11.4) ;;
            *)
                print_error "Invalid --mariadb-version=${MARIADB_SERIES} (supported: 10.11, 11.4)"
                print_usage
                report_fail parse_arguments invalid_argument
                exit 1
                ;;
        esac
    fi

    if [[ -n "$ADMIN_EMAIL" && ! "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        print_error "Invalid --email=${ADMIN_EMAIL}"
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    if [[ -n "$BOLT_SOURCE" ]]; then
        case "$BOLT_SOURCE" in
            stable|staging|testing) ;;
            *)
                print_error "Invalid --source=${BOLT_SOURCE} (allowed: stable, staging, testing)"
                print_usage
                report_fail parse_arguments invalid_argument
                exit 1
                ;;
        esac
    fi

    # bolt-agent's %post (Stage 2) starts the box with a self-signed
    # certificate and requests the real one in the background, so a slow or
    # unreachable ACME endpoint never blocks this script (AB-1652). That
    # background task waits for this marker to go away before it hot-swaps
    # the certificate or restarts the agent, so its own reload can never land
    # in the middle of a later stage of this whole panel-plus-agent install -
    # Stage 3 included - and break it. Always removed on exit, success or
    # failure, so a box never gets stuck with a marker nothing will ever
    # clear. Lives under /var/lib/adminbolt (POST_INSTALL_DB_PATH's own
    # directory) since it marks this install.sh run as a whole, not
    # anything specific to the agent package. The EXIT trap set by
    # report_init removes it (only once this run has created it).
    report_step_result parse_arguments ok
    mkdir -p "$(dirname "$REPORT_MARKER")"
    touch "$REPORT_MARKER"
    INSTALL_MARKER_CREATED=1

    echo -e "\n${BOLD}AdminBolt Staged Install (Stage 1 → 2 → 3)${NC}\n"
    TOTAL_START=$(date +%s)

    SECTION_START=$(date +%s)
    stage_prerequisites
    time_section_end "Stage 1: Prerequisites"

    report_stage_begin packages
    SECTION_START=$(date +%s)
    stage_install_base_packages
    time_section_end "Stage 2: Base packages"

    report_stage_begin configuration
    SECTION_START=$(date +%s)
    stage_configuration
    time_section_end "Stage 3: Post-install actions"
    report_stage_end

    time_total_end
    # Stage 4, for the install report only: prints nothing, changes nothing.
    report_readiness_check
}

# ADMINBOLT_INSTALL_SOURCE_ONLY=1 loads the functions without running the
# install (tests/telemetry_test.sh). An environment switch rather than a
# BASH_SOURCE check, which cannot tell `curl ... | bash` apart reliably.
if [[ "${ADMINBOLT_INSTALL_SOURCE_ONLY:-}" != 1 ]]; then
    main "$@"
fi
