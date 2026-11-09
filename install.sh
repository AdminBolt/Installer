#!/bin/bash
#
# AdminBolt Install Script (AlmaLinux 9, Rocky Linux 9, CloudLinux 9)
#
# Reorganizes the installation into three stages:
#   Stage 1: Check that everything is in place and ready for installation
#   Stage 2: (2.1) Prepare settings → (2.2) Install prerequisite packages → (2.3) Install all Bolt packages
#   Stage 3: Execute bolt-cli / post-install actions (database, agent, services, profiles, etc.)
#
# Supported: AlmaLinux 9, Rocky Linux 9, CloudLinux 9. Panel is installed from RPM; %pre/%post skipped.
# Usage:
#   sudo ./install.sh                          # install latest bolt-panel from repo
#   sudo ./install.sh --version=1.0.0.beta3-v46.el9 # install specific bolt-panel version from repo
#   sudo ./install.sh --source=staging         # use staging pulp repos (stable|staging|testing); default unchanged
#   sudo ./install.sh --email=user@example.com # activate a 24h trial license for this e-mail (confirmation link extends it to 30 days)
#   sudo ./install.sh --admin-username=random  # first administrator: admin-<6 random characters> instead of "admin" (or a name of your choice)
#   sudo ./install.sh --mariadb-version=10.11  # MariaDB 10.11 instead of the default 11.4 (10.11 or 11.4)
#   sudo ./install.sh --without=mail,dns,ftp   # leave optional components out (small servers); the end of the install says how to add them later
#   sudo ./install.sh --skip-database          # keep the database server already on the box (no MariaDB steps)
#   sudo ./install.sh --skip-apache            # no Apache steps (the caller sets the web server up)
#   sudo ./install.sh --source=testing --agent-version=1.30.4-pr230.1.el9 --package=bolt-php=8.4.14-1.el9
#                                              # exact builds of bolt-agent / other bolt-* packages
#
set -e

# ---------------------------------------------------------------------------
# bolt-panel install: from repo (latest by default; --version= selects a specific version)
# ---------------------------------------------------------------------------
PANEL_VERSION=""
# AB-2331 addendum: --agent-version= (bolt-agent version-release) and
# --package=<bolt-name>=<version-release> (repeatable), installed exactly,
# from the repositories --source points at. PINNED_PACKAGES: one name=version per line.
AGENT_VERSION=""
PINNED_PACKAGES=""
# Empty = current behavior (bolt-repo RPM from adminbolt). stable|staging|testing = pulp content path segment.
BOLT_SOURCE=""
# E-mail for the trial license; empty = skip the trial request (activate manually on the License page).
ADMIN_EMAIL=""
# --mariadb-version=; empty = the default below on a new box (see stage_configuration).
MARIADB_SERIES=""
# AB-2104: name of the first panel administrator; empty = "admin". "random" = admin-<6 random characters>.
# ADMIN_USERNAME_GIVEN: the option was given, so an empty value is refused.
ADMIN_USERNAME=""
ADMIN_USERNAME_GIVEN=0
# AB-2228: the MariaDB series of a new install (10.11 until then).
readonly DEFAULT_MARIADB_SERIES="11.4"
# AB-2331: --skip-database / --skip-apache. A database server already on the
# box skips the database steps by itself (see database_skip_decide), so an
# installer run never replaces one.
SKIP_DATABASE=0
SKIP_APACHE=0
DATABASE_SKIP_REASON=""
DATABASE_SKIP_DECIDED=0
# Packages that mean a database server is installed. The globs go to rpm -qa.
readonly DATABASE_SERVER_PACKAGES="MariaDB-server mariadb-server mysql-server mysql-community-server percona-server-server"
readonly DATABASE_SERVER_PACKAGE_GLOBS="cl-MySQL* cl-MariaDB* Percona-Server-server*"
# The systemd units a MySQL-compatible server runs under, in the order they are looked for.
readonly DATABASE_UNITS="mariadb mysqld mysql"
# With the database skipped, the agent takes the server's credentials from here.
ROOT_MY_CNF="/root/.my.cnf"
AGENT_CONF="/etc/bolt-agent/agent.conf"
# ID from os-release (almalinux, rocky, cloudlinux), set in Stage 1.
DISTRO_ID=""
OS_RELEASE_FILE="/etc/os-release"
readonly EPEL_RELEASE_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
# AB-2106: --ssh-key= value (a public key, or an https:// URL serving keys); empty = no SSH changes.
SSH_KEY_ARG=""
# Validated key lines and their SHA256 fingerprints, filled in Stage 1.
SSH_KEYS=""
SSH_KEY_FPS=""
ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
# Sorts before every other drop-in, so its first values win over 50-cloud-init.conf and the panel's files.
SSHD_KEY_ONLY_DROP_IN="/etc/ssh/sshd_config.d/00-adminbolt-ssh-key-only.conf"
# Seconds the installer waits, at a terminal, for a sign-in with the key before it gives up and keeps password login.
SSH_KEY_LOGIN_WAIT=600
SSH_KEY_TTY="/dev/tty"
SSH_KEY_LOGIN_ADDR=""
SSH_KEY_PROOF_SINCE=0
# Outcome line for the end of the install.
SSH_PASSWORD_NOTE=""
# Raw --without= values as given (comma-separated, every occurrence joined),
# and whether the option was given at all, so an empty value is refused.
WITHOUT_ARG=""
WITHOUT_GIVEN=0
# Components left out, in the order of OPTIONAL_COMPONENTS (set by set_left_out_components).
LEFT_OUT_COMPONENTS=""
# "<component> <command>" for every step skipped for them, in the order Stage 3 reached it.
SKIPPED_COMMANDS=()
# AB-1379: steps that failed (run_or_warn), "<step>: <last error line>", and
# the components without which the server cannot serve sites, mail or
# databases. A failed critical component ends the install with a non-zero
# exit status; every failure is listed in the closing summary either way.
FAILED_STEPS=()
readonly CRITICAL_COMPONENTS=("MariaDB" "Postfix" "Dovecot" "PHP 8.4")
CRITICAL_FAILED=0
# Set once the closing summary is printed; an install that stops early
# prints it from the EXIT trap instead (AB-1379 QA finding 2).
SUMMARY_PRINTED=0
# The step that stopped the install, "<step>: <reason>" (run_or_fail,
# install_packages); listed first in that summary.
STOPPED_STEP=""
# AB-472: steps that wait for an external package repository the server
# cannot reach. The install does not fail on them: the panel installs them
# on its own once the repository answers (post-install setup on the
# dashboard). "<step>: <what it waits for>".
DEFERRED_STEPS=()
# Outcome of the last run_or_warn: ok, failed or deferred.
LAST_STEP_RESULT=""
# External repositories that did not answer the Stage 1 probe, by name.
UNREACHABLE_REPOSITORIES=()
readonly WEB_INSTALL_ROOT="/usr/local/bolt/web"

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
# A value the user typed, made safe to show in a message: cut to 40
# characters, anything unprintable as "?". Print the result with %s, never
# through print_error or echo -e, so escape sequences are not interpreted.
# Filtered under LC_ALL=C, so every non-ASCII byte is "?" too, whatever the
# box's locale (a UTF-8 locale would let through e.g. U+202E).
shown_arg() {
    local LC_ALL=C
    local v="${1:0:40}"
    printf '%s' "${v//[^[:print:]]/?}"
}
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
# event waits, at most REPORT_FINAL_WAIT seconds; all of it together adds at
# most REPORT_BUDGET_MS to a run. As root, events are also kept in a root-only
# spool (REPORT_DIR), and a systemd timer resends whatever did not get
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
# The built-in address, before ADMINBOLT_INSTALL_REPORT_URL may replace REPORT_URL.
REPORT_DEFAULT_URL="$REPORT_URL"
# Accepted form of a receiver address (installer override and per-install file).
REPORT_URL_RE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
# Not under /var/lib/adminbolt: the panel's database install hands that
# directory, recursively, to its web user.
REPORT_DIR="/var/lib/adminbolt-install-report"
REPORT_SENDER="/usr/local/libexec/adminbolt/install-report-send"
REPORT_UNIT_DIR="/etc/systemd/system"
REPORT_UNIT_NAME="adminbolt-install-report"
REPORT_BOLT_CONFIG="/etc/bolt/bolt-config.ini"
REPORT_DMI_DIR="/sys/class/dmi/id"
REPORT_OS_RELEASE="/etc/os-release"
REPORT_UUID_FILE="/proc/sys/kernel/random/uuid"
# Its fingerprint is written next to the install ID, so the panel can tell a
# copy of this server (booted from an image of it) from the server itself.
REPORT_MACHINE_ID_FILE="/etc/machine-id"
# Repository file written for --source; the install report probes its baseurls.
BOLT_REPO_FILE="/etc/yum.repos.d/bolt.repo"
# Upper bound, in seconds, on the whole --source repository probe.
REPORT_PROBE_CAP=10
REPORT_PANEL_URL="https://127.0.0.1:8443/"
REPORT_MARKER="/var/lib/adminbolt/install-in-progress"
# Present while the system is going down: a scheduled shutdown, and logins
# closed (systemd-user-sessions creates it on its way down; it also exists
# early in boot, before logins open).
REPORT_SHUTDOWN_MARKERS="/run/systemd/shutdown/scheduled /run/nologin"
REPORT_FINAL_WAIT=5
# Upper bound, in milliseconds, on the time all reporting may add to a run;
# every call to rpm or systemctl is cut off after REPORT_CALL_TIMEOUT seconds.
REPORT_BUDGET_MS=8000
REPORT_SPENT_MS=0
REPORT_FINISH_START=0
REPORT_CALL_TIMEOUT=2
# Event ids 49 and 50 belong to the panel and the hub.
REPORT_MAX_EVENT_ID=48
REPORT_EUID=$EUID
REPORT_OWNER_UID=0
REPORT_CHANNEL="direct"
REPORT_CHANNEL_ARG=""
# Set when --channel was given at all, so an empty value can be told apart.
REPORT_CHANNEL_GIVEN=0
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
REPORT_STEP_RUN=0
REPORT_FAILED_STEP=""
REPORT_REASON=""
REPORT_FAILED_REQUIRED=""
REPORT_FAILED_OPTIONAL=""
REPORT_SIGNAL=""
REPORT_SUPPRESS=0
REPORT_TRIAL=""
REPORT_READINESS=""
# Set when the --source repository's metadata could not be fetched.
REPORT_REPO_UNREACHABLE=0
INSTALL_MARKER_CREATED=0

REPORT_CHANNELS="direct get-script web-installer vultr akamai node image-build test hostinger digitalocean aws azure"
REPORT_REASONS="not_root unsupported_os invalid_argument missing_command port_in_use repo_download_failed package_install_failed agent_install_failed panel_scriptlet_failed agent_panel_connect_failed required_step_failed readiness_check_failed interrupted unclassified"

# Prints the class of one install step id for the report: required (its failure
# is the install's failure), optional (its failure only adds a warning) or
# unknown (not a step id).
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

# Exact match of one word against a space-separated list.
_report_in_list() {
    local w
    for w in $2; do [[ "$w" == "$1" ]] && return 0; done
    return 1
}

# rpm and systemctl can hang on a locked database or a busy systemd; the
# report never waits on them for longer than REPORT_CALL_TIMEOUT seconds.
_report_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1 "$REPORT_CALL_TIMEOUT" "$@"
        return
    fi
    # No timeout(1): the same bound in bash. The command runs in the
    # background and is stopped (TERM, then KILL a second later) once it
    # overstays; 124 then, as timeout(1) would answer.
    local pid end i
    "$@" &
    pid=$!
    end=$(($(_report_now_ms) + REPORT_CALL_TIMEOUT * 1000))
    while kill -0 "$pid" 2>/dev/null; do
        if (($(_report_now_ms) >= end)); then
            kill -TERM "$pid" 2>/dev/null
            for ((i = 0; i < 10; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1 2>/dev/null || sleep 1 2>/dev/null || break
            done
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1 2>/dev/null || sleep 1 2>/dev/null || :
    done
    wait "$pid"
}

_report_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME//[.,]/}"
        printf '%s' $((10#$t / 1000))
    else
        printf '%s' $(($(date +%s) * 1000))
    fi
}

# Runs a report function and adds the time it took to REPORT_SPENT_MS.
_report_timed() {
    local t0 rc
    t0=$(_report_now_ms)
    "$@"
    rc=$?
    REPORT_SPENT_MS=$((REPORT_SPENT_MS + $(_report_now_ms) - t0))
    return "$rc"
}
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

# Sets REPORT_PANEL_VERSION and REPORT_AGENT_VERSION with one bounded rpm call.
REPORT_PANEL_VERSION=""
REPORT_AGENT_VERSION=""
_report_pkg_versions() {
    local name version
    command -v rpm >/dev/null 2>&1 || return 0
    while read -r name version _; do
        version=$(_report_clean "$version" '^[0-9A-Za-z.+~_-]{1,40}$' "")
        case "$name" in
            bolt-panel) REPORT_PANEL_VERSION="$version" ;;
            bolt-agent) REPORT_AGENT_VERSION="$version" ;;
        esac
    done < <(_report_bounded rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}\n' bolt-panel bolt-agent 2>/dev/null </dev/null)
}

# Subshell helper: cd into this install's spool directory and make sure it,
# and the spool root, are this user's and private. The path alone is not
# trusted: the checks run on the directory actually entered.
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
        # Each install keeps its own receiver address: the resend script is
        # shared, and a later install aimed elsewhere must not redirect this one.
        mkdir -m 0700 events sent && printf '%s\n' "$REPORT_START" >started \
            && printf '%s\n' "$REPORT_URL" >url
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
# REPORT_FINAL_WAIT seconds, and never past the overall REPORT_BUDGET_MS.
_report_flush() {
    local id pid i running ticks
    ticks=$(((REPORT_BUDGET_MS - REPORT_SPENT_MS) / 100))
    ((ticks <= REPORT_FINAL_WAIT * 10)) || ticks=$((REPORT_FINAL_WAIT * 10))
    for id in "${!REPORT_EVENTS[@]}"; do
        if [[ "$REPORT_MODE" == spool ]]; then
            [[ -e "$REPORT_DIR/$INSTALL_ID/sent/$id" ]] && continue
        else
            [[ -n "${REPORT_LAUNCHED[$id]:-}" ]] && continue
        fi
        _report_send_bg "$id"
    done
    for ((i = 0; i < ticks; i++)); do
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
    local step="$1" outcome="$2" reason="${3:-}" class int_run=0
    # Whether this is the run of the step that absorbed a Ctrl+C; checked
    # before the current step is cleared.
    ((REPORT_INT_SEEN)) && _report_is_int_run "$step" && int_run=1
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
    # A package step that fails after the --source repository's metadata
    # could not be fetched failed on the mirror: reported as the repository
    # step (the package step is listed too). Only the report changes.
    if [[ -z "$REPORT_REASON" && ( "$step" == agent_install || "$step" == panel_install ) ]] && ((REPORT_REPO_UNREACHABLE)); then
        _report_in_list repo_setup "$REPORT_FAILED_REQUIRED" || REPORT_FAILED_REQUIRED+="${REPORT_FAILED_REQUIRED:+ }repo_setup"
        REPORT_FAILED_STEP="repo_setup"
        REPORT_REASON="repo_download_failed"
    fi
    if [[ "$class" == required ]]; then
        _report_in_list "$step" "$REPORT_FAILED_REQUIRED" || REPORT_FAILED_REQUIRED+="${REPORT_FAILED_REQUIRED:+ }$step"
    else
        step=""
    fi
    if [[ -z "$REPORT_REASON" ]]; then
        REPORT_FAILED_STEP="$step"
        REPORT_REASON="$reason"
        if ((int_run)); then REPORT_INT_CLAIMED=1; fi
    fi
    # A step other than the run that absorbed a Ctrl+C failed after it (also
    # a later run of the same step): a real failure, which the interruption
    # must not hide (see _report_finish). Optional steps never get here (they
    # return above), so only steps that decide the result count.
    if ((REPORT_INT_SEEN && !int_run && !REPORT_FAILED_AFTER_INT)); then
        REPORT_FAILED_AFTER_INT=1
        REPORT_AFTER_INT_STEP="$step"
        REPORT_AFTER_INT_REASON="$reason"
    fi
    REPORT_STAGE_RESULT="failed"
}

