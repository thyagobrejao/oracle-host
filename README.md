# Unified Oracle Cloud VM Infrastructure

This repository contains the foundational infrastructure configuration for hosting multiple web applications and services on a single Oracle Cloud VM (ARM64 architecture).

It uses Docker Compose to provision essential shared services securely, ensuring zero external port exposure by default through the use of a Cloudflare Zero Trust Tunnel.

## Architecture Overview

All standalone projects hosted on this server run on a shared external Docker network called `infra-network`. This infrastructure repository defines that network and hosts the following shared services:

- **Nginx Proxy Manager (NPM)**: Acts as the reverse proxy for routing incoming web traffic to the appropriate containers (Django, Laravel, Go) across the shared network based on domain names.
- **Cloudflare Tunnel (`cloudflared`)**: Connects the local infrastructure securely to the Cloudflare edge network, eliminating the need to expose inbound ports (like 80/443) to the public internet.
- **Portainer**: A lightweight web interface to easily manage Docker containers, images, volumes, and networks on the host machine.
- **Redis**: A shared, internal in-memory data structure store used as a database, cache, and message broker by multiple projects.

*Note: All application databases have been migrated to a managed PostgreSQL cluster on Digital Ocean. Therefore, no relational database containers run on this host.*

## Security

Security is prioritized by restricting port bindings to `127.0.0.1` (localhost) or entirely disabling them for internal services:
- **Portainer UI (9000)** and **NPM Admin UI (81)** are only accessible locally on the host. We recommend using Cloudflare Access or an SSH tunnel to access these interfaces remotely.
- **Redis (6379)** is fully isolated and only reachable by other containers attached to the `infra-network`.
- Standard web traffic (80/443) is meant to be handled via the Cloudflare Tunnel. The local bindings are kept for testing or fallback scenarios and are restricted to localhost.

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

## Connecting Other Projects

For any other project running on this VM (e.g., Laravel, Django, Go), ensure its `docker-compose.yml` is configured to join the external `infra-network`:

```yaml
# Example snippet for client applications
networks:
  default:
    name: infra-network
    external: true
```

Instead of exposing ports on the application containers, map their container names and internal ports in the Nginx Proxy Manager interface to route traffic accordingly (e.g., Forward `app.yourdomain.com` to `http://django-app:8000`).
