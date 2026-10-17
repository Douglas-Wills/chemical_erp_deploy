#!/usr/bin/env bash
# ==============================================================================
# BRAVE CHEMICALS - AUTOMATED HOSTINGER VPS DEPLOYMENT & MIGRATION SCRIPT
# Target OS: Ubuntu 22.04 LTS / 24.04 LTS (x86_64)
# Apps: Frappe v15 + ERPNext v15 + HRMS v15 + Chemical ERP v1.0.7
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}====================================================================${NC}"
echo -e "${CYAN}   BRAVE CHEMICALS ERP - LIVE SERVER PRODUCTION DEPLOYMENT          ${NC}"
echo -e "${CYAN}   Hostinger VPS Automated Provisioning & Data Migration            ${NC}"
echo -e "${CYAN}====================================================================${NC}"

# Check root privilege
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] This script must be run as root (or with sudo). Exiting.${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration defaults
DEFAULT_SITE="bravechemicals.online"
DEFAULT_EMAIL="admin@bravechemicals.online"

if [ -z "$SITE_NAME" ]; then
  echo -e "\n${YELLOW}Domain for this ERP installation (default: ${DEFAULT_SITE}):${NC}"
  read -rp "Domain [${DEFAULT_SITE}]: " INPUT_SITE
  SITE_NAME="${INPUT_SITE:-$DEFAULT_SITE}"
fi

if [ -z "$DB_ROOT_PASSWORD" ]; then
  echo -e "\n${YELLOW}Please enter a secure password for MariaDB root:${NC}"
  read -rsp "MariaDB Root Password: " DB_ROOT_PASSWORD
  echo ""
fi

if [ -z "$ADMIN_PASSWORD" ]; then
  echo -e "\n${YELLOW}Please enter the Administrator password for your ERP site:${NC}"
  read -rsp "ERP Administrator Password: " ADMIN_PASSWORD
  echo ""
fi

if [ -z "$SSL_EMAIL" ]; then
  echo -e "\n${YELLOW}Email address for Let's Encrypt SSL certificate (default: ${DEFAULT_EMAIL}):${NC}"
  read -rp "Admin Email [${DEFAULT_EMAIL}]: " INPUT_EMAIL
  SSL_EMAIL="${INPUT_EMAIL:-$DEFAULT_EMAIL}"
fi

echo -e "\n${GREEN}[1/8] Updating Ubuntu system packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo -e "\n${GREEN}[2/8] Installing core system dependencies, Python, Git, and Redis...${NC}"
apt-get install -y \
  git \
  curl \
  wget \
  build-essential \
  python3-dev \
  python3-pip \
  python3-venv \
  python3-setuptools \
  redis-server \
  supervisor \
  nginx \
  libffi-dev \
  libssl-dev \
  libjpeg-dev \
  zlib1g-dev \
  libxml2-dev \
  libxslt1-dev \
  liblcms2-dev \
  libwebp-dev \
  tcl8.6-dev \
  tk8.6-dev \
  pkg-config \
  cron \
  certbot \
  python3-certbot-nginx

# Configure Redis
systemctl enable redis-server
systemctl start redis-server

echo -e "\n${GREEN}[3/8] Installing & Configuring MariaDB Server...${NC}"
apt-get install -y mariadb-server mariadb-client libmariadb-dev

# Frappe requires utf8mb4 encoding in MariaDB
cat << 'EOF' > /etc/mysql/mariadb.conf.d/99-frappe.cnf
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
bind-address = 127.0.0.1
max_allowed_packet = 128M
innodb_file_per_table = 1
innodb_buffer_pool_size = 512M

[mysql]
default-character-set = utf8mb4
EOF

systemctl restart mariadb
systemctl enable mariadb

# Set MariaDB root password and secure
SQL_CMDS="ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "${SQL_CMDS}" 2>/dev/null || mysql -u root -e "${SQL_CMDS}" 2>/dev/null || true

echo -e "\n${GREEN}[4/8] Installing Node.js, npm, yarn, and wkhtmltopdf...${NC}"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
fi
if ! command -v yarn &> /dev/null; then
  npm install -g yarn --force || true
fi

# Install wkhtmltopdf with patched qt for clean PDF printing
if ! command -v wkhtmltopdf &> /dev/null; then
  ARCH=$(dpkg --print-architecture)
  UBUNTU_CODENAME=$(lsb_release -cs)
  WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.${UBUNTU_CODENAME}_${ARCH}.deb"
  if curl --output /dev/null --silent --head --fail "$WK_URL"; then
    wget -q "$WK_URL" -O /tmp/wkhtmltox.deb
    apt-get install -y /tmp/wkhtmltox.deb || apt-get install -f -y
    rm -f /tmp/wkhtmltox.deb
  else
    apt-get install -y wkhtmltopdf
  fi
fi

echo -e "\n${GREEN}[5/8] Creating 'frappe' system user and installing Frappe Bench...${NC}"
if ! id -u frappe &>/dev/null; then
  useradd -m -s /bin/bash -d /home/frappe frappe
  echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe
  chmod 0440 /etc/sudoers.d/frappe
fi

# Install bench CLI
pip3 install frappe-bench --break-system-packages 2>/dev/null || pip3 install frappe-bench

echo -e "\n${GREEN}[6/8] Initializing Frappe Bench v15...${NC}"
BENCH_DIR="/home/frappe/frappe-bench"

if [ ! -d "$BENCH_DIR" ]; then
  su - frappe -c "bench init --frappe-branch version-15 --python $(which python3) ${BENCH_DIR}"
fi

# Fetch official apps
echo -e "\n${CYAN}Fetching ERPNext and HRMS v15 apps...${NC}"
if [ ! -d "$BENCH_DIR/apps/erpnext" ]; then
  su - frappe -c "cd ${BENCH_DIR} && bench get-app erpnext --branch version-15"
fi

if [ ! -d "$BENCH_DIR/apps/hrms" ]; then
  su - frappe -c "cd ${BENCH_DIR} && bench get-app hrms --branch version-15"
fi

# Install Chemical ERP custom app
echo -e "\n${CYAN}Deploying Chemical ERP app...${NC}"
if [ -f "$SCRIPT_DIR/chemical_erp.tar.gz" ]; then
  rm -rf "$BENCH_DIR/apps/chemical_erp"
  mkdir -p "$BENCH_DIR/apps/chemical_erp"
  tar -xzf "$SCRIPT_DIR/chemical_erp.tar.gz" -C "$BENCH_DIR/apps/chemical_erp"
  chown -R frappe:frappe "$BENCH_DIR/apps/chemical_erp"
  su - frappe -c "cd ${BENCH_DIR} && ./env/bin/pip install -e apps/chemical_erp"
  grep -qxF "chemical_erp" "$BENCH_DIR/sites/apps.txt" 2>/dev/null || echo "chemical_erp" >> "$BENCH_DIR/sites/apps.txt"
fi

# Link chemical_erp static assets directly into sites/assets
mkdir -p "$BENCH_DIR/sites/assets"
ln -sfn "$BENCH_DIR/apps/chemical_erp/chemical_erp/public" "$BENCH_DIR/sites/assets/chemical_erp"
chown -R frappe:frappe "$BENCH_DIR/sites/assets/chemical_erp"

echo -e "\n${GREEN}[7/8] Creating site and migrating database...${NC}"

# Check if site exists
if [ ! -d "$BENCH_DIR/sites/${SITE_NAME}" ]; then
  su - frappe -c "cd ${BENCH_DIR} && bench new-site ${SITE_NAME} --mariadb-root-password '${DB_ROOT_PASSWORD}' --admin-password '${ADMIN_PASSWORD}' --no-mariadb-socket"
else
  echo -e "\nSite ${SITE_NAME} already exists. Proceeding with update."
fi

# Install apps onto the site
echo -e "\n${CYAN}Installing apps on ${SITE_NAME}...${NC}"
su - frappe -c "cd ${BENCH_DIR} && bench --site ${SITE_NAME} install-app erpnext" 2>/dev/null || true
su - frappe -c "cd ${BENCH_DIR} && bench --site ${SITE_NAME} install-app hrms" 2>/dev/null || true
su - frappe -c "cd ${BENCH_DIR} && bench --site ${SITE_NAME} install-app chemical_erp" 2>/dev/null || true

# Restore database and uploaded files from local migration package
if [ -f "$SCRIPT_DIR/database.sql.gz" ]; then
  echo -e "\n${CYAN}Restoring local database & documents to live site...${NC}"
  RESTORE_CMD="bench --site ${SITE_NAME} --force restore '${SCRIPT_DIR}/database.sql.gz' --mariadb-root-password '${DB_ROOT_PASSWORD}'"
  if [ -f "$SCRIPT_DIR/files.tar" ]; then
    RESTORE_CMD="${RESTORE_CMD} --with-public-files '${SCRIPT_DIR}/files.tar'"
  fi
  if [ -f "$SCRIPT_DIR/private-files.tar" ]; then
    RESTORE_CMD="${RESTORE_CMD} --with-private-files '${SCRIPT_DIR}/private-files.tar'"
  fi
  su - frappe -c "cd ${BENCH_DIR} && ${RESTORE_CMD}"

  echo -e "\n${CYAN}Running database migrations...${NC}"
  su - frappe -c "cd ${BENCH_DIR} && bench --site ${SITE_NAME} migrate"
  su - frappe -c "cd ${BENCH_DIR} && bench --site ${SITE_NAME} clear-cache"
fi

# Build front-end production assets
su - frappe -c "cd ${BENCH_DIR} && bench build --app chemical_erp" 2>/dev/null || true

echo -e "\n${GREEN}[8/8] Configuring Nginx, Supervisor, and Production Services...${NC}"
su - frappe -c "cd ${BENCH_DIR} && bench setup supervisor --yes"
su - frappe -c "cd ${BENCH_DIR} && bench setup nginx --yes"

# Link supervisor and nginx configurations
ln -sf "$BENCH_DIR/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf

supervisorctl reread
supervisorctl update
supervisorctl restart all
systemctl reload nginx

# Firewall configuration
echo -e "\n${CYAN}Configuring UFW Firewall (SSH, HTTP, HTTPS)...${NC}"
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
echo "y" | ufw enable || true

# Setup SSL if a domain and email were provided (and domain is not an IP)
if [[ "$SITE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && [ -n "$SSL_EMAIL" ]; then
  echo -e "\n${CYAN}Obtaining Let's Encrypt SSL certificate for https://${SITE_NAME}...${NC}"
  certbot --nginx -d "${SITE_NAME}" --non-interactive --agree-tos -m "${SSL_EMAIL}" --redirect || {
    echo -e "${YELLOW}[WARNING] SSL auto-provisioning could not complete (ensure DNS A record points to this VPS IP). You can run 'sudo certbot --nginx -d ${SITE_NAME}' later.${NC}"
  }
fi

echo -e "\n${GREEN}====================================================================${NC}"
echo -e "${GREEN}   DEPLOYMENT COMPLETED SUCCESSFULLY!                               ${NC}"
echo -e "${GREEN}====================================================================${NC}"
echo -e "ERP URL     : http://${SITE_NAME} (or https://${SITE_NAME} if SSL enabled)"
echo -e "Username    : Administrator"
echo -e "Password    : [Your configured Admin Password]"
echo -e "Bench Dir   : ${BENCH_DIR}"
echo -e "App Version : Chemical ERP v1.0.7 on Frappe / ERPNext v15"
echo -e "${GREEN}====================================================================${NC}"