# TERM or HUP: succeeds only when it is known that the system is up and
# not shutting down, i.e. someone stopped the install. Anything else - a
# shutdown, or no answer - fails, and the install then reports nothing
# (no_result) rather than a cancellation it cannot prove.
# A shutdown is looked for first in files, without starting a process:
# while the system stops, systemd may kill every new process in the
# install's unit, and a systemctl started from here then dies before it
# answers (seen on reboots in E5: an empty answer after a few ms).
_report_operator_stop() {
    local f state
    for f in $REPORT_SHUTDOWN_MARKERS; do
        [[ -e "$f" ]] && return 1
    done
    command -v systemctl >/dev/null 2>&1 || return 1
    state=$(_report_bounded systemctl is-system-running 2>/dev/null </dev/null)
    case "$state" in
        initializing|starting|running|degraded|maintenance) return 0 ;;
    esac
    return 1
}

# The signal is recorded and the script exits through the EXIT trap, which
# reports it and then delivers the same signal again with its default action,
# so the script still ends killed by that signal, as it would without these
# traps. TERM or HUP is a cancellation only while the system is known to be
# up; during a shutdown, or when that cannot be told, nothing is reported
# and the attempt shows as no_result.
_report_on_signal() {
    local sig="$1"
    REPORT_SIGNAL="$sig"
    if [[ "$sig" != INT ]] && ! _report_timed _report_operator_stop; then REPORT_SUPPRESS=1; fi
    case "$sig" in INT) exit 130 ;; TERM) exit 143 ;; *) exit 129 ;; esac
}

# SIGINT as bash handles it without a trap: bash waits for the command in the
# foreground and stops only when that command was itself ended by SIGINT
# (status 130). A command that handles the interruption and returns normally
# lets the install carry on, as it did before. dnf is one: it catches Ctrl+C
# and exits 1. So the interruption is only remembered, with the step that
# took it: if the install then ends with an error caused there it is reported
# as cancelled (with the real exit code); if another step failed after it,
# that real failure is reported (failed); if it still succeeds, it is
# reported as it ended. The trap runs once the interrupted command has
# returned, before its step records the outcome, so REPORT_STEP is that step.
# The interruption belongs to that one run of the step (REPORT_STEP_RUN,
# counted up each time a step starts): a step can be started twice, as
# prerequisite_packages is, and a failure of its later run is a real one.
REPORT_INT_SEEN=0
REPORT_INT_STEP=""
REPORT_INT_RUN=-1
REPORT_INT_CLAIMED=0
REPORT_FAILED_AFTER_INT=0
REPORT_AFTER_INT_STEP=""
REPORT_AFTER_INT_REASON=""
_report_on_int() {
    local rc="$1"
    REPORT_INT_SEEN=1
    REPORT_INT_STEP="$REPORT_STEP"
    REPORT_INT_RUN="$REPORT_STEP_RUN"
    ((rc == 130)) || return 0
    _report_on_signal INT
}

# _report_is_int_run step: step is the one running now and this run of it
# absorbed the Ctrl+C.
_report_is_int_run() {
    [[ -n "$1" && "$1" == "$REPORT_INT_STEP" && "$1" == "$REPORT_STEP" && "$REPORT_STEP_RUN" == "$REPORT_INT_RUN" ]]
}

_report_finish() {
    local rc="$1" result failed_step reason sig_num=0
    case "$REPORT_SIGNAL" in INT) sig_num=2 ;; TERM) sig_num=15 ;; HUP) sig_num=1 ;; esac
    ((sig_num == 0)) || rc=$((128 + sig_num))
    if ((REPORT_SUPPRESS)); then
        _report_spool_mark_finished
        return 0
    fi
    local sig="$REPORT_SIGNAL" absorbed=0
    if [[ -z "$sig" ]] && ((REPORT_INT_SEEN && rc != 0)); then
        # An absorbed Ctrl+C ended the install as cancelled, unless another
        # step that is not optional failed after it: reported
        # (FAILED_AFTER_INT), or the step the script stopped in (set -e) is
        # not the run that took the Ctrl+C.
        absorbed=1
        if ((REPORT_FAILED_AFTER_INT)); then
            absorbed=0
        elif [[ -n "$REPORT_STEP" ]] && ! _report_is_int_run "$REPORT_STEP" \
            && [[ "$(report_step_class "$REPORT_STEP")" != optional ]]; then
            absorbed=0
        fi
    fi
    if [[ -n "$sig" ]] || ((absorbed)); then
        # An absorbed Ctrl+C is only reported; the exit code stays the script's.
        failed_step="$REPORT_STEP"
        if [[ -z "$sig" ]]; then failed_step="$REPORT_INT_STEP"; fi
        sig="${sig:-INT}"
        result="cancelled"
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
        # The first failure was the step that absorbed a Ctrl+C (it failed
        # because of it) and another step failed for real afterwards: that
        # one is the reason.
        if ((REPORT_INT_CLAIMED && REPORT_FAILED_AFTER_INT)); then
            REPORT_FAILED_STEP="$REPORT_AFTER_INT_STEP"
            REPORT_REASON="$REPORT_AFTER_INT_REASON"
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
    _report_pkg_versions
    local duration=$(($(date +%s) - REPORT_START))
    ((duration >= 0 && duration <= 86400)) || duration=0
    local trial
    trial=$(_report_clean "$REPORT_TRIAL" '^(ok|failed|skipped)$' "")
    _report_emit install_finished "\"result\":$(_report_json_str "$result"),\"failed_step\":$(_report_json_str "$failed_step"),\"reason\":$(_report_json_str "$reason"),\"exit_code\":${rc},\"signal\":$(_report_json_str "$sig"),\"failed_optional_steps\":$(_report_json_steps "$REPORT_FAILED_OPTIONAL"),\"failed_required_steps\":$(_report_json_steps "$REPORT_FAILED_REQUIRED"),\"panel_version\":$(_report_json_str "$REPORT_PANEL_VERSION"),\"agent_version\":$(_report_json_str "$REPORT_AGENT_VERSION"),\"trial_licence\":$(_report_json_str "$trial"),\"duration_s\":${duration}" final
    _report_spool_mark_finished
    REPORT_SPENT_MS=$((REPORT_SPENT_MS + $(_report_now_ms) - REPORT_FINISH_START))
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
    REPORT_FINISH_START=$(_report_now_ms)
    [[ "$REPORT_MODE" == off ]] || _report_finish "$rc" </dev/null >/dev/null 2>&1
    # AB-1379 QA finding 2: an install that stops early (a Stage 2 package
    # install, connecting bolt-agent to the panel) still lists the steps
    # that failed before it, which the closing summary never got to print.
    if ((rc != 0)) && [[ -z "$REPORT_SIGNAL" ]] && ((!SUMMARY_PRINTED)) && { [[ -n "$STOPPED_STEP" ]] || ((${#FAILED_STEPS[@]} > 0)); }; then
        echo -e ""
        print_failure_summary
        echo -e "${BOLD}${RED}Installation stopped early (exit status ${rc}).${NC}"
    fi
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
        printf '# or once nothing is left to send. The spool directory is kept.\n'
        printf 'SPOOL=%q\nDEFAULT_URL=%q\nUNIT_DIR=%q\nUNIT_NAME=%q\nSELF=%q\nOWNER_UID=%q\n' \
            "$REPORT_DIR" "$REPORT_DEFAULT_URL" "$REPORT_UNIT_DIR" "$REPORT_UNIT_NAME" "$dest" "$REPORT_OWNER_UID"
        # The pattern has no single quote, so it is written as it is.
        printf "URL_RE='%s'\n" "$REPORT_URL_RE"
        cat <<'SENDER'
umask 077
MAX_AGE=86400
now=${ADMINBOLT_REPORT_NOW:-$(date +%s)}
# Sending stops after this many seconds (the unit's TimeoutStartSec=300 is the
# hard stop); what is left waits for the next run.
deadline=$(($(date +%s) + ${ADMINBOLT_REPORT_RUN_BUDGET:-240}))

private_dir() { [ "$(stat -c '%u %a' "$1" 2>/dev/null)" = "$OWNER_UID 700" ]; }
valid_id() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; }
bounded() { if command -v timeout >/dev/null 2>&1; then timeout -k 1 2 "$@"; else "$@"; fi; }

# Run from the spool directory, in a subshell: tries every undelivered event
# of one install younger than 24 hours.
send_install() {
    local started f n code to
    cd -P "./$1" 2>/dev/null && private_dir . || return 0
    started=$(cat started 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] && ((now - started <= MAX_AGE)) || return 0
    # This install's own receiver, written once when it started.
    to=""
    { read -r to <url; } 2>/dev/null
    [[ "$to" =~ $URL_RE ]] || to=$DEFAULT_URL
    for f in events/*.json; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        n=${f#events/}
        n=${n%.json}
        [[ "$n" =~ ^[0-9]{1,2}$ ]] || continue
        [ -e "sent/$n" ] && continue
        (($(date +%s) < deadline)) || return 0
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
            -H 'Content-Type: application/json' --data-binary "@$f" "$to" </dev/null 2>/dev/null) || true
        # 2xx and 400/409/413 are final; 429, 507, 5xx and no answer are retried.
        if [[ "$code" =~ ^(2[0-9][0-9]|400|409|413)$ ]]; then : >"sent/$n"; fi
    done
    return 0
}

# Run from the spool directory, in a subshell: succeeds while this install,
# younger than 24 hours, is still running or has events not yet delivered.
needs_timer() {
    local started f n
    cd -P "./$1" 2>/dev/null && private_dir . || return 1
    started=$(cat started 2>/dev/null)
    [[ "$started" =~ ^[0-9]+$ ]] && ((now - started <= MAX_AGE)) || return 1
    [ -e finished ] || return 0
    for f in events/*.json; do
        [ -f "$f" ] || continue
        n=${f#events/}
        n=${n%.json}
        [ -e "sent/$n" ] || return 0
    done
    return 1
}

remove_self() {
    bounded systemctl disable --now "$UNIT_NAME.timer" </dev/null >/dev/null 2>&1
    rm -f "$UNIT_DIR/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.service"
    bounded systemctl daemon-reload </dev/null >/dev/null 2>&1
    rm -f "$SELF"
    rmdir "${SELF%/*}" 2>/dev/null
}

if cd -P "$SPOOL" 2>/dev/null && private_dir .; then
    # The installer takes the same lock to put the timer in place, so this run
    # never removes the timer of an install that has just started.
    if command -v flock >/dev/null 2>&1 && exec 9>>.lock; then
        flock -w 60 9 || exit 0
    fi
    for d in *; do
        valid_id "$d" && (send_install "$d")
    done
    # Looked at again, after sending: an install that started meanwhile
    # keeps the timer.
    for d in *; do
        valid_id "$d" && (needs_timer "$d") && exit 0
    done
fi
remove_self
exit 0
SENDER
    } >"$tmp" && chmod 0700 "$tmp" && mv -f "$tmp" "$dest" && return 0
    rm -f "$tmp"
    return 1
}

# In the background: it waits for a resend run that holds the spool lock, and
# systemd can be slow, neither of which the install should wait for.
_report_install_timer() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -d "$REPORT_UNIT_DIR" ]] || return 1
    (
        set +e
        if command -v flock >/dev/null 2>&1 && exec 9>>"$REPORT_DIR/.lock"; then
            flock -w 60 9
        fi
        _report_put_timer
    ) </dev/null >/dev/null 2>&1 &
    REPORT_PIDS+=" $!"
}

_report_put_timer() {
    _report_write_sender "$REPORT_SENDER" || return 1
    local svc="$REPORT_UNIT_DIR/$REPORT_UNIT_NAME.service" tim="$REPORT_UNIT_DIR/$REPORT_UNIT_NAME.timer"
    printf '[Unit]\nDescription=AdminBolt install report: resend undelivered events\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=%s\nTimeoutStartSec=300\nMemoryMax=64M\nCPUQuota=20%%\n' \
        "$REPORT_SENDER" >"$svc.tmp" && chmod 0644 "$svc.tmp" && mv -f "$svc.tmp" "$svc" || return 1
    # OnActiveSec covers this boot, OnBootSec the boots after a restart.
    printf '[Unit]\nDescription=AdminBolt install report: resend undelivered events every 15 minutes for 24 hours\n\n[Timer]\nOnBootSec=5min\nOnActiveSec=15min\nOnUnitActiveSec=15min\n\n[Install]\nWantedBy=timers.target\n' \
        >"$tim.tmp" && chmod 0644 "$tim.tmp" && mv -f "$tim.tmp" "$tim" || return 1
    _report_bounded systemctl daemon-reload </dev/null >/dev/null 2>&1
    _report_bounded systemctl enable --now "$REPORT_UNIT_NAME.timer" </dev/null >/dev/null 2>&1
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
        REPORT_URL=$(_report_clean "$ADMINBOLT_INSTALL_REPORT_URL" "$REPORT_URL_RE" "$REPORT_URL")
    fi
    INSTALL_ID=$(_report_new_uuid) || { INSTALL_ID=""; return 0; }
    REPORT_REV=$(_report_installer_rev)
    if [[ "$REPORT_EUID" -ne 0 ]]; then
        REPORT_MODE="deferred"
    elif [[ "$REPORT_CHANNEL" == image-build ]]; then
        # Building an image: what this run leaves on disk ends up on every
        # server booted from it. No spool and no timer (they would resend
        # the build's events from each of them); events are sent directly.
        REPORT_MODE="memory"
    else
        REPORT_OWNER_UID=$(id -u)
        if _report_spool_init; then
            REPORT_MODE="spool"
            _report_install_timer || true
        else
            REPORT_MODE="memory"
        fi
    fi
    trap '_report_on_int "$?"' INT
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

# sha256 of the machine ID in /etc/machine-id without white space (the file
# holds 32 hex characters and a newline), or nothing when it cannot be read
# or is empty. The panel computes the same value.
_report_machine_fingerprint() {
    local id h
    id=$(tr -d '[:space:]' <"$REPORT_MACHINE_ID_FILE" 2>/dev/null) || return 1
    [[ -n "$id" ]] || return 1
    h=$(printf '%s' "$id" | sha256sum 2>/dev/null | cut -c1-64) || return 1
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$h"
}

# The install ID goes into bolt-config.ini for the panel, with the machine's
# fingerprint: a server booted from an image of this one has another
# machine-id, and the panel then does not report under this install's ID.
# An image build writes no ID at all (every server from the image would
# share it; a server from such an image gets its own at first boot, AB-2068).
_report_write_panel_settings() {
    local machine
    if ((REPORT_NO_TELEMETRY)); then
        _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_TELEMETRY 0 \
            || echo -e "${YELLOW}WARNING:${NC} could not write BOLT_INSTALL_TELEMETRY=0 to ${REPORT_BOLT_CONFIG}; set it with: bolt-cli set-ini-settings BOLT_INSTALL_TELEMETRY 0"
    elif [[ -n "$INSTALL_ID" && "$REPORT_CHANNEL" != image-build ]]; then
        if machine=$(_report_machine_fingerprint); then
            _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_MACHINE "$machine" || true
        fi
        _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_ID "$INSTALL_ID" || true
    fi
}

_report_ready() {
    local states code
    # One bounded call; it prints one state per unit, in the order asked. The
    # services must all be "active" (with --without=mail, Postfix and Dovecot
    # are not expected), and the database server under one of its unit names
    # (AB-2331: mariadb, or mysqld / mysql for MySQL, such as cl-MySQL on
    # CloudLinux; MariaDB answers to all three). systemctl prints "inactive"
    # for a unit that does not exist.
    local -a units=(bolt-agent bolt-nginx bolt-php) db_units
    _report_in_list mail "$LEFT_OUT_COMPONENTS" || units+=(postfix dovecot)
    read -r -a db_units <<<"$DATABASE_UNITS"
    states=$(_report_bounded systemctl is-active "${units[@]}" "${db_units[@]}" </dev/null 2>/dev/null)
    [[ "$(printf '%s\n' "$states" | head -n "${#units[@]}" | grep -cx active)" -eq "${#units[@]}" ]] || return 1
    printf '%s\n' "$states" | tail -n "+$((${#units[@]} + 1))" | grep -qx active || return 1
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "$REPORT_PANEL_URL" </dev/null 2>/dev/null) || true
    [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}

_report_readiness_check() {
    [[ "$REPORT_MODE" != off ]] || return 0
    _report_stage_begin readiness
    report_step_start readiness
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
    _report_timed _report_init 2>/dev/null || true
    trap report_on_exit EXIT
}
report_stage_begin() { [[ "$REPORT_MODE" == off ]] || { _report_stage_end 2>/dev/null; _report_stage_begin "$1"; } || true; }
report_stage_end() { _report_stage_end 2>/dev/null || true; }
report_step_start() { REPORT_STEP="${1:-}"; REPORT_STEP_RUN=$((REPORT_STEP_RUN + 1)); }
report_step_result() { _report_step_result "$@" 2>/dev/null || true; }
# report_fail [step] [reason]: the step failed (default: the current one).
report_fail() { _report_step_result "${1:-$REPORT_STEP}" failed "${2:-}" 2>/dev/null || true; }
report_trial_licence() { REPORT_TRIAL="$1"; }
# AB-472: a step that waits for an external repository is reported like a
# failed optional step (the result becomes succeeded_with_warnings), never as
# the failure of a required one.
report_step_deferred() {
    {
        [[ "$REPORT_STEP" == "$1" ]] && REPORT_STEP=""
        [[ -n "$1" ]] || return 0
        _report_in_list "$1" "$REPORT_FAILED_OPTIONAL" || REPORT_FAILED_OPTIONAL+="${REPORT_FAILED_OPTIONAL:+ }$1"
        [[ "$REPORT_STAGE_RESULT" == failed ]] || REPORT_STAGE_RESULT="warnings"
    } 2>/dev/null || true
}
report_write_panel_settings() { _report_write_panel_settings 2>/dev/null || true; }
report_readiness_check() { _report_timed _report_readiness_check 2>/dev/null || true; }

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

# SELinux policy tooling without a policy store (AB-1379). With SELINUX=
# enforcing or permissive in /etc/selinux/config, every package step that
# manages SELinux policy runs semanage, which aborts with "SELinux policy is
# not managed or store cannot be accessed" when the store of the configured
# policy is missing - and the install used to go on without Postfix, Dovecot
# and Rspamd. Whether the store can be used is asked of semanage itself, not
# guessed from the kernel command line: selinux=0 with SELINUX=enforcing
# installs fine on a stock image, whose store is there (QA finding 1).
# Without semanage (a minimal image; it arrives with the packages) the
# store directory of the configured policy type is looked for instead.
# SELINUX=disabled, or no config at all, needs nothing. Paths overridable
# for tests.
check_selinux_state() {
    local config="${SELINUX_CONFIG_FILE:-/etc/selinux/config}" mode type out
    mode=$(sed -n 's/^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*//p' "$config" 2>/dev/null | tail -n 1 | tr -d '[:space:]"')
    case "$mode" in
        enforcing|permissive) ;;
        *) return 0 ;;
    esac
    type=$(sed -n 's/^[[:space:]]*SELINUXTYPE[[:space:]]*=[[:space:]]*//p' "$config" 2>/dev/null | tail -n 1 | tr -d '[:space:]"')
    type="${type:-targeted}"
    if command -v semanage >/dev/null 2>&1; then
        out=$(semanage login -l 2>&1) && return 0
        # Any other semanage failure is not this problem; the package steps report it.
        grep -qi 'not managed or store cannot be accessed' <<<"$out" || return 0
    elif [ -d "${SELINUX_STORE_ROOT:-/var/lib/selinux}/${type}/active" ]; then
        return 0
    fi
    print_error "${config} sets SELINUX=${mode}, but the SELinux policy store (${type}) cannot be used."
    echo "Package steps that manage SELinux policy fail in this state, so Postfix, Dovecot and Rspamd would not install."
    echo "Install the policy (dnf install selinux-policy-${type}), or set SELINUX=disabled in ${config} (this installer disables SELinux anyway), then run the installer again."
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
    # Distro: AlmaLinux 9, Rocky Linux 9 or CloudLinux 9
    local distro_info
    report_step_start check_os
    if ! distro_info=$(detect_distribution); then
        print_error "This script supports AlmaLinux 9, Rocky Linux 9 and CloudLinux 9 only. Current system is not supported."
        report_fail check_os unsupported_os
        exit 1
    fi
    DISTRO_ID="${distro_info%%|*}"
    print_success "Detected: $distro_info"
    # Required commands
    report_step_start check_commands
    if ! command -v curl >/dev/null 2>&1; then
        print_error "Required command not found: curl"
        report_fail check_commands missing_command
        exit 1
    fi
    check_port_8443
    report_step_start ""
    check_selinux_state
    probe_external_repositories
    # AB-2331: decided before anything is installed, and said once.
    database_skip_decide
    # AB-2106: a bad key stops the install here, before anything is changed.
    if [[ -n "$SSH_KEY_ARG" ]]; then
        # Reported as a bad argument, not as the port check that ran before it.
        report_step_start parse_arguments
        ssh_key_load || { report_fail parse_arguments invalid_argument; exit 1; }
        report_step_result parse_arguments ok
        print_success "SSH key checked ($(grep -c . <<<"$SSH_KEYS") key(s))"
    fi
    print_success "Stage 1 completed: ready for installation"
    print_progress "33% — prerequisites"
}

# Detect distribution: AlmaLinux 9, Rocky Linux 9 or CloudLinux 9 (AB-2331;
# a RHEL 9 rebuild, installed the same way). Prints ID|VERSION_ID. Read in a
# subshell, so os-release sets nothing in the installer's own shell.
detect_distribution() {
    [ -f "$OS_RELEASE_FILE" ] || return 1
    (
        ID="" VERSION_ID=""
        # shellcheck disable=SC1090
        . "$OS_RELEASE_FILE" >/dev/null 2>&1 || exit 1
        case "$ID" in
            almalinux|rocky|cloudlinux) ;;
            *) exit 1 ;;
        esac
        [[ "$VERSION_ID" =~ ^9(\.[0-9]*)?$ ]] || exit 1
        echo "${ID}|${VERSION_ID}"
    )
}

