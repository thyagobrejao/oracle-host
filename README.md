# Secure Shared Infrastructure for Cloud VMs

This repository contains the foundational infrastructure configuration for hosting multiple web applications and services on a single Oracle Cloud VM (or any cloud VPS) using ARM64 or x86_64 architecture.

It leverages Docker Compose to provision essential shared services securely, ensuring **zero public port exposure** by default. Direct external incoming traffic is completely eliminated, and access is managed via a secure Cloudflare Zero Trust Tunnel.

---

## Features & Services

All standalone projects hosted on this server connect to a shared, external Docker network named `infra-network`. This infrastructure repository defines that network and hosts the following central services:

- **Cloudflare Tunnel (`cloudflared`)**: Establishes a secure, encrypted outbound tunnel to the Cloudflare edge network. This completely bypasses the need for open inbound ports (like 80/443) on your firewall, protecting your VM from port scans and DDoS attacks.
- **Portainer**: A lightweight web interface to easily manage Docker containers, images, volumes, and networks on the host machine.
- **Redis**: A shared, in-memory data store used as a high-speed database, cache, or message broker by multiple projects.
- **Databases (`postgres` & `mysql`)**:
  - **PostgreSQL**: Production-ready relational database.
  - **MySQL**: Standard relational database.
  - *Note: Both databases are bound strictly to `127.0.0.1` (localhost) and are inaccessible from the public internet, protecting your data at all times.*

---

## Security First Design

Security is prioritized by restricting port bindings or completely omitting them for internal services:
- **Portainer UI (9000)** is only bound to `127.0.0.1` and accessible locally. We recommend putting it behind **Cloudflare Access** (with email verification/MFA) for secure, convenient remote administration.
- **Redis (6379)** is fully isolated with no port exposed to the host VM; it is only reachable internally by containers on the `infra-network`.
- **Databases (PostgreSQL on 5432, MySQL on 3306)** are locked to `127.0.0.1`. They can only be accessed locally by hosted applications or remotely via a secure SSH tunnel.
- **Repository Safety**: The `.gitignore` is pre-configured to strictly ignore sensitive database volumes (`mysql/`, `postgres/`), your `.env` configuration file, and local backups (`backups/`) to prevent accidental leaks on public repositories.

---

## Prerequisites

- Docker and Docker Compose installed on the host.
- A Cloudflare account with a Zero Trust Tunnel configured.

---

## Getting Started

1. **Clone the repository** to your VM host:
   ```bash
   git clone <your-repo-url>
   cd oracle-host
   ```

2. **Configure Environment Variables**:
   Copy the example environment file and define your secrets:
   ```bash
   cp .env.example .env
   # Edit .env and populate your Cloudflare token, DB passwords, and S3 credentials
   ```

3. **Initialize the Shared Docker Network**:
   Create the external bridge network before booting up the services:
   ```bash
   docker network create infra-network
   ```

4. **Start the Infrastructure**:
   ```bash
   docker-compose up -d
   ```

---

## Cloudflare Zero Trust Tunnel Setup

To securely route domains to your VM applications without opening inbound ports:

1. **Create a Tunnel**:
   - Go to your [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com).
   - Navigate to **Networks > Connectors** and click **Create Tunnel**.
   - Select **Cloudflared** as the connector type, name it (e.g., `oracle-vm-tunnel`), and click save.

2. **Retrieve the Token**:
   - In the Docker tab, copy the `TUNNEL_TOKEN` value (the long alphanumeric string after `--token`).
   - Paste it into your local `.env` file as `TUNNEL_TOKEN=your_token_here`.
   - Re-run `docker-compose up -d cloudflared` to connect the host.

3. **Map Your Applications**:
   - Under the tunnel's **Public Hostname** tab, add a route for each domain/subdomain you want to host.
   - **Example**: Map `eccnacional.yourdomain.com` directly to `http://eccnacional-app:8000` (Docker DNS handles local routing automatically).

4. **Secure Admin Consoles via Cloudflare Access**:
   - Expose Portainer through a subdomain (e.g., `portainer.yourdomain.com`) routed to `http://portainer:9000`.
   - Go to **Access > Applications** and click **Add an application** (Self-hosted).
   - Require authentication methods such as One-Time PINs (OTP) sent to your email to prevent unauthorized access.

---

## Connecting Client Projects

For external projects running on the same VM, configure their `docker-compose.yml` to attach to the shared network:

```yaml
# Example docker-compose.yml for separate app projects
services:
  web:
    image: my-app:latest
    networks:
      - default

networks:
  default:
    name: infra-network
    external: true
```

---

## Production-Grade Automated Backups

This repository provides two robust scripts to handle database backups seamlessly:

### 1. PostgreSQL Backup (`backup_db.sh`)
- Performs a complete logical backup of all PostgreSQL databases using `pg_dumpall`.
- Streams output into a gzip file using non-blocking named pipes (`mkfifo`) to maximize I/O efficiency.
- Computes SHA256 checksums for backup verification.
- Uploads the compressed dump and checksum to **AWS S3** via an ARM64-compatible AWS CLI Docker container.
- Sends instant success/failure notifications to a **Telegram Channel** using a Telegram Bot.
- Autocleans local backups older than 7 days.

### 2. MySQL Backup (`backup_mysql.sh`)
- Performs consistent hot logical backups of all MySQL databases using `mysqldump` with `--single-transaction --quick --routines --triggers`.
- Employs identical features (compression, SHA256 integrity, AWS S3 upload, Telegram notifications, and 7-day local rotation).

### Setting Up the Cron Schedule

To automate the backups, add the execution scripts to the host crontab (`crontab -e`):

```bash
# PostgreSQL Backup - Every day at 03:00 AM
0 3 * * * /home/ubuntu/oracle-host/backup_db.sh >> /home/ubuntu/oracle-host/backups/postgres_backup.log 2>&1

# MySQL Backup - Every day at 04:00 AM
0 4 * * * /home/ubuntu/oracle-host/backup_mysql.sh >> /home/ubuntu/oracle-host/backups/mysql_backup.log 2>&1
```
