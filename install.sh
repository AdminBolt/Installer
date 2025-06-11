#!/bin/bash

# Color definitions
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

# Get terminal width or fallback to 80
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
LINE=$(printf '%*s' "${TERM_WIDTH}" '' | tr ' ' '-')

# Group and user parameters
GROUP_NAME="boltweb"
GROUP_ID="801"
USER_NAME="boltweb"
USER_ID="801"
USER_HOME="/usr/local/bolt"
USER_SHELL="/sbin/nologin"

# Check if the user is root
if [[ ${EUID} -ne 0 ]]; then
	echo "This script must be run as root. Exiting..."
	exit 1
fi

# Check if the user is running a 64-bit system
if [[ $(uname -m) != "x86_64" ]]; then
	echo "This script must be run on a 64-bit system. Exiting..."
	exit 1
fi

# Check if the user is running a supported shell
if [[ $(echo ${SHELL}) != "/bin/bash" ]]; then
	echo "This script must be run on a system running Bash. Exiting..."
	exit 1
fi

# Check if the user is running a supported OS
if [[ $(uname -s) != "Linux" ]]; then
	echo "This script must be run on a Linux system. Exiting..."
	exit 1
fi

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING REPOSITORIES ${RESET}"
echo -e "${LINE}"
# System Update and Repositories
dnf update -y && echo "✅ System updated!" || echo "❌ System update failed!"
dnf install epel-release -y && echo "✅ EPEL repository installed!" || echo "❌ EPEL repository install failed!"
dnf config-manager --set-enabled epel && echo "✅ EPEL repository enabled!" || echo "❌ EPEL repository enable failed!"
dnf config-manager --set-enabled crb && echo "✅ CRB repository enabled!" || echo "❌ CRB repository enable failed!"

wget https://raw.githubusercontent.com/AdminBolt/Install/refs/heads/main/almalinux-9.5/repos/bolt.repo -q && echo "✅ Bolt repository downloaded!" || echo "❌ Bolt repository download failed!"
mv bolt.repo /etc/yum.repos.d/bolt.repo && echo "✅ Bolt repository installed!" || echo "❌ Bolt repository install failed!"


echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING PACKAGES ${RESET}"
echo -e "${LINE}"
# Install Required Dependencies
DEPENDENCIES_LIST=(
	"sudo"
	"apg"
	"openssl"
	"jq"
	"curl"
	"wget"
	"unzip"
	"zip"
	"tar"
	"gnupg2"
	"ca-certificates"
	"supervisor"
	"libsodium"
	"libsodium-devel"
    "bolt-php"
    "bolt-nginx"
    "bolt-updater"
)
for DEP in "${DEPENDENCIES_LIST[@]}"; do
    RPM_QUERY=$(rpm -q "$DEP" 2>&1)  # Capture both output and error
    if [ $? -eq 0 ]; then
        echo -e "✅ $DEP is already installed: ${RPM_QUERY}"
    else
        echo -e "⚠️ $DEP is not installed. rpm output: ${RPM_QUERY}"
        echo -e "Installing $DEP..."
        dnf install -y "$DEP"
    fi
done

# Create boltweb User
echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}CREATING SYSTEM USER ${RESET}"
echo -e "${LINE}"

# Create system group
if getent group "${GROUP_NAME}" >/dev/null; then
	echo -e "✅ Group '${GROUP_NAME}' already exists."
else
	echo -e "Creating group '${GROUP_NAME}' with GID ${GROUP_ID}..."
	if groupadd --system --gid "${GROUP_ID}" "${GROUP_NAME}"; then
		echo -e "✅ Group '${GROUP_NAME}' created."
	else
		echo -e "❌ Failed to create group '${GROUP_NAME}'."
		exit 1
	fi
fi

# Create system user
if id "${USER_NAME}" >/dev/null 2>&1; then
	echo -e "✅ User '${USER_NAME}' already exists."
else
	echo -e "Creating user '${USER_NAME}' with UID ${USER_ID}..."
	if useradd --uid "${USER_ID}" --gid "${GROUP_ID}" --home "${USER_HOME}" --shell "${USER_SHELL}" "${USER_NAME}"; then
		echo -e "✅ User '${USER_NAME}' created."
	else
		echo -e "❌ Failed to create user '${USER_NAME}'."
		exit 1
	fi
