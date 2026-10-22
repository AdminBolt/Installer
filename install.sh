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

# Check if port 8443 is free, or already used by an existing bolt-nginx.
# If used by some other service, abort installation early.
check_port_8443() {
    # ss is part of iproute2 on AlmaLinux 9
    if ! command -v ss >/dev/null 2>&1; then
        print_error "ss command not found; cannot check port 8443 usage"
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
    exit 1
}

# ---------- Stage 1: Check ready for installation ----------
stage_prerequisites() {
    print_info "Stage 1: Checking that everything is in place and ready for installation"
    # Root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
    # Distro: AlmaLinux 9 or Rocky Linux 9
    local distro_info
    if ! distro_info=$(detect_distribution); then
        print_error "This script supports AlmaLinux 9 and Rocky Linux 9 only. Current system is not supported."
        exit 1
    fi
    print_success "Detected: $distro_info"
    # Required commands
    for cmd in curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            print_error "Required command not found: $cmd"
            exit 1
        fi
    done
    check_port_8443
    # AB-2106: a bad key stops the install here, before anything is changed.
    if [[ -n "$SSH_KEY_ARG" ]]; then
        ssh_key_load || exit 1
        print_success "SSH key checked ($(grep -c . <<<"$SSH_KEYS") key(s))"
    fi
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
    local blocker saved="" tmp cfg line
    # Only a sign-in from now on counts: it ran under the sshd settings the install left behind.
    SSH_KEY_PROOF_SINCE=$(date +%s)
    if ! ssh_keys_in_place; then
        ssh_password_kept "the key is no longer in ${ROOT_AUTHORIZED_KEYS}"
        return 0
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if ssh_key_restricted "$line" "$ROOT_AUTHORIZED_KEYS"; then
            ssh_password_kept "${ROOT_AUTHORIZED_KEYS} also lists the key with restrictions (command=, from=, ...)"
            return 0
        fi
    done <<<"$SSH_KEYS"
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
    curl -f -L -k -o "$temp_rpm" "$rpm_url" || { print_error "Failed to download repo"; exit 1; }
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
    (command -v dnf >/dev/null 2>&1 && dnf install -y "${dnf_opts[@]}" "${missing[@]}") || (command -v yum >/dev/null 2>&1 && yum install -y "${dnf_opts[@]}" "${missing[@]}") || { print_error "dnf/yum not found"; exit 1; }
    print_success "Packages installed"
}

run_or_warn() {
    local cmd="$1" desc="${2:-Command}"
    print_info "$desc"
    if eval "$cmd"; then print_success "$desc completed"; else echo -e "${YELLOW}WARNING:${NC} $desc failed (continuing)"; fi
    echo -e ""
}
run_or_fail() {
    local cmd="$1" desc="${2:-Command}"
    if ! eval "$cmd"; then print_error "${desc} failed"; exit 1; fi
    print_success "${desc} completed"
    echo -e ""
}

# ---------- Stage 2: Prepare → Prerequisite packages → Bolt packages ----------
# Step 2.1: Prepare all settings (no package installs)
stage2_prepare_settings() {
    print_info "Stage 2.1: Preparing settings"
    run_or_warn "setenforce 0" "SELinux enforce"
    run_or_warn "sed -i 's#^SELINUX=.*#SELINUX=disabled#' /etc/selinux/config" "SELinux config"
    ssh_key_install
    print_success "Stage 2.1 completed: settings prepared"
}

# Step 2.2: Install all prerequisite packages (EPEL, CRB, libsodium, traceroute, openssl, jq, etc.)
stage2_install_prerequisite_packages() {
    print_info "Stage 2.2: Installing prerequisite packages"
    print_info "Enabling CRB (CodeReady Builder) repository"
    install_packages epel-release dnf-plugins-core
    run_or_warn "dnf config-manager --set-enabled crb" "Enable CRB repo"
    install_packages \
        libsodium traceroute openssl jq rsync ca-certificates wget curl tar gzip unzip zip sudo apg \
        systemd openssl-libs libcurl libzip zlib gmp freetype libjpeg-turbo libpng libwebp libXpm gd \
        gettext-libs libicu sqlite-libs oniguruma libxslt shadow-utils chrony restic rclone git
    run_or_warn "systemctl enable --now chronyd" "Time synchronization (chronyd)"
    run_or_warn "curl https://get.acme.sh | sh -s email=issue-ssl@adminbolt.com" "acme.sh"
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
        exit 1
    fi

    if [[ "$dnf_status" -ne 0 ]]; then
        rm -f "$log"
        print_error "Installing bolt-agent failed"
        exit 1
    fi
    if grep -Eq '%post\(bolt-agent[^)]*\) scriptlet failed' "$log"; then
        rm -f "$log"
        print_error "bolt-agent's post-install script (%post) failed. Check the output above (or 'journalctl -u bolt-agent') for the cause, fix it, then rerun this installer."
        exit 1
    fi
    rm -f "$log"
    print_success "bolt-agent installed"
}

