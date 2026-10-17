# Brave Chemicals ERP - Live Server Deployment Package

Automated deployment kit for **Brave Chemicals ERP** on **Hostinger VPS** (`bravechemicals.online`).

---

## 🚀 How to Deploy on the Hostinger VPS

Open your **Hostinger Web Console** (or SSH terminal as `root`), and run these 3 simple commands:

```bash
cd /root
git clone https://github.com/Douglas-Wills/chemical_erp_deploy.git
cd chemical_erp_deploy && bash install_on_hostinger.sh
```

---

## 📋 What the Installer Does Automatically:
1. Installs all Ubuntu system dependencies, Python 3, Node.js 18, Yarn, Redis, MariaDB, and wkhtmltopdf.
2. Configures MariaDB with Frappe-compliant `utf8mb4` character set.
3. Sets up system user `frappe` and initializes Frappe Bench v15.
4. Downloads ERPNext v15 and HRMS v15.
5. Installs the `chemical_erp` custom app.
6. Creates the site `bravechemicals.online`, restores your database & uploaded attachments, and runs migrations.
7. Sets up production Nginx and Supervisor background workers.
8. Automatically provisions and activates your free **Let's Encrypt SSL certificate** (`https://bravechemicals.online`).