fi

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING BOLT REPOSITORIES ${RESET}"
echo -e "${LINE}"
# Atomic Repo (optional tools)
# sudo wget -q -O - http://www.atomicorp.com/installers/atomic | sh

# Add AdminBolt Greeting and Repos
wget https://raw.githubusercontent.com/AdminBolt/Install/refs/heads/main/almalinux-9.5/greeting.sh -q && echo "✅ Greeting text downloaded!" || echo "❌ Greeting text download failed!"
mv greeting.sh /etc/profile.d/bolt-greeting.sh && echo "✅ Greeting text installed!" || echo "❌ Greeting text install failed!"

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING ADMINBOLT PANEL ${RESET}"
echo -e "${LINE}"

# Create folder if it doesn't exist
if [ ! -d /usr/local/bolt ]; then
    mkdir -p /usr/local/bolt
    chown boltweb:boltweb /usr/local/bolt
    chmod 750 /usr/local/bolt
    dnf reinstall -y bolt-php bolt-nginx bolt-updater
else
    echo "✅ /usr/local/bolt exists..."
fi

# Find latest stable version of AdminBolt Panel
GET_LATEST_ADMINBOLT_VERSION=$(curl -s "https://license.adminbolt.com/api/get-latest-version-of-package?os=any&os_version=any&name=adminbolt-web&branch=stable")
ADMINBOLT_VERSION=$(echo "$GET_LATEST_ADMINBOLT_VERSION" | jq -r '.latest_version')
DOWNLOAD_LINK=$(echo "$GET_LATEST_ADMINBOLT_VERSION" | jq -r '.package.download_link')
if [[ -z "$ADMINBOLT_VERSION" || -z "$DOWNLOAD_LINK" ]]; then
    echo -e "${RED}❌ Failed to retrieve the latest version or download link. Exiting...${RESET}"
    exit 1
fi

echo -e "✅ Latest AdminBolt Panel version: ${ADMINBOLT_VERSION}"

# Download and Extract AdminBolt Panel
{
    wget $DOWNLOAD_LINK -O adminbolt-cp.zip -q
} && echo "✅ AdminBolt Panel downloaded!" || echo "❌ AdminBolt Panel download failed!"

{
unzip -qq -o adminbolt-cp.zip -d /usr/local/bolt/web
} && echo "✅ AdminBolt Panel deployed!" || echo "❌ AdminBolt Panel deploy failed!"

rm -rf adminbolt-cp.zip

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING ADMINBOLT PANEL ${RESET}"
echo -e "${LINE}"

# Install SSL Certificates
mkdir -p /usr/local/bolt/ssl
{
    cp /usr/local/bolt/web/server/ssl/bolt.crt /usr/local/bolt/ssl/bolt.crt
    cp /usr/local/bolt/web/server/ssl/bolt.key /usr/local/bolt/ssl/bolt.key
    cp /usr/local/bolt/web/server/ssl/bolt.chain /usr/local/bolt/ssl/bolt.chain
} && echo "✅ Installed SSL Certificates!" || echo "❌ Install SSL Certificates failed!"

# Apply NGINX & PHP Configuration
{
    mkdir -p /usr/local/bolt/nginx/conf
    cp /usr/local/bolt/web/server/nginx/nginx.conf /usr/local/bolt/nginx/conf/nginx.conf

    mkdir -p /usr/local/bolt/php/etc
    cp /usr/local/bolt/web/server/php/php-fpm.conf /usr/local/bolt/php/etc/php-fpm.conf

    mkdir -p /usr/local/bolt/php/lib
    cp /usr/local/bolt/web/server/php/php.ini /usr/local/bolt/php/lib/php.ini
} && echo "✅ NGINX & PHP Configuration applied!" || echo "❌ NGINX & PHP Configuration failed!"

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}SET OWNERSHIP AND PERMISSIONS ${RESET}"
echo -e "${LINE}"

