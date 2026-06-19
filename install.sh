#!/bin/bash
#
# AdminBolt Install Script (AlmaLinux 9, Rocky Linux 9)
#
# Reorganizes the installation into four stages:
#   Stage 1: Check that everything is in place and ready for installation
#   Stage 2: Full system update (dnf update -y) — must succeed before AdminBolt is installed
#   Stage 3: (3.1) Prepare settings → (3.2) Install prerequisite packages → (3.3) Install all Bolt packages
#   Stage 4: Execute bolt-cli / post-install actions (database, agent, services, profiles, etc.)
#
# Supported: AlmaLinux 9, Rocky Linux 9. Panel is installed from RPM; %pre/%post skipped.
# Usage:
#   sudo ./install.sh                          # install latest bolt-panel from repo
#   sudo ./install.sh --version=1.0.0.beta3-v46.el9 # install specific bolt-panel version from repo
#   sudo ./install.sh --source=staging         # use staging pulp repos (stable|staging|testing); default unchanged
#
set -e

# ---------------------------------------------------------------------------
# bolt-panel install: from repo (latest by default; --version= selects a specific version)
# ---------------------------------------------------------------------------
PANEL_VERSION=""
# Empty = current behavior (bolt-repo RPM from adminbolt). stable|staging|testing = pulp content path segment.
BOLT_SOURCE=""
# Set to "true" once the full system update (Stage 2) completes successfully.
SYSTEM_UPDATED="false"
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
    print_success "Stage 1 completed: ready for installation"
    print_progress "25% — prerequisites"
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

# ---------- Stage 2: Full system update ----------
# Bring every installed package up to date BEFORE any AdminBolt-specific
# installation commands run, so dependencies resolve against the latest
# package versions and the risk of conflicts during setup is reduced.
# Mandatory: if the update fails the installer aborts with a non-zero exit
# code and no AdminBolt packages are touched.
stage_system_update() {
    print_info "Stage 2: Performing full system update before installing AdminBolt"
    print_info "Running 'dnf update -y' — this may take a while, please wait..."
    if command -v dnf >/dev/null 2>&1; then
        run_or_fail "dnf update -y" "Full system update (dnf update -y)"
    elif command -v yum >/dev/null 2>&1; then
        run_or_fail "yum update -y" "Full system update (yum update -y)"
    else
        print_error "Neither dnf nor yum is available; cannot perform the required system update"
        exit 1
    fi
    SYSTEM_UPDATED="true"
    print_success "Stage 2 completed: system fully updated, proceeding with AdminBolt installation"
    print_progress "50% — system update"
}

# ---------- Stage 3: Install base packages ----------
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

# ---------- Stage 3: Prepare → Prerequisite packages → Bolt packages ----------
# Step 3.1: Prepare all settings (no package installs)
stage3_prepare_settings() {
    print_info "Stage 3.1: Preparing settings"
    run_or_warn "setenforce 0" "SELinux enforce"
    run_or_warn "sed -i 's#^SELINUX=.*#SELINUX=disabled#' /etc/selinux/config" "SELinux config"
    print_success "Stage 3.1 completed: settings prepared"
}

# Step 3.2: Install all prerequisite packages (EPEL, CRB, libsodium, traceroute, openssl, jq, etc.)
stage3_install_prerequisite_packages() {
    print_info "Stage 3.2: Installing prerequisite packages"
    print_info "Enabling CRB (CodeReady Builder) repository"
    install_packages epel-release dnf-plugins-core
    run_or_warn "dnf config-manager --set-enabled crb" "Enable CRB repo"
    install_packages \
        libsodium traceroute openssl jq rsync ca-certificates wget curl tar gzip unzip zip sudo apg \
        systemd openssl-libs libcurl libzip zlib gmp freetype libjpeg-turbo libpng libwebp libXpm gd \
        gettext-libs libicu sqlite-libs oniguruma libxslt shadow-utils
    run_or_warn "curl https://get.acme.sh | sh -s email=issue-ssl@adminbolt.com" "acme.sh"
    print_success "Stage 3.2 completed: prerequisite packages installed"
}

# Step 3.3: Install all Bolt packages (repo, bolt-nginx/php/agent, panel RPM)
stage3_install_bolt_packages() {
    print_info "Stage 3.3: Installing all Bolt packages"
    install_repo_rhel 9
    local panel_pkg="bolt-panel"
    if [[ -n "$PANEL_VERSION" ]]; then
        panel_pkg="bolt-panel-${PANEL_VERSION}"
        print_info "Installing specific bolt-panel version: ${PANEL_VERSION}"
    fi
    install_packages --enablerepo=bolt bolt-agent bolt-nginx bolt-php "$panel_pkg"
    systemctl enable --now bolt-nginx bolt-php
    print_success "Stage 3.3 completed: all Bolt packages installed"
}

