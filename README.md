# Clinical Traefik Reverse Proxy Setup

An interactive Bash script that installs and configures a [Traefik](https://traefik.io/) reverse proxy for [Halo AP](https://www.indicalab.com/halo/) (Indica Labs), deployed as a Docker container on clinical Linux servers. Supports both single-node and high-availability multi-node deployments with Keepalived VRRP failover.

---

## Table of Contents

- [Features](#features)
- [Supported Operating Systems](#supported-operating-systems)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Normal Installation](#normal-installation)
  - [Clean / Uninstall](#clean--uninstall)
- [Installation Walkthrough](#installation-walkthrough)
- [Deployment Types](#deployment-types)
- [Halo AP Services Configured](#halo-ap-services-configured)
- [High-Availability (Multi-Node) Mode](#high-availability-multi-node-mode)
- [Proxy Support](#proxy-support)
- [Files Created](#files-created)
- [Re-running the Script](#re-running-the-script)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## Features

- Installs Docker CE and deploys Traefik as a containerised reverse proxy
- TLS termination with a user-supplied certificate and key
- Optional custom CA certificate for upstream HTTPS connections
- Generates Traefik static and dynamic configuration files for Halo AP services
- Sticky-session load balancing across multiple upstream Halo AP nodes
- Optional Keepalived installation for Virtual IP (VRRP) high-availability failover
- Automated SSH-based deployment to backup nodes in a multi-node HA setup
- Flexible HTTP proxy support (authenticated or unauthenticated) with smart strategy selection
- Supports both `apt` (Debian/Ubuntu) and `dnf` (RHEL/CentOS/Rocky/AlmaLinux) package managers
- Idempotent: re-running the script detects and loads an existing `clinical_traefik.env` config
- `--clean` mode for full removal of Traefik, Keepalived, and optionally Docker

---

## Supported Operating Systems

| Distribution | Supported Versions |
|---|---|
| Ubuntu | 20.04, 22.x, 24.x, 25.x |
| Debian | 11+ |
| CentOS / RHEL / Rocky / AlmaLinux | 8+ |

Other distributions may work but are not tested. The script will prompt you to confirm if your OS is unrecognised.

---

## Prerequisites

- Run as a **regular user with sudo privileges** — do **not** invoke with `sudo`
- `bash` (not `sh` or `dash`)
- `sudo`, `curl`, `wget`, `ca-certificates`, `gnupg` — the script will attempt to install any that are missing before proceeding
- SSH key-based access to all backup nodes (required for multi-node deployments)
- Internet access, or a configured HTTP proxy, sufficient to reach:
  - `download.docker.com`
  - `registry-1.docker.io`
  - `docker.io`
  - Docker image storage (Cloudflare R2)

---

## Configuration

Before running the script, open it in a text editor and adjust the variables at the top of the file:

```bash
# HTTP/HTTPS proxy (leave blank if no proxy is needed)
PROXY_HOST=""        # e.g. "proxy.company.com"
PROXY_PORT=""        # e.g. "8080"
PROXY_USER=""
PROXY_PASSWORD=""    # Special characters are URL-encoded automatically

# Proxy strategy
# "auto"     – try direct first, fall back to proxy (default)
# "all"      – force all traffic through the proxy
# "external" – proxy for external downloads only; internal repos direct
# "none"     – no proxy
PROXY_STRATEGY="auto"

# Internal repo domains to exclude from proxying (comma-separated, optional)
INTERNAL_REPO_DOMAINS=""

# Skip SSL verification (not recommended)
SKIP_SSL_VERIFY="false"
```

All other settings (deployment type, service URLs, certificates, Keepalived topology) are prompted for interactively during the run.

---

## Usage

### Normal Installation

```bash
chmod +x clinical_reverse_proxy_setup.sh
./clinical_reverse_proxy_setup.sh
```

> **Important:** Run as your regular user — do **not** prefix with `sudo`. The script invokes `sudo` internally where required.

### Clean / Uninstall

```bash
./clinical_reverse_proxy_setup.sh --clean
```

Removes Traefik, Keepalived (if installed), Docker proxy config, and the `clinical_traefik.env` config file. You are optionally prompted to also uninstall Docker and to extend cleanup to backup nodes in a multi-node deployment.

---

## Installation Walkthrough

The script is fully interactive. It guides you through the following steps:

1. **Pre-flight checks** — OS validation, sudo access, proxy validation, repository connectivity tests
2. **Existing config detection** — If `clinical_traefik.env` exists, you can reuse it to skip re-entering settings
3. **Deployment type selection** — Full install or Image Server Only (see [Deployment Types](#deployment-types))
4. **Sudo password capture** — Stored in memory only for the duration of the session
5. **Docker installation** — Installs Docker CE via the official Docker repository; configures proxy in `daemon.json` if a proxy is set
6. **Docker repository management** — When a proxy is configured, you are offered the option to disable the Docker repository after installation to prevent future `apt`/`dnf` update failures
7. **TLS certificate and key** — You provide the paths to your PEM-format certificate (`.crt`) and private key (`.key`); these are copied into the Traefik certificates directory
8. **Service URL configuration** — You enter the host, protocol, and port for each Halo AP service. You can configure multiple upstream nodes in batches for load balancing
9. **Custom CA certificate** (optional) — Paste a PEM CA certificate if your upstream Halo AP servers use a private/internal CA
10. **Keepalived (HA)** — Optionally install Keepalived and configure a VRRP Virtual IP and network interface for this node
11. **Multi-node deployment** — If configuring HA, you define master and backup node hostnames and IP addresses; the script deploys to backup nodes automatically over SSH
12. **Final service restart and verification** — Docker and Keepalived are restarted; Traefik health is checked

---

## Deployment Types

| Type | Description |
|---|---|
| **Full Install** (`full`) | Configures all Halo AP services: App, API, iDP, File Monitor, and Image Service |
| **Image Server Only** (`image-site`) | Configures the Image Service only |

---

## Halo AP Services Configured

| Service | Default Port | Notes |
|---|---|---|
| `app-service` | 3000 | Main application |
| `api-service` | 7000 | REST API (sticky sessions) |
| `idp-service` | 6000 | Identity Provider (sticky sessions) |
| `file-monitor-service` | 5000 | File monitoring |
| `image-service` | 8000 | Whole-slide image serving (sticky sessions) |

URL routing, TLS, security headers, and response compression are all managed by Traefik. TLS 1.2 is the minimum enforced version.

---

## High-Availability (Multi-Node) Mode

When Keepalived is selected, the script configures VRRP across a master and one or more backup nodes:

- The **master node** (the server the script is run on) receives VRRP priority 110
- Each **backup node** receives decreasing priority (100, 90, …)
- A **Virtual IP** floats to whichever node currently holds the master VRRP state
- The `haloap_service_check.sh` health check script is deployed to `/bin/` on each node; Keepalived uses it to detect Traefik failures and trigger failover

Backup nodes are configured automatically over SSH. The current user's `~/.ssh/id_rsa` key is used; you are guided through SSH key distribution if it is not already in place.

---

## Proxy Support

The script handles HTTP proxies robustly, including:

- Passwords containing special characters (URL-encoded via Python 3, `jq`, or a built-in fallback)
- Masking of credentials in all log output
- Propagation of proxy settings to `apt`/`dnf`, `curl`, and the Docker daemon
- Four configurable strategies (`auto`, `all`, `external`, `none`) — see [Configuration](#configuration)

---

## Files Created

| Path | Description |
|---|---|
| `clinical_traefik.env` (next to the script) | Saved configuration for re-runs |
| `/home/haloap/traefik/` | Traefik root directory (owned by `haloap` system user) |
| `/home/haloap/traefik/config/traefik.yml` | Traefik static configuration |
| `/home/haloap/traefik/config/clinical_conf.yml` | Traefik dynamic configuration (services, routers, TLS) |
| `/home/haloap/traefik/certs/cert.crt` | TLS certificate |
| `/home/haloap/traefik/certs/server.key` | TLS private key |
| `/home/haloap/traefik/docker-compose.yml` | Docker Compose file for the Traefik container |
| `/etc/docker/daemon.json` | Docker daemon proxy configuration (only if proxy is configured) |
| `/etc/keepalived/keepalived.conf` | Keepalived VRRP configuration (only if Keepalived is installed) |
| `/bin/haloap_service_check.sh` | Keepalived health check script (only if Keepalived is installed) |
| `/var/log/installation.log` | Full installation log |

---

## Re-running the Script

The script is safe to re-run. On startup, if `clinical_traefik.env` is found, you are asked whether to use the existing configuration. Choosing **yes** skips re-entering certificates and service URLs and applies the saved values directly, making re-runs useful for:

- Applying configuration changes (e.g. new service URLs)
- Recovering from a failed installation
- Adding or changing Keepalived settings

Choosing **no** renames the existing config to `clinical_traefik.env.bak` and starts fresh.

---

## Verification

After installation, use these commands to confirm everything is running:

```bash
# Check all containers
docker ps

# Check Traefik logs
docker logs traefik

# Check Traefik health endpoint
curl http://localhost:8800/ping

# Check Keepalived (if installed)
sudo systemctl status keepalived

# Confirm Virtual IP is assigned to this node (HA mode)
ip addr show <interface>
```

---

## Troubleshooting

**View the installation log:**
```bash
cat /var/log/installation.log
```

**Traefik won't start:**
Check `docker logs traefik` for configuration errors. Verify that the certificate and key paths in `clinical_conf.yml` are correct and the files are readable by the container.

**Keepalived failover not working:**
Confirm the `haloap_service_check.sh` script exits non-zero when Traefik is unhealthy (`sudo /bin/haloap_service_check.sh`), that the VRRP interface name is correct (`ip link show`), and that both nodes are running the same VRRP instance name and authentication.

**Proxy issues during installation:**
Set `PROXY_STRATEGY="all"` if the auto-detection probes fail in your environment. If your proxy password contains special characters, ensure `python3` is installed before running the script for reliable URL encoding.

**Docker repository causes `apt update` failures:**
This is expected in proxied environments. Re-enable the repository only when you need to update Docker, then disable it again:
```bash
sudo mv /etc/apt/sources.list.d/docker.list.disabled /etc/apt/sources.list.d/docker.list
sudo mv /etc/apt/keyrings/docker.gpg.disabled /etc/apt/keyrings/docker.gpg
sudo -E apt-get update && sudo -E apt-get upgrade docker-ce
sudo mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled
sudo mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled
```

**Domain-joined username issues:**
The script automatically strips the `@domain` suffix from UPN-style usernames (e.g. `user@ad.example.com` → `user`) for Linux commands and SSH operations.
