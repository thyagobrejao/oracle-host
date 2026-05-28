# Unified Oracle Cloud VM Infrastructure

This repository contains the foundational infrastructure configuration for hosting multiple web applications and services on a single Oracle Cloud VM (ARM64 architecture).

It uses Docker Compose to provision essential shared services securely, ensuring zero external port exposure by default through the use of a Cloudflare Zero Trust Tunnel.

## Architecture Overview

All standalone projects hosted on this server run on a shared external Docker network called `infra-network`. This infrastructure repository defines that network and hosts the following shared services:

- **Cloudflare Tunnel (`cloudflared`)**: Connects the local infrastructure securely to the Cloudflare edge network, eliminating the need to expose inbound ports (like 80/443) to the public internet. It routes external domain traffic directly to individual containers running on the shared network.
- **Portainer**: A lightweight web interface to easily manage Docker containers, images, volumes, and networks on the host machine.
- **Redis**: A shared, internal in-memory data structure store used as a database, cache, and message broker by multiple projects.

*Note: All application databases have been migrated to a managed PostgreSQL cluster on Digital Ocean. Therefore, no relational database containers run on this host.*

## Security

Security is prioritized by restricting port bindings to `127.0.0.1` (localhost) or entirely disabling them for internal services:
- **Portainer UI (9000)** is only accessible locally on the host. We recommend using Cloudflare Access or an SSH tunnel to access this interface remotely.
- **Redis (6379)** is fully isolated and only reachable by other containers attached to the `infra-network`.
- No services bind to standard public web ports (80/443). All external incoming traffic is handled securely and encrypted via the Cloudflare Tunnel.

## Prerequisites

- Docker and Docker Compose installed on the host.
- A Cloudflare account with Zero Trust tunnels configured.

## Getting Started

1. **Clone the repository** to your Oracle VM host:
   ```bash
   git clone <your-repo-url>
   cd oracle-host
   ```

2. **Configure Environment Variables**:
   Copy the example environment file and fill in your Cloudflare Tunnel token:
   ```bash
   cp .env.example .env
   # Edit .env and set your TUNNEL_TOKEN
   ```

3. **Initialize the Shared Infrastructure Network**:
   This network must be created before starting the infrastructure or any client applications.
   ```bash
   docker network create infra-network
   ```

4. **Start the Services**:
   ```bash
   docker-compose up -d
   ```

## Cloudflare Zero Trust Tunnel Setup

To securely connect this infrastructure to the web without opening any public ports on your Oracle VM, follow these steps:

1. **Access Cloudflare Zero Trust**:
   - Go to your [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com).
   - Navigate to **Networks > Connectors**.

2. **Create a New Tunnel**:
   - Click on the **Create Tunnel** button.
   - Choose **Cloudflared** as the connector type and click Next.
   - Name your tunnel (e.g., `oracle-vm-tunnel`) and save.

3. **Get the Tunnel Token**:
   - On the installation page, choose **Docker** as the environment.
   - Copy the `TUNNEL_TOKEN` from the provided command. It is the long alphanumeric string after `--token`.
   - Paste this token into the `.env` file of this repository on your VM (`TUNNEL_TOKEN=your_token_here`).
   - Run `docker-compose up -d cloudflared` (or start all services) to start the tunnel.

4. **Configure Public Hostnames**:
   - Go back to the Cloudflare Zero Trust Dashboard, select your tunnel, and go to the **Public Hostname** tab.
   - For each application/subdomain you want to host, add a Public Hostname to route directly to its container.
   - **Example**: To expose a Django project running in container `eccnacional-app` on port `8000`:
     - **Subdomain**: `eccnacional`
     - **Domain**: `yourdomain.com`
     - **Service Type**: `HTTP`
     - **URL**: `eccnacional-app:8000` (Docker DNS resolves this to the container's internal IP).

5. **(Optional) Secure Admin Interfaces via Cloudflare Access**:
   - You can securely access Portainer remotely by placing it behind an authentication wall using Cloudflare Access.
   - First, add a Public Hostname in your tunnel for Portainer (e.g., `portainer.yourdomain.com`) pointing to `HTTP://portainer:9000`.
   
   **To Configure Access Policies (Authentication):**
   - In the Zero Trust Dashboard, navigate to **Access > Applications**.
   - Click **Add an application** and select **Self-hosted**.
   - Name your application (e.g., "Portainer") and set the subdomain you configured earlier (e.g., `portainer.yourdomain.com`).
   - Click **Next** to define policies. Name your policy (e.g., "Allow Admins").
   - Under **Action**, select `Allow`.
   - Under **Configure rules** > **Include**, choose the method of authentication, such as `Emails` and type your personal email address. This uses a one-time PIN (OTP) sent to your email. You can also configure GitHub or Google logins in **Settings > Authentication**.
   - Save the application. Now, whenever you visit `portainer.yourdomain.com`, Cloudflare will intercept the request and require authentication before forwarding traffic to your Portainer container.

## Connecting Other Projects

For any other project running on this VM (e.g., Laravel, Django, Go), ensure its `docker-compose.yml` is configured to join the external `infra-network`:

```yaml
# Example snippet for client applications
networks:
  default:
    name: infra-network
    external: true
```

Instead of exposing ports on the host, you just need to run your applications inside the `infra-network`. To map domains/subdomains to these projects, add them as **Public Hostnames** in your Cloudflare Tunnel pointing directly to their internal container name and port (e.g., `http://laravel-app:80` or `http://django-app:8000`).