stage_install_base_packages() {
    print_info "Stage 3: Prepare settings → Prerequisite packages → Bolt packages"
    SECTION_START=$(date +%s)
    stage3_prepare_settings
    time_section_end "Stage 3.1: Prepare settings"
    SECTION_START=$(date +%s)
    stage3_install_prerequisite_packages
    time_section_end "Stage 3.2: Prerequisite packages"
    SECTION_START=$(date +%s)
    stage3_install_bolt_packages
    time_section_end "Stage 3.3: Bolt packages"
    print_success "Stage 3 completed"
    print_progress "75% — base packages"
}

# ---------- Stage 4: Execute bolt-cli / Install services ----------
stage_configuration() {
    print_info "Stage 4: Executing bolt-cli / post-install actions"
    run_or_fail "bolt-cli request-trial-license" "Request trial licence"
    run_or_fail "bolt-cli connect-bolt-agent-with-panel" "Connect bolt-agent to panel"
    run_or_warn "bolt-cli add-bolt-greeting-message" "Add bolt greeting message"
    run_or_warn "bolt-cli manage-nftable --action=install" "Nftable"
    run_or_warn "bolt-cli manage-sshd --action=install" "SSH server"
    run_or_warn "bolt-cli manage-powerdns --action=install" "PowerDNS"
    run_or_warn "bolt-cli manage-mariadb --action=install" "MariaDB"
    run_or_warn "bolt-cli manage-postfix --action=install" "Postfix"
    run_or_warn "bolt-cli manage-dovecot --action=install" "Dovecot"
    run_or_warn "bolt-cli manage-redis --action=install" "Redis"
    run_or_warn "bolt-cli manage-rspamd --action=install" "Rspamd"
    run_or_warn "bolt-cli manage-mlmmj --action=install" "MLMMJ"
    run_or_warn "bolt-cli manage-php --action=install --php-version=8.4" "PHP 8.4"
    run_or_warn "bolt-cli manage-my-apache --action=install" "MyApache"
    run_or_warn "bolt-cli manage-vsftpd --action=install" "Vsftpd"
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
    systemctl restart rspamd
    local SSO_URL=$(bolt-cli admin-sso-generate 2>/dev/null || echo "")
    [ -z "${SSO_URL}" ] && echo -e "${YELLOW}WARNING:${NC} SSO URL not generated" || print_success "SSO URL generated"
    echo -e "\n${BOLD}${GREEN}+----------------------------------------------------------+${NC}"
    echo -e "${BOLD}${GREEN}|          Installation Completed Successfully             |${NC}"
    echo -e "${BOLD}${GREEN}+----------------------------------------------------------+${NC}\n"
    if [ "$SYSTEM_UPDATED" = "true" ]; then
        print_success "AdminBolt was installed after a successful full system update (dnf update -y)"
    fi
    [ -n "${SSO_URL:-}" ] && echo -e "${BOLD}${CYAN}--- Access ---${NC}\n${GREEN}Admin Panel:${NC}\n${BOLD}${SSO_URL}${NC}\n"
    echo -e "${GREEN}New SSO URL:${NC}\n${BOLD}bolt-cli admin-sso-generate${NC}"
    print_progress "100% — post-install"
    print_success "Stage 4 completed: all post-install actions done"
}

# ---------- Main ----------
print_usage() {
    echo "Usage: sudo $0 [--help] [--version=<PANEL_VERSION>] [--source=<stable|staging|testing>]"
    echo "AlmaLinux 9 / Rocky Linux 9. Stages: 1=ready check, 2=full system update, 3=(3.1 settings, 3.2 prereq packages, 3.3 bolt packages), 4=post-install."
    echo "If --version is not provided, latest bolt-panel from repo is installed."
    echo "If --source is not provided, the bolt-repo RPM from adminbolt is used (default). Otherwise repos point at pulp content stable/staging/testing."
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
        esac
    done

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
    echo -e "\n${BOLD}AdminBolt Staged Install (Stage 1 → 2 → 3 → 4)${NC}\n"
    TOTAL_START=$(date +%s)

    SECTION_START=$(date +%s)
    stage_prerequisites
    time_section_end "Stage 1: Prerequisites"

    SECTION_START=$(date +%s)
    stage_system_update
    time_section_end "Stage 2: Full system update"

    SECTION_START=$(date +%s)
    stage_install_base_packages
    time_section_end "Stage 3: Base packages"

    SECTION_START=$(date +%s)
    stage_configuration
    time_section_end "Stage 4: Post-install actions"

    time_total_end
}

main "$@"
