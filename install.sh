#!/bin/bash

# Check is AdminBolt is already installed
if [ -d "/usr/local/bolt" ]; then
echo "AdminBolt is already installed. Exiting..."
exit 0
fi

# Check if the user is root
if [[ $EUID -ne 0 ]]; then
echo "This script must be run as root. Exiting..."
exit 1
fi

# Check if the user is running a 64-bit system
if [[ $(uname -m) != "x86_64" ]]; then
echo "This script must be run on a 64-bit system. Exiting..."
exit 1
fi

# Check if the user is running a supported shell
if [[ $(echo $SHELL) != "/bin/bash" ]]; then
echo "This script must be run on a system running Bash. Exiting..."
exit 1
fi

# Check if the user is running a supported OS
if [[ $(uname -s) != "Linux" ]]; then
echo "This script must be run on a Linux system. Exiting..."
exit 1
fi

# Check if the user is running a supported distro version
DISTRO_VERSION=$(cat /etc/os-release | grep -w "VERSION_ID" | cut -d "=" -f 2)
DISTRO_VERSION=${DISTRO_VERSION//\"/} # Remove quotes from version string

DISTRO_NAME=$(cat /etc/os-release | grep -w "NAME" | cut -d "=" -f 2)
DISTRO_NAME=${DISTRO_NAME//\"/} # Remove quotes from name string
# Lowercase the distro name
DISTRO_NAME=$(echo $DISTRO_NAME | tr '[:upper:]' '[:lower:]')
# replace spaces
DISTRO_NAME=${DISTRO_NAME// /-}


installAlmalinuxNineFour()
{
    INSTALL_DIR="/bolt/install"

yum update -y
dnf -y install sudo wget
export NON_INT=1
sudo wget -q -O - http://www.atomicorp.com/installers/atomic | sh
dnf install epel-release -y
dnf config-manager --set-enabled epel
dnf config-manager --set-enabled crb
yum install -y libsodium libsodium-devel

mkdir -p $INSTALL_DIR

cd $INSTALL_DIR

DEPENDENCIES_LIST=(
    "apg"
    "openssl"
    "jq"
    "curl"
    "wget"
    "unzip"
    "zip"
    "tar"
    "mysql-common"
    "mysql-server"
    "lsb-release"
    "gnupg2"
    "ca-certificates"
    "apt-transport-https"
    "supervisor"
)
# Check if the dependencies are installed
for DEPENDENCY in "${DEPENDENCIES_LIST[@]}"; do
    dnf install -y $DEPENDENCY
done

## Start MySQL
systemctl start mysqld
systemctl enable mysqld

cat > /etc/profile.d/bolt-greeting.sh <<EOF
#!/bin/bash

CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "
 Welcome to AdminBolt!
 OS: AlmaLinux 9.4
 You can login at: http://$CURRENT_IP:8443
"
EOF

dnf install https://license.adminbolt.com/mirrorlist/almalinux/9/bolt-repo-1.0.0-1.el9.noarch.rpm -y

dnf install -y bolt-php --enablerepo=bolt
dnf install -y bolt-nginx --enablerepo=bolt
dnf install -y bolt-updater --enablerepo=bolt
dnf install -y httpd --enablerepo=bolt

systemctl start httpd
systemctl enable httpd

BOLT_PHP=/usr/local/bolt/php/bin/php
ln -s $BOLT_PHP /usr/bin/bolt-php
HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | cut -d " " -f 1)

DISTRO_VERSION=$(cat /etc/os-release | grep -w "VERSION_ID" | cut -d "=" -f 2)
DISTRO_VERSION=${DISTRO_VERSION//\"/} # Remove quotes from version string

DISTRO_NAME=$(cat /etc/os-release | grep -w "NAME" | cut -d "=" -f 2)
DISTRO_NAME=${DISTRO_NAME//\"/} # Remove quotes from name string

LOG_JSON='{"os": "'$DISTRO_NAME-$DISTRO_VERSION'", "host_name": "'$HOSTNAME'", "ip": "'$IP_ADDRESS'"}'

curl -s https://adminbolt.com/api/bolt-installation-log -X POST -H "Content-Type: application/json" -d "$LOG_JSON"

USE_WEB_SOURCE_FROM_PATH=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --use-web-source-from-path=*) USE_WEB_SOURCE_FROM_PATH="${1#*=}";;
        --use-web-source-from-path) USE_WEB_SOURCE_FROM_PATH="$2"; shift;;
    esac
    shift
done

if [[ -d USE_WEB_SOURCE_FROM_PATH ]]; then
    echo "Using web source from path"
    cp -r $USE_WEB_SOURCE_FROM_PATH /usr/local/bolt/web/
else
    echo "Downloading web source"
    wget https://license.adminbolt.com/mirrorlist/any/any/adminbolt-web-stable.zip -O adminbolt-cp.zip -q
    unzip -qq -o adminbolt-cp.zip -d /usr/local/bolt/web
    rm -rf adminbolt-cp.zip
fi

# Check dir exists
if [ ! -d "/usr/local/bolt/web" ]; then
  echo "AdminBolt directory not found."
  exit 1
fi

chmod 711 /home
chmod -R 750 /usr/local/bolt

ln -s /usr/local/bolt/web/bolt-shell.sh /usr/bin/bolt-shell
chmod +x /usr/local/bolt/web/bolt-shell.sh

ln -s /usr/local/bolt/web/bolt-cli.sh /usr/bin/bolt-cli
chmod +x /usr/local/bolt/web/bolt-cli.sh

mkdir -p /usr/local/bolt/ssl
cp /usr/local/bolt/web/server/ssl/bolt.crt /usr/local/bolt/ssl/bolt.crt
cp /usr/local/bolt/web/server/ssl/bolt.key /usr/local/bolt/ssl/bolt.key
cp /usr/local/bolt/web/server/ssl/bolt.chain /usr/local/bolt/ssl/bolt.chain


# Go to web directory
cd /usr/local/bolt/web

chmod -R o+w /usr/local/bolt/web/storage/
chmod -R o+w /usr/local/bolt/web/bootstrap/cache/

rm -rf /usr/local/bolt/php/lib/php.ini
ln -s /usr/local/bolt/web/server/php/php.ini /usr/local/bolt/php/lib/php.ini

rm -rf /usr/local/bolt/php/etc/php-fpm.conf
ln -s /usr/local/bolt/web/server/php/php-fpm.conf /usr/local/bolt/php/etc/php-fpm.conf

rm -rf /usr/local/bolt/nginx/conf/nginx.conf
ln -s /usr/local/bolt/web/server/nginx/nginx.conf /usr/local/bolt/nginx/conf/nginx.conf


service bolt start

bolt-php /usr/local/bolt/web/artisan bolt:install-core

}

installAlmalinuxNineFive()
{
    INSTALL_DIR="/bolt/install"

yum update -y
dnf -y install sudo wget
export NON_INT=1
sudo wget -q -O - http://www.atomicorp.com/installers/atomic | sh
dnf install epel-release -y
dnf config-manager --set-enabled epel
dnf config-manager --set-enabled crb
yum install -y libsodium libsodium-devel

mkdir -p $INSTALL_DIR

cd $INSTALL_DIR

DEPENDENCIES_LIST=(
    "apg"
    "openssl"
    "jq"
    "curl"
    "wget"
    "unzip"
    "zip"
    "tar"
    "mysql-common"
    "mysql-server"
    "lsb-release"
    "gnupg2"
    "ca-certificates"
    "apt-transport-https"
    "supervisor"
)
# Check if the dependencies are installed
for DEPENDENCY in "${DEPENDENCIES_LIST[@]}"; do
    dnf install -y $DEPENDENCY
done

## Start MySQL
systemctl start mysqld
systemctl enable mysqld


cat > /etc/profile.d/bolt-greeting.sh <<EOF
#!/bin/bash

CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "
 Welcome to AdminBolt!
 OS: AlmaLinux 9.5
 You can login at: http://$CURRENT_IP:8443
"
EOF

dnf install https://license.adminbolt.com/mirrorlist/almalinux/9/bolt-repo-1.0.0-1.el9.noarch.rpm -y


dnf install -y bolt-php --enablerepo=bolt
dnf install -y bolt-nginx --enablerepo=bolt
dnf install -y bolt-updater --enablerepo=bolt
dnf install -y httpd --enablerepo=bolt

systemctl start httpd
systemctl enable httpd

BOLT_PHP=/usr/local/bolt/php/bin/php
ln -s $BOLT_PHP /usr/bin/bolt-php
HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | cut -d " " -f 1)

DISTRO_VERSION=$(cat /etc/os-release | grep -w "VERSION_ID" | cut -d "=" -f 2)
DISTRO_VERSION=${DISTRO_VERSION//\"/} # Remove quotes from version string

DISTRO_NAME=$(cat /etc/os-release | grep -w "NAME" | cut -d "=" -f 2)
DISTRO_NAME=${DISTRO_NAME//\"/} # Remove quotes from name string

LOG_JSON='{"os": "'$DISTRO_NAME-$DISTRO_VERSION'", "host_name": "'$HOSTNAME'", "ip": "'$IP_ADDRESS'"}'

curl -s https://adminbolt.com/api/bolt-installation-log -X POST -H "Content-Type: application/json" -d "$LOG_JSON"

USE_WEB_SOURCE_FROM_PATH=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --use-web-source-from-path=*) USE_WEB_SOURCE_FROM_PATH="${1#*=}";;
        --use-web-source-from-path) USE_WEB_SOURCE_FROM_PATH="$2"; shift;;
    esac
    shift
done

if [[ -d USE_WEB_SOURCE_FROM_PATH ]]; then
    echo "Using web source from path"
    cp -r $USE_WEB_SOURCE_FROM_PATH /usr/local/bolt/web/
else
    echo "Downloading web source"
    wget https://license.adminbolt.com/mirrorlist/any/any/adminbolt-web-stable.zip -O adminbolt-cp.zip -q
    unzip -qq -o adminbolt-cp.zip -d /usr/local/bolt/web
    rm -rf adminbolt-cp.zip
fi

# Check dir exists
if [ ! -d "/usr/local/bolt/web" ]; then
  echo "AdminBolt directory not found."
  exit 1
fi

chmod 711 /home
chmod -R 750 /usr/local/bolt

ln -s /usr/local/bolt/web/bolt-shell.sh /usr/bin/bolt-shell
chmod +x /usr/local/bolt/web/bolt-shell.sh

ln -s /usr/local/bolt/web/bolt-cli.sh /usr/bin/bolt-cli
chmod +x /usr/local/bolt/web/bolt-cli.sh

mkdir -p /usr/local/bolt/ssl
cp /usr/local/bolt/web/server/ssl/bolt.crt /usr/local/bolt/ssl/bolt.crt
cp /usr/local/bolt/web/server/ssl/bolt.key /usr/local/bolt/ssl/bolt.key
cp /usr/local/bolt/web/server/ssl/bolt.chain /usr/local/bolt/ssl/bolt.chain


# Go to web directory
cd /usr/local/bolt/web

chmod -R o+w /usr/local/bolt/web/storage/
chmod -R o+w /usr/local/bolt/web/bootstrap/cache/

rm -rf /usr/local/bolt/php/lib/php.ini
ln -s /usr/local/bolt/web/server/php/php.ini /usr/local/bolt/php/lib/php.ini

rm -rf /usr/local/bolt/php/etc/php-fpm.conf
ln -s /usr/local/bolt/web/server/php/php-fpm.conf /usr/local/bolt/php/etc/php-fpm.conf

rm -rf /usr/local/bolt/nginx/conf/nginx.conf
ln -s /usr/local/bolt/web/server/nginx/nginx.conf /usr/local/bolt/nginx/conf/nginx.conf


service bolt start

bolt-php /usr/local/bolt/web/artisan bolt:install-core

}

if [[ $DISTRO_NAME == "almalinux" && $DISTRO_VERSION == "9.5" ]]; then
    echo "Supported OS detected: $DISTRO_NAME $DISTRO_VERSION"
    installAlmalinuxNineFive
elif [[ $DISTRO_NAME == "almalinux" && $DISTRO_VERSION == "9.4" ]]; then
    echo "Supported OS detected: $DISTRO_NAME $DISTRO_VERSION"
    installAlmalinuxNineFour
else
    echo "Unsupported OS detected: $DISTRO_NAME $DISTRO_VERSION. Exiting..."
    exit 1
fi
