# Clinical Traefik Reverse Proxy Setup

An interactive Bash script that installs and configures a [Traefik](https://traefik.io/) reverse proxy for [Halo AP](https://www.indicalab.com/halo/) (Indica Labs), deployed as a Docker container on clinical Linux servers. Supports both single-node and high-availability multi-node deployments with Keepalived VRRP failover, offline (air-gapped) installation, and post-install change management.

**Script version:** 1.4.1

---

## Table of Contents

- [Features](#features)
- [Supported Operating Systems](#supported-operating-systems)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Normal Installation](#normal-installation)
  - [Offline Installation](#offline-installation)
  - [Status Check](#status-check)
  - [Change Deployment](#change-deployment)
  - [Clean / Uninstall](#clean--uninstall)
- [Installation Walkthrough](#installation-walkthrough)
- [Deployment Types](#deployment-types)
- [Halo AP Services Configured](#halo-ap-services-configured)
- [High-Availability (Multi-Node) Mode](#high-availability-multi-node-mode)
- [HL7 / TCP Integration](#hl7--tcp-integration)
- [Diagnostics Monitor](#diagnostics-monitor)
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
- **Offline installation mode** — build a transferable bundle on an internet-connected machine and install on air-gapped targets
- **Post-install change management** (`--extend` / Change Deployment menu):
  - Update SSL or CA certificate and push to all nodes
  - Add, remove, or replace Traefik HA nodes
  - Edit component server / service URLs
  - Edit HL7/TCP port configuration
  - Enable or reconfigure the Diagnostics Monitor
- **HL7/TCP integration** — configure Traefik TCP entrypoints for HL7 messaging with per-port backend groups
- **Diagnostics Monitor** — optional reverse-proxy route for a diagnostics service with ForwardAuth and Basic auth
- **`--status` flag** — quick health check showing Traefik status on all nodes and SSL certificate expiry
- **Audit log** — every configuration change is appended to `/opt/indica/traefik/audit.log`
- **Configuration snapshots** — the deployment config is automatically backed up before each change
- `/etc/hosts` entry management for component server hostname resolution
- Flexible HTTP proxy support (authenticated or unauthenticated) with smart strategy selection
- Supports both `apt` (Debian/Ubuntu) and `dnf` (RHEL/CentOS/Rocky/AlmaLinux) package managers
- Idempotent: re-running the script on an existing deployment presents a menu (Reinstall, Status, Change Deployment, Uninstall)
- Automatic migration of legacy `clinical_traefik.env` configurations to the current `deployment.config` format
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

- Run **with `sudo`** from a regular user account — do **not** log in directly as root
- `bash` (not `sh` or `dash`)
- `sudo`, `curl`, `wget`, `ca-certificates`, `gnupg` — the script will attempt to install any that are missing before proceeding
- SSH key-based access to all backup nodes (required for multi-node deployments)
- Internet access, or a configured HTTP proxy, sufficient to reach (for online installs):
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

# HL7 / TCP integration (optional — can also be configured interactively)
HL7_ENABLED="no"
HL7_LISTEN_PORTS=""      # Pipe-separated listen ports  e.g. "1050|1051"
HL7_PORT_BACKENDS=""     # Pipe-separated backend groups e.g. "host1:1050,host2:1050|host1:1051"
HL7_PORT_COMMENTS=""     # Pipe-separated comments       e.g. "Main lab|Radiology"

# Diagnostics Monitor (optional — can also be configured interactively)
DIAG_ENABLED="no"
DIAG_URL=""              # Service URL  e.g. https://host:9090
DIAG_AUTH_ADDRESS=""     # ForwardAuth address  e.g. https://host/idsrv/connect/userinfo
DIAG_PASSWORD=""         # Basic auth password (username: diagnostics)

# Component server /etc/hosts entries (pipe-separated hostname:ip pairs, optional)
# e.g. "HNUKAP24COM01:10.0.40.200|HNUKAP24APL01:10.0.40.201"
HOSTS_ENTRIES=""
```

All other settings (deployment type, service URLs, certificates, Keepalived topology) are prompted for interactively during the run.

---

## Usage

### Normal Installation

```bash
chmod +x clinical_reverse_proxy.sh
sudo ./clinical_reverse_proxy.sh
```

> **Important:** Always invoke with `sudo` from your regular user account. Do **not** log in as root directly — the script uses `SUDO_USER` to resolve SSH keys and set correct file ownership on `/opt/indica`.

On a bare invocation the script presents a top-level action menu:

```
:: Select Action
──────────────────────────────────────────────────

  [1] Install Reverse Proxy           (deploy on this machine)
  [2] Generate Offline Install Bundle (download packages + Traefik image)
  [3] Cancel
```

### Offline Installation

Use offline mode to install on air-gapped machines that cannot reach the internet.

**Step 1 — Build the bundle** (run on an internet-connected machine with the same OS as the target):

```bash
sudo ./clinical_reverse_proxy.sh --prepare-offline
```

Or select option **[2] Generate Offline Install Bundle** from the interactive menu. This downloads all required packages and the Traefik Docker image into a transferable archive (`traefik-rp-packages-*.tar.gz` by default).

```bash
# Use zip format instead of tar.gz
sudo ./clinical_reverse_proxy.sh --prepare-offline --archive-format=zip
```

**Step 2 — Transfer** the archive to the target machine (USB, SCP, etc.).

**Step 3 — Install on the target** (the bundle is auto-detected in `~/`, `/opt`, or `/tmp`):

```bash
sudo ./clinical_reverse_proxy.sh
```

The script will detect the bundle automatically and switch to offline mode. You can also be explicit:

```bash
# Force offline mode (fail if no bundle found)
sudo ./clinical_reverse_proxy.sh --offline

# Use a specific bundle path
sudo ./clinical_reverse_proxy.sh --package-source=/path/to/traefik-rp-packages-*.tar.gz

# Skip OS codename compatibility check (use with caution)
sudo ./clinical_reverse_proxy.sh --offline --force-os-mismatch
```

To force an online install even if a bundle is present:

```bash
sudo ./clinical_reverse_proxy.sh --online
```

### Status Check

```bash
sudo ./clinical_reverse_proxy.sh --status
```

Displays a summary of the current deployment:

- Traefik container status on the master and all backup nodes
- SSL certificate validity and days until expiry
- Keepalived / Virtual IP information (HA deployments)
- HL7 and Diagnostics Monitor state (if configured)

The status check is also available from within the interactive menus.

### Change Deployment

After a successful installation, re-running the script on an existing deployment shows the **Existing Deployment Detected** menu:

```
  [1] Reinstall
  [2] Status Check
  [3] Change Deployment
  [4] Uninstall
  [5] Clean Orphaned Nodes
  [6] Exit
```

You can jump directly to **Change Deployment** mode with:

```bash
sudo ./clinical_reverse_proxy.sh --extend
```

The Change Deployment menu offers:

```
  [1] Update SSL Certificate
  [2] Update CA Certificate
  [3] Edit Traefik Nodes
  [4] Edit Component Servers/Services
  [5] Edit HL7 Configuration
  [6] Edit Diagnostics Monitor
  [7] Status Check
```

Changes are automatically pushed to all backup nodes in multi-node deployments. The deployment config is snapshotted before each change and all modifications are appended to the audit log.

### Clean / Uninstall

```bash
sudo ./clinical_reverse_proxy.sh --clean
```

Removes Traefik, Keepalived (if installed), Docker proxy config, and the `deployment.config` file. You are optionally prompted to also uninstall Docker and to extend cleanup to backup nodes in a multi-node deployment.

---

## Installation Walkthrough

The script is fully interactive. It guides you through the following steps:

1. **Pre-flight checks** — OS validation, sudo access, proxy validation, repository connectivity tests
2. **Existing config detection** — If a deployment config exists, you can reinstall using it, run a status check, change the deployment, or uninstall
3. **Offline/online mode banner** — Displays whether the install will use a local bundle or reach the network
4. **Deployment type selection** — Full install or Image Server Only (see [Deployment Types](#deployment-types))
5. **Docker installation** — Installs Docker CE via the official Docker repository (or from the offline bundle); configures proxy in `daemon.json` if a proxy is set
6. **Docker repository management** — When a proxy is configured, you are offered the option to disable the Docker repository after installation to prevent future `apt`/`dnf` update failures
7. **TLS certificate and key** — You paste or provide the paths to your PEM-format certificate and private key; these are written into the Traefik certificates directory
8. **Service URL configuration** — You enter the host, protocol, and port for each Halo AP service. You can configure multiple upstream nodes in batches for load balancing
9. **Custom CA certificate** (optional) — Paste a PEM CA certificate if your upstream Halo AP servers use a private/internal CA
10. **Component server `/etc/hosts` entries** (optional) — Map hostnames to IP addresses for servers that are not in DNS
11. **HL7 / TCP integration** (optional) — Configure TCP entrypoints and backend groups for HL7 messaging ports
12. **Diagnostics Monitor** (optional) — Configure a diagnostics monitoring service with ForwardAuth and Basic auth
13. **Keepalived (HA)** — Optionally install Keepalived and configure a VRRP Virtual IP and network interface for this node
14. **Multi-node deployment** — If configuring HA, you define master and backup node hostnames and IP addresses; the script deploys to backup nodes automatically over SSH
15. **Final service restart and verification** — Docker and Keepalived are restarted; Traefik health is checked

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

After installation, nodes can be added, removed, or replaced from the **Edit Traefik Nodes** option in the Change Deployment menu.

---

## HL7 / TCP Integration

Traefik can be configured to proxy raw TCP connections for HL7 messaging alongside its HTTP/HTTPS routes. Each HL7 port is configured as a separate Traefik entrypoint with one or more backend host:port pairs.

HL7 configuration can be set in the script variables before running, or configured interactively during installation, or added/modified later via **Change Deployment → Edit HL7 Configuration**.

Example pre-configuration in the script:

```bash
HL7_ENABLED="yes"
HL7_LISTEN_PORTS="1050|1051"
HL7_PORT_BACKENDS="host1:1050,host2:1050|host1:1051"
HL7_PORT_COMMENTS="Main lab|Radiology"
```

The HL7 configuration is written to a separate dynamic config file (`hl7.yml`) and pushed to all nodes in multi-node deployments.

---

## Diagnostics Monitor

An optional Diagnostics Monitor route can be configured to reverse-proxy a diagnostics service (e.g. hosted at `https://host:9090`) through Traefik. Access is protected by:

- **ForwardAuth** — validates the session against a configured identity provider endpoint
- **Basic auth** — `diagnostics` username with a configurable password

The Diagnostics Monitor can be enabled during installation or added later via **Change Deployment → Edit Diagnostics Monitor**.

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
| `/opt/indica/traefik/deployment.config` | Saved deployment configuration (replaces legacy `clinical_traefik.env`) |
| `/opt/indica/traefik/audit.log` | Append-only log of all configuration changes |
| `/opt/indica/traefik/backups/` | Automatic config snapshots created before each change |
| `/opt/indica/traefik/config/traefik.yml` | Traefik static configuration |
| `/opt/indica/traefik/config/dynamic/clinical_conf.yml` | Traefik dynamic configuration (services, routers, TLS) |
| `/opt/indica/traefik/config/dynamic/hl7.yml` | Traefik TCP configuration for HL7 ports (only if HL7 is enabled) |
| `/opt/indica/traefik/config/dynamic/diagnostics_monitor.yml` | Diagnostics Monitor route config (only if enabled) |
| `/opt/indica/traefik/certs/cert.crt` | TLS certificate |
| `/opt/indica/traefik/certs/server.key` | TLS private key |
| `/opt/indica/traefik/certs/customca.crt` | Custom CA certificate (only if a custom CA is supplied) |
| `/opt/indica/traefik/docker-compose.yaml` | Docker Compose file for the Traefik container |
| `/etc/docker/daemon.json` | Docker daemon proxy configuration (only if proxy is configured) |
| `/etc/keepalived/keepalived.conf` | Keepalived VRRP configuration (only if Keepalived is installed) |
| `/bin/haloap_service_check.sh` | Keepalived health check script (only if Keepalived is installed) |
| `/var/log/installation.log` | Full installation log |

---

## Re-running the Script

The script is safe to re-run. On startup, if `/opt/indica/traefik/deployment.config` is found, you are presented with a menu offering Reinstall, Status Check, Change Deployment, Uninstall, and Clean Orphaned Nodes.

**Reinstall** backs up the current files under `/opt/indica/traefik/backups/` and re-runs the full setup using the saved configuration as a starting point, making it useful for:

- Applying configuration changes (e.g. new service URLs)
- Recovering from a failed installation
- Adding or changing Keepalived settings

**Change Deployment** (also available as `--extend`) allows targeted post-install changes without a full reinstall — updating certificates, editing nodes, or toggling optional services.

### Legacy configuration migration

If a legacy `clinical_traefik.env` file is found (from an earlier version of this script) and no `deployment.config` exists, the script will offer to migrate it automatically, adding any missing newer variables with safe defaults.

---

## Verification

After installation, use these commands to confirm everything is running:

```bash
# Quick status check via the script
sudo ./clinical_reverse_proxy.sh --status

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

# View the audit log
cat /opt/indica/traefik/audit.log
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

**Offline bundle OS mismatch:**
The bundle encodes the OS codename at build time and will refuse to install on a different OS by default. If you are certain the packages are compatible, pass `--force-os-mismatch` to bypass the check.

**`deployment.config` not found after legacy install:**
Run the script normally — it will detect any `clinical_traefik.env` file and offer to migrate it to the new format at `/opt/indica/traefik/deployment.config`.