# ---------- SSH key and password login (AB-2106) ----------
# --ssh-key= adds root's key in Stage 2.1 and turns SSH password login for
# root off at the very end, but only once sshd has logged a root sign-in with
# that key after every install step that configures sshd, and its effective
# settings for that client still let root in with the key. Anything short of
# that keeps password login on and says why: the customer must never be
# locked out of their own server. Other users (hosting accounts) keep their
# password login, and root login itself stays under the panel's SSH settings.

# Read --ssh-key= into SSH_KEYS / SSH_KEY_FPS. Every non-comment line must be
# a plain public key: no authorized_keys options (command=, from=, ...).
ssh_key_load() {
    local raw line tmp fp keys="" fps=""
    local key_re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*( [^[:cntrl:]]*)?$'
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        print_error "ssh-keygen not found; cannot check --ssh-key"
        return 1
    fi
    if [[ "$SSH_KEY_ARG" == https://* ]]; then
        if ! raw=$(curl -fsSL --proto =https --proto-redir =https --max-time 30 "$SSH_KEY_ARG"); then
            print_error "Could not download the SSH key from ${SSH_KEY_ARG}"
            return 1
        fi
    elif [[ "$SSH_KEY_ARG" == *://* ]]; then
        print_error "--ssh-key takes a public key or an https:// URL"
        return 1
    else
        raw="$SSH_KEY_ARG"
    fi
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line" >"$tmp"
        if [[ ! "$line" =~ $key_re ]] || ! fp=$(ssh-keygen -l -E sha256 -f "$tmp" 2>/dev/null | awk '{print $2}') || [[ -z "$fp" ]]; then
            rm -f "$tmp"
            print_error "--ssh-key: not an SSH public key: ${line:0:60} (put the whole key in quotes: --ssh-key=\"ssh-ed25519 AAAA... comment\")"
            return 1
        fi
        keys+="${line}"$'\n'
        fps+="${fp}"$'\n'
    done <<<"$raw"
    rm -f "$tmp"
    if [[ -z "$keys" ]]; then
        print_error "--ssh-key: no SSH public key found"
        return 1
    fi
    SSH_KEYS="$keys"
    SSH_KEY_FPS="$fps"
}

# 0 when key line $1 is in authorized_keys file $2 as a plain line (type and key first; the comment is ignored).
ssh_key_present() {
    local type b64
    read -r type b64 _ <<<"$1"
    [[ -f "$2" ]] && awk -v t="$type" -v k="$b64" '$1 == t && $2 == k { f = 1 } END { exit !f }' "$2"
}

# 0 when key line $1 also appears in file $2 behind options (command=, from=, restrict, ...):
# a sign-in with it can succeed and still give no shell, so it proves nothing.
ssh_key_restricted() {
    local type b64
    read -r type b64 _ <<<"$1"
    [[ -f "$2" ]] && awk -v t="$type" -v k="$b64" '$1 !~ /^#/ { for (i = 2; i < NF; i++) if ($i == t && $(i + 1) == k) f = 1 } END { exit !f }' "$2"
}

# Root's AuthorizedKeysFile paths from `sshd -T` output $1, one per line, with %h, %u, %U and %%
# expanded as sshd does and relative paths under root's home. 1 when the list cannot be worked out.
ssh_root_key_files() {
    local v f home
    local -a files
    home=$(getent passwd root 2>/dev/null | cut -d: -f6)
    v=$(sshd_value authorizedkeysfile "$1")
    [[ -n "$home" && -n "$v" ]] || return 1
    read -ra files <<<"$v"
    for f in "${files[@]}"; do
        [[ "$f" == none ]] && continue
        f=${f//"%%"/$'\001'}
        f=${f//"%h"/$home}
        f=${f//"%u"/root}
        f=${f//"%U"/0}
        [[ "$f" != *%* ]] || return 1
        f=${f//$'\001'/%}
        [[ "$f" == /* ]] || f="$home/$f"
        printf '%s\n' "$f"
    done
}

# Why a sign-in with the key may give no shell under `sshd -T` output $1; empty when it cannot.
# sshd takes the first file that lists the key, so the key behind options (command=, restrict,
# no-pty, ...) in any of root's key files, or keys from a command, means the log proves nothing.
ssh_key_restriction_blocker() {
    local v files f line
    v=$(sshd_value authorizedkeyscommand "$1")
    [[ -z "$v" || "$v" == none ]] || { echo "sshd also takes root's keys from AuthorizedKeysCommand ${v}"; return; }
    files=$(ssh_root_key_files "$1") || { echo "could not work out root's AuthorizedKeysFile list"; return; }
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if ssh_key_restricted "$line" "$f"; then
                echo "${f} also lists the key with restrictions (command=, restrict, no-pty, ...)"
                return
            fi
        done <<<"$SSH_KEYS"
    done <<<"$ROOT_AUTHORIZED_KEYS"$'\n'"$files"
}

ssh_keys_in_place() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        ssh_key_present "$line" "$ROOT_AUTHORIZED_KEYS" || return 1
    done <<<"$SSH_KEYS"
}

# Stage 2.1: add the keys to root's authorized_keys; keys already there are kept as they are.
ssh_key_install() {
    [[ -n "$SSH_KEYS" ]] || return 0
    local dir line added=0
    dir=$(dirname "$ROOT_AUTHORIZED_KEYS")
    if ! { mkdir -p "$dir" && chmod 700 "$dir" && touch "$ROOT_AUTHORIZED_KEYS" && chmod 600 "$ROOT_AUTHORIZED_KEYS"; }; then
        print_error "Could not prepare ${ROOT_AUTHORIZED_KEYS}"
        exit 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        ssh_key_present "$line" "$ROOT_AUTHORIZED_KEYS" && continue
        # A file without a final newline would glue the new key onto its last line.
        [[ -s "$ROOT_AUTHORIZED_KEYS" && -n "$(tail -c1 "$ROOT_AUTHORIZED_KEYS")" ]] && echo >>"$ROOT_AUTHORIZED_KEYS"
        printf '%s\n' "$line" >>"$ROOT_AUTHORIZED_KEYS"
        added=$((added + 1))
    done <<<"$SSH_KEYS"
    chown root:root "$dir" "$ROOT_AUTHORIZED_KEYS" 2>/dev/null || true
    command -v restorecon >/dev/null 2>&1 && { restorecon -R "$dir" >/dev/null 2>&1 || true; }
    if ! ssh_keys_in_place; then
        print_error "The SSH key is not in ${ROOT_AUTHORIZED_KEYS} after writing it"
        exit 1
    fi
    print_success "SSH key in ${ROOT_AUTHORIZED_KEYS} (${added} added)"
}

# Effective sshd settings for root connecting from address $1.
sshd_effective_for_root() {
    sshd -T -C "user=root,host=$1,addr=$1" 2>/dev/null
}

# Value of setting $1 in `sshd -T` output $2 (first line only; empty when absent).
sshd_value() {
    awk -v k="$1" 'tolower($1) == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$2"
}

# Why root cannot sign in with a key under `sshd -T` output $1; empty when it can.
ssh_root_key_login_blocker() {
    local cfg="$1" v
    [[ -n "$cfg" ]] || { echo "sshd -T did not run"; return; }
    v=$(sshd_value permitrootlogin "$cfg")
    case "$v" in yes|prohibit-password|without-password) ;; *) echo "root login over SSH is not allowed (PermitRootLogin ${v:-unset})"; return ;; esac
    v=$(sshd_value pubkeyauthentication "$cfg")
    [[ "$v" == yes ]] || { echo "key login is off (PubkeyAuthentication ${v:-unset})"; return; }
    v=$(sshd_value authorizedkeysfile "$cfg")
    [[ " $v " == *.ssh/authorized_keys\ * ]] || { echo "sshd does not read .ssh/authorized_keys (AuthorizedKeysFile ${v:-unset})"; return; }
    v=$(sshd_value authenticationmethods "$cfg")
    [[ -z "$v" || "$v" == any || "$v" == publickey ]] || { echo "sshd requires more than a key (AuthenticationMethods ${v})"; return; }
    v=$(sshd_value forcecommand "$cfg")
    [[ -z "$v" || "$v" == none ]] || { echo "root's SSH sessions are forced to run ${v}"; return; }
    ssh_key_restriction_blocker "$cfg"
}

# Set SSH_KEY_LOGIN_ADDR to the client address of the latest root sign-in with one of the keys
# that sshd logged since epoch second $1. The whole message must match: a login name is logged
# as typed in failed attempts, so a partial match could be forged from the network.
ssh_key_login_seen() {
    local addr
    addr=$(journalctl -q --no-pager -o cat -u sshd --since "@$1" 2>/dev/null | awk -v fps="$SSH_KEY_FPS" '
        BEGIN { n = split(fps, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
        /^Accepted publickey for root from [0-9A-Fa-f.:]+ port [0-9]+ ssh2: [A-Z0-9-]+ SHA256:[A-Za-z0-9+\/]+$/ && ($NF in want) { last = $6 }
        END { print last }')
    [[ -n "$addr" ]] || return 1
    SSH_KEY_LOGIN_ADDR="$addr"
}

# At a terminal, ask for a sign-in with the key and wait for sshd to log it. 1 = skipped, timed out or no terminal.
ssh_key_login_wait() {
    { exec 3<"$SSH_KEY_TTY"; } 2>/dev/null || return 1
    local ip port deadline rc
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    port=$(sshd_value port "$(sshd_effective_for_root 127.0.0.1)")
    echo -e "\n${BOLD}${CYAN}--- Check your SSH key before password login for root is turned off ---${NC}"
    echo -e "Keep this session open. From a new terminal, sign in with your key:"
    echo -e "  ${BOLD}ssh -p ${port:-22} root@${ip:-<this-server-ip>}${NC}"
    echo -e "Waiting up to $((SSH_KEY_LOGIN_WAIT / 60)) minutes for that sign-in. Press Enter to skip and keep password login on."
    deadline=$(($(date +%s) + SSH_KEY_LOGIN_WAIT))
    while (($(date +%s) < deadline)); do
        if ssh_key_login_seen "$SSH_KEY_PROOF_SINCE"; then
            exec 3<&-
            print_success "Sign-in with your key seen from ${SSH_KEY_LOGIN_ADDR}"
            return 0
        fi
        # Enter or a closed terminal ends the wait; only a timeout (status > 128) keeps it going.
        rc=0
        read -r -t 5 -u 3 _ || rc=$?
        ((rc > 128)) || break
    done
    exec 3<&-
    return 1
}

# Password login was not changed: say why, and what sshd actually does for root now.
ssh_password_kept() {
    local now
    now=$(sshd_value passwordauthentication "$(sshd_effective_for_root 127.0.0.1)")
    if [[ "$now" == no ]]; then
        SSH_PASSWORD_NOTE="${YELLOW}NOTE:${NC} The installer did not change SSH password login for root ($1); sshd already has it off. Your key is in ${ROOT_AUTHORIZED_KEYS}.\n"
        echo -e "${YELLOW}WARNING:${NC} SSH password login for root not changed: $1"
        return 0
    fi
    SSH_PASSWORD_NOTE="${YELLOW}NOTE:${NC} SSH password login for root left ON: $1. Your key is in ${ROOT_AUTHORIZED_KEYS}. After you sign in with it, turn password login for root off with:\n  ${BOLD}printf 'Match User root\\\\n    PasswordAuthentication no\\\\n    KbdInteractiveAuthentication no\\\\n' > ${SSHD_KEY_ONLY_DROP_IN} && sshd -t && systemctl reload sshd${NC}\n"
    echo -e "${YELLOW}WARNING:${NC} SSH password login for root left on: $1"
}

# Put the drop-in back as it was ($1 = saved copy, or empty when there was none) and reload when $2 = reload.
# Never fails: a copy that cannot be put back is removed rather than left half-written.
ssh_drop_in_restore() {
    if [[ -n "$1" ]]; then
        mv -f "$1" "$SSHD_KEY_ONLY_DROP_IN" 2>/dev/null || rm -f "$SSHD_KEY_ONLY_DROP_IN" "$1" 2>/dev/null || true
    else
        rm -f "$SSHD_KEY_ONLY_DROP_IN" 2>/dev/null || true
    fi
    if [[ "${2:-}" == reload ]]; then systemctl reload sshd >/dev/null 2>&1 || true; fi
    return 0
}

# End of Stage 3: turn SSH password login for root off once the key is proven. Never fatal.
ssh_password_login_off() {
    [[ -n "$SSH_KEYS" ]] || return 0
    print_info "SSH: turning password login for root off (--ssh-key)"
    local blocker saved="" tmp cfg
    # Only a sign-in from now on counts: it ran under the sshd settings the install left behind.
    SSH_KEY_PROOF_SINCE=$(date +%s)
    if ! ssh_keys_in_place; then
        ssh_password_kept "the key is no longer in ${ROOT_AUTHORIZED_KEYS}"
        return 0
    fi
    # Also checks every file sshd reads root's keys from for the key behind options.
    blocker=$(ssh_root_key_login_blocker "$(sshd_effective_for_root 127.0.0.1)")
    if [[ -n "$blocker" ]]; then
        ssh_password_kept "$blocker"
        return 0
    fi
    if ! ssh_key_login_wait; then
        ssh_password_kept "no sign-in with the key was seen after the installer set up SSH"
        return 0
    fi
    # The settings for the address the key was used from, not only for localhost.
    blocker=$(ssh_root_key_login_blocker "$(sshd_effective_for_root "$SSH_KEY_LOGIN_ADDR")")
    if [[ -n "$blocker" ]]; then
        ssh_password_kept "$blocker (for ${SSH_KEY_LOGIN_ADDR})"
        return 0
    fi
    if [[ -e "$SSHD_KEY_ONLY_DROP_IN" ]]; then
        saved="${SSHD_KEY_ONLY_DROP_IN}.saved.$$"
        if ! cp -p "$SSHD_KEY_ONLY_DROP_IN" "$saved"; then ssh_password_kept "could not back up ${SSHD_KEY_ONLY_DROP_IN}"; return 0; fi
    fi
    # Written next to the target under a name sshd does not read (*.conf only), then moved into place.
    tmp="${SSHD_KEY_ONLY_DROP_IN}.new.$$"
    if ! {
        printf '# Written by install.sh --ssh-key (AB-2106). Remove this file and reload sshd to allow SSH password login for root again.\n'
        printf 'Match User root\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n'
    } >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$SSHD_KEY_ONLY_DROP_IN"; then
        rm -f "$tmp"
        ssh_drop_in_restore "$saved"
        ssh_password_kept "could not write ${SSHD_KEY_ONLY_DROP_IN}"
        return 0
    fi
    if ! sshd -t >/dev/null 2>&1; then
        ssh_drop_in_restore "$saved"
        ssh_password_kept "sshd -t refused the new setting"
        return 0
    fi
    cfg=$(sshd_effective_for_root "$SSH_KEY_LOGIN_ADDR") || cfg=""
    blocker=$(ssh_root_key_login_blocker "$cfg")
    if [[ -n "$blocker" || "$(sshd_value passwordauthentication "$cfg")" != no || "$(sshd_value kbdinteractiveauthentication "$cfg")" != no ]]; then
        ssh_drop_in_restore "$saved"
        ssh_password_kept "another sshd setting overrides ${SSHD_KEY_ONLY_DROP_IN}${blocker:+ ($blocker)}"
        return 0
    fi
    if ! systemctl reload sshd >/dev/null 2>&1; then
        ssh_drop_in_restore "$saved" reload
        ssh_password_kept "sshd did not reload"
        return 0
    fi
    rm -f "$saved"
    SSH_PASSWORD_NOTE="${GREEN}SSH:${NC} password login for root is off; root signs in with your key. Other users are not changed. To allow passwords again: ${BOLD}rm ${SSHD_KEY_ONLY_DROP_IN} && systemctl reload sshd${NC}\n"
    print_success "SSH password login for root turned off"
}

# ---------- Stage 2: Install base packages ----------
# Write bolt / bolt-noarch repos for a pulp content tier (stable, staging, testing).
#
# Priorities below dnf's default of 99 (lower wins, AB-1407): the AdminBolt
# repositories carry their own builds of packages the distribution also ships
# (httpd, httpd-core, ...), and with the previous 300/400 every such name
# resolved to appstream/baseos instead - hosts ran the distribution Apache.
install_bolt_repos_from_source() {
    local tier="$1"
    local repofile="$BOLT_REPO_FILE"
    print_info "Configuring Bolt repositories (source=${tier})..."
    cat >"$repofile" <<EOF
[bolt]
name = Adminbolt RHEL - \$releasever - \$basearch
baseurl = https://mirror.adminbolt.com/pulp/content/${tier}/rhel/\$releasever/\$basearch
enabled = 1
gpgcheck = 0
priority = 30
sslverify = 0

[bolt-noarch]
name = Adminbolt RHEL - \$releasever - noarch
baseurl = https://mirror.adminbolt.com/pulp/content/${tier}/rhel/\$releasever/noarch
enabled = 1
gpgcheck = 0
priority = 40
sslverify = 0
EOF
    print_success "Repository file written: ${repofile}"
}

# Install report only: fetches the metadata index (repodata/repomd.xml) of
# every baseurl in the repository file just written, with dnf's $releasever
# and $basearch filled in; REPORT_PROBE_CAP seconds at most in total. Nothing
# is printed and the install goes on either way; a package step that fails
# afterwards is then reported as repo_download_failed instead of a package
# failure.
report_probe_source_repos() {
    local el_version="$1" arch url start left connect
    [[ "$REPORT_MODE" != off ]] || return 0
    arch=$(uname -m 2>/dev/null)
    start=$(date +%s)
    while read -r url; do
        [[ -n "$url" ]] || continue
        url="${url//\$releasever/$el_version}"
        url="${url//\$basearch/$arch}"
        left=$((REPORT_PROBE_CAP - ($(date +%s) - start)))
        connect=3
        ((left < connect)) && connect=$left
        if ((left < 1)) || ! curl -f -s -k -o /dev/null --connect-timeout "$connect" --max-time "$left" \
            "${url%/}/repodata/repomd.xml" </dev/null >/dev/null 2>&1; then
            REPORT_REPO_UNREACHABLE=1
            return 0
        fi
    done < <(sed -n 's/^[[:space:]]*baseurl[[:space:]]*=[[:space:]]*//p' "$BOLT_REPO_FILE" 2>/dev/null)
}

install_repo_rhel() {
    local el_version=$1 rc
    if [[ -n "$BOLT_SOURCE" ]]; then
        install_bolt_repos_from_source "$BOLT_SOURCE"
        report_probe_source_repos "$el_version" || true
        return 0
    fi
    local rpm_url="${REPO_BASE_URL}/rhel/${el_version}/noarch/Packages/b/${REPO_PACKAGE}.el${el_version}.noarch.rpm"
    local temp_rpm="/tmp/bolt-repo-${el_version}.rpm"
    print_info "Downloading repository package..."
    curl -f -L -k -o "$temp_rpm" "$rpm_url" || { print_error "Failed to download repo"; STOPPED_STEP="Bolt repository: ${rpm_url} could not be downloaded"; report_fail repo_setup repo_download_failed; exit 1; }
    # A failed install of the downloaded package stops the script as before
    # (with rpm's exit code), reported as a package failure.
    (command -v dnf >/dev/null 2>&1 && dnf install -y "$temp_rpm") || (command -v yum >/dev/null 2>&1 && yum install -y "$temp_rpm") || rpm -ivh "$temp_rpm" \
        || { rc=$?; STOPPED_STEP="Bolt repository: the repository package did not install"; report_fail repo_setup package_install_failed; exit "$rc"; }
    rm -f "$temp_rpm"
    rank_bolt_repos "$BOLT_REPO_FILE"
    print_success "Repository installed"
}

# bolt-repo up to 1.0.7 ships priorities 100 to 400, which lose to dnf's
# default 99, so a fresh server took httpd from appstream instead of the
# AdminBolt repositories (AB-1407). Same values as bolt-agent's
# POST /api/system/repos/bolt and the panel upgrade step; a file that already
# has them (bolt-repo 1.0.8) is left untouched.
rank_bolt_repos() {
    local repo=$1 tmp
    [[ -f "$repo" ]] || return 0
    tmp=$(mktemp "${repo%/*}/.bolt.repo.XXXXXX") || return 0
    awk '/^\[/{sec=$0}
        /^[[:space:]]*priority[[:space:]]*=/{
            if (sec=="[bolt-cdn]") {print "priority = 10"; next}
            if (sec=="[bolt-noarch-cdn]") {print "priority = 20"; next}
            if (sec=="[bolt]") {print "priority = 30"; next}
            if (sec=="[bolt-noarch]") {print "priority = 40"; next}
            if (sec ~ /^\[bolt/) {print "priority = 50"; next}
        }
        {print}' "$repo" >"$tmp" || { rm -f "$tmp"; return 0; }
    # Plain bash comparison: a minimal server has no cmp (diffutils).
    if [[ "$(<"$repo")" == "$(<"$tmp")" ]]; then
        rm -f "$tmp"
    else
        chmod 0644 "$tmp" && mv -f "$tmp" "$repo" && print_success "Bolt repository priorities set below dnf's default"
    fi
}

# Single package install helper: dnf or yum only (AlmaLinux). Skips already-installed. Optional leading args: dnf opts (e.g. --enablerepo=bolt, --exclude=bolt-bootstrap).
install_packages() {
    local dnf_opts=()
    while [[ $# -gt 0 && "$1" == --* ]]; do dnf_opts+=("$1"); shift; done
    [[ $# -eq 0 ]] && return 0
    local missing=()
    for p in "$@"; do rpm -q "$p" &>/dev/null || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && { print_success "Packages already installed"; return 0; }
    # Pick the package manager once: chaining dnf || yum reran a failed install
    # through yum and then reported "dnf/yum not found", hiding dnf's error.
    local pm
    if command -v dnf >/dev/null 2>&1; then pm=dnf
    elif command -v yum >/dev/null 2>&1; then pm=yum
    else print_error "dnf/yum not found"; report_fail; exit 1
    fi
    "$pm" install -y "${dnf_opts[@]}" "${missing[@]}" || {
        local status=$?
        print_error "Installing packages failed ($pm exit $status): ${missing[*]}. See $pm's output above."
        STOPPED_STEP="Packages ${missing[*]}: $pm exit $status"
        report_fail
        exit "$status"
    }
    print_success "Packages installed"
}

# ---------------------------------------------------------------------------
# Optional components (--without=)
#
# A small server can leave out whole components. Each one is a set of Stage 3
# steps, skipped together, because their parts only work together: Postfix
# hands mail to Dovecot, its submission ports refuse mail while Rspamd is
# missing (milter_default_action=tempfail), webmail (Roundcube) and the
# system e-mail account need both. A skipped step is not run and not reported
# as a result, so the install report does not count it as a failure. The
# panel computes each service's Installed state on the server, so every
# skipped service shows as not installed on Health > Services. Install there
# sets up the package only, not its profiles, so the end of the install
# prints the skipped commands themselves: run in that order, they add the
# component later.
# ---------------------------------------------------------------------------
readonly OPTIONAL_COMPONENTS="mail dns ftp"

# Stage 3 step ids of an optional component.
component_steps() {
    case "$1" in
        mail) echo "postfix dovecot rspamd mlmmj postfix_profiles dovecot_profiles rspamd_profiles rspamd_restart system_email app_roundcube" ;;
        dns) echo "powerdns" ;;
        ftp) echo "vsftpd vsftpd_profile" ;;
    esac
}

# What leaving a component out takes away, for --help and the end of the install.
component_description() {
    case "$1" in
        mail) echo "mail: Postfix, Dovecot, Rspamd (spam filter), MLMMJ (mailing lists), Roundcube webmail and the system e-mail account - no mailboxes or webmail, and the panel's own e-mail (alerts, password resets) is not sent" ;;
        dns) echo "dns: PowerDNS - the server answers no DNS queries, so domains need DNS hosted elsewhere" ;;
        ftp) echo "ftp: vsftpd - no FTP accounts; files can still be managed in the panel's file manager" ;;
    esac
}

# Sets LEFT_OUT_COMPONENTS from a comma-separated list. Every item must be a
# known component; an empty list or item, or an unknown one, is refused
# (returns 1, LEFT_OUT_COMPONENTS unchanged) rather than installing more or
# less than was asked for.
set_left_out_components() {
    local list="$1" item component chosen=" " result=""
    # Lower-case names and commas only: nothing else can name a component,
    # and a newline would end the split below early.
    [[ "$list" =~ ^[a-z,]+$ ]] || return 1
    # A trailing comma would otherwise vanish in the split below.
    [[ "$list" != *, ]] || return 1
    local -a items
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        _report_in_list "$item" "$OPTIONAL_COMPONENTS" || return 1
        chosen+="$item "
    done
    for component in $OPTIONAL_COMPONENTS; do
        [[ "$chosen" == *" $component "* ]] && result+="${result:+ }$component"
    done
    LEFT_OUT_COMPONENTS="$result"
}

# Prints the left-out component a Stage 3 step belongs to; returns 1 when the
# step is to run.
left_out_component_of_step() {
    local step="$1" component
    for component in $LEFT_OUT_COMPONENTS; do
        if _report_in_list "$step" "$(component_steps "$component")"; then
            printf '%s' "$component"
            return 0
        fi
    done
    return 1
}

# Returns 0 (after saying so, and keeping the command for the end of the
# install) when the step belongs to a left-out component.
skip_left_out_step() {
    local step="$1" desc="$2" cmd="$3" component
    component=$(left_out_component_of_step "$step") || return 1
    SKIPPED_COMMANDS+=("$component $cmd")
    print_info "${desc}: skipped (--without=${component})"
    echo -e ""
    return 0
}

# The choice is kept for the panel in bolt-config.ini, next to the install
# ID: only the installer knows that a service is missing because it was
# left out. Written on every install, empty when nothing was left out, so a
# reinstall that puts everything back leaves no old list behind.
write_left_out_components() {
    local value="${LEFT_OUT_COMPONENTS// /,}"
    _report_ini_set "$REPORT_BOLT_CONFIG" BOLT_INSTALL_WITHOUT "$value" \
        || echo -e "${YELLOW}WARNING:${NC} could not write BOLT_INSTALL_WITHOUT=${value} to ${REPORT_BOLT_CONFIG}; set it with: bolt-cli set-ini-settings BOLT_INSTALL_WITHOUT ${value:-\"\"}"
}

print_left_out_components() {
    local component
    [[ -n "$LEFT_OUT_COMPONENTS" ]] || return 0
    echo -e "${YELLOW}NOTE:${NC} Left out at your request (--without):"
    for component in $LEFT_OUT_COMPONENTS; do
        echo "  - $(component_description "$component")"
    done
    echo "To add one later, run the commands skipped for it as root, in this order:"
    local entry
    for component in $LEFT_OUT_COMPONENTS; do
        echo "  ${component}:"
        for entry in "${SKIPPED_COMMANDS[@]}"; do
            [[ "${entry%% *}" == "$component" ]] && echo "    ${entry#* }"
        done
    done
    echo -e ""
}

# EPEL from the distribution's own repositories (AlmaLinux and Rocky ship
# epel-release in extras). AB-2331: when the distribution does not offer it
# (CloudLinux 9 may not), the release package straight from the Fedora
# project, which configures the same repositories.
install_epel_release() {
    rpm -q epel-release &>/dev/null && return 0
    if dnf -q list epel-release &>/dev/null; then
        install_packages epel-release
    else
        print_info "epel-release is not in the ${DISTRO_ID:-system} repositories; installing it from ${EPEL_RELEASE_URL}"
        install_packages "$EPEL_RELEASE_URL"
    fi
}

# The repository ids of CodeReady Builder: "crb" on AlmaLinux and Rocky;
# CloudLinux names its own (AB-2331), so the ids are looked up. Debug and
# source repositories are left out; "crb" when nothing is found, as before.
crb_repo_ids() {
    local ids
    ids=$(dnf -q repolist --all 2>/dev/null | awk '
        { id = $1; lid = tolower(id) }
        id ~ /^[A-Za-z0-9._:-]+$/ && lid ~ /(^|[-_.])(crb|powertools)$|codeready-builder/ && lid !~ /debug|source/ { print id }
    ' | sort -u | tr '\n' ' ')
    ids="${ids% }"
    printf '%s' "${ids:-crb}"
}

# $3 (optional) = step id for the install report.
# STEP_REPOSITORY (set just before the call, cleared by it) = the external
# repository the step installs from ("remi"): when the step fails because
# that repository cannot be reached, it is deferred (AB-472) instead of
# failed. A variable, not a fourth argument: the step id stays the last word
# of the call, where the install report's tests look for it.
STEP_REPOSITORY=""
run_or_warn() {
    local cmd="$1" desc="${2:-Command}" step="${3:-}" repository="$STEP_REPOSITORY" out rc=0
    STEP_REPOSITORY=""
    LAST_STEP_RESULT=skipped
    skip_left_out_step "$step" "$desc" "$cmd" && return 0
    print_info "$desc"
    report_step_start "$step"
    out=$(mktemp)
    # tee through a process substitution rather than a pipe: the command still
    # runs in this shell, so an assignment it makes survives, and its output
    # still streams live while a copy is kept for the summary (AB-1379).
    eval "$cmd" > >(tee "$out") 2>&1 || rc=$?
    wait $! 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        print_success "$desc completed"; report_step_result "$step" ok
        LAST_STEP_RESULT=ok
    elif [[ -n "$repository" ]] && step_waits_for_repository "$repository" "$out"; then
        echo -e "${YELLOW}NOTE:${NC} $desc deferred: the $(repository_name "$repository") cannot be reached right now. The panel installs it on its own as soon as the repository answers (continuing)"
        report_step_deferred "$step"
        DEFERRED_STEPS+=("${desc}: waits for the $(repository_name "$repository")")
        LAST_STEP_RESULT=deferred
    else
        echo -e "${YELLOW}WARNING:${NC} $desc failed (continuing)"; report_step_result "$step" failed
        record_failure "$desc" "$out"
        LAST_STEP_RESULT=failed
    fi
    rm -f "$out"
    echo -e ""
}

# ---------- External package repositories (AB-472) ----------
# The panel itself comes from the AdminBolt repositories; PHP for websites
# comes from Remi, the database server from MariaDB, many prerequisites from
# EPEL. None of them is ours, and an outage of one used to stop an install
# half way. Each is probed once in Stage 1 (said, never fatal); a step that
# then fails because Remi cannot be reached is deferred and finished by the
# panel later.

repository_name() {
    case "$1" in
        remi) echo "Remi package repository" ;;
        epel) echo "EPEL package repository" ;;
        mariadb) echo "MariaDB package repository" ;;
        *) echo "$1 package repository" ;;
    esac
}

# URLs that answer when the repository can be used: any one is enough. Remi:
# its mirror list host and the fallback mirrors bolt-agent configures.
repository_probe_urls() {
    case "$1" in
        remi) echo "http://cdn.remirepo.net/enterprise/9/safe/x86_64/mirror https://rpms.remirepo.net/enterprise/9/safe/x86_64/repodata/repomd.xml https://mirror.23m.com/remi/enterprise/9/safe/x86_64/repodata/repomd.xml https://mirrors.ukfast.co.uk/sites/remi/enterprise/9/safe/x86_64/repodata/repomd.xml https://mirror.team-cymru.com/remi/enterprise/9/safe/x86_64/repodata/repomd.xml" ;;
        epel) echo "https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=x86_64 https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/repodata/repomd.xml" ;;
        mariadb) echo "https://mirror.mariadb.org/yum/ https://mirrors.gigenet.com/mariadb/yum/ https://archive.mariadb.org/" ;;
    esac
}

# Whether any address of the repository answers; at most a few seconds each.
repository_reachable() {
    local url
    for url in $(repository_probe_urls "$1"); do
        curl -fsS -o /dev/null --connect-timeout 4 --max-time 8 "$url" </dev/null >/dev/null 2>&1 && return 0
    done
    return 1
}

# A failed step waits for the repository when bolt-agent said so (reason code
# remi_repository_unreachable, from bolt-agent with AB-472), or - an agent that
# predates it - when the step's output names the repository and the
# repository does not answer now either.
step_waits_for_repository() {
    local repository="$1" out="$2"
    case "$repository" in
        remi)
            grep -qiE 'remi_repository_unreachable|Remi repository unreachable' "$out" 2>/dev/null && return 0
            grep -qiE "remirepo\.net|repo '?remi" "$out" 2>/dev/null && ! repository_reachable remi && return 0
            ;;
    esac
    return 1
}

# Stage 1: says which external repositories do not answer, before anything
# is installed. Never stops the install; the three run side by side.
probe_external_repositories() {
    local name dir
    dir=$(mktemp -d) || return 0
    for name in remi epel mariadb; do
        { repository_reachable "$name" || : >"$dir/$name"; } &
    done
    wait
    UNREACHABLE_REPOSITORIES=()
    for name in remi epel mariadb; do
        [[ -e "$dir/$name" ]] && UNREACHABLE_REPOSITORIES+=("$name")
    done
    rm -rf "$dir"
    ((${#UNREACHABLE_REPOSITORIES[@]} == 0)) && { print_success "External package repositories answer (Remi, EPEL, MariaDB)"; return 0; }
    for name in "${UNREACHABLE_REPOSITORIES[@]}"; do
        case "$name" in
            remi) echo -e "${YELLOW}NOTE:${NC} The $(repository_name remi) does not answer. The panel installs without it; PHP for websites follows on its own once it answers." ;;
            epel) echo -e "${YELLOW}WARNING:${NC} The $(repository_name epel) does not answer. Prerequisite packages come from it, so the install may stop in Stage 2 while it is down." ;;
            mariadb) echo -e "${YELLOW}WARNING:${NC} The $(repository_name mariadb) does not answer. The database server comes from it; the install reports it at the end if it cannot be installed." ;;
        esac
    done
    return 0
}

# Remember a failed step with the line of its output that says why: the last
# line mentioning an error, or else its last non-empty line (AB-1379).
record_failure() {
    local desc="$1" out="$2" reason
    reason=$(sed 's/\x1b\[[0-9;]*m//g' "$out" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -iE 'error|fail|exception|cannot|not found|denied' | tail -n 1)
    [ -n "$reason" ] || reason=$(sed 's/\x1b\[[0-9;]*m//g' "$out" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)
    reason=$(echo "${reason:-no output}" | sed 's/^[[:space:]]*//' | cut -c1-200)
    FAILED_STEPS+=("${desc}: ${reason}")
}

# True when a failed step ("<step>: <reason>") is the install of a critical
# component. The name must match exactly: "PHP 8.4 profile" or "Postfix
# profiles" are follow-up steps, not the component. The MariaDB install is
# also named after its series ("MariaDB 11.4", "MariaDB (default series)").
is_critical_step() {
    local step="${1%%: *}" component
    for component in "${CRITICAL_COMPONENTS[@]}"; do
        [ "$step" = "$component" ] && return 0
    done
    [[ "$step" =~ ^MariaDB\ ([0-9][0-9.]*|\(default\ series\))$ ]] && return 0
    return 1
}

# Closing summary of every failed step, whatever the outcome (AB-1379).
# Sets CRITICAL_FAILED=1 when a critical component is among them.
print_failure_summary() {
    CRITICAL_FAILED=0
    SUMMARY_PRINTED=1
    if ((${#DEFERRED_STEPS[@]} > 0)); then
        echo -e "${BOLD}${YELLOW}--- Deferred: installs on its own (${#DEFERRED_STEPS[@]}) ---${NC}"
        printf '%b  %s\n' "${YELLOW}DEFERRED${NC}" "${DEFERRED_STEPS[@]}"
        echo "The panel tries again every few minutes and finishes it as soon as the repository answers; its dashboard shows the progress and offers Try now."
        echo -e ""
    fi
    [[ -n "$STOPPED_STEP" ]] || [ "${#FAILED_STEPS[@]}" -gt 0 ] || return 0
    local step count=${#FAILED_STEPS[@]}
    [[ -z "$STOPPED_STEP" ]] || count=$((count + 1))
    # printf %s, not echo -e: a reason is the step's own output and may carry a
    # literal "\n" (an agent's JSON error) that must not become a line break.
    echo -e "${BOLD}${YELLOW}--- Failed steps (${count}) ---${NC}"
    [[ -z "$STOPPED_STEP" ]] || printf '%b  %s\n' "${RED}STOPPED${NC}" "$STOPPED_STEP"
    for step in "${FAILED_STEPS[@]}"; do
        if is_critical_step "$step"; then
            CRITICAL_FAILED=1
            printf '%b %s\n' "${RED}CRITICAL${NC}" "$step"
        else
            printf '%b  %s\n' "${YELLOW}WARNING${NC}" "$step"
        fi
    done
    echo -e ""
}
run_or_fail() {
    local cmd="$1" desc="${2:-Command}" step="${3:-}"
    skip_left_out_step "$step" "$desc" "$cmd" && return 0
    report_step_start "$step"
    if ! eval "$cmd"; then print_error "${desc} failed"; STOPPED_STEP="${desc}: failed, the installation cannot go on without it"; report_fail "$step"; exit 1; fi
    report_step_result "$step" ok
    print_success "${desc} completed"
    echo -e ""
}

# SELinux already Disabled or Permissive: nothing to switch off (setenforce
# would fail on a Disabled system and report a warning for nothing).
selinux_not_enforcing() {
    command -v getenforce >/dev/null 2>&1 || return 1
    case "$(getenforce 2>/dev/null)" in
        Disabled|Permissive) return 0 ;;
    esac
    return 1
}

# Sets the caller's TRIAL_LICENCE_OK to 1 when a trial licence was issued.
# Same output as run_or_warn, but bolt-cli is called directly with the
# address as one argument: the address never becomes part of a command text
# and never goes through eval (AB-2211). A refused request only warns.
request_trial_licence() {
    local desc="Request trial licence"
    print_info "$desc"
    report_step_start ""
    if bolt-cli request-trial-license "--email=${ADMIN_EMAIL}"; then
        TRIAL_LICENCE_OK=1
        print_success "$desc completed"; report_step_result "" ok
    else
        echo -e "${YELLOW}WARNING:${NC} $desc failed (continuing)"; report_step_result "" failed
    fi
    echo -e ""
}

# ---------- Stage 2: Prepare → Prerequisite packages → Bolt packages ----------
# Step 2.1: Prepare all settings (no package installs)
stage2_prepare_settings() {
    print_info "Stage 2.1: Preparing settings"
    run_or_warn "selinux_not_enforcing || setenforce 0" "SELinux enforce" selinux_enforce
    run_or_warn "sed -i 's#^SELINUX=.*#SELINUX=disabled#' /etc/selinux/config" "SELinux config" selinux_config
    ssh_key_install
    print_success "Stage 2.1 completed: settings prepared"
}

# CloudLinux tools (X-Ray, MySQL Governor, lve-utils) call /sbin/service
# directly; minimal EL9 images ship neither package that provides it.
ensure_service_command() {
    if rpm -q initscripts &>/dev/null || rpm -q initscripts-service &>/dev/null; then
        print_success "service command already provided (initscripts/initscripts-service)"
        return 0
    fi
    print_info "Installing initscripts-service (provides the service command)"
    install_packages initscripts-service
}

# Step 2.2: Install all prerequisite packages (EPEL, CRB, libsodium, traceroute, openssl, jq, etc.)
stage2_install_prerequisite_packages() {
    print_info "Stage 2.2: Installing prerequisite packages"
    print_info "Enabling CRB (CodeReady Builder) repository"
    report_step_start prerequisite_packages
    install_epel_release
    install_packages dnf-plugins-core
    local crb_ids
    crb_ids=$(crb_repo_ids)
    run_or_warn "dnf config-manager --set-enabled ${crb_ids}" "Enable CRB repo (${crb_ids})" crb_repo
    report_step_start prerequisite_packages
    # Container and minimal AlmaLinux/Rocky 9 images ship curl-minimal and
    # libcurl-minimal, which conflict with the full curl/libcurl below. Replace
    # them first; --allowerasing is scoped to this one install.
    if rpm -q curl-minimal &>/dev/null || rpm -q libcurl-minimal &>/dev/null; then
        print_info "Replacing curl-minimal/libcurl-minimal with curl/libcurl"
        install_packages --allowerasing curl libcurl
    fi
    install_packages \
        libsodium traceroute openssl jq rsync ca-certificates wget curl tar gzip unzip zip sudo apg \
        systemd openssl-libs libcurl libzip zlib gmp freetype libjpeg-turbo libpng libwebp libXpm gd \
        gettext-libs libicu sqlite-libs oniguruma libxslt shadow-utils chrony restic rclone git
    ensure_service_command
    run_or_warn "systemctl enable --now chronyd" "Time synchronization (chronyd)" chronyd
    # pipefail: a failed download feeds sh nothing, which sh reports as success.
    run_or_warn "(set -o pipefail; curl https://get.acme.sh | sh -s email=issue-ssl@adminbolt.com)" "acme.sh" acme_sh
    print_success "Stage 2.2 completed: prerequisite packages installed"
}

# dnf reports a failed %post scriptlet as a warning but the package
# transaction still exits 0, so install_packages()'s exit-code check cannot
# see it - a failure in bolt-agent's %post (permissions, disk space, a real
# certificate issuance failure the self-signed fallback did not catch) stops
# the rest of the agent's setup. Left undetected here, the only symptom shows
# up later in Stage 3 as a bare agent connection error, which does not name
# the actual cause. Kept separate from install_packages() (used by every
# other package install in this script) so this check only ever applies to
# bolt-agent, and every other install keeps its existing behavior unchanged.
#
# The failed %post does not undo the package install, so on the rerun the
# error message asks for, rpm -q alone would report bolt-agent as installed
# and skip it. Nor is the service state enough: %post does not start the
# agent, the package's %posttrans enables and restarts it whatever %post did,
# so an agent whose setup stopped halfway is often running. And a clean
# looking %post proves nothing either: the package records nothing when its
# %post finishes, much of it ignores its own errors (a full disk turns the
# certificate step into a warning and leaves HTTPS off), and the copy of
# dnf's output the failure message is looked for in can itself be lost to a
# full disk. So the setup counts as done only on positive proof: dnf
# succeeded, its complete output names no failed %post, and the end state a
# finished %post and %posttrans leave behind is there (agent_setup_problems).
# Anything short of that stops the install and leaves AGENT_POST_FAILED_MARKER
# behind; while it exists an installed bolt-agent is installed again (its
# %post with it), and only that positive proof removes it. Without the marker
# an installed agent is installed again too when its end state is
# incomplete, or - only as a best effort, carrying on as before if that
# cannot be done - when it is not running.
AGENT_POST_FAILED_MARKER="/var/lib/adminbolt/agent-post-failed"
AGENT_CONF="/etc/bolt-agent/agent.conf"
AGENT_CONF_BACKUP_DIR="/var/lib/adminbolt/agent-conf-backup"
AGENT_ACTIVE_WAIT_SECONDS=30

# Value of KEY in [SECTION] of agent.conf, read the way bolt-agent's own
# scripts read it.
agent_conf_value() {
    awk -F= -v section="[$1]" -v key="$2" '
        index($0, section) == 1 { in_s = 1; next }
        /^\[/ { in_s = 0 }
        in_s && $1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }
    ' "$AGENT_CONF" 2>/dev/null
}

# What is wrong with an existing agent.conf that bolt-agent's %post cannot put
# right: it keeps an existing file and only appends a few sections to it, so
# a file cut short (a full disk while %post wrote it) stays broken on every
# rerun - without the certificate paths %post stops each time, without the
# [security] section or with an empty token the agent has no token. Prints
# the first such problem; returns 0 when there is one.
agent_conf_damage() {
    [[ -e "$AGENT_CONF" ]] || return 1
    if [[ ! -s "$AGENT_CONF" ]]; then echo "$AGENT_CONF is empty"; return 0; fi
    if ! grep -q '^\[server\]' "$AGENT_CONF"; then echo "$AGENT_CONF has no [server] section"; return 0; fi
    local key
    for key in https_cert_path https_key_path https_ca_path; do
        if [[ -z "$(agent_conf_value server "$key")" ]]; then echo "$AGENT_CONF has no $key"; return 0; fi
    done
    if ! grep -q '^\[security\]' "$AGENT_CONF"; then echo "$AGENT_CONF has no [security] section"; return 0; fi
    if grep -q '^token=' "$AGENT_CONF" && [[ -z "$(agent_conf_value security token)" ]]; then
        echo "$AGENT_CONF has an empty token"
        return 0
    fi
    return 1
}

# The files a finished %post leaves behind, in every bolt-agent version this
# installer can install: agent.conf with a token, HTTPS on (%post turns it on
# once a certificate is in place, or stops) and the certificate files it
# names. Prints each thing missing, one per line; returns 1 if anything is.
agent_setup_problems() {
    local missing=() damage key file
    if [[ ! -e "$AGENT_CONF" ]]; then
        missing+=("$AGENT_CONF is missing")
    elif damage=$(agent_conf_damage); then
        missing+=("$damage")
    else
        [[ -n "$(agent_conf_value security token)" ]] || missing+=("$AGENT_CONF has no token")
        grep -Eq '^[[:space:]]*https_enabled=true[[:space:]]*$' "$AGENT_CONF" ||
            missing+=("HTTPS is off in $AGENT_CONF")
        for key in https_cert_path https_key_path https_ca_path; do
            file=$(agent_conf_value server "$key")
            [[ -s "$file" ]] || missing+=("the certificate file $file is missing or empty")
        done
    fi
    ((${#missing[@]} == 0)) && return 0
    printf '%s\n' "${missing[@]}"
    return 1
}

# The agent service is up: %posttrans restarts it, a crash on start shows as
# activating or failed for a moment, so it is given AGENT_ACTIVE_WAIT_SECONDS.
agent_service_active() {
    local waited=0
    until systemctl is-active --quiet bolt-agent 2>/dev/null; do
        ((waited >= AGENT_ACTIVE_WAIT_SECONDS)) && return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# A likely reason worth naming: a full disk, from dnf's output (when there is
# a copy, $1) or from what df reports for the directories the setup writes to.
agent_disk_hint() {
    local dir avail
    if [[ -n "${1:-}" && -s "$1" ]] && grep -q 'No space left on device' "$1"; then
        echo "the disk is full (No space left on device)"
        return 0
    fi
    for dir in /etc /var/lib "${TMPDIR:-/tmp}"; do
        avail=$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }') || avail=""
        if [[ "$avail" =~ ^[0-9]+$ ]] && ((avail < 20480)); then
            echo "the disk holding $dir is (almost) full, ${avail} KB free"
            return 0
        fi
    done
    return 0
}

# Stops the install because bolt-agent's setup is not done. $1 says what went
# wrong, $2 (optional) what to do. The marker is left behind so the rerun
# installs the agent again; if it cannot be written (and is not there), the
# message says so and how to make the rerun do it anyway.
agent_setup_failed() {
    local next="${2:-Fix the cause, then rerun this installer; it retries the agent install.}"
    { mkdir -p "$(dirname "$AGENT_POST_FAILED_MARKER")" &&
        date -u '+%Y-%m-%dT%H:%M:%SZ' >"$AGENT_POST_FAILED_MARKER"; } 2>/dev/null || true
    if [[ ! -e "$AGENT_POST_FAILED_MARKER" ]]; then
        next="The installer could not record this failure in $AGENT_POST_FAILED_MARKER, so a rerun may not install the agent again by itself. Fix the cause, run 'mkdir -p $(dirname "$AGENT_POST_FAILED_MARKER") && touch $AGENT_POST_FAILED_MARKER', then rerun this installer."
    fi
    print_error "$1 $next"
    STOPPED_STEP="bolt-agent: its setup did not finish"
    report_fail agent_scriptlet agent_install_failed
    exit 1
}

# Moves a damaged agent.conf (agent_conf_damage, $1) into a dated copy under
# AGENT_CONF_BACKUP_DIR, next to a MANIFEST saying what it was and why it was
# moved, so the agent's %post writes a new one. The manifest is written
# first; when either step fails nothing is moved and the install stops.
set_aside_agent_conf() {
    local reason="$1" dir sum size
    dir="$AGENT_CONF_BACKUP_DIR/$(date -u '+%Y%m%dT%H%M%SZ')"
    sum=$(sha256sum "$AGENT_CONF" 2>/dev/null | awk '{ print $1 }') || sum=""
    size=$(wc -c <"$AGENT_CONF" 2>/dev/null | tr -d ' ') || size=""
    if ! { mkdir -p "$dir" && chmod 700 "$dir" &&
        printf 'original=%s\nmoved_at=%s\nreason=%s\nsize_bytes=%s\nsha256=%s\nmoved_by=AdminBolt installer (install.sh), before installing bolt-agent again\n' \
            "$AGENT_CONF" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason" "${size:-unknown}" "${sum:-unknown}" >"$dir/MANIFEST" &&
        mv "$AGENT_CONF" "$dir/agent.conf"; } 2>/dev/null; then
        agent_setup_failed "bolt-agent's configuration is damaged ($reason) and could not be moved aside to $dir, so its setup cannot write a new one." \
            "Make room on the disk (or move $AGENT_CONF away yourself), then rerun this installer; it retries the agent install."
    fi
    print_info "Moved the damaged $AGENT_CONF to $dir (MANIFEST there says why); bolt-agent's setup writes a new one"
}

# Runs one package command for bolt-agent ($@: dnf/yum subcommand), on screen
# and, when there is a temporary file, copied to $log. Sets the caller's
# dnf_status, and log_ok=0 when the copy is incomplete (writing it failed).
agent_package_command() {
    local statuses errexit=0
    if [[ -z "$log" ]]; then
        if "$pm" "$@" -y --enablerepo=bolt "$agent_pkg"; then dnf_status=0; else dnf_status=$?; fi
        return 0
    fi
    # Without set -e for the pipeline: a tee that cannot write the copy (a
    # full disk) must not end the installer without a word.
    [[ $- == *e* ]] && errexit=1
    set +e
    "$pm" "$@" -y --enablerepo=bolt "$agent_pkg" 2>&1 | tee "$log"
    statuses=("${PIPESTATUS[@]}")
    ((errexit)) && set -e
    dnf_status=${statuses[0]}
    [[ "${statuses[1]}" -eq 0 ]] || log_ok=0
    return 0
}

install_bolt_agent_and_check_post() {
    report_step_start agent_install
    local again="" problems="" damage="" hint=""
    # AB-2331 addendum: --agent-version installs exactly that build. Another
    # installed version is replaced by a plain install of the pinned
    # version-release (dnf install of a version-release replaces it), and the
    # checks below apply to the pinned build once it is the installed one.
    local agent_pkg
    agent_pkg=$(pinned_spec bolt-agent)
    if [[ "$agent_pkg" != bolt-agent ]] && rpm -q bolt-agent &>/dev/null && ! rpm -q "$agent_pkg" &>/dev/null; then
        print_info "bolt-agent $(rpm -q --qf '%{VERSION}-%{RELEASE}' bolt-agent 2>/dev/null) is installed; installing the requested ${agent_pkg}"
    elif rpm -q bolt-agent &>/dev/null; then
        if [[ -e "$AGENT_POST_FAILED_MARKER" ]]; then
            again=marker
            print_info "bolt-agent is installed but its setup did not finish; installing it again"
        elif ! problems=$(agent_setup_problems); then
            again=incomplete
            print_info "bolt-agent is installed but its setup is incomplete (${problems//$'\n'/; }); installing it again"
        elif ! systemctl is-active --quiet bolt-agent 2>/dev/null; then
            again=stopped
            print_info "bolt-agent is installed but not running; reinstalling it to rerun its setup"
        else
            print_success "bolt-agent already installed"
            return 0
        fi
    fi
    if damage=$(agent_conf_damage); then
        set_aside_agent_conf "$damage"
    fi

    local pm log dnf_status=0 log_ok=1
    if command -v dnf >/dev/null 2>&1; then pm=dnf
    elif command -v yum >/dev/null 2>&1; then pm=yum
    else
        print_error "dnf/yum not found"
        report_fail agent_install agent_install_failed
        exit 1
    fi
    # No temporary file (a full disk): dnf runs as usual, but nothing can show
    # its %post was clean, so the setup cannot count as done below.
    log=$(mktemp 2>/dev/null) || log=""
    [[ -n "$log" ]] || log_ok=0
    if [[ -n "$again" ]]; then
        agent_package_command reinstall
        if [[ "$dnf_status" -ne 0 && "$again" == stopped ]]; then
            # Nothing says this agent's setup failed: keep the installed
            # version and go on, as the installer did before.
            rm -f "$log"
            echo -e "${YELLOW}WARNING:${NC} reinstalling bolt-agent failed; keeping the installed version (continuing)"
            report_step_result agent_install ok
            return 0
        fi
        # The setup did fail. If the installed version is gone from the
        # repository, upgrade to the newer one there, which runs %post too.
        if [[ "$dnf_status" -ne 0 && -n "$log" ]] && grep -q 'not available' "$log"; then
            agent_package_command upgrade
            if [[ "$dnf_status" -eq 0 && -n "$log" ]] && grep -q '^Nothing to do' "$log"; then
                rm -f "$log"
                agent_setup_failed "bolt-agent's setup has to run again, but the installed version is not in the repository and there is no newer one to install." \
                    "Rerun this installer with the --source (stable, staging or testing) whose repository has this version or a newer one; it retries the agent install."
            fi
        fi
    else
        agent_package_command install
    fi

    if [[ "$dnf_status" -ne 0 ]]; then
        rm -f "$log"
        print_error "Installing bolt-agent failed"
        STOPPED_STEP="bolt-agent: the package did not install"
        report_fail agent_install agent_install_failed
        exit 1
    fi
    if [[ -n "$log" ]] && grep -Eq '%post\(bolt-agent[^)]*\) scriptlet failed|Error in POSTIN scriptlet in rpm package bolt-agent' "$log"; then
        hint=$(agent_disk_hint "$log")
        rm -f "$log"
        agent_setup_failed "bolt-agent's post-install script (%post) failed${hint:+ ($hint)}. Check the output above (or 'journalctl -u bolt-agent') for the cause."
    fi
    if ((log_ok == 0)); then
        hint=$(agent_disk_hint "")
        rm -f "$log"
        agent_setup_failed "The installer could not keep a complete copy of bolt-agent's install output${hint:+ ($hint)}, so nothing shows that the agent's post-install script (%post) finished."
    fi
    problems=$(agent_setup_problems) || true
    agent_service_active || problems+="${problems:+$'\n'}the bolt-agent service is not running"
    if [[ -n "$problems" ]]; then
        hint=$(agent_disk_hint "$log")
        rm -f "$log"
        agent_setup_failed "bolt-agent's setup did not finish: ${problems//$'\n'/; }${hint:+ (likely cause: $hint)}. Check the output above (or 'journalctl -u bolt-agent')."
    fi
    rm -f "$log" "$AGENT_POST_FAILED_MARKER"
    report_step_result agent_install ok
    print_success "bolt-agent installed"
}

# Stage 3 end: the agent's end state is checked once more before the install
# is reported complete, so a failure after Stage 2 (a disk that filled up
# meanwhile, HTTPS turned off) stops the install rather than end in
# "Installation Completed Successfully".
check_agent_setup_at_end() {
    local problems="" hint=""
    report_step_start agent_scriptlet
    problems=$(agent_setup_problems) || true
    agent_service_active || problems+="${problems:+$'\n'}the bolt-agent service is not running"
    if [[ -n "$problems" ]]; then
        hint=$(agent_disk_hint "")
        agent_setup_failed "bolt-agent's setup is not complete at the end of the install: ${problems//$'\n'/; }${hint:+ (likely cause: $hint)}. Check 'journalctl -u bolt-agent'."
    fi
    report_step_result agent_scriptlet ok
}

# bolt-panel's %post (database install, base setup, marking the panel as
# installed) fails the same quiet way as bolt-agent's above, and is detected
# the same way. Unlike bolt-agent's, a failure here does not stop the
# installer - when to stop is a separate decision (AB-2067 reports, it does
# not change the flow) - it is reported as panel_scriptlet_failed and the
# install carries on exactly as before.
#
# The log copy is only for this check: when no temporary file can be made the
# packages are installed exactly as before and the check is skipped, and a
# failing tee cannot stop the install either (the pipeline runs without
# set -e, the package step itself still with it). A skipped or incomplete
# log means the %post failure goes unreported, never a false one.
install_bolt_panel_and_check_post() {
    local log status errexit=0
    report_step_start panel_install
    if ! log=$(mktemp 2>/dev/null); then
        install_packages --enablerepo=bolt "$(pinned_spec bolt-nginx)" "$(pinned_spec bolt-php)" "$1"
        report_step_result panel_install ok
        return 0
    fi
    [[ $- == *e* ]] && errexit=1
    set +e
    # The copy does not take the pipe away from the package step: tee ignores
    # Ctrl+C (dnf may handle it and go on writing), and if tee cannot start or
    # stops early, cat passes the rest through to the screen, as without the
    # copy; the pipe stays open in between. (If the installer's own output is
    # gone - a closed terminal, a reader of a pipe stopped by Ctrl+C - dnf
    # loses its output as it would without the copy.)
    (
        ((errexit)) && set -e
        install_packages --enablerepo=bolt "$(pinned_spec bolt-nginx)" "$(pinned_spec bolt-php)" "$1"
    ) 2>&1 | { trap '' INT; tee "$log" || cat; }
    status=${PIPESTATUS[0]}
    ((errexit)) && set -e
    if [[ "$status" -ne 0 ]]; then
        rm -f "$log"
        STOPPED_STEP="bolt-panel: the package did not install (exit ${status})"
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
    pinned_versions_available
    local panel_pkg="bolt-panel"
    if [[ -n "$PANEL_VERSION" ]]; then
        panel_pkg="bolt-panel-${PANEL_VERSION}"
        print_info "Installing specific bolt-panel version: ${PANEL_VERSION}"
    fi
    install_bolt_agent_and_check_post
    install_bolt_panel_and_check_post "$panel_pkg"
    install_pinned_extra_packages
    report_write_panel_settings
    write_left_out_components
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
    # AB-2331: with the database skipped (--skip-database, or a server found
    # on the box) no MariaDB step runs at all: no package, no series, no root
    # password reset, no my.cnf profile. The agent is pointed at the server
    # that is there instead.
    database_skip_decide
    if ((SKIP_DATABASE)); then
        agent_db_credentials_from_my_cnf
    else
        stage_configuration_mariadb
    fi
    run_or_warn "bolt-cli manage-postfix --action=install" "Postfix" postfix
    run_or_warn "bolt-cli manage-dovecot --action=install" "Dovecot" dovecot
    run_or_warn "bolt-cli manage-redis --action=install" "Redis" redis
    run_or_warn "bolt-cli manage-rspamd --action=install" "Rspamd" rspamd
    run_or_warn "bolt-cli manage-mlmmj --action=install" "MLMMJ" mlmmj
    # AB-472: PHP 8.4 comes from Remi; while Remi cannot be reached it is
    # deferred, not failed - the post-install setup queued below installs it
    # (and its default profile) once Remi answers. Any other failure stays
    # critical (AB-1379).
    STEP_REPOSITORY=remi
    run_or_warn "bolt-cli manage-php --action=install --php-version=8.4" "PHP 8.4" php84
    local php84_result="$LAST_STEP_RESULT"
    if ((SKIP_APACHE)); then
        print_info "MyApache skipped (--skip-apache)"
    else
        run_or_warn "bolt-cli manage-my-apache --action=install" "MyApache" myapache
    fi
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
    if ((SKIP_DATABASE)); then
        print_info "MariaDB profile skipped (${DATABASE_SKIP_REASON}): the database server's configuration is left as it is"
    else
        run_or_warn "bolt-cli manage-mariadb-default-profile --action=install" "MariaDB profile" mariadb_profile
    fi
    if ((SKIP_APACHE)); then
        print_info "MyApache profile skipped (--skip-apache)"
    else
        run_or_warn "bolt-cli manage-my-apache-default-profile --action=install" "MyApache profile" myapache_profile
    fi
    run_or_warn "bolt-cli manage-system-email-account --action=install" "System email" system_email
    run_or_warn "bolt-cli manage-dns-records-default-template --action=install" "DNS template" dns_template
    if [[ "$php84_result" == deferred ]]; then
        print_info "PHP 8.4 profile: deferred, applied when PHP 8.4 installs"
        echo -e ""
    elif [[ "$php84_result" == failed ]]; then
        # The profile marks the version installed in the panel; without PHP
        # 8.4 on the server that would be untrue.
        print_info "PHP 8.4 profile: skipped, PHP 8.4 did not install"
        echo -e ""
    else
        run_or_warn "bolt-cli manage-php-default-profile --php-version=8.4 --action=install" "PHP 8.4 profile" php84_profile
    fi
    run_or_warn "bolt-cli manage-vsftpd-profiles --action=install" "Vsftpd profile" vsftpd_profile
    run_or_warn "bolt-cli manage-fail2ban-profiles --action=install" "Fail2Ban profile" fail2ban_profile
    run_or_warn "bolt-cli setup-cron-jobs" "Setup Cron jobs" cron_jobs
    # Only records a provisioning plan and returns; the panel scheduler (installed by setup-cron-jobs) executes it in the background.
    run_or_warn "bolt-cli post-install-provision" "Queue post-install provisioning (remaining PHP versions, SecureBox, SymLock)" postinstall_queue
    run_or_warn "bolt-cli setup-hidepid" "Harden /proc (hidepid)" hidepid
    # QA F2: a bare restart under set -e aborted the whole run (no trial
    # licence, no SSO URL, no banner) whenever rspamd was not installed.
    run_or_warn "systemctl restart rspamd" "Rspamd restart" rspamd_restart
    # AB-2069: the page the web server shows on port 80 for the server IP (and
    # for domains with no site yet). Written by the panel through bolt-agent, so
    # it carries the brand and the panel port; never fatal. No step id: the
    # install report takes only the step ids its receiver knows.
    run_or_warn "bolt-cli publish-default-site-page" "Default site page"
    # Before the trial licence and the SSH password change: a failed install
    # keeps password login and does not use up the trial request.
    check_agent_setup_at_end
    # Trial licence last: nothing in the install depends on it, and the licence server refuses repeats
    # per e-mail and per IP, which must never abort an otherwise complete installation.
    local TRIAL_LICENCE_OK=0
    if [[ -n "$ADMIN_EMAIL" ]]; then
        request_trial_licence
        # Its own report field; never part of the install result.
        if [[ "${TRIAL_LICENCE_OK}" -eq 1 ]]; then report_trial_licence ok; else report_trial_licence failed; fi
    else
        report_trial_licence skipped
        print_info "No --email= provided; skipping trial licence request. Activate a licence later on the panel's License page."
    fi
    # AB-2106: last, after every step that configures sshd, so they cannot undo it and a failed install keeps password login.
    ssh_password_login_off || true
    # AB-2104: the SSO link creates the first administrator, under the
    # --admin-username= name when one was given.
    local SSO_ARGS=()
    [[ -n "$ADMIN_USERNAME" ]] && SSO_ARGS+=("--first-admin=${ADMIN_USERNAME}")
    local SSO_URL=""
    local SSO_OUT=""
    local SSO_RETRY="bolt-cli admin-sso-generate"
    local SSO_ERR_FILE
    SSO_ERR_FILE=$(mktemp)
    if SSO_OUT=$(bolt-cli admin-sso-generate "${SSO_ARGS[@]}" 2>"$SSO_ERR_FILE"); then
        SSO_URL="${SSO_OUT}"
        print_success "SSO URL generated"
    elif [[ -n "$ADMIN_USERNAME" ]] && { grep -qi 'option does not exist' "$SSO_ERR_FILE" || grep -qi 'option does not exist' <<<"$SSO_OUT"; }; then
        # A panel that predates --first-admin: nothing was created, so fall back to the default name, loudly.
        echo -e "${YELLOW}WARNING:${NC} the installed panel does not support --admin-username yet; the first administrator is named admin"
        ADMIN_USERNAME=""
        if SSO_OUT=$(bolt-cli admin-sso-generate 2>/dev/null); then
            SSO_URL="${SSO_OUT}"
            print_success "SSO URL generated"
        else
            echo -e "${YELLOW}WARNING:${NC} SSO URL not generated${SSO_OUT:+: ${SSO_OUT}}"
        fi
    else
        echo -e "${YELLOW}WARNING:${NC} SSO URL not generated${SSO_OUT:+: ${SSO_OUT}}"
        # The reason above says whether the panel refused the name; a refused name needs another one on retry.
        [[ -n "$ADMIN_USERNAME" ]] && SSO_RETRY+=" --first-admin=<name|random>"
    fi
    rm -f "$SSO_ERR_FILE"
    # The name to sign in with later: the one the panel reports for the link
    # ("Logs in as administrator: <name>"), else the one asked for, else
    # admin. Without a link the asked-for name may have been refused, so the
    # retry command below names it.
    local ADMIN_LOGIN_NAME=""
    [[ -n "$SSO_URL" ]] && ADMIN_LOGIN_NAME=$(sed -n 's/^Logs in as administrator: //p' <<<"$SSO_OUT" | head -n 1)
    if [[ -z "$ADMIN_LOGIN_NAME" ]]; then
        if [[ -z "$ADMIN_USERNAME" ]]; then
            ADMIN_LOGIN_NAME="admin"
        elif [[ -n "$SSO_URL" && "$ADMIN_USERNAME" != random ]]; then
            ADMIN_LOGIN_NAME="$ADMIN_USERNAME"
        else
            ADMIN_LOGIN_NAME="the one the panel shows when the sign-in link is generated"
        fi
    fi
    [ -n "${SSH_PASSWORD_NOTE}" ] && echo -e "\n${SSH_PASSWORD_NOTE}"
    echo -e ""
    print_failure_summary
    if [ "$CRITICAL_FAILED" -eq 1 ]; then
        echo -e "${BOLD}${RED}+----------------------------------------------------------+${NC}"
        echo -e "${BOLD}${RED}|  Installation Incomplete: critical components failed     |${NC}"
        echo -e "${BOLD}${RED}+----------------------------------------------------------+${NC}\n"
        echo -e "${RED}This server cannot host mail, databases or PHP sites until the CRITICAL steps above are fixed and installed again (bolt-cli manage-<component> --action=install).${NC}\n"
    elif [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
        echo -e "${BOLD}${YELLOW}+----------------------------------------------------------+${NC}"
        echo -e "${BOLD}${YELLOW}|          Installation Completed With Warnings            |${NC}"
        echo -e "${BOLD}${YELLOW}+----------------------------------------------------------+${NC}\n"
    elif [ "${#DEFERRED_STEPS[@]}" -gt 0 ]; then
        echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}"
        echo -e "${BOLD}${GREEN}|      Installation Completed: deferred parts follow       |${NC}"
        echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}\n"
    else
        echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}"
        echo -e "${BOLD}${GREEN}|          Installation Completed Successfully             |${NC}"
        echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}\n"
    fi
    if [ -n "${ADMIN_EMAIL}" ] && [ "${TRIAL_LICENCE_OK}" -eq 0 ]; then
        # QA finding 2: "the installation itself succeeded" only when it did.
        if [ "$CRITICAL_FAILED" -eq 1 ]; then
            echo -e "${YELLOW}NOTE:${NC} Trial licence not issued (request refused or licence server unreachable). Activate a licence on the panel's License page.\n"
        else
            echo -e "${YELLOW}NOTE:${NC} Trial licence not issued (request refused or licence server unreachable). The installation itself succeeded and the panel is usable; activate a licence on its License page.\n"
        fi
    fi
    print_left_out_components
    [ -n "${SSO_URL:-}" ] && echo -e "${BOLD}${CYAN}--- Access ---${NC}\n${GREEN}Admin Panel:${NC}\n${BOLD}${SSO_URL}${NC}\n"
    # AB-2069: nothing here used to say which login the panel takes, and the
    # guesses (root, the hosting username, an e-mail) each counted towards a
    # Fail2Ban ban. The link above signs in once; this is for every time after.
    echo -e "${BOLD}${CYAN}--- Signing in later ---${NC}"
    echo -e "${GREEN}Admin username:${NC} ${BOLD}${ADMIN_LOGIN_NAME}${NC} (or the e-mail you enter in the setup wizard)"
    echo -e "${GREEN}Password:${NC} the one you set in the setup wizard that opens with the link above"
    echo -e "${GREEN}Until the setup wizard is finished, root can also sign in with this server's root password; the wizard offers to turn that off.${NC}\n"
    echo -e "${BOLD}${CYAN}--- If you get locked out ---${NC}"
    echo -e "${GREEN}New one-time sign-in link:${NC} ${BOLD}${SSO_RETRY}${NC}"
    echo -e "${GREEN}Reset the admin password:${NC}  ${BOLD}bolt-cli reset-admin-account-password${NC}"
    echo -e "${GREEN}Lift a Fail2Ban ban:${NC}       ${BOLD}bolt-cli fail2ban-unban <your-ip> --whitelist${NC}"
    print_progress "100% — post-install"
    if [ "$CRITICAL_FAILED" -eq 1 ]; then
        print_error "Stage 3 finished with failed critical components"
    else
        print_success "Stage 3 completed: all post-install actions done"
    fi
}

# The MariaDB step of Stage 3, on a box without a database server.
stage_configuration_mariadb() {
    # AB-1446: the MariaDB series is a choice. AB-2228: without
    # --mariadb-version a new box gets DEFAULT_MARIADB_SERIES, asked for
    # explicitly so a panel with an older default installs it too. A box that
    # already runs a database server (the installer run again, a converted
    # server) does not get here since AB-2331: database_skip_decide skips the
    # database steps there.
    MARIADB_SERIES=$(mariadb_series_to_install "$MARIADB_SERIES")
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
            local mariadb_out_file
            mariadb_out_file=$(mktemp)
            printf '%s\n' "$MARIADB_OUT" > "$mariadb_out_file"
            record_failure "MariaDB ${MARIADB_SERIES}" "$mariadb_out_file"
            rm -f "$mariadb_out_file"
        fi
        echo -e ""
    else
        run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB" mariadb
    fi
}

# The series stage_configuration asks the panel for: the one given with
# --mariadb-version, else DEFAULT_MARIADB_SERIES when no MariaDB server
# package is installed yet, else none (the panel keeps the installed one).
mariadb_series_to_install() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then
        echo "$given"
    elif ! rpm -q MariaDB-server >/dev/null 2>&1 && ! rpm -q mariadb-server >/dev/null 2>&1; then
        echo "$DEFAULT_MARIADB_SERIES"
    fi
}

# ---------- Pinned package versions (AB-2331 addendum) ----------
# An RPM version-release: no dash inside either part, exactly one between them.
readonly PINNED_VERSION_RE='^[0-9A-Za-z._+~^]+-[0-9A-Za-z._+~^]+$'

# Checks --agent-version and every --package; prints the first problem.
# AGENT_VERSION_GIVEN is main's: an empty --agent-version= is an error too.
pinned_versions_valid() {
    local entry name version seen=" "
    if [[ "${AGENT_VERSION_GIVEN:-0}" == 1 && ! "$AGENT_VERSION" =~ $PINNED_VERSION_RE ]]; then
        print_error "Invalid --agent-version=${AGENT_VERSION} (expected <version>-<release>, e.g. 1.30.4-1.el9)"
        return 1
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="${entry%%=*}"
        version="${entry#*=}"
        if [[ "$entry" != *=* || ! "$name" =~ ^bolt-[a-z0-9-]+$ || ! "$version" =~ $PINNED_VERSION_RE ]]; then
            print_error "Invalid --package=${entry} (expected bolt-<name>=<version>-<release>, e.g. bolt-php=8.4.14-1.el9)"
            return 1
        fi
        case "$name" in
            bolt-panel) print_error "--package=${entry}: use --version= for bolt-panel"; return 1 ;;
            bolt-agent) print_error "--package=${entry}: use --agent-version= for bolt-agent"; return 1 ;;
        esac
        if [[ "$seen" == *" $name "* ]]; then
            print_error "--package=${name}= given twice"
            return 1
        fi
        seen+="$name "
    done <<<"$PINNED_PACKAGES"
    return 0
}

# The package spec to install: name-version-release when pinned, else the name.
pinned_spec() {
    local entry
    if [[ "$1" == bolt-agent && -n "$AGENT_VERSION" ]]; then
        printf '%s' "bolt-agent-${AGENT_VERSION}"
        return 0
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" && "${entry%%=*}" == "$1" ]] || continue
        printf '%s' "$1-${entry#*=}"
        return 0
    done <<<"$PINNED_PACKAGES"
    printf '%s' "$1"
}

# Every pinned spec (bolt-agent first), one per line.
pinned_specs() {
    local entry
    [[ -n "$AGENT_VERSION" ]] && echo "bolt-agent-${AGENT_VERSION}"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] && echo "${entry%%=*}-${entry#*=}"
    done <<<"$PINNED_PACKAGES"
    return 0
}

# Stops the install, before any Bolt package is installed, when a pinned
# version is not in the repositories just configured (--source, or the
# bolt-repo default). dnf install of an exact version-release installs it
# whatever version is there, so a pinned version also moves a box back.
pinned_versions_available() {
    local spec missing=()
    [[ -n "$AGENT_VERSION$PINNED_PACKAGES" ]] || return 0
    # Reported as the repository step: the install report takes only its
    # fixed list of step ids.
    report_step_start repo_setup
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        if dnf -q --enablerepo=bolt --showduplicates list "$spec" >/dev/null 2>&1; then
            print_success "Pinned version found: ${spec}"
        else
            missing+=("$spec")
        fi
    done < <(pinned_specs)
    if ((${#missing[@]})); then
        print_error "Not found in the Bolt repositories (source=${BOLT_SOURCE:-default}): ${missing[*]}. Check the version-release, or the --source the build was published to (PR builds: --source=testing)."
        report_fail repo_setup package_install_failed
        exit 1
    fi
    report_step_result repo_setup ok
}

# The pinned packages Stage 2.3 does not install by itself (all but
# bolt-agent, bolt-nginx and bolt-php), at exactly the given versions.
install_pinned_extra_packages() {
    local entry name specs=()
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="${entry%%=*}"
        case "$name" in bolt-nginx|bolt-php) continue ;; esac
        specs+=("$name-${entry#*=}")
    done <<<"$PINNED_PACKAGES"
    ((${#specs[@]})) || return 0
    print_info "Installing pinned packages: ${specs[*]}"
    # Bolt packages like the panel's: reported as that step.
    report_step_start panel_install
    install_packages --enablerepo=bolt "${specs[@]}"
    report_step_result panel_install ok
}

# ---------- Database server already on the box (AB-2331) ----------
# MariaDB's install step reaches `dnf install MariaDB-server --allowerasing`
# in bolt-agent and resets root's password, so it must never run where a
# database server already is: it would replace MySQL (cl-MySQL under MySQL
# Governor on CloudLinux, a cPanel server being converted) and start MariaDB
# on its data directory.

# Prints why the box counts as having a database server; fails when it has
# none. A server that answers is enough (mysqladmin ping exits 0 even when it
# refuses the login); so is any server package, running or not.
database_server_found() {
    local admin p hit
    local -a globs
    for admin in mysqladmin mariadb-admin; do
        command -v "$admin" >/dev/null 2>&1 || continue
        if run_bounded 15 "$admin" --connect-timeout=5 ping </dev/null >/dev/null 2>&1; then
            echo "a database server answers ($admin ping)"
            return 0
        fi
        break
    done
    for p in $DATABASE_SERVER_PACKAGES; do
        if rpm -q "$p" >/dev/null 2>&1; then
            echo "$p is installed"
            return 0
        fi
    done
    # Read into an array: unquoted, the globs would match files in the current directory.
    read -r -a globs <<<"$DATABASE_SERVER_PACKAGE_GLOBS"
    for p in "${globs[@]}"; do
        hit=$(rpm -qa "$p" 2>/dev/null | head -n 1)
        if [[ -n "$hit" ]]; then
            echo "$hit is installed"
            return 0
        fi
    done
    return 1
}

# Sets SKIP_DATABASE (and DATABASE_SKIP_REASON) once per run, and says why.
database_skip_decide() {
    ((DATABASE_SKIP_DECIDED)) && return 0
    DATABASE_SKIP_DECIDED=1
    local found
    if ((SKIP_DATABASE)); then
        DATABASE_SKIP_REASON="--skip-database"
    elif found=$(database_server_found); then
        SKIP_DATABASE=1
        DATABASE_SKIP_REASON="$found"
    else
        return 0
    fi
    print_info "Database steps skipped (${DATABASE_SKIP_REASON}): no database server is installed, upgraded or reconfigured, and root's password is not reset; the panel uses the server on this box with the credentials in ${ROOT_MY_CNF}"
    if [[ -n "$MARIADB_SERIES" ]]; then
        echo -e "${YELLOW}WARNING:${NC} --mariadb-version=${MARIADB_SERIES} ignored: the database steps are skipped"
    fi
    return 0
}

# timeout(1) when there is one; the command as it is otherwise.
run_bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$secs" "$@"; else "$@"; fi
}

# The value of key $3 in section [$2] of the INI file $1 (the last one
# wins), surrounding blanks and quotes removed; empty when there is none.
ini_value() {
    local v
    v=$(awk -v want="$2" -v key="$3" '
        /^[[:space:]]*\[/ {
            sec = $0
            gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", sec)
            insec = (tolower(sec) == want)
            next
        }
        insec {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            i = index(line, "=")
            if (i == 0) next
            k = substr(line, 1, i - 1)
            sub(/[[:space:]]+$/, "", k)
            if (tolower(k) != key) next
            val = substr(line, i + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        }
        END { print val }
    ' "$1" 2>/dev/null) || return 0
    while [[ "$v" == [\"\']* ]]; do v="${v:1}"; done
    while [[ "$v" == *[\"\'] ]]; do v="${v:0:${#v}-1}"; done
    printf '%s' "$v"
}

# With the database skipped, bolt-agent still needs the server's administrator
# login: [dbservers.mariadb] user/password in agent.conf, which the MariaDB
# step would otherwise have written. Taken from root's /root/.my.cnf
# ([client], then [mysql]; user root when only a password is there), the way
# bolt-migrate does it after the install, and written the same way (quoted),
# so its later sync finds the same values. The file is rewritten in place:
# the agent watches it and reloads it, as after the MariaDB step.
agent_db_credentials_from_my_cnf() {
    local user="" pass="" v cur_user cur_pass tmp
    if [[ -r "$ROOT_MY_CNF" ]]; then
        for v in client mysql; do
            [[ -n "$(ini_value "$ROOT_MY_CNF" "$v" user)" ]] && user=$(ini_value "$ROOT_MY_CNF" "$v" user)
            [[ -n "$(ini_value "$ROOT_MY_CNF" "$v" password)" ]] && pass=$(ini_value "$ROOT_MY_CNF" "$v" password)
        done
    fi
    [[ -n "$pass" && -z "$user" ]] && user="root"
    if [[ -z "$pass" ]]; then
        echo -e "${YELLOW}WARNING:${NC} no database password in ${ROOT_MY_CNF}: set user= and password= of the database administrator in [dbservers.mariadb] of ${AGENT_CONF} (bolt-agent reloads it by itself)"
        return 0
    fi
    if [[ "$user$pass" == *\"* ]]; then
        echo -e "${YELLOW}WARNING:${NC} the database login in ${ROOT_MY_CNF} contains a double quote, which ${AGENT_CONF} cannot hold: set [dbservers.mariadb] user= and password= there by hand"
        return 0
    fi
    if [[ ! -f "$AGENT_CONF" ]]; then
        echo -e "${YELLOW}WARNING:${NC} ${AGENT_CONF} not found: bolt-agent cannot be pointed at the database server"
        return 0
    fi
    cur_user=$(ini_value "$AGENT_CONF" dbservers.mariadb user)
    cur_pass=$(ini_value "$AGENT_CONF" dbservers.mariadb password)
    if [[ "$cur_user" == "$user" && "$cur_pass" == "$pass" ]]; then
        print_success "bolt-agent already uses the database login from ${ROOT_MY_CNF}"
        return 0
    fi
    if ! tmp=$(mktemp "${AGENT_CONF}.XXXXXX" 2>/dev/null); then
        echo -e "${YELLOW}WARNING:${NC} could not update ${AGENT_CONF}: set [dbservers.mariadb] user= and password= there by hand"
        return 0
    fi
    # Values through the environment: awk -v would turn backslashes into escapes.
    if DB_USER="$user" DB_PASS="$pass" awk '
        function keys() {
            if (!have_user) print "user=\"" ENVIRON["DB_USER"] "\""
            if (!have_pass) print "password=\"" ENVIRON["DB_PASS"] "\""
        }
        /^[[:space:]]*\[/ {
            if (insec) keys()
            sec = $0
            gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", sec)
            insec = (tolower(sec) == "dbservers.mariadb")
            if (insec) { found = 1; have_user = 0; have_pass = 0 }
            print
            next
        }
        insec && /^[[:space:]]*[Uu][Ss][Ee][Rr][[:space:]]*=/ { print "user=\"" ENVIRON["DB_USER"] "\""; have_user = 1; next }
        insec && /^[[:space:]]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*=/ { print "password=\"" ENVIRON["DB_PASS"] "\""; have_pass = 1; next }
        { print }
        END {
            if (insec) keys()
            if (!found) {
                print ""
                print "[dbservers.mariadb]"
                print "type=mysql"
                print "host=localhost"
                print "port=3306"
                have_user = 0; have_pass = 0
                keys()
            }
        }
    ' "$AGENT_CONF" >"$tmp" && cat "$tmp" >"$AGENT_CONF"; then
        rm -f "$tmp"
        print_success "bolt-agent pointed at the database server on this box (login from ${ROOT_MY_CNF})"
    else
        rm -f "$tmp"
        echo -e "${YELLOW}WARNING:${NC} could not update ${AGENT_CONF}: set [dbservers.mariadb] user= and password= there by hand"
    fi
    return 0
}

# ---------- Main ----------
print_usage() {
    echo "Usage: sudo $0 [--help] [--version=<PANEL_VERSION>] [--agent-version=<version-release>] [--package=<bolt-name>=<version-release> ...] [--source=<stable|staging|testing>] [--email=<address>] [--mariadb-version=<10.11|11.4>] [--without=<mail,dns,ftp>] [--skip-database] [--skip-apache] [--channel=<name>] [--no-telemetry] [--ssh-key=<public key|https URL>] [--admin-username=<name|random>]"
    echo "AlmaLinux 9 / Rocky Linux 9 / CloudLinux 9. Stages: 1=ready check, 2=(2.1 settings, 2.2 prereq packages, 2.3 bolt packages), 3=post-install."
    echo "If --version is not provided, latest bolt-panel from repo is installed."
    echo "If --source is not provided, the bolt-repo RPM from adminbolt is used (default). Otherwise repos point at pulp content stable/staging/testing."
    echo "--agent-version installs exactly that bolt-agent build (e.g. 1.30.4-1.el9); --package=<bolt-name>=<version-release> does the same for another bolt-* package (repeatable, e.g. --package=bolt-php=8.4.14-1.el9). Both come from the repositories --source selects (PR builds: --source=testing); the install stops before any Bolt package is installed when a version is not there."
    echo "--skip-database runs no database step (no MariaDB package, series, root password reset or my.cnf profile); the panel uses the MySQL/MariaDB server already on this server, with the administrator login from ${ROOT_MY_CNF} ([client] user= and password=) copied into [dbservers.mariadb] of ${AGENT_CONF}. The database steps are skipped by themselves when a database server answers (mysqladmin ping) or a server package is installed (MariaDB-server, mariadb-server, mysql-server, cl-MySQL*, cl-MariaDB*, ...)."
    echo "--skip-apache runs no Apache step (manage-my-apache and its default profile); the web server is then the caller's to set up."
    echo "If --mariadb-version is not provided, MariaDB ${DEFAULT_MARIADB_SERIES} is installed (long-term series, supported until 2029); --mariadb-version=10.11 installs the previous long-term series (supported until 2028). A server that already has a database server keeps it as it is (see --skip-database)."
    echo "If --email is provided, a 24h trial licence is requested for that address at the very end of the install (clicking the e-mailed confirmation link extends it to the full trial period); the install completes even if the request is refused."
    echo "Without --email the install proceeds unlicensed; activate on the panel's License page."
    echo "--without leaves optional components out, for servers with little memory (comma-separated; everything is installed by default):"
    local component
    for component in $OPTIONAL_COMPONENTS; do
        echo "  $(component_description "$component")"
    done
    echo "  The end of the install prints the skipped commands, which add a left-out component later."
    echo "--channel names what started the install (${REPORT_CHANNELS// /, }); default direct."
    echo "The installer reports its progress and result (no hostnames, e-mail addresses or passwords) to AdminBolt; --no-telemetry (or ADMINBOLT_NO_TELEMETRY=1) turns this off for the installer and the panel."
    echo "If --admin-username is not provided, the first panel administrator is named admin. --admin-username=random names it admin- plus 6 random characters; any other value is used as the name (3-32 characters: lowercase letters, numbers, dots, dashes or underscores, starting with a letter; not a reserved system name, a hosting account or an existing Linux user). The setup wizard can still rename it."
    echo "If --ssh-key is provided (a public key, or an https:// URL serving keys), the key is added to root's authorized_keys; SSH password login for root is turned off at the end only after a root sign-in with that key is seen (at a terminal the installer waits up to 10 minutes for one), otherwise it stays on."
}

main() {
    local AGENT_VERSION_GIVEN=0
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
            --without=*)
                # Joined with a comma, so an empty occurrence stays visible and is refused.
                ((WITHOUT_GIVEN)) && WITHOUT_ARG+=","
                WITHOUT_ARG+="${arg#--without=}"
                WITHOUT_GIVEN=1
                ;;
            --[Ww][Ii][Tt][Hh][Oo][Uu][Tt]*)
                # "--without mail", "--without-mail" or "--Without=mail" would
                # otherwise install everything without a word: the value goes
                # in the same argument, after "--without=".
                ((WITHOUT_GIVEN)) && WITHOUT_ARG+=","
                WITHOUT_GIVEN=1
                ;;
            --skip-database)
                SKIP_DATABASE=1
                ;;
            --skip-apache)
                SKIP_APACHE=1
                ;;
            --agent-version=*)
                AGENT_VERSION="${arg#--agent-version=}"
                AGENT_VERSION_GIVEN=1
                ;;
            --package=*)
                PINNED_PACKAGES+="${arg#--package=}"$'\n'
                ;;
            --channel=*)
                REPORT_CHANNEL_ARG="${arg#--channel=}"
                REPORT_CHANNEL_GIVEN=1
                ;;
            --channel)
                REPORT_CHANNEL_ARG=""
                REPORT_CHANNEL_GIVEN=1
                ;;
            --no-telemetry)
                REPORT_NO_TELEMETRY=1
                ;;
            --admin-username=*)
                ADMIN_USERNAME="${arg#--admin-username=}"
                ADMIN_USERNAME_GIVEN=1
                ;;
            --admin-username)
                # "--admin-username bob" would otherwise name the account admin
                # without a word: the value goes after "--admin-username=".
                ADMIN_USERNAME=""
                ADMIN_USERNAME_GIVEN=1
                ;;
            --ssh-key=*)
                SSH_KEY_ARG="${arg#--ssh-key=}"
                if [[ -z "$SSH_KEY_ARG" ]]; then
                    print_error "--ssh-key= needs a public key or an https:// URL"
                    print_usage
                    exit 1
                fi
                ;;
        esac
    done

    # Install report: ID, start event, signal traps and the one EXIT trap.
    report_init
    report_step_start parse_arguments

    # --channel only labels the report, so a value it does not know (a typo,
    # an empty one) never stops the install: one warning, and the install is
    # reported as direct. The value is shown cut to 40 characters, with
    # anything unprintable as "?", and printed with %s, never interpreted.
    if ((REPORT_CHANNEL_GIVEN)) && ! _report_in_list "$REPORT_CHANNEL_ARG" "$REPORT_CHANNELS"; then
        printf '%bWARNING:%b unknown --channel=%s, reporting this install as direct (known: %s)\n' \
            "$YELLOW" "$NC" "$(shown_arg "$REPORT_CHANNEL_ARG")" "${REPORT_CHANNELS// /, }"
    fi

    if [[ -n "$MARIADB_SERIES" ]]; then
        case "$MARIADB_SERIES" in
            10.11|11.4) ;;
            *)
                printf '%bERROR:%b Invalid --mariadb-version=%s (supported: 10.11, 11.4)\n' \
                    "$RED" "$NC" "$(shown_arg "$MARIADB_SERIES")" >&2
                print_usage
                report_fail parse_arguments invalid_argument
                exit 1
                ;;
        esac
    fi

    if ((WITHOUT_GIVEN)) && ! set_left_out_components "$WITHOUT_ARG"; then
        local shown="${WITHOUT_ARG:0:40}"
        shown="${shown//[^[:print:]]/?}"
        printf '%bERROR:%b Invalid --without=%s (give --without=<list>, comma-separated, of: %s)\n' "$RED" "$NC" "$shown" "${OPTIONAL_COMPONENTS// /, }" >&2
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    # Before the @: letters, digits and most other characters RFC 5322 allows
    # in an address (! # % & ' * + / = ? ^ _ { | } ~ . -); after it: a domain
    # of letters, digits, hyphens and dots. Refused before anything is
    # installed (AB-2211): $ and ` (valid by the RFC, but no real address
    # needs them), quotes, ;, any whitespace and control characters. The
    # address still only ever reaches bolt-cli as one argument.
    local email_re="^[A-Za-z0-9!#%&'*+/=?^_{|}~.-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\$"
    if [[ -n "$ADMIN_EMAIL" && ! "$ADMIN_EMAIL" =~ $email_re ]]; then
        printf '%bERROR:%b Invalid --email=%s (expected name@domain.tld; no spaces, ", $, `, ; or control characters)\n' \
            "$RED" "$NC" "$(shown_arg "$ADMIN_EMAIL")" >&2
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    # AB-2104: format only, the panel's own rule for an administrator name;
    # the panel checks the rest (root, reserved names, hosting accounts,
    # Linux users) when it creates the account.
    if ((ADMIN_USERNAME_GIVEN)) && [[ "$ADMIN_USERNAME" != "random" && ! "$ADMIN_USERNAME" =~ ^[a-z][a-z0-9._-]{2,31}$ ]]; then
        printf '%bERROR:%b Invalid --admin-username=%s (3-32 characters: lowercase letters, numbers, dots, dashes or underscores, starting with a letter; or random)\n' \
            "$RED" "$NC" "$(shown_arg "$ADMIN_USERNAME")" >&2
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    # AB-2331 addendum: pinned versions, checked before anything is installed.
    if ! pinned_versions_valid; then
        print_usage
        report_fail parse_arguments invalid_argument
        exit 1
    fi

    if [[ -n "$BOLT_SOURCE" ]]; then
        case "$BOLT_SOURCE" in
            stable|staging|testing) ;;
            *)
                printf '%bERROR:%b Invalid --source=%s (allowed: stable, staging, testing)\n' \
                    "$RED" "$NC" "$(shown_arg "$BOLT_SOURCE")" >&2
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
    # clear. Lives under /var/lib/adminbolt (the panel's own data
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

    # AB-1379: a failed critical component makes the whole install fail, after
    # the summary and the access details have been printed.
    [ "${CRITICAL_FAILED:-0}" -eq 1 ] && exit 1
    return 0
}

# ADMINBOLT_INSTALL_SOURCE_ONLY=1 loads the functions without running the
# install (tests/). An environment switch rather than a BASH_SOURCE check,
# which cannot tell `curl ... | bash` apart reliably.
if [[ "${ADMINBOLT_INSTALL_SOURCE_ONLY:-}" != 1 ]]; then
    main "$@"
fi