# Step 2.3: Install all Bolt packages (repo, bolt-nginx/php/agent, panel RPM)
stage2_install_bolt_packages() {
    print_info "Stage 2.3: Installing all Bolt packages"
    install_repo_rhel 9
    local panel_pkg="bolt-panel"
    if [[ -n "$PANEL_VERSION" ]]; then
        panel_pkg="bolt-panel-${PANEL_VERSION}"
        print_info "Installing specific bolt-panel version: ${PANEL_VERSION}"
    fi
    install_bolt_agent_and_check_post
    install_packages --enablerepo=bolt bolt-nginx bolt-php "$panel_pkg"
    systemctl enable --now bolt-nginx bolt-php
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
    run_or_fail "bolt-cli connect-bolt-agent-with-panel" "Connect bolt-agent to panel"
    run_or_warn "bolt-cli add-bolt-greeting-message" "Add bolt greeting message"
    run_or_warn "bolt-cli manage-nftable --action=install" "Nftable"
    run_or_warn "bolt-cli manage-sshd --action=install" "SSH server"
    run_or_warn "bolt-cli manage-powerdns --action=install" "PowerDNS"
    # AB-1446: the MariaDB series is a choice; without --mariadb-version the
    # panel's default series is installed.
    if [[ -n "$MARIADB_SERIES" ]]; then
        # QA F1: a panel that predates the --series option (an older channel
        # head, a pinned older version) refused the flag and the box was left
        # without a database. Fall back to the panel's default series, loudly,
        # rather than install nothing.
        print_info "MariaDB ${MARIADB_SERIES}"
        local MARIADB_OUT
        if MARIADB_OUT=$(bolt-cli manage-mariadb --action=install --series="${MARIADB_SERIES}" 2>&1); then
            echo "$MARIADB_OUT"
            print_success "MariaDB ${MARIADB_SERIES} completed"
        elif grep -qi 'option does not exist' <<<"$MARIADB_OUT"; then
            echo "$MARIADB_OUT"
            echo -e "${YELLOW}WARNING:${NC} the installed panel does not support --mariadb-version yet; installing its default MariaDB series instead"
            run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB (default series)"
        else
            echo "$MARIADB_OUT"
            echo -e "${YELLOW}WARNING:${NC} MariaDB ${MARIADB_SERIES} failed (continuing)"
        fi
        echo -e ""
    else
        run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB"
    fi
    run_or_warn "bolt-cli manage-postfix --action=install" "Postfix"
    run_or_warn "bolt-cli manage-dovecot --action=install" "Dovecot"
    run_or_warn "bolt-cli manage-redis --action=install" "Redis"
    run_or_warn "bolt-cli manage-rspamd --action=install" "Rspamd"
    run_or_warn "bolt-cli manage-mlmmj --action=install" "MLMMJ"
    run_or_warn "bolt-cli manage-php --action=install --php-version=8.4" "PHP 8.4"
    run_or_warn "bolt-cli manage-my-apache --action=install" "MyApache"
    run_or_warn "bolt-cli manage-vsftpd --action=install" "Vsftpd"
    # Disk quota, on a box that has no accounts yet: the accounting pass is
    # instant here and enforcement is on from the first account, rather than
    # being switched on later under accounts that are already over their
    # plans. Warn-only - a filesystem that cannot carry quota is a reason to
    # tell the administrator, not to fail the install.
    run_or_warn "bolt-cli manage-disk-quota --action=install" "Disk quota enforcement"
    run_or_warn "bolt-cli manage-fail2ban --action=install" "Fail2Ban"
    for app in local-api filemanager phpmyadmin roundcube git metrics adminer; do
        run_or_warn "bolt-php ${WEB_INSTALL_ROOT}/artisan bolt:manage-app --action=install --app-name=${app}" "App ${app}"
    done
    sleep 5
    run_or_warn "bolt-cli manage-sshd-profiles --action=install" "SSH server profiles"
    run_or_warn "bolt-cli manage-postfix-profiles --action=install" "Postfix profiles"
    run_or_warn "bolt-cli manage-dovecot-profiles --action=install" "Dovecot profiles"
    run_or_warn "bolt-cli manage-redis-profiles --action=install" "Redis profiles"
    run_or_warn "bolt-cli manage-rspamd-profiles --action=install" "Rspamd profiles"
    run_or_warn "bolt-cli setup-firewall" "Firewall setup"
    run_or_warn "bolt-cli manage-mariadb-default-profile --action=install" "MariaDB profile"
    run_or_warn "bolt-cli manage-my-apache-default-profile --action=install" "MyApache profile"
    run_or_warn "bolt-cli manage-system-email-account --action=install" "System email"
    run_or_warn "bolt-cli manage-dns-records-default-template --action=install" "DNS template"
    run_or_warn "bolt-cli manage-php-default-profile --php-version=8.4 --action=install" "PHP 8.4 profile"
    run_or_warn "bolt-cli manage-vsftpd-profiles --action=install" "Vsftpd profile"
    run_or_warn "bolt-cli manage-fail2ban-profiles --action=install" "Fail2Ban profile"
    run_or_warn "bolt-cli setup-cron-jobs" "Setup Cron jobs"
    # Only records a provisioning plan and returns; the panel scheduler (installed by setup-cron-jobs) executes it in the background.
    run_or_warn "bolt-cli post-install-provision" "Queue post-install provisioning (remaining PHP versions, SecureBox, SymLock)"
    run_or_warn "bolt-cli setup-hidepid" "Harden /proc (hidepid)"
    # QA F2: a bare restart under set -e aborted the whole run (no trial
    # licence, no SSO URL, no banner) whenever rspamd was not installed.
    run_or_warn "systemctl restart rspamd" "Rspamd restart"
    # Trial licence last: nothing in the install depends on it, and the licence server refuses repeats
    # per e-mail and per IP, which must never abort an otherwise complete installation.
    local TRIAL_LICENCE_OK=0
    if [[ -n "$ADMIN_EMAIL" ]]; then
        # run_or_warn evaluates the command in this shell, so the assignment records the outcome.
        run_or_warn "bolt-cli request-trial-license --email=${ADMIN_EMAIL} && TRIAL_LICENCE_OK=1" "Request trial licence"
    else
        print_info "No --email= provided; skipping trial licence request. Activate a licence later on the panel's License page."
    fi
    # AB-2106: last, after every step that configures sshd, so they cannot undo it and a failed install keeps password login.
    ssh_password_login_off || true
    local SSO_URL=$(bolt-cli admin-sso-generate 2>/dev/null || echo "")
    [ -z "${SSO_URL}" ] && echo -e "${YELLOW}WARNING:${NC} SSO URL not generated" || print_success "SSO URL generated"
    [ -n "${SSH_PASSWORD_NOTE}" ] && echo -e "\n${SSH_PASSWORD_NOTE}"
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
    echo "Usage: sudo $0 [--help] [--version=<PANEL_VERSION>] [--source=<stable|staging|testing>] [--email=<address>] [--mariadb-version=<10.11|11.4>] [--ssh-key=<public key|https URL>]"
    echo "AlmaLinux 9 / Rocky Linux 9. Stages: 1=ready check, 2=(2.1 settings, 2.2 prereq packages, 2.3 bolt packages), 3=post-install."
    echo "If --version is not provided, latest bolt-panel from repo is installed."
    echo "If --source is not provided, the bolt-repo RPM from adminbolt is used (default). Otherwise repos point at pulp content stable/staging/testing."
    echo "If --mariadb-version is not provided, MariaDB 10.11 is installed; 11.4 is the newer long-term series (supported until 2029)."
    echo "If --email is provided, a 24h trial licence is requested for that address at the very end of the install (clicking the e-mailed confirmation link extends it to the full trial period); the install completes even if the request is refused."
    echo "Without --email the install proceeds unlicensed; activate on the panel's License page."
    echo "If --ssh-key is provided (a public key, or an https:// URL serving keys), the key is added to root's authorized_keys; SSH password login for root is turned off at the end only after a root sign-in with that key is seen (at a terminal the installer waits up to 10 minutes for one), otherwise it stays on."
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

    if [[ -n "$MARIADB_SERIES" ]]; then
        case "$MARIADB_SERIES" in
            10.11|11.4) ;;
            *)
                print_error "Invalid --mariadb-version=${MARIADB_SERIES} (supported: 10.11, 11.4)"
                print_usage
                exit 1
                ;;
        esac
    fi

    if [[ -n "$ADMIN_EMAIL" && ! "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        print_error "Invalid --email=${ADMIN_EMAIL}"
        print_usage
        exit 1
    fi

    if [[ -n "$BOLT_SOURCE" ]]; then
        case "$BOLT_SOURCE" in
            stable|staging|testing) ;;
            *)
                print_error "Invalid --source=${BOLT_SOURCE} (allowed: stable, staging, testing)"
                print_usage
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
    # anything specific to the agent package.
    mkdir -p /var/lib/adminbolt
    touch /var/lib/adminbolt/install-in-progress
    trap 'rm -f /var/lib/adminbolt/install-in-progress' EXIT

    echo -e "\n${BOLD}AdminBolt Staged Install (Stage 1 → 2 → 3)${NC}\n"
    TOTAL_START=$(date +%s)

    SECTION_START=$(date +%s)
    stage_prerequisites
    time_section_end "Stage 1: Prerequisites"

    SECTION_START=$(date +%s)
    stage_install_base_packages
    time_section_end "Stage 2: Base packages"

    SECTION_START=$(date +%s)
    stage_configuration
    time_section_end "Stage 3: Post-install actions"

    time_total_end
}

# ADMINBOLT_INSTALL_SOURCE_ONLY=1 loads the functions without running the
# install (tests/). An environment switch rather than a BASH_SOURCE check,
# which cannot tell `curl ... | bash` apart reliably.
if [[ "${ADMINBOLT_INSTALL_SOURCE_ONLY:-}" != 1 ]]; then
    main "$@"
fi