# Set Ownership and Permissions
{
    # Ensure the boltweb user owns the /usr/local/bolt directory
    chown -R boltweb:boltweb /usr/local/bolt
    chmod 750 /usr/local/bolt
} && echo "✅ Ownership and permissions set for /usr/local/bolt!" || echo "❌ Ownership and permissions failed!"

{
    # Set 750 for directories
    find /usr/local/bolt -type d -exec chmod 750 {} \;
    # Set 640 for regular files
    find /usr/local/bolt -type f -exec chmod 640 {} \;
} && echo "✅ Permissions set for directories and files!" || echo "❌ Permissions set for directories and files failed!"

{
    # Set +x for scripts and artisan
    chmod +x /usr/local/bolt/php/sbin/bolt-php-fpm
    chmod +x /usr/local/bolt/nginx/sbin/bolt-nginx
    find /usr/local/bolt -type f -name "*.sh" -exec chmod +x {} \;
    find /usr/local/bolt -type f -name "*artisan*" -exec chmod +x {} \;
} && echo "✅ Permissions set for scripts and artisan!" || echo "❌ Permissions set for scripts and artisan failed!"

{
    # Set Web Permissions
    chmod -R o+w /usr/local/bolt/web/storage/
    chmod -R o+w /usr/local/bolt/web/bootstrap/cache/
} && echo "✅ Permissions set for webapp work directories!" || echo "❌ Permissions set for webapp directories failed!"

{
    # Set Permissions and Shell Tools
    ln -sf /usr/local/bolt/php/bin/php /usr/bin/bolt-php
    chmod +x /usr/local/bolt/php/bin/php
    ln -sf /usr/local/bolt/web/bolt-shell.sh /usr/bin/bolt-shell
    chmod +x /usr/local/bolt/web/bolt-shell.sh
    ln -sf /usr/local/bolt/web/bolt-cli.sh /usr/bin/bolt-cli
    chmod +x /usr/local/bolt/web/bolt-cli.sh
} && echo "✅ Permissions set for Shell Tools!" || echo "❌ Permissions set for Shell Tools failed!"

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}SENDING INSTALLATION STATS TO ADMINBOLT API... ${RESET}"
echo -e "${LINE}"

# Log OS Info to AdminBolt API
HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | cut -d " " -f 1)
DISTRO_VERSION=$(grep -w "VERSION_ID" /etc/os-release | cut -d '"' -f 2)
DISTRO_NAME=$(grep -w "NAME" /etc/os-release | cut -d '"' -f 2)
LOG_JSON='{"os": "'$DISTRO_NAME-$DISTRO_VERSION'", "host_name": "'$HOSTNAME'", "ip": "'$IP_ADDRESS'"}'
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" https://adminbolt.com/api/bolt-installation-log \
  -X POST -H "Content-Type: application/json" -d "$LOG_JSON")

if [[ "${RESPONSE}" = "200" ]]; then
    echo -e "✅ Installation log sent successfully."
else
    echo -e "❌ Failed to send log to AdminBolt API (HTTP ${RESPONSE})."
fi

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}START BOLT SERVICES ${RESET}"
echo -e "${LINE}"
{
    # Start Bolt Services
    service bolt start
} && echo "✅ Bolt Services started!" || echo "❌ Bolt Services failed to start!"

echo -e ""
echo -e "${LINE}"
echo -e "${BOLD}INSTALLING HOSTING SERVICES... ${RESET}"
echo -e "${LINE}"

# Install all required packages in one go
dnf install -y \
  yum-utils \
  supervisor \
  bolt-securebox \
  git \
  fail2ban \
  traceroute \
  vsftpd \
  pam-devel \
  libdb-utils \
  gcc \
  make \
  firewalld \
  sscg \
  mod_maxminddb \
  mod_security \
  mod_ssl \
  mod_suphp \
  php84 \
  php84-php-fpm \
  goaccess \
  GeoIP \
  GeoIP-devel \
  GeoIP-data \
  httpd --enablerepo=bolt

dnf update -y
dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm -y
dnf install https://rpms.remirepo.net/enterprise/remi-release-9.rpm -y

chmod +x /usr/local/bolt/web/bolt-install.sh
/usr/local/bolt/web/bolt-install.sh
