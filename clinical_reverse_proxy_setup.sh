#!/bin/bash

# Enhanced Clinical Traefik Reverse Proxy Setup
#
# USAGE:
#   sudo ./clinicalrp.sh                         # Normal installation
#   sudo ./clinicalrp.sh --clean                 # Remove Traefik/Keepalived/Docker
#   sudo ./clinicalrp.sh --status                # Quick health check of current deployment
#
# NOTE: Must be run with sudo from your own user account — never log in as root directly.
#       Running as sudo ensures /opt/indica is owned by root:root and SSH keys are
#       resolved correctly from the invoking user's home directory.

VERSION="1.2.0"

set -e

# ==========================================
# Standardised y/n prompt helper
# ==========================================
# Usage: prompt_yn "Question" [default: y|n]
# Returns 0 for yes, 1 for no. Only accepts y/n — re-prompts on anything else.
prompt_yn() {
    local message="$1"
    local default="${2:-}"
    local hint response

    case "${default,,}" in
        y) hint="[Y/n]" ;;
        n) hint="[y/N]" ;;
        *)  hint="[y/n]" ;;
    esac

    while true; do
        read -p "$message $hint: " response
        [[ -z "$response" && -n "$default" ]] && response="$default"
        case "${response,,}" in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "  Please enter 'y' or 'n'." ;;
        esac
    done
}

# ==========================================
# Configuration
# ==========================================

# HTTP/HTTPS proxy for outbound downloads (curl/wget/apt/dnf)
# Leave blank if no proxy is needed
# Note: Passwords with special characters will be automatically URL-encoded
PROXY_HOST=""  # Example: "proxy.company.com"
PROXY_PORT=""  # Example: "8080"
PROXY_USER=""
PROXY_PASSWORD="" # Special characters will be handled automatically
SKIP_SSL_VERIFY="false"  # Set to "true" to disable SSL verification (not recommended)

# Proxy Strategy - How to handle internal vs external repos
# Options:
#   "auto"     - Try without proxy first, fallback to proxy if needed (DEFAULT)
#   "all"      - Use proxy for all connections (strict firewall environments)
#   "external" - Use proxy only for external downloads, DNF direct (mixed access)
#   "none"     - No proxy used anywhere
PROXY_STRATEGY="auto"

# Internal Repo Domains (optional - for "external" strategy)
# Comma-separated list of internal repo domains that don't need proxy
# Example: "repo.svc.t-systems.at,internal.company.com"
# Leave empty for auto-detection
INTERNAL_REPO_DOMAINS=""

# Multi-node deployment variables
MULTI_NODE_DEPLOYMENT="no"
BACKUP_NODE_COUNT=0
MASTER_HOSTNAME=""
MASTER_IP=""
BACKUP_NODES=()
BACKUP_IPS=()
BACKUP_INTERFACES=()

# HL7 / TCP integration (optional)
# Set HL7_ENABLED="yes" to pre-configure without interactive prompts
HL7_ENABLED="no"
HL7_LISTEN_PORTS=""      # Pipe-separated Traefik listen ports      (e.g. "1050|1051")
HL7_PORT_BACKENDS=""     # Pipe-separated backend groups per port    (e.g. "host1:1050,host2:1050|host1:1051")
HL7_PORT_COMMENTS=""     # Pipe-separated comment per port           (e.g. "Main lab|Radiology")

# Diagnostics Monitor (optional)
DIAG_ENABLED="no"
DIAG_URL=""              # Service URL  e.g. https://host:9090
DIAG_AUTH_ADDRESS=""     # ForwardAuth address  e.g. https://host/idsrv/connect/userinfo
DIAG_PASSWORD=""         # Raw password for Basic auth (username: diagnostics)
DIAG_AUTH_TOKEN=""       # Base64 encoded Basic auth token

# Custom CA certificate for upstream TLS verification
USE_CUSTOM_CA="no"
CUSTOM_CA_CERT_CONTENT=""

# Logging setup
LOGFILE="/var/log/installation.log"

# Get the actual user running the script (before sudo elevation)
_RAW_USER="${SUDO_USER:-$USER}"
# Strip domain suffix (e.g. user@domain.com → user) but only if the
# stripped name is a valid local user — on domain-joined systems the
# full UPN may be required.
_STRIPPED_USER="${_RAW_USER%%@*}"
if id "$_STRIPPED_USER" >/dev/null 2>&1; then
    CURRENT_USER="$_STRIPPED_USER"
else
    CURRENT_USER="$_RAW_USER"
fi
CURRENT_GROUP=$(id -gn "$CURRENT_USER")

# Get the actual user's home directory (not root's when using sudo)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Get the directory where the script is located
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_FILE="/opt/indica/traefik/deployment.config"

# Directory for temporary scripts
SCRIPTS_DIR="$ACTUAL_HOME/traefik_setup_scripts"

# ==========================================
# SSL and Proxy Options
# ==========================================

# Curl SSL options
if [ "$SKIP_SSL_VERIFY" = "true" ]; then
    CURL_SSL_OPT="--insecure"
else
    CURL_SSL_OPT=""
fi

# APT SSL options
APT_SSL_OPT=""
if [ "$SKIP_SSL_VERIFY" = "true" ]; then
    APT_SSL_OPT="-o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false"
fi

# DNF SSL options
DNF_SSL_OPT=""
if [ "$SKIP_SSL_VERIFY" = "true" ]; then
    DNF_SSL_OPT="--setopt=sslverify=false"
fi

# Wget SSL options
WGET_SSL_OPT=""
if [ "$SKIP_SSL_VERIFY" = "true" ]; then
    WGET_SSL_OPT="--no-check-certificate"
fi

# ==========================================
# Helper Functions
# ==========================================

# Enhanced URL encoding function with better error handling
url_encode_password() {
    local password="$1"
    local encoded=""
    
    # Method 1: Try Python3 (most reliable)
    if command -v python3 &>/dev/null; then
        encoded=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$password" 2>/dev/null)
        if [ -n "$encoded" ] && [ "$encoded" != "$password" ]; then
            echo "$encoded"
            return 0
        fi
    fi
    
    # Method 2: Try jq
    if command -v jq &>/dev/null; then
        encoded=$(printf '%s' "$password" | jq -sRr @uri 2>/dev/null)
        if [ -n "$encoded" ] && [ "$encoded" != "$password" ]; then
            echo "$encoded"
            return 0
        fi
    fi
    
    # Method 3: Manual encoding (fallback for common special characters)
    # This is a basic implementation - not comprehensive but handles most cases
    encoded="$password"
    encoded="${encoded//\%/%25}"  # % must be first
    encoded="${encoded//!/%21}"
    encoded="${encoded//:/%3A}"
    encoded="${encoded//@/%40}"
    encoded="${encoded//\#/%23}"
    encoded="${encoded//\$/%24}"
    encoded="${encoded//\&/%26}"
    encoded="${encoded//\'/%27}"
    encoded="${encoded//\(/%28}"
    encoded="${encoded//)/%29}"
    encoded="${encoded//\*/%2A}"
    encoded="${encoded//+/%2B}"
    encoded="${encoded//,/%2C}"
    encoded="${encoded//\//%2F}"
    encoded="${encoded//;/%3B}"
    encoded="${encoded//=/%3D}"
    encoded="${encoded//\?/%3F}"
    encoded="${encoded//\[/%5B}"
    encoded="${encoded//]/%5D}"
    encoded="${encoded// /%20}"
    
    echo "$encoded"
}

# Verify URL encoding worked for special characters
verify_password_encoding() {
    local original="$1"
    local encoded="$2"
    local has_special_chars=false
    
    # Check if password contains special characters that need encoding
    if echo "$original" | grep -q '[!@#$%^&*()+=:;<>?/`~\\ ]'; then
        has_special_chars=true
    fi
    
    # If we have special characters but encoding didn't change the string, encoding failed
    if [ "$has_special_chars" = true ] && [ "$encoded" = "$original" ]; then
        return 1  # Encoding failed
    fi
    
    return 0  # Encoding succeeded or not needed
}

# Run command on remote host with sudo
run_remote_sudo() {
    local ip=$1
    local cmd=$2
    
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" -- bash -lc "echo \"$SUDO_PASS\" | ssh $SSH_OPTS -l '$CURRENT_USER' '$ip' 'sudo -S bash -c \"$cmd\"'"
    else
        echo "$SUDO_PASS" | ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "sudo -S bash -c \"$cmd\""
    fi
}

# Copy file to remote host
copy_to_remote() {
    local file=$1
    local ip=$2
    local dest=$3

    # SCP options — -O forces legacy SCP protocol to avoid SFTP subsystem requirement
    local SCP_OPTS="-O -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
    # SSH options for the cat fallback — no -O (that flag has a different meaning for ssh)
    local SSH_COPY_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
    local KEY_OPT="-i $ACTUAL_HOME/.ssh/id_rsa"

    # Helper: stream file via ssh cat, writing to a tmp file then sudo-moving to dest
    # This handles destinations owned by a different user (e.g. haloap)
    _ssh_cat_copy() {
        local _ip="$1" _dest="$2" _file="$3"
        local _tmp_dest="/tmp/.copy_to_remote_$$.tmp"
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" ssh $KEY_OPT $SSH_COPY_OPTS -l "$CURRENT_USER" "$_ip" \
                "cat > '$_tmp_dest'" < "$_file" \
            && echo "$SUDO_PASS" | sudo -u "$SUDO_USER" ssh $KEY_OPT $SSH_COPY_OPTS \
                -l "$CURRENT_USER" "$_ip" \
                "sudo -S mv '$_tmp_dest' '$_dest' && sudo chmod 644 '$_dest'" 2>/dev/null \
            || sudo -u "$SUDO_USER" ssh $KEY_OPT $SSH_COPY_OPTS -l "$CURRENT_USER" "$_ip" \
                "mv '$_tmp_dest' '$_dest'" 2>/dev/null
        else
            ssh $KEY_OPT $SSH_COPY_OPTS -l "$CURRENT_USER" "$_ip" \
                "cat > '$_tmp_dest'" < "$_file" \
            && echo "$SUDO_PASS" | ssh $KEY_OPT $SSH_COPY_OPTS -l "$CURRENT_USER" "$_ip" \
                "sudo -S mv '$_tmp_dest' '$_dest' && sudo chmod 644 '$_dest'" 2>/dev/null \
            || ssh $KEY_OPT $SSH_COPY_OPTS -l "$CURRENT_USER" "$_ip" \
                "mv '$_tmp_dest' '$_dest'" 2>/dev/null
        fi
    }

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        if ! sudo -u "$SUDO_USER" scp -q -o "User=$CURRENT_USER" $KEY_OPT $SCP_OPTS "$file" "$ip:$dest" 2>/tmp/scp_err.$$; then
            _ssh_cat_copy "$ip" "$dest" "$file"
        fi
    else
        if ! scp -q -o "User=$CURRENT_USER" $KEY_OPT $SCP_OPTS "$file" "$ip:$dest" 2>/tmp/scp_err.$$; then
            _ssh_cat_copy "$ip" "$dest" "$file"
        fi
    fi
    rm -f /tmp/scp_err.$$
}

# Copy file to remote and ensure it is owned by root:root
# Use for all /opt/indica files pushed during Change Deployment
copy_to_remote_root() {
    local file=$1
    local ip=$2
    local dest=$3
    copy_to_remote "$file" "$ip" "$dest" || true
    # Chown to root:root on remote via sudo
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_PASS" | sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
            "sudo -S chown root:root '$dest'" 2>/dev/null || true
    else
        echo "$SUDO_PASS" | ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
            "sudo -S chown root:root '$dest'" 2>/dev/null || true
    fi
}

# Ensure remote user's scripts dir exists
ensure_SCRIPTS_DIR() {
    local ip=$1
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "mkdir -p '$SCRIPTS_DIR' && chmod 755 '$SCRIPTS_DIR'"
    else
        ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "mkdir -p '$SCRIPTS_DIR' && chmod 755 '$SCRIPTS_DIR'"
    fi
}

# ==========================================
# Proxy Strategy Implementation

# Detect repo hosts that are reachable directly (no proxy)
_detect_direct_repo_hosts() {
    local hosts=()
    local out=""

    # Collect hosts from yum/dnf repo files
    if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
        mapfile -t hosts < <(grep -hE '^(baseurl|mirrorlist)' /etc/yum.repos.d/*.repo 2>/dev/null \
                              | grep -oE 'https?://[^/]+' \
                              | sed -E 's#^https?://##' \
                              | sort -u)
    fi

    # Probe each host directly (bypass proxy); keep those that answer
    for h in "${hosts[@]}"; do
        if timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "https://$h" >/dev/null 2>&1 || \
           timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "http://$h"  >/dev/null 2>&1; then
            out="${out}${out:+,}$h"
        fi
    done

    echo "$out"
}
# ==========================================

# Mask credentials in URLs for logging
_mask_url_creds() {
    local url="$1"
    # Replace :password@ with :****@
    echo "$url" | sed -E 's#(https?://[^:]+:)[^@]*(@)#\1****\2#g'
}

# Normalize proxy environment variables to avoid double schemes
normalize_proxy_env() {
  for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
    val="${!v:-}"
    if [ -n "$val" ]; then
      # Strip accidental double prefixes (http://http://, https://https://, mixed)
      val="${val#http://http://}"
      val="${val#https://https://}"
      val="${val#http://https://}"
      val="${val#https://http://}"
      export "$v=$val"
    fi
  done
  : "${no_proxy:=localhost,127.0.0.1,::1,.local}"
}

setup_proxy_strategy() {
    log "Configuring proxy strategy: ${PROXY_STRATEGY}"

    # Reset proxy-related state
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
    PROXY_CURL_OPTS=""
    DNF_PROXY_OPT=""
    APT_PROXY_OPT_PROXY=""

    # If no proxy host/port is provided, go direct
    if [ -z "${PROXY_HOST}" ] || [ -z "${PROXY_PORT}" ]; then
        log "No proxy configured - using direct connections"
        PROXY_STRATEGY="none"
        log "✓ Proxy strategy configured: ${PROXY_STRATEGY}"
        log "  http_proxy: <not set>"
        log "  https_proxy: <not set>"
        log "  no_proxy: <not set>"
        return 0
    fi

    # Build proxy URLs
    local ENCODED_PASS="" PROXY_URL PROXY_URL_NO_CREDS
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
        PROXY_URL="http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
        PROXY_URL_NO_CREDS="http://${PROXY_HOST}:${PROXY_PORT}"
        PROXY_CURL_OPTS="-x ${PROXY_HOST}:${PROXY_PORT} -U ${PROXY_USER}:${PROXY_PASSWORD} ${CURL_SSL_OPT}"
    else
        PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
        PROXY_URL_NO_CREDS="${PROXY_URL}"
        PROXY_CURL_OPTS="-x ${PROXY_HOST}:${PROXY_PORT} ${CURL_SSL_OPT}"
    fi

    # Helper: build NO_PROXY using explicit INTERNAL_REPO_DOMAINS and probe-based detection
    _build_no_proxy_list() {
        local base="localhost,127.0.0.1,::1,.local"
        local extra="${INTERNAL_REPO_DOMAINS}"

        # Auto-detect repo hosts from .repo files and add only those reachable DIRECT
        if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            local detected
            detected=$(_detect_direct_repo_hosts)
            if [ -n "$detected" ]; then
                extra="${extra:+$extra,}$detected"
            fi
        fi

        # De-duplicate entries
        printf '%s' "$base${extra:+,$extra}" | awk -v RS=',' '!a[$0]++ {out=out (out?",":"") $0} END{print out}'
    }

    case "${PROXY_STRATEGY}" in
        all)
            log "Strategy: ALL - All repos and downloads via proxy"
            export http_proxy="${PROXY_URL}"
            export https_proxy="${PROXY_URL}"
            export no_proxy="localhost,127.0.0.1,::1,.local"
            export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
            # Force dnf/yum to use the authenticated proxy explicitly
            if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
                DNF_PROXY_OPT="--setopt=proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            else
                DNF_PROXY_OPT="--setopt=proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            fi
            # APT explicit proxy
            APT_PROXY_OPT_PROXY="-o Acquire::http::Proxy=${PROXY_URL} -o Acquire::https::Proxy=${PROXY_URL}"
            ;;

        external)
            log "Strategy: EXTERNAL - External via proxy, internal repos direct"
            local NO_PROXY_LIST
            NO_PROXY_LIST=$(_build_no_proxy_list)
            export http_proxy="${PROXY_URL}"
            export https_proxy="${PROXY_URL}"
            export no_proxy="${NO_PROXY_LIST}"
            export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
            # Let env + NO_PROXY govern dnf/yum (no forced --setopt proxy here)
            DNF_PROXY_OPT=""
            APT_PROXY_OPT_PROXY="-o Acquire::http::Proxy=${PROXY_URL} -o Acquire::https::Proxy=${PROXY_URL}"
            ;;

        none)
            log "Strategy: NONE - Direct connections, no proxy"
            unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
            DNF_PROXY_OPT=""
            APT_PROXY_OPT_PROXY=""
            ;;

        auto|*)
            log "Strategy: AUTO - Try direct first, then proxy; settle on EXTERNAL if either works"
            log "Testing repository connectivity..."
            # Probe Docker CE endpoint direct
            if timeout 5 curl -s -o /dev/null -w "%{http_code}" ${CURL_SSL_OPT} "https://download.docker.com/" 2>/dev/null | grep -qE '^(200|301|302)$'; then
                log "External repos reachable directly - using EXTERNAL strategy"
                PROXY_STRATEGY="external"; setup_proxy_strategy; return $?
            fi
            # Probe via proxy with credentials and accept 407 as success (proxy path viable)
            if timeout 7 curl -s -o /dev/null -w "%{http_code}" -x "${PROXY_URL}" ${CURL_SSL_OPT} --proxy-anyauth "https://download.docker.com/" 2>/dev/null | grep -qE '^(200|301|302|407)$'; then
                log "External repos reachable via proxy - using EXTERNAL strategy"
                PROXY_STRATEGY="external"; setup_proxy_strategy; return $?
            fi
            log "Neither direct nor proxy probe succeeded - using ALL strategy"
            PROXY_STRATEGY="all"; setup_proxy_strategy; return $?
            ;;
    esac

    # Export key proxy variables so they survive subshells
    export PROXY_STRATEGY DNF_PROXY_OPT APT_PROXY_OPT_PROXY PROXY_URL PROXY_URL_NO_CREDS http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
    log "✓ Proxy strategy configured: ${PROXY_STRATEGY}"
    local _hp=$([ -n "${http_proxy:-}" ] && _mask_url_creds "$http_proxy" || echo "<not set>")
    local _hps=$([ -n "${https_proxy:-}" ] && _mask_url_creds "$https_proxy" || echo "<not set>")
    log "  http_proxy: ${_hp}"
    log "  https_proxy: ${_hps}"
    log "  no_proxy: ${no_proxy:-<not set>}"
    return 0
}

# Validate proxy configuration
validate_proxy_config() {
    if [ -z "${PROXY_HOST}" ] || [ -z "${PROXY_PORT}" ]; then
        return 0
    fi
    
    echo ""
    echo ""
    echo ""
    echo ":: Validating Proxy Configuration"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        echo "  Proxy: ${PROXY_HOST}:${PROXY_PORT} (authenticated)"
        echo "  User: ${PROXY_USER}"
        
        # Encode password and verify encoding
        ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
        
        if ! verify_password_encoding "${PROXY_PASSWORD}" "$ENCODED_PASS"; then
            echo ""
            echo "⚠️  WARNING: Proxy Password Encoding"
            echo ""
            echo "Your password contains special characters but URL encoding did not work."
            echo ""
            echo "Solutions:"
            echo "  1. Install python3: sudo apt-get install -y python3 (Debian/Ubuntu)"
            echo "  2. Install python3: sudo dnf install -y python3 (RHEL/CentOS)"
            echo "  3. Install jq: sudo apt-get install -y jq"
            echo "  4. Or the script will use fallback encoding (less reliable)"
            echo ""
            if ! prompt_yn "Continue anyway with potentially broken encoding?" "n"; then
                echo "Installation cancelled."
                exit 1
            fi
        else
            echo "✓ Password encoding successful"
        fi
        
        # Check for tools
        echo ""
        echo "Checking encoding tools availability:"
        if command -v python3 &>/dev/null; then
            echo "  ✓ python3: $(python3 --version 2>&1)"
        else
            echo "  ✗ python3: not installed (recommended for reliable encoding)"
        fi
        
        if command -v jq &>/dev/null; then
            echo "  ✓ jq: $(jq --version 2>&1)"
        else
            echo "  ✗ jq: not installed (alternative encoding method)"
        fi
        
        # Warn if neither python3 nor jq is available
        if ! command -v python3 &>/dev/null && ! command -v jq &>/dev/null; then
            echo ""
            echo "⚠️  WARNING: Neither python3 nor jq is installed."
            echo "   Using fallback manual encoding which may not handle all special characters."
            echo "   Recommend: sudo $PKG_MANAGER install -y python3"
            echo ""
        fi
        
    else
        echo "  Proxy: ${PROXY_HOST}:${PROXY_PORT}"
        echo "  Authentication: None"
    fi
    
    echo ""
    echo "✓ Proxy configuration validated"
    echo ""
}

cleanup_remote_scripts_dirs() {
    echo ""
    echo ""
    echo ""
    echo ":: Cleaning Up Temporary Files on Remote Nodes"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    
    local cleanup_failed=0
    local failed_cleanups=()
    
    # For multi-node Traefik setup
    local hosts_to_clean=()
    local host_names=()
    
    if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
        hosts_to_clean=("${BACKUP_IPS[@]}")
        host_names=("${BACKUP_NODES[@]}")
    fi
    
    for i in "${!hosts_to_clean[@]}"; do
        ip="${hosts_to_clean[$i]}"
        name="${host_names[$i]}"
        
        echo -n "Cleaning up $name ($ip)... "
        
        # Try to remove the scripts directory on remote host
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            if sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "rm -rf '$SCRIPTS_DIR' 2>/dev/null" 2>/dev/null; then
                echo "✓ Done"
            else
                echo "⚠️  Warning (cleanup failed, but not critical)"
                cleanup_failed=1
                failed_cleanups+=("$name")
            fi
        else
            if ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "rm -rf '$SCRIPTS_DIR' 2>/dev/null" 2>/dev/null; then
                echo "✓ Done"
            else
                echo "⚠️  Warning (cleanup failed, but not critical)"
                cleanup_failed=1
                failed_cleanups+=("$name")
            fi
        fi
    done
    
    if [ $cleanup_failed -eq 1 ]; then
        echo ""
        echo "Note: Cleanup warnings are non-critical. Installation completed successfully."
        echo "You can manually remove the scripts directory if desired:"
        for failed in "${failed_cleanups[@]}"; do
            echo "  ssh $failed 'rm -rf $SCRIPTS_DIR'"
        done
    fi
    
    echo "✓ Remote cleanup complete"
}

# Execute script on remote host
execute_remote_script() {
    local ip=$1
    local script_path=$2
    
    PASS_B64="$(printf '%s' "$SUDO_PASS" | base64)"

    write_local_file "$SCRIPTS_DIR/run_script_wrapper.sh" <<'WRAPPER'
#!/bin/bash
set +e

# === Receive inputs ===
SUDO_PASS="$(printf %s "$SUDO_PASS_B64" | base64 -d)"

# The caller may pass these as env when invoking this wrapper over SSH
# PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASSWORD, INTERNAL_REPO_DOMAINS, SKIP_SSL_VERIFY

# === Minimal URL-encode for password (python3 -> jq -> manual) ===
_urlenc() {
  local s="$1" e=""
  if command -v python3 >/dev/null 2>&1; then
    e=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=''))" "$s" 2>/dev/null) || e=""
  fi
  if [ -z "$e" ] && command -v jq >/dev/null 2>&1; then
    e=$(printf '%s' "$s" | jq -sRr @uri 2>/dev/null) || e=""
  fi
  if [ -z "$e" ]; then
    e="$s"; e="${e//%/%25}"; e="${e//!/%21}"; e="${e//:/%3A}"; e="${e//@/%40}"; e="${e//#/%23}"; e="${e//\$/%24}"; e="${e//&/%26}"; e="${e//\'/%27}"; e="${e//\(/%28}"; e="${e//)/%29}"; e="${e//\*/%2A}"; e="${e//+/%2B}"; e="${e//,/%2C}"; e="${e//\//%2F}"; e="${e//;/%3B}"; e="${e//=/%3D}"; e="${e//\?/%3F}"; e="${e//[/%5B}"; e="${e//]/%5D}"; e="${e// /%20}"
  fi
  printf '%s' "$e"
}

# === Build CURL SSL option ===
CURL_SSL_OPT=""; [ "${SKIP_SSL_VERIFY}" = "true" ] && CURL_SSL_OPT="--insecure"

# === Normalize proxy usage inside target script ===
# Prevent constructs like "http://http://..." when the target script builds envs from $PROXY
if [ -f SCRIPT_PATH ]; then
  sed -i -E 's#(=|\s)http://\$PROXY#\1\$PROXY#g' SCRIPT_PATH
  sed -i -E 's#(=|\s)https://\$PROXY#\1\$PROXY#g' SCRIPT_PATH
  sed -i -E 's#-x http://\$PROXY#-x \$PROXY#g' SCRIPT_PATH
  sed -i -E 's#Acquire::http::Proxy=http://\$PROXY#Acquire::http::Proxy=\$PROXY#g' SCRIPT_PATH
  sed -i -E 's#Acquire::https::Proxy=http://\$PROXY#Acquire::https::Proxy=\$PROXY#g' SCRIPT_PATH
  sed -i -E 's#--setopt=proxy=http://\$PROXY#--setopt=proxy=\$PROXY#g' SCRIPT_PATH
fi

# === Reconstruct proxy env if host/port provided ===
if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
  if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
    _ENC=$(_urlenc "${PROXY_PASSWORD}")
    export http_proxy="http://${PROXY_USER}:${_ENC}@${PROXY_HOST}:${PROXY_PORT}"
  else
    export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
  fi
  export https_proxy="$http_proxy"

  # Build a smart no_proxy on the remote (no function calls)
  if [ -z "${no_proxy}" ] || [ "${no_proxy}" = "localhost,127.0.0.1,::1,.local" ]; then
    np_base="localhost,127.0.0.1,::1,.local"; detected_hosts=""
    if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
      while IFS= read -r h; do
        if timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "https://$h" >/dev/null 2>&1 || \
           timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "http://$h"  >/dev/null 2>&1; then
          case ",${detected_hosts}," in *,"$h",*) :;; *) detected_hosts="${detected_hosts}${detected_hosts:+,}$h";; esac
        fi
      done < <(grep -hE '^(baseurl|mirrorlist)' /etc/yum.repos.d/*.repo 2>/dev/null | grep -oE 'https?://[^/]+' | sed -E 's#^https?://##' | sort -u)
    fi
    if [ -n "${INTERNAL_REPO_DOMAINS}" ]; then
      detected_hosts="${detected_hosts}${detected_hosts:+,}${INTERNAL_REPO_DOMAINS}"
    fi
    if [ -n "$detected_hosts" ]; then
      export no_proxy="${np_base},${detected_hosts}"
    else
      export no_proxy="${np_base}"
    fi
  fi
  export HTTP_PROXY="$http_proxy"
  export HTTPS_PROXY="$https_proxy"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
fi

# === Elevate with environment preserved ===
# Use -E to pass proxy env to root for dnf/curl within SCRIPT_PATH
printf '%s' "$SUDO_PASS" | sudo -E -S bash SCRIPT_PATH 2>&1 || true

# Cleanup wrapper copy
rm -f SCRIPT_PATH || true
exit 0
WRAPPER
    chmod 644 "$SCRIPTS_DIR/run_script_wrapper.sh"
    sed -i "s|SCRIPT_PATH|$script_path|g" "$SCRIPTS_DIR/run_script_wrapper.sh"

    ensure_SCRIPTS_DIR "$ip" || true
    copy_to_remote "$SCRIPTS_DIR/run_script_wrapper.sh" "$ip" "$SCRIPTS_DIR/run_script.sh" || true

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh -tt $SSH_OPTS -l "$CURRENT_USER" "$ip" "env SUDO_PASS_B64='$PASS_B64' PROXY_HOST='${PROXY_HOST}' PROXY_PORT='${PROXY_PORT}' PROXY_USER='${PROXY_USER}' PROXY_PASSWORD='${PROXY_PASSWORD}' INTERNAL_REPO_DOMAINS='${INTERNAL_REPO_DOMAINS}' SKIP_SSL_VERIFY='${SKIP_SSL_VERIFY}' PROXY_STRATEGY='${PROXY_STRATEGY}' bash '$SCRIPTS_DIR/run_script.sh' && rm -f '$SCRIPTS_DIR/run_script.sh'" 2>&1 | grep -v "^Connection to\|^Shared connection to"
    else
        ssh -tt $SSH_OPTS -l "$CURRENT_USER" "$ip" "env SUDO_PASS_B64='$PASS_B64' PROXY_HOST='${PROXY_HOST}' PROXY_PORT='${PROXY_PORT}' PROXY_USER='${PROXY_USER}' PROXY_PASSWORD='${PROXY_PASSWORD}' INTERNAL_REPO_DOMAINS='${INTERNAL_REPO_DOMAINS}' SKIP_SSL_VERIFY='${SKIP_SSL_VERIFY}' PROXY_STRATEGY='${PROXY_STRATEGY}' bash '$SCRIPTS_DIR/run_script.sh' && rm -f '$SCRIPTS_DIR/run_script.sh'" 2>&1 | grep -v "^Connection to\|^Shared connection to"
    fi
    
    rm -f "$SCRIPTS_DIR/run_script_wrapper.sh"
}

# Helper function to run docker commands with proper permissions
docker_cmd() {
    if [ "${USE_DOCKER_GROUP:-false}" = "true" ]; then
        sg docker -c "docker $*"
    else
        docker "$@"
    fi
}

ensure_log_file() {
    # DON'T use SCRIPTS_DIR for the log file!
    # Use /var/log or user's home directory instead
    
    if [ ! -f "$LOGFILE" ]; then
        touch "$LOGFILE" 2>/dev/null || LOGFILE="$ACTUAL_HOME/traefik_installation.log"
    fi
    
    if [ ! -w "$LOGFILE" ]; then
        LOGFILE="$ACTUAL_HOME/traefik_installation.log"
        # Create directory if it doesn't exist
        mkdir -p "$(dirname "$LOGFILE")"
        touch "$LOGFILE"
        chmod 644 "$LOGFILE"
    fi
    
    # Ensure log file is always writable
    if [ ! -w "$LOGFILE" ]; then
        chmod 666 "$LOGFILE" 2>/dev/null || true
    fi
    
    echo "Log file: $LOGFILE"
}

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE" >&2
}

# Function to exit the script on error
exit_on_error() {
    log "Error: $1"
    log "Context: ${BASH_SOURCE[1]}:${BASH_LINENO[0]}"
    cleanup
    exit 1
}

# Function to cleanup on failure
cleanup() {
    log "Cleaning up..."
    # Remove temporary scripts directory if it exists
    if [ -d "$SCRIPTS_DIR" ]; then
        rm -rf "$SCRIPTS_DIR"
        log "Removed temporary scripts directory: $SCRIPTS_DIR"
    fi
}

# Write a local file as the non-root user when invoked via sudo
write_local_file() {
    local dest="$1"
    local dest_dir
    dest_dir="$(dirname -- "$dest")"

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" mkdir -p -- "$dest_dir"
        sudo -u "$SUDO_USER" rm -f -- "$dest"
        sudo -u "$SUDO_USER" bash -lc "umask 022; cat > '$dest'"
    else
        mkdir -p -- "$dest_dir"
        rm -f -- "$dest"
        umask 022
        cat > "$dest"
    fi
}

# Validate OS and version
validate_os() {
    echo ""
    echo ""
    echo ""
    echo ":: Checking operating system compatibility..."
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    
    if [ ! -f /etc/os-release ]; then
        echo "ERROR: Cannot determine operating system"
        exit 1
    fi
    
    source /etc/os-release
    
    OS_ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    OS_VERSION="${VERSION_ID%%.*}"
    
    # Supported operating systems
    case "$OS_ID" in
        ubuntu)
            echo "✓ Operating System: $PRETTY_NAME"
            ;;
        debian)
            echo "✓ Operating System: $PRETTY_NAME"
            ;;
        centos|rhel|rocky|almalinux)
            echo "✓ Operating System: $PRETTY_NAME"
            ;;
        *)
            echo "⚠️  Operating System: $PRETTY_NAME (untested)"
            if ! prompt_yn "Continue anyway?"; then
                echo "Installation cancelled"
                exit 0
            fi
            ;;
    esac
    
    # Check version for Ubuntu
    if [ "$OS_ID" = "ubuntu" ]; then
        case "$VERSION_ID" in
            20.04*|22.*|24.*|25.*)
                echo "✓ Version: $VERSION_ID (supported)"
                ;;
            *)
                echo "⚠️  Version: $VERSION_ID (untested, may work)"
                if ! prompt_yn "Continue anyway?"; then
                    echo "Installation cancelled"
                    exit 0
                fi
                ;;
        esac
    fi
    
    # Check version for Debian
    if [ "$OS_ID" = "debian" ]; then
        if [ "$OS_VERSION" -lt 11 ]; then
            echo "⚠️  Debian version $OS_VERSION may be too old"
            if ! prompt_yn "Continue anyway?"; then
                echo "Installation cancelled"
                exit 0
            fi
        else
            echo "✓ Version: $OS_VERSION"
        fi
    fi
    
    # Check for required commands
    echo "Checking required commands..."
    local missing=0

    # Check for sudo
    if ! command -v sudo &> /dev/null; then
        echo "❌ sudo not found"
        echo ""
        echo "ERROR: This script requires sudo to be installed."
        echo ""
        echo "To install sudo, run the following commands as root:"
        echo "  apt-get update && apt-get install sudo  # Debian/Ubuntu"
        echo "  dnf install sudo                         # CentOS/RHEL"
        echo "  usermod -aG sudo YOUR_USERNAME"
        echo ""
        echo "Then log out and log back in, and run this script again."
        exit 1
    fi
    
    if [ $missing -eq 1 ]; then
        echo "ERROR: Required commands are missing"
        exit 1
    fi
    
    echo "✓ All required commands found"
    echo ""
}

check_execution_context() {
    echo ""
    echo ""
    echo ":: Validating Execution Context"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""

    # Check 1: Must be run with sudo (EUID 0) but not logged in directly as root
    if [ "$EUID" -ne 0 ]; then
        echo "❌ ERROR: This script must be run with sudo"
        echo ""
        echo "Correct usage:"
        echo "  sudo ./$(basename "$0")"
        echo ""
        echo "This is required because the script writes to /opt/indica which"
        echo "is owned by root. All files will be owned by root:root ensuring"
        echo "no single engineer account has ownership of production files."
        echo ""
        exit 1
    fi

    if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" = "root" ]; then
        echo "❌ ERROR: Do not log in as root and run this script directly."
        echo ""
        echo "Always invoke via sudo from your own user account:"
        echo "  sudo ./$(basename "$0")"
        echo ""
        echo "This ensures SSH keys and home directory are resolved correctly"
        echo "for remote backup node operations."
        echo ""
        exit 1
    fi

    echo "✓ Script is being run as: ${CURRENT_USER} (via sudo)"
    echo "✓ Home directory: $ACTUAL_HOME"
    echo "✓ SSH keys: $ACTUAL_HOME/.ssh/id_rsa"
    echo "✓ Execution context validated"
}

# Check repository connectivity
check_repository_connectivity() {
    echo ""
    echo ""
    echo ""
    echo ":: Checking Repository Connectivity"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    
    # Check local node first
    local LOCAL_CHECK_FAILED=0
    
    echo ""
    echo "Local/Master Node:"
    echo "----------"
    
    check_single_node "local" "" ""
    LOCAL_CHECK_FAILED=$?
    
    # Check if we should test backup nodes
    # Safe check: verify variable is set and equals "yes"
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ]; then
        # Safe array check: verify array is declared and has elements
        local backup_count=0
        if [ -n "${BACKUP_NODES+x}" ]; then
            # Array is declared, get length
            backup_count=${#BACKUP_NODES[@]}
        fi
        
        if [ "$backup_count" -gt 0 ]; then
            echo ""
            echo "Checking Backup Nodes:"
            
            local REMOTE_FAILURES=0
            
            for i in "${!BACKUP_NODES[@]}"; do
                local node="${BACKUP_NODES[$i]}"
                local ip="${BACKUP_IPS[$i]}"
                
                echo ""
                echo "$node ($ip):"
                echo "----------"

                # Install minimal prerequisites on the backup node before running
                # connectivity checks — curl/wget/ca-certificates may not be present yet.
                # Uses write_local_file + execute_remote_script so SUDO_PASS is passed
                # correctly via the wrapper (plain SSH sudo -S won't work here).
                echo "  Installing prerequisites for connectivity checks..."
                local _prereq_script="$SCRIPTS_DIR/prereq_check_${node}.sh"
                write_local_file "$_prereq_script" <<'PREREQSCRIPT'
#!/bin/bash
set -e
if command -v apt-get >/dev/null 2>&1; then
    missing=""
    for p in curl wget ca-certificates; do
        dpkg -l "$p" 2>/dev/null | grep -q "^ii" || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        echo "  Installing:$missing"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq $missing
    fi
elif command -v dnf >/dev/null 2>&1; then
    missing=""
    for p in curl wget ca-certificates; do
        rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        echo "  Installing:$missing"
        dnf install -y --setopt=skip_if_unavailable=True $missing
    fi
fi
echo "  Prerequisites ready"
PREREQSCRIPT
                chmod 644 "$_prereq_script"
                ensure_SCRIPTS_DIR "$ip" || true
                copy_to_remote "$_prereq_script" "$ip" "$_prereq_script" || true
                execute_remote_script "$ip" "$_prereq_script" || true
                rm -f "$_prereq_script"

                check_single_node "remote" "$node" "$ip"
                if [ $? -ne 0 ]; then
                    REMOTE_FAILURES=$((REMOTE_FAILURES + 1))
                fi
            done
            
            if [ $REMOTE_FAILURES -gt 0 ]; then
                echo ""
                echo ""
                echo "  ── ⚠️  $REMOTE_FAILURES backup node(s) failed repository checks "
                echo ""
                echo ""
                echo "Deployment to these nodes may fail during package installation."
                echo ""
                if ! prompt_yn "Continue with multi-node deployment?"; then
                    echo "Installation cancelled."
                    cleanup
                    exit 1
                fi
                echo ""
                echo "⚠️  Continuing despite remote node connectivity warnings..."
            else
                echo ""
                echo ""
                echo ""
                echo ":: ✓ All Nodes: Repository Access Verified"
                echo "──────────────────────────────────────────────────"
                echo ""
                echo ""
            fi
        fi
    fi
    
    # Final status message for single-node or after multi-node checks
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "no" ] || [ "${backup_count:-0}" -eq 0 ]; then
        if [ $LOCAL_CHECK_FAILED -eq 1 ]; then
            echo ""
            echo "⚠️  Continuing despite local connectivity warnings..."
        else
            echo ""
            echo "✓ Repository Access Verified"
        fi
    fi
    
    echo ""
}

# Helper function to check a single node (local or remote)
check_single_node() {
    local check_type="$1"  # 'local' or 'remote'
    local node_name="$2"
    local node_ip="$3"
    
    local REPO_CHECK_FAILED=0
    local FAILED_REPOS=()
    
    # Configure proxy for connectivity checks
    if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
        if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
            # URL-encode password for environment variables and curl
            ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
            export http_proxy="http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            export https_proxy="http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            PROXY_CURL_OPT="-x ${PROXY_HOST}:${PROXY_PORT} -U ${PROXY_USER}:${PROXY_PASSWORD} ${CURL_SSL_OPT}"
        else
            export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
            export https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
            PROXY_CURL_OPT="-x ${PROXY_HOST}:${PROXY_PORT} ${CURL_SSL_OPT}"
        fi
        # Respect any precomputed no_proxy from strategy
        export no_proxy="${no_proxy:-localhost,127.0.0.1}"
    else
        PROXY_CURL_OPT="${CURL_SSL_OPT}"
    fi
    
    # Helper function to run command locally or remotely
    run_check() {
        local cmd="$1"
        if [ "$check_type" = "remote" ]; then
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$node_ip" "$cmd" 2>/dev/null
            else
                ssh $SSH_OPTS -l "$CURRENT_USER" "$node_ip" "$cmd" 2>/dev/null
            fi
        else
            eval "$cmd"
        fi
    }
    
    # Check 1: Docker Package Repository
    echo -n "  Docker packages (download.docker.com)... "
    DOWNLOAD_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} https://download.docker.com 2>/dev/null || echo 'FAILED'")
    
    if echo "$DOWNLOAD_TEST" | grep -q "200\|301\|302\|403"; then
        echo "✓ Reachable"
    else
        echo "❌ FAILED"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Docker packages (download.docker.com)")
    fi
    
    # Check 2: Docker Hub Registry API
    echo -n "  Docker Hub registry (registry-1.docker.io)... "
    REGISTRY_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} https://registry-1.docker.io/v2/ 2>/dev/null || echo 'FAILED'")
    
    if echo "$REGISTRY_TEST" | grep -q "200\|301\|401"; then
        echo "✓ Reachable"
    else
        echo "❌ FAILED"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Docker Hub registry (registry-1.docker.io)")
    fi

    # Check 2b: Docker Auth Service (required for image pulls)
    echo -n "  Docker auth (auth.docker.io)... "
    AUTH_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} https://auth.docker.io/token 2>/dev/null || echo 'FAILED'")

    if echo "$AUTH_TEST" | grep -q "200\|400\|401"; then
        echo "✓ Reachable"
    else
        echo "❌ FAILED (image pulls will fail — auth endpoint blocked)"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Docker auth (auth.docker.io)")
    fi
    
    # Check 3: Docker Hub Main Domain
    echo -n "  Docker Hub (docker.io)... "
    DOCKERIO_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} https://docker.io 2>/dev/null || echo 'FAILED'")
    
    if echo "$DOCKERIO_TEST" | grep -q "200\|301\|302"; then
        echo "✓ Reachable"
    else
        echo "❌ FAILED"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Docker Hub (docker.io)")
    fi
    
    # Check 4: Docker Image Storage (Cloudflare R2)
    echo -n "  Docker image storage (docker-images-prod...cloudflarestorage.com)... "
    R2_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} https://docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com 2>/dev/null || echo 'FAILED'")
    
    if echo "$R2_TEST" | grep -q "200\|301\|302\|400\|403\|404"; then
        echo "✓ Reachable"
    else
        echo "❌ FAILED (image downloads will fail)"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Docker image storage (docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com)")
    fi
    
    # Check 5: Standard package repositories
    echo -n "  Standard package repositories... "
    
    # Detect OS
    if [ "$check_type" = "remote" ]; then
        DETECTED_OS=$(run_check "grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '\"'")
    else
        DETECTED_OS="${OS_ID:-unknown}"
    fi
    
    REPO_TEST_PASSED=0
    
    case "$DETECTED_OS" in
        ubuntu)
            REPO_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} http://archive.ubuntu.com/ubuntu/dists/ 2>/dev/null || echo 'FAILED'")
            if echo "$REPO_TEST" | grep -q "200\|301\|302"; then
                REPO_TEST_PASSED=1
            fi
            ;;
        debian)
            REPO_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} http://deb.debian.org/debian/dists/ 2>/dev/null || echo 'FAILED'")
            if echo "$REPO_TEST" | grep -q "200\|301\|302"; then
                REPO_TEST_PASSED=1
            fi
            ;;
        centos|rhel|rocky|almalinux)
            REPO_TEST=$(run_check "timeout 10 curl -s ${CURL_SSL_OPT} -o /dev/null -w '%{http_code}' ${PROXY_CURL_OPT} http://mirror.centos.org 2>/dev/null || echo 'FAILED'")
            if echo "$REPO_TEST" | grep -q "200\|301\|302"; then
                REPO_TEST_PASSED=1
            fi
            ;;
        *)
            if [ "$check_type" = "remote" ]; then
                echo "⚠️  Unknown OS ($DETECTED_OS)"
                REPO_TEST_PASSED=1
            else
                echo "❌ FAILED (unknown OS: $DETECTED_OS)"
                REPO_CHECK_FAILED=1
                FAILED_REPOS+=("Standard package repositories")
            fi
            ;;
    esac
    
    if [ $REPO_TEST_PASSED -eq 1 ]; then
        if [ -n "$DETECTED_OS" ] && [ "$DETECTED_OS" != "unknown" ]; then
            echo "✓ Reachable ($DETECTED_OS)"
        else
            echo "✓ Reachable"
        fi
    elif [ $REPO_TEST_PASSED -eq 0 ]; then
        echo "❌ FAILED"
        REPO_CHECK_FAILED=1
        FAILED_REPOS+=("Standard package repositories ($DETECTED_OS)")
    fi
    
    # Additional checks for remote nodes
    if [ "$check_type" = "remote" ]; then
        # Check DNS resolution
        echo -n "  DNS resolution... "
        DNS_TEST=$(run_check "getent hosts registry-1.docker.io >/dev/null 2>&1 && echo 'OK' || echo 'FAILED'")
        
        if echo "$DNS_TEST" | grep -q "OK"; then
            echo "✓ Working"
        else
            echo "❌ FAILED"
            REPO_CHECK_FAILED=1
            FAILED_REPOS+=("DNS resolution")
        fi
        
        # Check outbound HTTPS
        echo -n "  Outbound HTTPS (port 443)... "
        HTTPS_TEST=$(run_check "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/registry-1.docker.io/443' 2>/dev/null && echo 'OK' || echo 'FAILED'")
        
        if echo "$HTTPS_TEST" | grep -q "OK"; then
            echo "✓ Open"
        else
            echo "⚠️  May be blocked (non-critical if proxy configured)"
        fi
    fi
    
    # Handle failures
    if [ $REPO_CHECK_FAILED -eq 1 ]; then
        echo ""
        if [ "$check_type" = "remote" ]; then
            echo "  ❌ Failed checks on $node_name:"
        else
            echo ""
            echo "  ⚠️  Failed checks:"
        fi
        
        for failed in "${FAILED_REPOS[@]}"; do
            echo "    - $failed"
        done
        
        if [ "$check_type" = "local" ]; then
            echo ""
            echo "  Possible causes:"
            echo "    1. Firewall blocking Docker Hub"
            echo "    2. Network connectivity issues"
            echo "    3. Proxy misconfiguration"
            echo "    4. DNS resolution problems"
            echo ""
            echo "Current proxy settings:"
            if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
                if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
                    echo "  Proxy: ${PROXY_HOST}:${PROXY_PORT} (authenticated as ${PROXY_USER})"
                else
                    echo "  Proxy: ${PROXY_HOST}:${PROXY_PORT}"
                fi
            else
                echo "  Proxy: Not configured"
            fi
            echo ""
            
            echo "  Required Docker endpoints:"
            echo "    - download.docker.com"
            echo "    - registry-1.docker.io"
            echo "    - docker.io"
            echo "    - docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com"
            echo ""
            
            if ! prompt_yn "  Continue anyway? Docker pulls will likely fail." "n"; then
                echo "  Installation cancelled."
                cleanup
                exit 1
            fi
            # User confirmed to continue despite warnings, reset failure flag
            REPO_CHECK_FAILED=0
        else

            REPO_CHECK_FAILED=0
        fi
    else
        echo "  ✓ All checks passed"
    fi
    
    return $REPO_CHECK_FAILED
}

# Function to validate IPv4 address
validate_ip() {
    local ip=$1
    
    # Regex pattern for valid IPv4 address
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    # Check if IP matches the pattern
    if [[ ! $ip =~ $ip_regex ]]; then
        return 1
    fi
    
    # Check each octet is between 0-255
    local IFS='.'
    local -a octets=($ip)
    
    for octet in "${octets[@]}"; do
        # Remove leading zeros to avoid octal interpretation
        octet=$((10#$octet))
        if ((octet < 0 || octet > 255)); then
            return 1
        fi
    done
    
    return 0
}

# ==========================================
# Script Execution Starts Here
# ==========================================

ensure_log_file

# Now log can be used safely
log "=== Clinical Traefik Setup Started ==="
log "User: $CURRENT_USER"
log "Home: $ACTUAL_HOME"

echo ""
echo "╔═════════════════════════════════════════════════╗"
echo "║                                                 ║"
echo "║   Reverse Proxy                                 ║"
echo "║   Setup & Management                            ║"
echo "║                                                 ║"
printf "║   %-45s║\n" "v${VERSION}"
echo "║                                                 ║"
echo "╚═════════════════════════════════════════════════╝"
echo ""

# ==========================================
# Early Prerequisites Check
# ==========================================
# Install essential packages before OS detection and proxy checks.
# The full prerequisites list (ipcalc, nano, etc.) is installed later;
# this section only covers what is needed for the script to bootstrap.

echo ""
echo "Checking essential prerequisites..."

if command -v apt-get &>/dev/null; then
    _early_missing=""
    for _pkg in lsb-release ca-certificates gnupg curl wget; do
        if ! dpkg -l "$_pkg" 2>/dev/null | grep -q "^ii"; then
            _early_missing="$_early_missing $_pkg"
        fi
    done
    if [ -n "$_early_missing" ]; then
        echo "Installing essential prerequisites:$_early_missing"
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq $_early_missing || {
            echo "⚠️  Warning: Could not install some prerequisites"
            echo "   The script will continue but some checks may fail"
        }
        echo "✓ Essential prerequisites installed"
    else
        echo "✓ All essential prerequisites already installed"
    fi
elif command -v dnf &>/dev/null; then
    _early_missing=""
    for _pkg in ca-certificates curl wget gnupg2; do
        if ! rpm -q "$_pkg" &>/dev/null; then
            _early_missing="$_early_missing $_pkg"
        fi
    done
    if [ -n "$_early_missing" ]; then
        echo "Installing essential prerequisites:$_early_missing"
        dnf --setopt=skip_if_unavailable=True install -y $_early_missing || {
            echo "⚠️  Warning: Could not install some prerequisites"
            echo "   The script will continue but some checks may fail"
        }
        echo "✓ Essential prerequisites installed"
    else
        echo "✓ All essential prerequisites already installed"
    fi
fi
echo ""

validate_os
check_execution_context
validate_proxy_config
setup_proxy_strategy || exit_on_error "Failed to setup proxy strategy"

# ==========================================
# Cleanup Mode
# ==========================================

if [[ "$1" == "--clean" ]]; then
    # ===== LOAD CONFIG FIRST (before any cleanup) =====
    CLEAN_BACKUP_NODES=false
    UNINSTALL_DOCKER_REMOTE=false
    UNINSTALL_KEEPALIVED_REMOTE=false
    declare -a BACKUP_NODES
    declare -a BACKUP_IPS
    
    # Preserve config data before we start deleting anything
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Loading configuration..."
        source "$CONFIG_FILE"
        
        if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        echo ""
        echo ""
        echo ":: Multi-Node Deployment Detected"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo "This system was configured with backup nodes:"
            for i in "${!BACKUP_NODES[@]}"; do
            # Check if interface info is available
            if [ -n "${BACKUP_INTERFACES[$i]:-}" ]; then
                echo "  - ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]}) - Interface: ${BACKUP_INTERFACES[$i]}"
            else
                echo "  - ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
            fi
        done
            echo ""
            if prompt_yn "Do you want to clean backup nodes as well?" "y"; then
                CLEAN_BACKUP_NODES=true
                
                # Ask about package removal
                echo ""
                echo "Package Removal Options for Backup Nodes:"
                echo ""
                if prompt_yn "Uninstall Keepalived package on backup nodes?" "y"; then
                    UNINSTALL_KEEPALIVED_REMOTE=true
                fi
                
                if prompt_yn "Uninstall Docker on backup nodes?" "n"; then
                    echo ""
                    echo "⚠️  WARNING: This will remove Docker and ALL containers/images on backup nodes!"
                    if prompt_yn "Are you absolutely sure?" "n"; then
                        UNINSTALL_DOCKER_REMOTE=true
                    fi
                fi
                
                # Get sudo password for remote operations
                echo ""
                read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
                echo ""
                export SUDO_PASS
                
                # Set up SSH options
                SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
            fi
        fi
    fi
    
    # ===== CONFIRM CLEANUP =====
    echo ""
    echo ""
    echo ""
    echo ":: Traefik/Keepalived Cleanup"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo "  ┌─ What will be removed ────────────────────────────────────────"
    echo "  │  - Traefik Docker container and all configuration"
    echo "  │  - SSL certificates and keys"
    echo "  │  - Keepalived service and configuration"
    echo "  │  - Deployment configuration file"
    echo "  │  - /opt/indica/traefik directory"
    if [[ "$CLEAN_BACKUP_NODES" == "true" ]]; then
        echo "  │"
        echo "  │  Backup nodes (${#BACKUP_NODES[@]}):"
        for i in "${!BACKUP_NODES[@]}"; do
            echo "  │    - ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
        done
        if [[ "$UNINSTALL_KEEPALIVED_REMOTE" == "true" ]]; then
            echo "  │  - Keepalived package will be uninstalled from backup nodes"
        fi
        if [[ "$UNINSTALL_DOCKER_REMOTE" == "true" ]]; then
            echo "  │  - Docker will be uninstalled from backup nodes"
        fi
    fi
    echo "  └────────────────────────────────────────────────────────────────"
    echo ""
    echo "  !! This operation cannot be undone !!"
    echo ""
    if ! prompt_yn "Are you sure you want to proceed with the full uninstall?" "n"; then
        echo "Cleanup cancelled."
        exit 0
    fi
    echo ""
    if ! prompt_yn "Last chance — are you absolutely sure?" "n"; then
        echo "Cleanup cancelled."
        exit 0
    fi
    
    # ===== PERFORM CLEANUP =====
    
    # Function to perform cleanup on a node (local or remote)
    perform_cleanup() {
        local is_remote=$1
        local node_name=${2:-"local"}
        local node_ip=${3:-""}
        local is_local_final=${4:-"false"}  # Flag to know if this is the final local cleanup
        
        if [[ "$is_remote" == "true" ]]; then
            # ... (remote cleanup code - same as before)
            echo ""
            echo ""
            echo ""
            echo ":: Cleaning $node_name ($node_ip)"
            echo "──────────────────────────────────────────────────"
            echo ""
            echo ""
            
            # Create cleanup script for remote execution
            write_local_file "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh" <<'REMOTECLEANUP'
#!/bin/bash
set -e

echo "Starting cleanup on $(hostname)..."

# Check if we can access docker
DOCKER_ACCESSIBLE=true
if ! docker ps &>/dev/null 2>&1; then
    if sg docker -c "docker ps" &>/dev/null 2>&1; then
        DOCKER_ACCESSIBLE="sg"
    else
        DOCKER_ACCESSIBLE=false
    fi
fi

cleanup_docker_cmd() {
    if [ "$DOCKER_ACCESSIBLE" = "true" ]; then
        docker "$@"
    elif [ "$DOCKER_ACCESSIBLE" = "sg" ]; then
        sg docker -c "docker $*"
    else
        return 1
    fi
}

# Stop and remove Traefik
echo -n "Stopping Traefik... "
if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -q -f name=traefik 2>/dev/null | grep -q .; then
    cleanup_docker_cmd stop traefik 2>/dev/null || true
    echo "✓ Removed"
else
    echo "Not running"
fi

echo -n "Removing Traefik container... "
if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -a -q -f name=traefik 2>/dev/null | grep -q .; then
    cleanup_docker_cmd rm traefik 2>/dev/null || true
    echo "✓ Removed"
else
    echo "Not found"
fi

# Remove Docker network
#echo -n "Removing Docker network 'proxynet'... "
#if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd network inspect proxynet >/dev/null 2>&1; then
#    cleanup_docker_cmd network rm proxynet 2>/dev/null || true
#    echo "✓ Removed"
#else
#    echo "Not found"
#fi

# Remove Traefik directories
echo -n "Removing Traefik directories... "
if [ -d "/opt/indica/traefik" ]; then
    rm -rf /opt/indica/traefik
    echo "✓ Removed"
else
    echo "Not found"
fi

if [ -d "/opt/indica" ] && [ -z "$(ls -A /opt/indica 2>/dev/null)" ]; then
    rm -rf /opt/indica 2>/dev/null || true
fi

# Stop and disable Keepalived
echo -n "Stopping Keepalived... "
if systemctl is-active --quiet keepalived 2>/dev/null; then
    systemctl stop keepalived 2>/dev/null || true
    echo "✓ Stopped"
else
    echo "Not running"
fi

echo -n "Disabling Keepalived... "
if systemctl is-enabled --quiet keepalived 2>/dev/null; then
    systemctl disable keepalived 2>/dev/null || true
    echo "✓ disabled"
else
    echo "Not enabled"
fi

# Uninstall Keepalived if requested
if [[ "UNINSTALL_KEEPALIVED_FLAG" == "true" ]]; then
    echo -n "Uninstalling Keepalived package... "
    if command -v keepalived &> /dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get -y purge keepalived 2>/dev/null || true
            apt-get -y autoremove 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf -y remove keepalived 2>/dev/null || true
        fi
        echo "✓ Removed"
    else
        echo "Not installed"
    fi
fi

# Remove Keepalived configuration
echo -n "Removing Keepalived config... "
if [ -f "/etc/keepalived/keepalived.conf" ]; then
    rm -f /etc/keepalived/keepalived.conf
    rm -f /etc/keepalived/keepalived.conf.bak*
    echo "✓ Removed"
else
    echo "Not found"
fi

# Remove health check script
echo -n "Removing health check script... "
if [ -f "/bin/indica_service_check.sh" ]; then
    rm -f /bin/indica_service_check.sh
    echo "✓ Removed"
else
    echo "Not found"
fi

# Remove keepalived_script user and group
echo -n "Removing keepalived_script user/group... "
if id "keepalived_script" &>/dev/null; then
    userdel keepalived_script 2>/dev/null || true
fi
if getent group keepalived_script > /dev/null 2>&1; then
    groupdel keepalived_script 2>/dev/null || true
fi
echo "✓ Removed"

# Uninstall Docker if requested
if [[ "UNINSTALL_DOCKER_FLAG" == "true" ]]; then
    echo -n "Stopping Docker... "
    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    echo "✓ Removed"
    
    echo -n "Uninstalling Docker... "
    if command -v apt-get &>/dev/null; then
        apt-get -y purge docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
        apt-get -y autoremove 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
    elif command -v dnf &>/dev/null; then
        dnf -y remove docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    fi
    echo "✓ Removed"
    
    echo -n "Removing Docker data... "
    rm -rf /var/lib/docker 2>/dev/null || true
    rm -rf /var/lib/containerd 2>/dev/null || true
    rm -rf /etc/docker/daemon.json 2>/dev/null || true
    echo "✓ Removed"
fi

# Remove Docker proxy configuration
echo -n "Removing Docker proxy config... "
if [ -f "/etc/docker/daemon.json" ]; then
    rm -f /etc/docker/daemon.json
    systemctl daemon-reload 2>/dev/null || true
    echo "✓ Removed"
else
    echo "Not found"
fi

echo "✓ Cleanup complete on $(hostname)"
REMOTECLEANUP
            chmod 644 "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh"
            
            # Replace flags in the script
            sed -i "s/UNINSTALL_KEEPALIVED_FLAG/$UNINSTALL_KEEPALIVED_REMOTE/g" "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh"
            sed -i "s/UNINSTALL_DOCKER_FLAG/$UNINSTALL_DOCKER_REMOTE/g" "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh"
            
            # Copy and execute
            ensure_SCRIPTS_DIR "$node_ip" || true
            copy_to_remote "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh" "$node_ip" "$SCRIPTS_DIR/cleanup_traefik.sh" || true
            execute_remote_script "$node_ip" "$SCRIPTS_DIR/cleanup_traefik.sh" || true
            
            # Cleanup temp files
            rm -f "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh"
            
            echo "✓ Cleanup completed on $node_name"
            
        else
            # Local cleanup
            echo ""
            echo ""
            echo ""
            echo ":: Starting Cleanup Process (Local)"
            echo "──────────────────────────────────────────────────"
            echo ""
            echo ""
            echo ""
            
            # Check if we can access docker
            DOCKER_ACCESSIBLE=true
            if ! docker ps &>/dev/null; then
                if sg docker -c "docker ps" &>/dev/null 2>&1; then
                    DOCKER_ACCESSIBLE="sg"
                else
                    DOCKER_ACCESSIBLE=false
                fi
            fi
            
            cleanup_docker_cmd() {
                if [ "$DOCKER_ACCESSIBLE" = "true" ]; then
                    docker "$@"
                elif [ "$DOCKER_ACCESSIBLE" = "sg" ]; then
                    sg docker -c "docker $*"
                else
                    return 1
                fi
            }
            
            # Stop and remove Traefik container
            echo -n "Stopping Traefik container... "
            if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -q -f name=traefik 2>/dev/null | grep -q .; then
                cleanup_docker_cmd stop traefik 2>/dev/null || true
                echo "✓ Stopped"
            else
                echo "Not running or Docker not accessible"
            fi
            
            echo -n "Removing Traefik container... "
            if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -a -q -f name=traefik 2>/dev/null | grep -q .; then
                cleanup_docker_cmd rm traefik 2>/dev/null || true
                echo "✓ Removed"
            else
                echo "Not found or Docker not accessible"
            fi
            
            # Remove Docker network
            # echo -n "Removing Docker network 'proxynet'... "
            # if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd network inspect proxynet >/dev/null 2>&1; then
            #     cleanup_docker_cmd network rm proxynet 2>/dev/null || true
            #     echo "✓ Removed"
            # else
            #     echo "Not found or Docker not accessible"
            # fi
            
            # Remove Traefik image (optional)
            if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd images 2>/dev/null | grep -q traefik; then
                echo ""
                if prompt_yn "Remove Traefik Docker image?" "n"; then
                    echo -n "Removing Traefik images... "
                    IMAGE_IDS=$(cleanup_docker_cmd images | grep traefik | awk '{print $3}')
                    if [ -n "$IMAGE_IDS" ]; then
                        for img_id in $IMAGE_IDS; do
                            cleanup_docker_cmd rmi -f "$img_id" 2>/dev/null || true
                        done
                    fi
                    echo "✓ Removed"
                fi
            fi
            
            # Remove Traefik directories
            echo -n "Removing Traefik directories... "
            if [ -d "/opt/indica/traefik" ]; then
                rm -rf /opt/indica/traefik || exit_on_error "Failed to remove Traefik directory"
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            if [ -d "/opt/indica" ]; then
                if [ -z "$(ls -A /opt/indica 2>/dev/null)" ]; then
                    rm -rf /opt/indica 2>/dev/null || true
                    echo "✓ Removed empty /opt/indica directory"
                fi
            fi
            
            # Stop and remove Keepalived
            echo -n "Stopping Keepalived service... "
            if systemctl is-active --quiet keepalived 2>/dev/null; then
                systemctl stop keepalived 2>/dev/null || true
                echo "✓ Stopped"
            else
                echo "Not running"
            fi
            
            echo -n "Disabling Keepalived service... "
            if systemctl is-enabled --quiet keepalived 2>/dev/null; then
                systemctl disable keepalived 2>/dev/null || true
                echo "✓ Disabled"
            else
                echo "Not enabled"
            fi
            
            # Ask if user wants to uninstall Keepalived package
            if command -v keepalived &> /dev/null; then
                echo ""
                if prompt_yn "Uninstall Keepalived package?" "n"; then
                    echo -n "Uninstalling Keepalived... "
                    if [[ -f /etc/os-release ]]; then
                        source /etc/os-release
                        if command -v apt-get &>/dev/null; then
                            apt-get -y purge keepalived 2>/dev/null || true
                            apt-get -y autoremove 2>/dev/null || true
                        elif command -v dnf &>/dev/null; then
                            dnf -y remove keepalived 2>/dev/null || true
                        fi
                    fi
                    echo "✓ Uninstalled"
                fi
            fi
            
            # Remove Keepalived configuration
            echo -n "Removing Keepalived configuration... "
            if [ -f "/etc/keepalived/keepalived.conf" ]; then
                rm -f /etc/keepalived/keepalived.conf || true
                rm -f /etc/keepalived/keepalived.conf.bak* || true
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            # Remove health check script
            echo -n "Removing health check script... "
            if [ -f "/bin/indica_service_check.sh" ]; then
                rm -f /bin/indica_service_check.sh || true
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            # Remove keepalived_script user and group
            echo -n "Removing keepalived_script user and group... "
            if id "keepalived_script" &>/dev/null; then
                userdel keepalived_script 2>/dev/null || true
            fi
            if getent group keepalived_script > /dev/null 2>&1; then
                groupdel keepalived_script 2>/dev/null || true
            fi
            echo "✓ Removed"
            
            # Remove Docker proxy configuration
            echo -n "Removing Docker proxy configuration... "
            if [ -f "/etc/docker/daemon.json" ]; then
                rm -f /etc/docker/daemon.json || true
                systemctl daemon-reload 2>/dev/null || true
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            # Only remove config file if this is the final cleanup
            # (after backup nodes have been cleaned)
            if [[ "$is_local_final" == "true" ]]; then
                echo -n "Removing configuration file... "
                if [ -f "$CONFIG_FILE" ]; then
                    rm -f "$CONFIG_FILE" || true
                    rm -f "$CONFIG_FILE".bak* || true
                    echo "✓ Removed"
                else
                    echo "Not found"
                fi
            fi
            
            # Ask about Docker
            echo ""
            if command -v docker &> /dev/null; then
                if prompt_yn "Uninstall Docker?" "n"; then
                    echo ""
                    echo "⚠️  WARNING: This will remove Docker and ALL containers/images!"
                    if prompt_yn "Are you absolutely sure?" "n"; then
                        echo -n "Stopping Docker... "
                        systemctl stop docker 2>/dev/null || true
                        systemctl disable docker 2>/dev/null || true
                        echo "✓ Stopped"
                        
                        echo -n "Uninstalling Docker... "
                        if command -v apt-get &>/dev/null; then
                            apt-get -y purge docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
                            apt-get -y autoremove 2>/dev/null || true
                            rm -f /etc/apt/sources.list.d/docker.list
                            rm -f /etc/apt/keyrings/docker.gpg
                        elif command -v dnf &>/dev/null; then
                            dnf -y remove docker-ce docker-ce-cli containerd.io 2>/dev/null || true
                        fi
                        echo "✓ Uninstalled"
                        
                        echo -n "Removing Docker data... "
                        rm -rf /var/lib/docker 2>/dev/null || true
                        rm -rf /var/lib/containerd 2>/dev/null || true
                        rm -rf /etc/docker/daemon.json 2>/dev/null || true
                        echo "✓ Removed"
                        
                        if groups "$CURRENT_USER" | grep -q docker; then
                            echo -n "Removing $CURRENT_USER from docker group... "
                            gpasswd -d "$CURRENT_USER" docker 2>/dev/null || true
                            echo "✓ Removed"
                        fi
                    fi
                fi
            fi
        fi
    }
    
    # ===== EXECUTION ORDER =====
    # 1. Clean backup nodes first (if applicable)
    if [[ "$CLEAN_BACKUP_NODES" == "true" ]]; then
        for i in "${!BACKUP_NODES[@]}"; do
            perform_cleanup true "${BACKUP_NODES[$i]}" "${BACKUP_IPS[$i]}"
        done
        
        # Cleanup remote scripts
        cleanup_remote_scripts_dirs
    fi
    
    # 2. Clean local (master) node LAST (so config file is available until the end)
    perform_cleanup false "local" "" "true"
    
    # ===== FINAL MESSAGE =====
    echo ""
    echo ""
    echo ""
    echo ":: ✓✓✓ CLEANUP COMPLETE ✓✓✓"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    if [[ "$CLEAN_BACKUP_NODES" == "true" ]]; then
        echo "Traefik and Keepalived have been removed from:"
        echo "  - Master node (this system)"
        echo "  - ${#BACKUP_NODES[@]} backup node(s)"
        if [[ "$UNINSTALL_KEEPALIVED_REMOTE" == "true" ]]; then
            echo "  - Keepalived was uninstalled from backup nodes"
        fi
        if [[ "$UNINSTALL_DOCKER_REMOTE" == "true" ]]; then
            echo "  - Docker was uninstalled from backup nodes"
        fi
    else
        echo "Traefik and Keepalived have been removed from this system."
    fi
    echo ""
    echo "Note: You may want to manually check/remove:"
    echo "  - Firewall rules (if any were added manually)"
    echo "  - Any custom modifications to /etc/hosts"
    echo "  - Log files in /var/log/"
    echo "=========================================="
    exit 0
fi

# ==========================================
INITIAL_DEPLOYMENT_TYPE=""

# Function to load existing values from deployment.config
load_config() {
    local _PS_SAVE="$PROXY_STRATEGY"
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"

        # Store initial deployment type before any user input
        INITIAL_DEPLOYMENT_TYPE=$(grep '^DEPLOYMENT_TYPE=' "$CONFIG_FILE" | cut -d'"' -f2)

        # Use temporary env vars to avoid polluting main environment
        TEMP_ENV=$(mktemp)
        cp "$CONFIG_FILE" "$TEMP_ENV"
        sed -i '/^DEPLOYMENT_TYPE=/s/^/export /' "$TEMP_ENV"
        source "$TEMP_ENV"
        rm -f "$TEMP_ENV"

        # Preserve deployment type from config
        if [[ -n "$DEPLOYMENT_TYPE" ]]; then
            log "Loaded deployment type: $DEPLOYMENT_TYPE"
        fi

        source "$CONFIG_FILE"
        # Prevent env file from blanking or overriding runtime proxy strategy
        if [ -z "${PROXY_STRATEGY}" ] && [ -n "${_PS_SAVE}" ]; then
            PROXY_STRATEGY="${_PS_SAVE}"
            log "Preserved proxy strategy from runtime: ${PROXY_STRATEGY}"
        fi

        # Backup existing certificate and key files
        backup_file "$CERT_FILE"
        backup_file "$KEY_FILE"

        # Ensure CERT_FILE and KEY_FILE are not directories
        if [[ -d "$CERT_FILE" ]]; then
          log "Removing directory $CERT_FILE"
          rm -rf "$CERT_FILE" || exit_on_error "Failed to remove directory $CERT_FILE"
        fi
        if [[ -d "$KEY_FILE" ]]; then
          log "Removing directory $KEY_FILE"
          rm -rf "$KEY_FILE" || exit_on_error "Failed to remove directory $KEY_FILE"
        fi

        # Recreate the certificate and key files from the saved content
        # Ensure the directory exists
        CERT_DIR=$(dirname "$CERT_FILE")
        mkdir -p "$CERT_DIR"
        chown -R root:root /opt/indica || exit_on_error "Failed to set ownership on /opt/indica"

        # Guard: remove if incorrectly created as directories
        if [[ -d "$CERT_FILE" ]]; then
            log "Removing incorrectly created directory: $CERT_FILE"
            rm -rf "$CERT_FILE" || exit_on_error "Failed to remove directory $CERT_FILE"
        fi
        if [[ -d "$KEY_FILE" ]]; then
            log "Removing incorrectly created directory: $KEY_FILE"
            rm -rf "$KEY_FILE" || exit_on_error "Failed to remove directory $KEY_FILE"
        fi

        touch "$CERT_FILE"
        touch "$KEY_FILE"
        echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
        echo "$SSL_KEY_CONTENT" > "$KEY_FILE"
    else
        # Config file not found — but if cert content is already in memory
        # (e.g. after backup_existing_deployment moved the config), recreate
        # the cert files on disk so the rest of the install can use them.
        if [[ -n "$CERT_FILE" && -n "$SSL_CERT_CONTENT" && -n "$SSL_KEY_CONTENT" ]]; then
            log "Config file not found but cert content in memory — recreating cert files"
            CERT_DIR=$(dirname "$CERT_FILE")
            mkdir -p "$CERT_DIR"
            chown -R root:root /opt/indica 2>/dev/null || true
            if [[ -d "$CERT_FILE" ]]; then rm -rf "$CERT_FILE"; fi
            if [[ -d "$KEY_FILE" ]];  then rm -rf "$KEY_FILE";  fi
            echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
            echo "$SSL_KEY_CONTENT"  > "$KEY_FILE"
            log "✓ Cert files recreated from in-memory content"
        else
            log "No existing configuration found. Proceeding with new setup."
        fi
    fi
}

# ==========================================
# Backup Existing Deployment
# ==========================================

backup_existing_deployment() {
    local _date _time
    _date=$(date +'%d_%b_%y' | tr '[:lower:]' '[:upper:]')
    _time=$(date +'%H_%M_%S')
    local traefik_root="/opt/indica/traefik"
    local backup_dir="${traefik_root}/backups/${_date}/${_time}/files"

    echo ""
    echo ""
    echo ""
    echo ":: Backing Up Existing Deployment"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !! All current Traefik files will be moved to:           !!"
    printf  "  !!   %-54s!!\n" "${backup_dir}"
    echo "  !! Your deployment will be fully restored after reinstall!!"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""

    # ------ Local backup ------
    echo -n "  Backing up local node... "
    mkdir -p "${backup_dir}"
    chown -R root:root "${traefik_root}" 2>/dev/null || true

    # Move every first-level item except the backups folder itself
    find "${traefik_root}" -maxdepth 1 \
        ! -path "${traefik_root}" \
        ! -path "${traefik_root}/backups" \
        ! -path "${traefik_root}/backups/*" \
        -exec mv {} "${backup_dir}/" \; 2>/dev/null || true

    chown -R root:root "${traefik_root}" 2>/dev/null || true
    echo "✓"

    # ------ Backup nodes ------
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        echo ""
        echo "  Backing up remote nodes..."

        for i in "${!BACKUP_NODES[@]}"; do
            local node="${BACKUP_NODES[$i]}"
            local ip="${BACKUP_IPS[$i]}"

            echo -n "    ${node} (${ip})... "

            local backup_script="${SCRIPTS_DIR}/backup_node_${node}.sh"
            write_local_file "${backup_script}" <<BKPSCRIPT
#!/bin/bash
set -e
TRAEFIK_ROOT="/opt/indica/traefik"
BACKUP_DIR="\${TRAEFIK_ROOT}/backups/${_date}/${_time}/files"
mkdir -p "\${BACKUP_DIR}"
find "\${TRAEFIK_ROOT}" -maxdepth 1 \\
    ! -path "\${TRAEFIK_ROOT}" \\
    ! -path "\${TRAEFIK_ROOT}/backups" \\
    ! -path "\${TRAEFIK_ROOT}/backups/*" \\
    -exec mv {} "\${BACKUP_DIR}/" \\; 2>/dev/null || true
chown -R root:root "${TRAEFIK_ROOT}" 2>/dev/null || true
BKPSCRIPT
            chmod 644 "${backup_script}"
            ensure_SCRIPTS_DIR "${ip}" || true
            copy_to_remote "${backup_script}" "${ip}" "${backup_script}" || true
            local _backup_out
            _backup_out=$(execute_remote_script "${ip}" "${backup_script}" 2>&1) || {
                echo "✗"
                echo "    Error backing up ${node}:"
                echo "$_backup_out" | grep -v "^Connection to\|^Shared connection\|^\s*$" | sed 's/^/    /'
            }
            rm -f "${backup_script}"

            echo "✓"
        done
    fi

    audit_log "REINSTALL" "Full backup → ${backup_dir}"

    echo ""
    echo "  ✓ Backup complete. All files preserved in:"
    echo "    ${backup_dir}"
    echo ""
}

# ==========================================
# Extend Mode — Helper: Restart Traefik everywhere
# ==========================================

_extend_restart_traefik_all_nodes() {
    echo ""
    echo "Restarting Traefik..."

    # Local node
    echo -n "  Local node... "
    (cd /opt/indica/traefik && docker_cmd compose up -d --force-recreate 2>&1) || {
        echo "✗ FAILED"
        echo ""
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !! WARNING — Traefik failed to restart locally            !!"
        echo "  !! Your previous config snapshot can be found in:         !!"
        echo "  !!   ${TRAEFIK_ROOT}/backups/                             !!"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        return 1
    }

    # Health check local with retry
    local _healthy=false
    for _i in $(seq 1 10); do
        if curl -fs http://localhost:8800/ping >/dev/null 2>&1; then
            _healthy=true; break
        fi
        sleep 1
    done

    if [[ "$_healthy" == true ]]; then
        echo "✓ healthy"
    else
        echo "⚠️  started but health check not responding — check: docker logs traefik"
    fi

    # Backup nodes
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        for i in "${!BACKUP_NODES[@]}"; do
            local node="${BACKUP_NODES[$i]}"
            local ip="${BACKUP_IPS[$i]}"
            echo -n "  ${node} (${ip})... "
            local _restart_result
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                _restart_result=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "cd /opt/indica/traefik && docker compose up -d --force-recreate 2>&1" 2>&1) || \
                _restart_result=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "cd /opt/indica/traefik && sg docker -c 'docker compose up -d --force-recreate' 2>&1" 2>&1)
            else
                _restart_result=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "cd /opt/indica/traefik && docker compose up -d --force-recreate 2>&1" 2>&1) || \
                _restart_result=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "cd /opt/indica/traefik && sg docker -c 'docker compose up -d --force-recreate' 2>&1" 2>&1)
            fi
            if [[ $? -eq 0 ]]; then
                # Quick remote health check
                local _remote_healthy=false
                for _i in $(seq 1 5); do
                    local _ping
                    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                        _ping=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "curl -fs http://localhost:8800/ping 2>/dev/null && echo ok" 2>/dev/null)
                    else
                        _ping=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "curl -fs http://localhost:8800/ping 2>/dev/null && echo ok" 2>/dev/null)
                    fi
                    if echo "$_ping" | grep -q ok; then _remote_healthy=true; break; fi
                    sleep 1
                done
                [[ "$_remote_healthy" == true ]] && echo "✓ healthy" || echo "✓ started (health pending)"
            else
                echo "⚠️  restart may have failed on ${node}"
            fi
        done
    fi

    echo "  ✓ Traefik restarted on all nodes"
}

# ==========================================
# Extend Mode — Option 1: Update SSL Certificate
# ==========================================

extend_update_ssl() {
    echo ""
    echo ""
    echo ""
    echo ":: Update SSL Certificate"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    local _cert_file="/opt/indica/traefik/certs/cert.crt"
    local _key_file="/opt/indica/traefik/certs/server.key"

    echo "Paste the new SSL certificate:"
    SSL_CERT_CONTENT=$(prompt_ssl_input "certificate")

    echo "Paste the new SSL private key:"
    SSL_KEY_CONTENT=$(prompt_ssl_input "key")

    echo "$SSL_CERT_CONTENT" > "${_cert_file}"
    echo "$SSL_KEY_CONTENT" > "${_key_file}"
    chmod 644 "${_cert_file}"
    chmod 600 "${_key_file}"

    check_key_cert_match "${_cert_file}" "${_key_file}"
    echo "✓ Certificate and key written locally"

    # Push to backup nodes
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        echo ""
        echo "Pushing certificates to backup nodes..."
        for i in "${!BACKUP_NODES[@]}"; do
            local node="${BACKUP_NODES[$i]}"
            local ip="${BACKUP_IPS[$i]}"
            echo -n "  ${node} (${ip})... "
            ensure_SCRIPTS_DIR "${ip}" || true
            copy_to_remote_root "${_cert_file}" "${ip}" "/opt/indica/traefik/certs/cert.crt"
            copy_to_remote_root "${_key_file}" "${ip}" "/opt/indica/traefik/certs/server.key"
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "chmod 644 /opt/indica/traefik/certs/cert.crt && chmod 600 /opt/indica/traefik/certs/server.key" 2>/dev/null || true
            else
                ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "chmod 644 /opt/indica/traefik/certs/cert.crt && chmod 600 /opt/indica/traefik/certs/server.key" 2>/dev/null || true
            fi
            echo "✓"
        done
    fi

    # Update CERT_FILE/KEY_FILE so save_config reads the right paths
    CERT_FILE="${_cert_file}"
    KEY_FILE="${_key_file}"

    _extend_restart_traefik_all_nodes
    echo -n "  Saving configuration... "
    snapshot_config "SSL_UPDATE" "SSL certificate updated"
    save_config
    echo "✓"
    echo "✓ SSL certificate updated"
}

# ==========================================
# Extend Mode — Option 2: Update CA Certificate
# ==========================================

extend_update_ca() {
    echo ""
    echo ""
    echo ""
    echo ":: Update CA Certificate"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    local _ca_file="/opt/indica/traefik/certs/customca.crt"

    # Force re-prompt by clearing existing CA state
    USE_CUSTOM_CA="no"
    CUSTOM_CA_CERT_CONTENT=""

    prompt_custom_ca

    if [[ "$USE_CUSTOM_CA" == "yes" && -n "$CUSTOM_CA_CERT_CONTENT" ]]; then
        echo "$CUSTOM_CA_CERT_CONTENT" > "${_ca_file}"
        chmod 644 "${_ca_file}"
        echo "✓ CA certificate written locally"

        # Add volume mount to docker-compose.yaml if not already present
        local _compose="/opt/indica/traefik/docker-compose.yaml"
        if [[ -f "$_compose" ]] && ! grep -q "customca.crt" "$_compose"; then
            sed -i '/      - \.\/certs\/server\.key:\/certs\/server\.key:ro/a\      - ./certs/customca.crt:/certs/customca.crt:ro' "$_compose"
            echo "✓ Custom CA volume mount added to docker-compose.yaml"
        fi

        # Add serversTransport to clinical_conf.yml if not already present
        local _clinical_conf="/opt/indica/traefik/config/dynamic/clinical_conf.yml"
        if [[ -f "$_clinical_conf" ]]; then
            if ! grep -q "serversTransports" "$_clinical_conf"; then
                # Append serversTransports block
                cat >> "$_clinical_conf" <<'CACONF'

  serversTransports:
    internalCA:
      rootcas:
        - /certs/customca.crt
CACONF
                echo "✓ serversTransports block added to clinical_conf.yml"
            fi
            if ! grep -q "serversTransport: internalCA" "$_clinical_conf"; then
                # Add serversTransport reference to each loadBalancer
                sed -i '/        healthCheck:/i\        serversTransport: internalCA' "$_clinical_conf"
                echo "✓ serversTransport reference added to load balancers"
            fi
        fi

        # Push to backup nodes
        if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
            echo ""
            echo "Pushing CA certificate to backup nodes..."
            for i in "${!BACKUP_NODES[@]}"; do
                local node="${BACKUP_NODES[$i]}"
                local ip="${BACKUP_IPS[$i]}"
                echo -n "  ${node} (${ip})... "
                ensure_SCRIPTS_DIR "${ip}" || true
                copy_to_remote_root "${_ca_file}" "${ip}" "/opt/indica/traefik/certs/customca.crt"
                if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                    sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "chmod 644 /opt/indica/traefik/certs/customca.crt" 2>/dev/null || true
                else
                    ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "chmod 644 /opt/indica/traefik/certs/customca.crt" 2>/dev/null || true
                fi
                # Also update docker-compose.yaml on backup node if mount not present
                if [[ -f "$_compose" ]]; then
                    local _remote_has_mount
                    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                        _remote_has_mount=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "grep -q customca.crt /opt/indica/traefik/docker-compose.yaml 2>/dev/null && echo yes || echo no" 2>/dev/null)
                    else
                        _remote_has_mount=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "grep -q customca.crt /opt/indica/traefik/docker-compose.yaml 2>/dev/null && echo yes || echo no" 2>/dev/null)
                    fi
                    if [[ "$_remote_has_mount" != "yes" ]]; then
                        copy_to_remote_root "$_compose" "$ip" "/opt/indica/traefik/docker-compose.yaml"
                    fi
                fi
                # Push updated clinical_conf.yml if serversTransport was added
                if [[ -f "$_clinical_conf" ]] && grep -q "serversTransports" "$_clinical_conf"; then
                    copy_to_remote_root "$_clinical_conf" "$ip" "/opt/indica/traefik/config/dynamic/clinical_conf.yml"
                fi
                echo "✓"
            done
        fi

        _extend_restart_traefik_all_nodes
        echo -n "  Saving configuration... "
        CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
        snapshot_config "CA_UPDATE" "CA certificate updated"
        KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
        save_config
        echo "✓"
        echo "✓ CA certificate updated"
    else
        echo "No CA certificate configured — skipping."
    fi
}

# ==========================================
# Extend Mode — Option 3: Add Additional Traefik Nodes
# ==========================================

extend_add_nodes() {
    echo ""
    echo ""
    echo ""
    echo ":: Add Additional Traefik Nodes"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    if [[ "$MULTI_NODE_DEPLOYMENT" != "yes" ]]; then
        echo "Current deployment is single-node. This will configure additional HA backup nodes."
        echo ""
        MULTI_NODE_DEPLOYMENT="yes"
        MASTER_HOSTNAME="${MASTER_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
        MASTER_IP="${MASTER_IP:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')}"
        BACKUP_NODES=()
        BACKUP_IPS=()
        BACKUP_INTERFACES=()
    fi

    echo "Existing nodes:"
    echo "  Master : ${MASTER_HOSTNAME} (${MASTER_IP}) — Priority 110"
    for i in "${!BACKUP_NODES[@]}"; do
        local p=$((100 - (i * 10)))
        echo "  Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]}) — Priority ${p}"
    done
    echo ""

    # How many new nodes?
    local new_count
    while true; do
        read -p "How many new backup nodes to add? [1]: " new_count
        new_count=${new_count:-1}
        if [[ "$new_count" =~ ^[1-9][0-9]*$ ]]; then break; fi
        echo "  Please enter a positive integer."
    done

    # Collect details for each new node
    local start_idx=${#BACKUP_NODES[@]}
    local -A _ip_seen=()
    # Seed with existing IPs to prevent duplicates
    _ip_seen["$MASTER_IP"]=1
    for ip in "${BACKUP_IPS[@]}"; do _ip_seen["$ip"]=1; done

    for ((n=1; n<=new_count; n++)); do
        local new_idx=$(( start_idx + n - 1 ))
        local priority=$(( 100 - (new_idx * 10) ))

        echo ""
        echo "New Backup Node #$((new_idx + 1)) (Priority ${priority}):"

        local new_hostname=""
        while [[ -z "$new_hostname" ]]; do
            read -p "  Hostname: " new_hostname
            if [[ -z "$new_hostname" ]]; then echo "  ERROR: Hostname cannot be empty."; fi
        done

        local new_ip=""
        while true; do
            read -p "  IP address: " new_ip
            if ! validate_ip "$new_ip"; then
                echo "  ERROR: Invalid IP address format."
                continue
            fi
            if [[ -n "${_ip_seen[$new_ip]+x}" ]]; then
                echo "  ERROR: IP ${new_ip} is already in use by another node."
                continue
            fi
            _ip_seen["$new_ip"]=1
            break
        done

        BACKUP_NODES+=("$new_hostname")
        BACKUP_IPS+=("$new_ip")
        BACKUP_INTERFACES+=("")
        echo "  ✓ Node added"
    done

    echo ""
    echo "Updated node list:"
    echo "  Master : ${MASTER_HOSTNAME} (${MASTER_IP}) — Priority 110"
    for i in "${!BACKUP_NODES[@]}"; do
        local p=$(( 100 - (i * 10) ))
        echo "  Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]}) — Priority ${p}"
    done
    echo ""

    # Update BACKUP_NODE_COUNT for save_config
    BACKUP_NODE_COUNT=${#BACKUP_NODES[@]}

    # ----------------------------------------
    # Offer to deploy the new nodes immediately
    # ----------------------------------------
    echo ""
    echo ""
    echo ""
    echo ":: Deploy New Nodes"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "New node(s) registered. You can deploy them now or"
    echo "save the config and deploy on the next Reinstall run."
    echo ""

    if ! prompt_yn "Deploy new nodes now?" "y"; then
        echo ""
        echo "  New node(s) saved. Run this script again and choose"
        echo "  Reinstall to deploy them."
        return 0
    fi

    # ---- SSH key setup for new nodes ----
    echo ""
    echo "Setting up SSH keys for new node(s)..."

    if [ ! -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]; then
        echo "  No SSH key found — generating one..."
        mkdir -p "$ACTUAL_HOME/.ssh"
        chmod 700 "$ACTUAL_HOME/.ssh"
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown -R "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/.ssh"
            sudo -u "$SUDO_USER" ssh-keygen -t rsa -b 4096 -N "" -f "$ACTUAL_HOME/.ssh/id_rsa"
        else
            ssh-keygen -t rsa -b 4096 -N "" -f "$ACTUAL_HOME/.ssh/id_rsa"
        fi
        chmod 600 "$ACTUAL_HOME/.ssh/id_rsa"
        chmod 644 "$ACTUAL_HOME/.ssh/id_rsa.pub"
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/.ssh/id_rsa" "$ACTUAL_HOME/.ssh/id_rsa.pub"
        fi
    fi

    SSH_OPTS="${SSH_OPTS:--i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no}"

    # Sudo password — may already be set by the extend-mode dispatcher
    if [ -z "${SUDO_PASS:-}" ]; then
        echo ""
        read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
        echo ""
        export SUDO_PASS
    fi

    echo ""
    echo "Copying SSH keys and verifying access..."

    # Ensure SSH key pair exists
    if [[ ! -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]]; then
        echo "  No SSH key found — generating one..."
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" ssh-keygen -t rsa -b 4096 -N "" \
                -f "$ACTUAL_HOME/.ssh/id_rsa" -q 2>/dev/null || true
        else
            ssh-keygen -t rsa -b 4096 -N "" -f "$ACTUAL_HOME/.ssh/id_rsa" -q 2>/dev/null || true
        fi
        if [[ ! -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]]; then
            echo "  ❌ Failed to generate SSH key. Please generate one manually:"
            echo "     ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa"
            return 1
        fi
        echo "  ✓ SSH key generated"
    fi

    local _ssh_ok=true
    for i in "${!BACKUP_NODES[@]}"; do
        [ "$i" -lt "$start_idx" ] && continue
        local _n="${BACKUP_NODES[$i]}"
        local _ip="${BACKUP_IPS[$i]}"
        echo "  ${_n} (${_ip}) — copying SSH key..."

        local _copy_ok=false
        local _copy_err=""

        # Try with sshpass if available (non-interactive password passing)
        if command -v sshpass &>/dev/null && [[ -n "$SUDO_PASS" ]]; then
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                _copy_err=$(sudo -u "$SUDO_USER" sshpass -p "$SUDO_PASS" \
                    ssh-copy-id -o StrictHostKeyChecking=accept-new \
                    -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                    -o "User=$CURRENT_USER" "$_ip" 2>&1) && _copy_ok=true
            else
                _copy_err=$(sshpass -p "$SUDO_PASS" \
                    ssh-copy-id -o StrictHostKeyChecking=accept-new \
                    -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                    -o "User=$CURRENT_USER" "$_ip" 2>&1) && _copy_ok=true
            fi
        else
            # Fall back to interactive ssh-copy-id
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                _copy_err=$(sudo -u "$SUDO_USER" ssh-copy-id \
                    -o StrictHostKeyChecking=accept-new \
                    -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                    -o "User=$CURRENT_USER" "$_ip" 2>&1) && _copy_ok=true
            else
                _copy_err=$(ssh-copy-id -o StrictHostKeyChecking=accept-new \
                    -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                    -o "User=$CURRENT_USER" "$_ip" 2>&1) && _copy_ok=true
            fi
        fi

        if [[ "$_copy_ok" == true ]]; then
            echo "✓"
        else
            echo "⚠️  (may need manual key copy)"
            if [[ -n "$_copy_err" ]]; then
                echo "    Reason: $(echo "$_copy_err" | grep -v "^$" | tail -2 | sed 's/^/    /')"
            fi
            echo "    To fix manually: ssh-copy-id -i ~/.ssh/id_rsa.pub ${CURRENT_USER}@${_ip}"
        fi

        echo -n "  ${_n} — verify SSH... "
        local _test
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            _test=$(sudo -u "$SUDO_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 \
                $SSH_OPTS -l "$CURRENT_USER" "$_ip" "echo SSH_TEST_OK" 2>/dev/null)
        else
            _test=$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
                $SSH_OPTS -l "$CURRENT_USER" "$_ip" "echo SSH_TEST_OK" 2>/dev/null)
        fi
        if echo "$_test" | grep -q "SSH_TEST_OK"; then
            echo "✓"
        else
            echo "❌ FAILED"
            _ssh_ok=false
        fi
    done

    if [ "$_ssh_ok" = false ]; then
        echo ""
        echo "⚠️  SSH verification failed for one or more nodes."
        echo "   New node(s) saved to config. Fix SSH access then:"
        echo "   run the script again and choose Reinstall."
        return 0
    fi

    # ---- Interface configuration for new nodes ----
    echo ""
    echo "Configuring network interfaces for new node(s)..."
    echo ""

    for i in "${!BACKUP_NODES[@]}"; do
        [ "$i" -lt "$start_idx" ] && continue
        local _n="${BACKUP_NODES[$i]}"
        local _ip="${BACKUP_IPS[$i]}"

        echo "  ${_n} (${_ip}):"

        local _detected_iface
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            _detected_iface=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                "ip -o addr show | grep 'inet $_ip' | awk '{print \$2}' | head -1" 2>/dev/null)
        else
            _detected_iface=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                "ip -o addr show | grep 'inet $_ip' | awk '{print \$2}' | head -1" 2>/dev/null)
        fi

        if [ -n "$_detected_iface" ]; then
            echo "    ✓ Detected interface: ${_detected_iface}"
            echo ""
            while true; do
                read -p "    Use '${_detected_iface}'? (y/n/other) [Y/n]: " _use
                _use="${_use:-y}"
                case "${_use,,}" in
                    y)
                        BACKUP_INTERFACES[$i]="$_detected_iface"
                        echo "    ✓ Interface set to: ${_detected_iface}"
                        break
                        ;;
                    n|other)
                        read -p "    Enter interface name: " _manual
                        BACKUP_INTERFACES[$i]="$_manual"
                        echo "    ✓ Interface set to: ${_manual} (unverified)"
                        break
                        ;;
                    *) echo "    Please enter y, n, or other." ;;
                esac
            done
        else
            echo "    ⚠️  Auto-detection failed."
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                echo ""
                echo "    Available interfaces on ${_n}:"
                sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                    "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo" 2>/dev/null || true
            else
                echo ""
                echo "    Available interfaces on ${_n}:"
                ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                    "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo" 2>/dev/null || true
            fi
            echo ""
            local _manual=""
            while [ -z "$_manual" ]; do
                read -p "    Enter interface name for ${_n}: " _manual
                [ -z "$_manual" ] && echo "    ERROR: Interface cannot be empty."
            done
            BACKUP_INTERFACES[$i]="$_manual"
            echo "    ✓ Interface set to: ${_manual} (unverified)"
        fi
        echo ""
    done

    # ---- Run repository connectivity check on new nodes ----
    echo ""
    echo "Checking repository connectivity on new node(s)..."
    for i in "${!BACKUP_NODES[@]}"; do
        [ "$i" -lt "$start_idx" ] && continue
        local _n="${BACKUP_NODES[$i]}"
        local _ip="${BACKUP_IPS[$i]}"
        echo ""
        echo "${_n} (${_ip}):"
        echo "----------"

        # Install minimal prerequisites before running connectivity checks
        # curl/wget/ca-certificates may not be present on a fresh node
        echo "  Installing prerequisites for connectivity checks..."
        local _prereq_script="$SCRIPTS_DIR/prereq_check_${_n}.sh"
        write_local_file "$_prereq_script" <<'PREREQSCRIPT'
#!/bin/bash
set -e
if command -v apt-get >/dev/null 2>&1; then
    missing=""
    for p in curl wget ca-certificates; do
        dpkg -l "$p" 2>/dev/null | grep -q "^ii" || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        echo "  Installing:$missing"
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq $missing
    fi
elif command -v dnf >/dev/null 2>&1; then
    missing=""
    for p in curl wget ca-certificates; do
        rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        echo "  Installing:$missing"
        dnf install -y --setopt=skip_if_unavailable=True $missing
    fi
fi
echo "  Prerequisites ready"
PREREQSCRIPT
        chmod 644 "$_prereq_script"
        ensure_SCRIPTS_DIR "$_ip" || true
        copy_to_remote "$_prereq_script" "$_ip" "$_prereq_script" || true
        execute_remote_script "$_ip" "$_prereq_script" || true
        rm -f "$_prereq_script"

        check_single_node "remote" "$_n" "$_ip"
    done

    # ---- Keepalived configuration (required for HA) ----
    # Prompt for missing vars — this happens when converting single→multi node.
    # For an already-multi deployment these will be loaded from config.

    local _kv_needs_master_install=false

    if [[ -z "$VIRTUAL_IP" ]]; then
        _kv_needs_master_install=true
        echo ""
        echo ""
        echo ""
        echo ":: Keepalived — Virtual IP Configuration"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""
        echo "  Keepalived requires a Virtual IP (VIP) that floats between"
        echo "  nodes. This must be an unused IP on the same subnet as your"
        echo "  node IPs."
        echo ""
        while true; do
            read -p "  Virtual IP address: " VIRTUAL_IP
            if validate_ip "$VIRTUAL_IP"; then break; fi
            echo "  ERROR: Invalid IPv4 address."
        done
    fi

    if [[ -z "$VRID" ]]; then
        echo ""
        read -p "  Virtual Router ID [1-255, Enter to auto-generate]: " VRID
        if [[ -z "$VRID" ]]; then
            VRID=$(echo "$VIRTUAL_IP" | cksum | awk '{print $1 % 255 + 1}')
            echo "  Auto-generated VRID: ${VRID}"
        elif ! [[ "$VRID" =~ ^[0-9]+$ ]] || (( VRID < 1 || VRID > 255 )); then
            echo "  Invalid VRID — auto-generating."
            VRID=$(echo "$VIRTUAL_IP" | cksum | awk '{print $1 % 255 + 1}')
        fi
    fi

    if [[ -z "$AUTH_PASS" ]]; then
        AUTH_PASS=$(openssl rand -base64 6 | tr -dc 'A-Za-z0-9' | cut -c1-8)
        echo "  Generated Keepalived auth password: ${AUTH_PASS}"
    fi

    if [[ -z "$VRRP" ]]; then
        local _rl _rn
        _rl=$(head /dev/urandom | tr -dc 'A-Z' | fold -w 2 | head -n 1)
        _rn=$(head /dev/urandom | tr -dc '0-9' | fold -w 2 | head -n 1)
        VRRP="VI_01_${_rl}${_rn}"
        echo "  Generated VRRP instance name: ${VRRP}"
    fi

    if [[ -z "$NETWORK_INTERFACE" ]]; then
        echo ""
        echo "  Detecting master node network interface..."
        local _auto_iface
        _auto_iface=$(ip -o addr show | grep "inet ${MASTER_IP}" | awk '{print $2}' | head -1)
        if [[ -n "$_auto_iface" ]]; then
            echo "  Detected: ${_auto_iface}"
            while true; do
                read -p "  Use '${_auto_iface}' for the master VIP? (y/n) [Y/n]: " _use
                _use="${_use:-y}"
                case "${_use,,}" in
                    y) NETWORK_INTERFACE="$_auto_iface"; break ;;
                    n)
                        echo "  Available interfaces:"
                        ip -o link show | awk '{print "    - " $2}' | sed 's/:$//' | grep -v lo
                        echo ""
                        read -p "  Enter interface name: " NETWORK_INTERFACE
                        break
                        ;;
                    *) echo "  Please enter y or n." ;;
                esac
            done
        else
            echo "  Auto-detection failed. Available interfaces:"
            ip -o link show | awk '{print "    - " $2}' | sed 's/:$//' | grep -v lo
            echo ""
            while [[ -z "$NETWORK_INTERFACE" ]]; do
                read -p "  Enter master interface name for VIP: " NETWORK_INTERFACE
            done
        fi
        echo "  ✓ Master interface: ${NETWORK_INTERFACE}"
    fi

    # ---- Install Keepalived on master if this is a single→multi conversion ----
    if [[ "$_kv_needs_master_install" == "true" ]]; then
        echo ""
        echo ""
        echo ""
        echo ":: Installing Keepalived on Master Node"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""

        if command -v apt-get &>/dev/null; then
            sudo -E apt-get ${APT_PROXY_OPT_PROXY:-} install -y keepalived \
                || exit_on_error "Failed to install Keepalived on master"
        elif command -v dnf &>/dev/null; then
            sudo -E dnf ${DNF_PROXY_OPT:-} ${DNF_SSL_OPT:-} \
                --setopt=skip_if_unavailable=True install -y keepalived \
                || sudo -E dnf ${DNF_PROXY_OPT:-} ${DNF_SSL_OPT:-} \
                    --setopt=skip_if_unavailable=True install -y keepalived --nobest \
                || exit_on_error "Failed to install Keepalived on master"
        fi

        # Create keepalived_script user/group if missing
        if ! getent group keepalived_script > /dev/null 2>&1; then
            groupadd -r keepalived_script
        fi
        if ! id "keepalived_script" &>/dev/null; then
            useradd -r -s /sbin/nologin -G keepalived_script -g docker -M keepalived_script
        fi

        # Write health check script
        tee /bin/indica_service_check.sh > /dev/null <<'HEALTHCHECK'
#!/bin/bash
if curl -fs http://localhost:8800/ping > /dev/null; then
  exit 0
else
  exit 1
fi
HEALTHCHECK
        chmod +x /bin/indica_service_check.sh
        chown keepalived_script:docker /bin/indica_service_check.sh

        local KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"

        tee $KEEPALIVED_CONF > /dev/null <<EOF
global_defs {
  enable_script_security
  script_user keepalived_script
  max_auto_priority
}
vrrp_script check_traefik {
  script "/bin/indica_service_check.sh"
  interval 2
  weight 50
}
vrrp_instance ${VRRP} {
  state MASTER
  interface ${NETWORK_INTERFACE}
  virtual_router_id ${VRID}
  priority 110
  virtual_ipaddress {
    ${VIRTUAL_IP}
  }
  track_script {
    check_traefik
  }
  authentication {
    auth_type PASS
    auth_pass ${AUTH_PASS}
  }
}
EOF
        chmod 640 "$KEEPALIVED_CONF"

        systemctl enable keepalived
        systemctl start keepalived

        sleep 2
        if systemctl is-active --quiet keepalived; then
            echo "  ✓ Keepalived running on master (MASTER, priority 110)"
            echo "  ✓ Virtual IP: ${VIRTUAL_IP}"
        else
            echo "  ⚠️  Keepalived may not have started — check: sudo systemctl status keepalived"
        fi
    fi

    # ---- Deploy ----
    echo ""
    echo "Starting deployment to new node(s)..."

    # Ensure path vars are set (they are in main flow; may not be in extend mode)
    TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/opt/indica/traefik/config/dynamic}"
    DISABLE_DOCKER_REPO="${DISABLE_DOCKER_REPO:-no}"

    # Save config so the deployment config file on the remote is up-to-date
    snapshot_config "NODE_ADD" "Backup node(s) added"
    CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
    KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
    save_config

    deploy_to_backup_nodes "$start_idx"
}

# ==========================================
# Extend Mode — Option 4: Add/Edit Component Servers/Services
# ==========================================

# Internal helper — print a numbered flat list of all current service URLs.
# Populates caller-scoped arrays _ec_svc_idx and _ec_url_idx (parallel to
# _ec_flat_svcs / _ec_flat_urls) so the caller can look up which service
# and URL a chosen number corresponds to.
#
# Args: $1 = name-ref to _svc_names array
#       $2 = name-ref to _svc_vars array
#       $3 = output name-ref for _ec_flat_svcs  (service name per entry)
#       $4 = output name-ref for _ec_flat_urls   (url per entry)
#
# Because bash 3 doesn't support namerefs we use a simpler approach:
# the function writes into globals _ec_flat_svcs / _ec_flat_urls directly.
_ec_build_flat_list() {
    local -n _bfl_names="$1"
    local -n _bfl_vars="$2"
    _ec_flat_svcs=()
    _ec_flat_urls=()

    local _n=1
    for i in "${!_bfl_names[@]}"; do
        local _svc="${_bfl_names[$i]}"
        local _var="${_bfl_vars[$i]}"
        local _urls_raw="${!_var}"
        if [[ -z "$_urls_raw" ]]; then continue; fi

        IFS=',' read -ra _url_arr <<< "$_urls_raw"
        for _u in "${_url_arr[@]}"; do
            if [[ -z "$_u" ]]; then continue; fi
            _ec_flat_svcs+=("$_svc")
            _ec_flat_urls+=("$_u")
            printf "  [%2d]  %-24s  %s\n" "$_n" "${_svc}:" "$_u"
            (( _n++ ))
        done
    done
    return 0
}

# Remove a URL from a comma-separated string. Prints the updated string.
_ec_remove_url() {
    local _haystack="$1"
    local _needle="$2"
    echo "$_haystack" | tr ',' '\n' | grep -vxF "$_needle" | paste -sd ',' -
}

# Replace a URL in a comma-separated string. Prints the updated string.
_ec_replace_url() {
    local _haystack="$1"
    local _old="$2"
    local _new="$3"
    echo "$_haystack" | tr ',' '\n' | awk -v old="$_old" -v new="$_new" \
        '$0 == old { print new; next } { print }' | paste -sd ',' -
}

# ---- Main function ----

extend_edit_components() {
    local _dynamic_dir="/opt/indica/traefik/config/dynamic"

    # Service metadata — ordered parallel arrays
    local -a _svc_names _svc_vars _svc_ports _svc_labels

    if [[ "$DEPLOYMENT_TYPE" == "image-site" ]]; then
        _svc_names=("image-service")
        _svc_vars=("IMAGE_SERVICE_URLS")
        _svc_ports=("8050")
        _svc_labels=("Image Service")
    else
        _svc_names=("app-service" "idp-service" "api-service" "filemonitor-service" "image-service")
        _svc_vars=("APP_SERVICE_URLS" "IDP_SERVICE_URLS" "API_SERVICE_URLS" "FILEMONITOR_SERVICE_URLS" "IMAGE_SERVICE_URLS")
        _svc_ports=("3000" "5002" "4040" "4444" "8050")
        _svc_labels=("App Service" "Identity Provider (iDP)" "API Service" "File Monitor" "Image Service")
    fi

    # Pending changes log
    local -a _ec_pending_log=()

    # ---- Helper: check if a hostname already exists in any service ----
    # Returns 0 (true) if found, 1 if not found
    _ec_host_exists() {
        local _check_host="$1"
        for _v in "${_svc_vars[@]}"; do
            local _raw="${!_v}"
            if [[ -z "$_raw" ]]; then continue; fi
            IFS=',' read -ra _es <<< "$_raw"
            for _e in "${_es[@]}"; do
                local _eh
                _eh=$(echo "$_e" | sed -E 's#^https?://##; s#:[0-9]+$##')
                if [[ "$_eh" == "$_check_host" ]]; then return 0; fi
            done
        done
        return 1
    }

    # ---- Helper: count total URL entries across all services ----
    # NOTE: all [[ ]] && ... patterns replaced with if blocks — bare [[ ]] && x
    # returns exit code 1 when the condition is false, which trips set -e inside
    # the $() subshell used to capture the return value.
    _ec_total_entries() {
        local _t=0
        for _v in "${_svc_vars[@]}"; do
            local _raw="${!_v}"
            if [[ -z "$_raw" ]]; then continue; fi
            IFS=',' read -ra _es <<< "$_raw"
            for _e in "${_es[@]}"; do
                if [[ -n "$_e" ]]; then _t=$(( _t + 1 )); fi
            done
        done
        echo "$_t"
        return 0
    }

    # ---- Helper: count entries in one service var ----
    _ec_count_in_var() {
        local _v="$1"
        local _raw="${!_v}"
        local _c=0
        if [[ -z "$_raw" ]]; then
            echo 0
            return 0
        fi
        IFS=',' read -ra _es <<< "$_raw"
        for _e in "${_es[@]}"; do
            if [[ -n "$_e" ]]; then _c=$(( _c + 1 )); fi
        done
        echo "$_c"
        return 0
    }

    # ---- Helper: show current server table ----
    _ec_show_current() {
        local _found=false
        for i in "${!_svc_names[@]}"; do
            local _v="${_svc_vars[$i]}"
            local _raw="${!_v}"
            if [[ -n "$_raw" ]]; then
                _found=true
                echo "  ${_svc_labels[$i]} (${_svc_names[$i]}):"
                IFS=',' read -ra _u_arr <<< "$_raw"
                for _u in "${_u_arr[@]}"; do
                    if [[ -n "$_u" ]]; then
                        printf "    - %s\n" "$_u"
                    fi
                done
            else
                echo "  ${_svc_labels[$i]} (${_svc_names[$i]}): (none configured)"
            fi
            echo ""
        done
        if [[ "$_found" == false ]]; then
            echo "  (no upstream servers configured)"
        fi
        return 0
    }

    # ---- Helper: build deduplicated list of server hostnames across all services ----
    # Writes to globals _ec_server_hosts (unique hostnames) and
    # _ec_server_svcs (pipe-separated service names per host)
    _ec_build_server_list() {
        _ec_server_hosts=()
        _ec_server_svcs=()
        local -A _seen=()

        for i in "${!_svc_names[@]}"; do
            local _v="${_svc_vars[$i]}"
            local _raw="${!_v}"
            if [[ -z "$_raw" ]]; then continue; fi
            IFS=',' read -ra _urls <<< "$_raw"
            for _u in "${_urls[@]}"; do
                if [[ -z "$_u" ]]; then continue; fi
                # Extract hostname (strip scheme and port)
                local _host
                _host=$(echo "$_u" | sed -E 's#^https?://##; s#:[0-9]+$##')
                if [[ -z "${_seen[$_host]+x}" ]]; then
                    _seen[$_host]=1
                    _ec_server_hosts+=("$_host")
                    _ec_server_svcs+=("${_svc_names[$i]}")
                else
                    # Append service to existing entry
                    local _idx=0
                    for _h in "${_ec_server_hosts[@]}"; do
                        if [[ "$_h" == "$_host" ]]; then
                            _ec_server_svcs[$_idx]="${_ec_server_svcs[$_idx]}|${_svc_names[$i]}"
                            break
                        fi
                        _idx=$(( _idx + 1 ))
                    done
                fi
            done
        done

        # Print numbered list
        local _n=1
        for _h in "${_ec_server_hosts[@]}"; do
            local _svcs="${_ec_server_svcs[$(( _n - 1 ))]}"
            local _svc_display
            _svc_display=$(echo "$_svcs" | tr '|' ', ')
            printf "  [%d]  %-36s  services: %s\n" "$_n" "$_h" "$_svc_display"
            _n=$(( _n + 1 ))
        done
        return 0
    }

    # =====================================================================
    # Main loop — keeps showing the menu until the user chooses "Done"
    # =====================================================================
    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Edit Component Servers/Services"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""

        # Pending changes block
        if [[ ${#_ec_pending_log[@]} -gt 0 ]]; then
            echo ""
            echo "  ┌─ Pending changes (not yet applied) ─────────────────────────"
            for _pl in "${_ec_pending_log[@]}"; do
                echo "  │  ${_pl}"
            done
            echo "  └──────────────────────────────────────────────────────────────"
        fi

        echo ""
        echo "Current servers:"
        echo ""

        # Summary of unique component server hostnames
        echo "  Existing component servers:"
        echo ""
        local -A _cs_seen=()
        for _csv in "${_svc_vars[@]}"; do
            local _csraw="${!_csv}"
            if [[ -z "$_csraw" ]]; then continue; fi
            IFS=',' read -ra _csurls <<< "$_csraw"
            for _csu in "${_csurls[@]}"; do
                if [[ -z "$_csu" ]]; then continue; fi
                local _csh
                _csh=$(echo "$_csu" | sed -E 's#^https?://##; s#:[0-9]+$##')
                if [[ -z "${_cs_seen[$_csh]+x}" ]]; then
                    _cs_seen[$_csh]=1
                    printf "    - %s\n" "$_csh"
                fi
            done
        done
        echo ""

        local _total
        _total=$(_ec_total_entries)

        echo "  ----------------------------------------"
        echo "  [1] Add a new component server"
        if (( _total > 0 )); then
            echo "  [2] Edit an existing component server"
        else
            echo "  [2] Edit an existing component server  (n/a — no servers configured)"
        fi
        echo "  ─────────────────────────────────────────────────────"
        if [[ ${#_ec_pending_log[@]} -gt 0 ]]; then
            echo "  [3] Apply changes & restart Traefik"
        else
            echo "  [3] Apply changes & restart Traefik  (n/a — no pending changes)"
        fi
        echo "  [4] Cancel — return to Extend menu"
        echo ""

        local _sub
        while true; do
            read -p "Enter choice [1-4]: " _sub
            case "$_sub" in
                1|4) break ;;
                2)
                    if (( _total > 0 )); then break
                    else echo "  No servers configured yet."; fi
                    ;;
                3)
                    if [[ ${#_ec_pending_log[@]} -gt 0 ]]; then break
                    else echo "  No pending changes to apply."; fi
                    ;;
                *) echo "  Please enter 1–4." ;;
            esac
        done

        # ==================================================================
        # [1] Add
        # ==================================================================
        if [[ "$_sub" == "1" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Add a NEW component server"
            echo "  ----------------------------------------"
            echo ""

            if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
                echo "  Which services would you like this new component server to apply to?"
                echo "  (Enter a number, or comma-separated for multiple e.g. 1,3 or A to apply to all)"
                echo ""
                for i in "${!_svc_names[@]}"; do
                    local _v="${_svc_vars[$i]}"
                    local _cnt
                    _cnt=$(_ec_count_in_var "$_v")
                    printf "  [%d] %-28s — %d server(s)\n" \
                        "$((i+1))" "${_svc_labels[$i]} (${_svc_names[$i]})" "$_cnt"
                done
                echo "  ─────────────────────────────────────────────────────"
                echo "  [A] All services — add a new upstream node (same host, default ports)"
                echo "  [0] Cancel"
                echo ""

                local _svc_pick
                while true; do
                    read -p "Enter choice: " _svc_pick
                    _svc_pick="${_svc_pick^^}"
                    if [[ "$_svc_pick" == "0" ]]; then break
                    elif [[ "$_svc_pick" == "A" ]]; then break
                    elif [[ "$_svc_pick" == *","* ]]; then
                        # Validate comma-separated entries
                        local _valid=true
                        IFS=',' read -ra _mpicks <<< "$_svc_pick"
                        for _mp in "${_mpicks[@]}"; do
                            _mp="${_mp// /}"
                            if ! [[ "$_mp" =~ ^[0-9]+$ ]] || (( _mp < 1 || _mp > ${#_svc_names[@]} )); then
                                echo "  Invalid: '${_mp}'. Enter numbers 1–${#_svc_names[@]}."
                                _valid=false; break
                            fi
                        done
                        if [[ "$_valid" == true ]]; then break; fi
                    elif [[ "$_svc_pick" =~ ^[0-9]+$ ]] && \
                         (( _svc_pick >= 1 && _svc_pick <= ${#_svc_names[@]} )); then break
                    else echo "  Invalid choice."; fi
                done

                if [[ "$_svc_pick" == "0" ]]; then
                    echo "  Cancelled."
                    continue
                fi

                if [[ "$_svc_pick" == "A" ]]; then
                    echo ""
                    echo "  Configure the App Service URL for the new upstream node."
                    local _new_app_url
                    _new_app_url=$(prompt_single_entry "app-service" "3000")
                    local _new_app_host
                    _new_app_host=$(echo "$_new_app_url" | sed -E 's#^https?://##; s#:[0-9]+$##')
                    if _ec_host_exists "$_new_app_host"; then
                        echo ""
                        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        echo "  !! WARNING                                               !!"
                        echo "  !! '${_new_app_host}' is already configured."
                        echo "  !! To update an existing server, use:"
                        echo "  !!   [2] Edit an existing component server"
                        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        echo ""
                        continue
                    fi
                    APP_SERVICE_URLS="${APP_SERVICE_URLS:+${APP_SERVICE_URLS},}${_new_app_url}"
                    echo "  ✓ Added ${_new_app_url} → app-service"
                    _ec_pending_log+=("+ Add  app-service  ${_new_app_url}")

                    if [[ "$_new_app_url" =~ ^(https?)://([^:/]+): ]]; then
                        local _np="${BASH_REMATCH[1]}" _nh="${BASH_REMATCH[2]}"
                        echo ""
                        if prompt_yn "  Use same host (${_nh}) and protocol (${_np}) for all other services on default ports?" "y"; then
                            for i in "${!_svc_names[@]}"; do
                                if [[ "${_svc_names[$i]}" == "app-service" ]]; then continue; fi
                                local _v="${_svc_vars[$i]}" _port="${_svc_ports[$i]}"
                                local _u="${_np}://${_nh}:${_port}"
                                declare -g "$_v"="${!_v:+${!_v},}${_u}"
                                echo "  ✓ Added ${_u} → ${_svc_names[$i]}"
                                _ec_pending_log+=("+ Add  ${_svc_names[$i]}  ${_u}")
                            done
                        else
                            echo ""
                            echo "  Configure each service individually:"
                            for i in "${!_svc_names[@]}"; do
                                if [[ "${_svc_names[$i]}" == "app-service" ]]; then continue; fi
                                local _v="${_svc_vars[$i]}" _port="${_svc_ports[$i]}"
                                echo ""
                                local _u
                                _u=$(prompt_single_entry "${_svc_names[$i]}" "$_port")
                                declare -g "$_v"="${!_v:+${!_v},}${_u}"
                                echo "  ✓ Added ${_u} → ${_svc_names[$i]}"
                                _ec_pending_log+=("+ Add  ${_svc_names[$i]}  ${_u}")
                            done
                        fi
                    fi
                else
                    # Single or comma-separated selection — prompt URL for each
                    local -a _selected_idxs=()
                    IFS=',' read -ra _sel_parts <<< "$_svc_pick"
                    for _sp in "${_sel_parts[@]}"; do
                        _selected_idxs+=("$(( ${_sp// /} - 1 ))")
                    done

                    for _si in "${_selected_idxs[@]}"; do
                        local _tv="${_svc_vars[$_si]}"
                        echo ""
                        echo "  Configure URL for ${_svc_labels[$_si]} (${_svc_names[$_si]}):"
                        local _u
                        _u=$(prompt_single_entry "${_svc_names[$_si]}" "${_svc_ports[$_si]}")
                        local _uh
                        _uh=$(echo "$_u" | sed -E 's#^https?://##; s#:[0-9]+$##')
                        if _ec_host_exists "$_uh"; then
                            echo ""
                            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                            echo "  !! WARNING                                               !!"
                            echo "  !! '${_uh}' is already configured."
                            echo "  !! To update an existing server, use:"
                            echo "  !!   [2] Edit an existing component server"
                            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                            echo ""
                        else
                            declare -g "$_tv"="${!_tv:+${!_tv},}${_u}"
                            echo "  ✓ Added ${_u} → ${_svc_names[$_si]}"
                            _ec_pending_log+=("+ Add  ${_svc_names[$_si]}  ${_u}")
                        fi
                    done
                fi

            else
                # image-site — only one service
                local _u
                _u=$(prompt_single_entry "image-service" "8050")
                local _uh
                _uh=$(echo "$_u" | sed -E 's#^https?://##; s#:[0-9]+$##')
                if _ec_host_exists "$_uh"; then
                    echo ""
                    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                    echo "  !! WARNING                                               !!"
                    echo "  !! '${_uh}' is already configured."
                    echo "  !! To update an existing server, use:"
                    echo "  !!   [2] Edit an existing component server"
                    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                    echo ""
                    continue
                fi
                IMAGE_SERVICE_URLS="${IMAGE_SERVICE_URLS:+${IMAGE_SERVICE_URLS},}${_u}"
                echo "  ✓ Added ${_u} → image-service"
                _ec_pending_log+=("+ Add  image-service  ${_u}")
            fi
            echo ""
            echo "  Changes staged — select [3] to apply & restart Traefik"

        # ==================================================================
        # [2] Edit an existing component server
        #     Merges: edit service URL, edit host for all services, delete server
        # ==================================================================
        elif [[ "$_sub" == "2" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Edit an existing component server"
            echo "  ----------------------------------------"
            echo ""
            echo "  Current service assignments:"
            echo ""
            _ec_show_current
            echo "  ----------------------------------------"
            echo ""

            # Step 1: pick server
            echo "  Select a component server (or 0 to cancel):"
            echo ""
            local -a _ec_server_hosts=() _ec_server_svcs=()
            _ec_build_server_list

            echo ""
            local _sp
            while true; do
                read -p "  Enter number or 0 to cancel [0-${#_ec_server_hosts[@]}]: " _sp
                if [[ "$_sp" == "0" ]]; then break; fi
                if [[ "$_sp" =~ ^[0-9]+$ ]] && (( _sp >= 1 && _sp <= ${#_ec_server_hosts[@]} )); then break; fi
                echo "  Invalid selection."
            done

            if [[ "$_sp" == "0" ]]; then echo "  Cancelled."; continue; fi

            local _chosen_host="${_ec_server_hosts[$(( _sp - 1 ))]}"
            local _host_svcs="${_ec_server_svcs[$(( _sp - 1 ))]}"
            IFS='|' read -ra _host_svc_arr <<< "$_host_svcs"

            # Build per-service URL lookup for this host
            local -a _host_urls=()
            local -a _host_vars=()
            local -a _host_ports=()
            for _hsvc in "${_host_svc_arr[@]}"; do
                local _hv="" _hport=""
                for i in "${!_svc_names[@]}"; do
                    if [[ "${_svc_names[$i]}" == "$_hsvc" ]]; then
                        _hv="${_svc_vars[$i]}"; _hport="${_svc_ports[$i]}"; break
                    fi
                done
                local _hu=""
                IFS=',' read -ra _hurls <<< "${!_hv}"
                for _hurl in "${_hurls[@]}"; do
                    local _hhost
                    _hhost=$(echo "$_hurl" | sed -E 's#^https?://##; s#:[0-9]+$##')
                    if [[ "$_hhost" == "$_chosen_host" ]]; then
                        _hu="$_hurl"; break
                    fi
                done
                _host_urls+=("$_hu")
                _host_vars+=("$_hv")
                _host_ports+=("$_hport")
            done

            # Step 2: show service list + bulk options
            # Build list of services this host is NOT yet on
            local -a _missing_svcs=() _missing_vars=() _missing_ports=() _missing_labels=()
            for i in "${!_svc_names[@]}"; do
                local _already=false
                for _hsvc in "${_host_svc_arr[@]}"; do
                    if [[ "$_hsvc" == "${_svc_names[$i]}" ]]; then
                        _already=true; break
                    fi
                done
                if [[ "$_already" == false ]]; then
                    _missing_svcs+=("${_svc_names[$i]}")
                    _missing_vars+=("${_svc_vars[$i]}")
                    _missing_ports+=("${_svc_ports[$i]}")
                    _missing_labels+=("${_svc_labels[$i]}")
                fi
            done

            echo ""
            echo "  ┌─ ${_chosen_host} $(printf '%.0s─' {1..40})"
            echo "  │"
            local _si=1
            for _hsvc in "${_host_svc_arr[@]}"; do
                printf "  │  [%d] %-28s  %s\n" "$_si" "$_hsvc" "${_host_urls[$(( _si - 1 ))]}"
                _si=$(( _si + 1 ))
            done
            echo "  │"
            echo "  │  ── Bulk Actions ──────────────────────────"
            echo "  │  [A] Update hostname/IP"
            echo "  │  [D] Deregister from all services"
            if [[ ${#_missing_svcs[@]} -gt 0 ]]; then
                echo "  │  [N] Register for another service"
            fi
            if [[ ${#_host_svc_arr[@]} -gt 1 ]]; then
                echo "  │  [R] Deregister from a specific service"
            fi
            echo "  │"
            echo "  │  [0] Cancel"
            echo "  └────────────────────────────────────────────"
            echo ""

            local _action
            while true; do
                read -p "  Select a service to edit, or choose an action: " _action
                _action="${_action^^}"
                if [[ "$_action" == "0" || "$_action" == "A" || "$_action" == "D" ]]; then break
                elif [[ "$_action" == "N" && ${#_missing_svcs[@]} -gt 0 ]]; then break
                elif [[ "$_action" == "R" && ${#_host_svc_arr[@]} -gt 1 ]]; then break
                elif [[ "$_action" =~ ^[0-9]+$ ]] && (( _action >= 1 && _action <= ${#_host_svc_arr[@]} )); then break
                else echo "  Invalid choice."; fi
            done

            if [[ "$_action" == "0" ]]; then echo "  Cancelled."; continue; fi

            # ----------------------------------------------------------
            # Individual service selected
            # ----------------------------------------------------------
            if [[ "$_action" =~ ^[0-9]+$ ]]; then
                local _sidx=$(( _action - 1 ))
                local _svc="${_host_svc_arr[$_sidx]}"
                local _svc_url="${_host_urls[$_sidx]}"
                local _svc_var="${_host_vars[$_sidx]}"
                local _svc_port="${_host_ports[$_sidx]}"

                echo ""
                echo "  Service : ${_svc}"
                echo "  Current : ${_svc_url}"
                echo ""
                echo "  [1] Edit hostname/IP"
                echo "  [2] Change protocol (http ↔ https)"
                echo "  [3] Delete this component server for this service"
                echo "  [0] Cancel"
                echo ""

                local _svc_action
                while true; do
                    read -p "Enter choice [0-3]: " _svc_action
                    case "$_svc_action" in
                        0|1|2) break ;;
                        3)
                            # Guard: cannot remove if last server for this service
                            local _rem
                            _rem=$(_ec_remove_url "${!_svc_var}" "$_svc_url")
                            if [[ -z "$_rem" ]]; then
                                echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                                echo "  !! WARNING                                               !!"
                                echo "  !! '${_chosen_host}' is the only server for ${_svc}."
                                echo "  !! Add a replacement server before removing this one."
                                echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                            else
                                break
                            fi ;;
                        *) echo "  Please enter 0, 1, 2, or 3." ;;
                    esac
                done

                if [[ "$_svc_action" == "0" ]]; then echo "  Cancelled."; continue; fi

                if [[ "$_svc_action" == "1" ]]; then
                    # Edit hostname for this service
                    echo ""
                    echo "  Enter new URL for ${_svc} on this server:"
                    local _new_url
                    _new_url=$(prompt_single_entry "$_svc" "$_svc_port")
                    local _updated
                    _updated=$(_ec_replace_url "${!_svc_var}" "$_svc_url" "$_new_url")
                    declare -g "$_svc_var"="$_updated"
                    _ec_pending_log+=("~ Edit  ${_svc} on ${_chosen_host}  →  ${_new_url}")
                    echo ""
                    echo "  ✓ Staged:"
                    echo "    Was : ${_svc_url}"
                    echo "    Now : ${_new_url}"
                    echo "  Select [3] to apply & restart Traefik"
                elif [[ "$_svc_action" == "2" ]]; then
                    # Toggle protocol http ↔ https
                    local _cur_proto _new_proto _new_url
                    _cur_proto=$(echo "$_svc_url" | grep -oE '^https?')
                    if [[ "$_cur_proto" == "https" ]]; then
                        _new_proto="http"
                    else
                        _new_proto="https"
                    fi
                    _new_url="${_new_proto}${_svc_url#${_cur_proto}}"
                    local _updated
                    _updated=$(_ec_replace_url "${!_svc_var}" "$_svc_url" "$_new_url")
                    declare -g "$_svc_var"="$_updated"
                    _ec_pending_log+=("~ Protocol  ${_svc} on ${_chosen_host}  →  ${_new_proto}")
                    echo ""
                    echo "  ✓ Staged:"
                    echo "    Was : ${_svc_url}"
                    echo "    Now : ${_new_url}"
                    echo "  Select [3] to apply & restart Traefik"
                else
                    # [3] Delete this component server for this service
                    local _rem
                    _rem=$(_ec_remove_url "${!_svc_var}" "$_svc_url")
                    declare -g "$_svc_var"="$_rem"
                    _ec_pending_log+=("- Remove  ${_svc}  ${_svc_url}")
                    echo "  ✓ Removal staged — select [3] to apply & restart Traefik"
                fi

            # ----------------------------------------------------------
            # [R] Deregister from a specific service
            # ----------------------------------------------------------
            elif [[ "$_action" == "R" ]]; then
                echo ""
                echo "  Which service(s) would you like to remove ${_chosen_host} from?"
                echo "  (Enter a number, or comma-separated for multiple e.g. 1,2)"
                echo ""
                local _ri=1
                for _rsvc in "${_host_svc_arr[@]}"; do
                    printf "  [%d] %-30s  %s\n" "$_ri" "$_rsvc" "${_host_urls[$(( _ri - 1 ))]}"
                    _ri=$(( _ri + 1 ))
                done
                echo "  [0] Cancel"
                echo ""

                local _rpick
                while true; do
                    read -p "Enter choice: " _rpick
                    if [[ "$_rpick" == "0" ]]; then break; fi
                    if [[ "$_rpick" == *","* ]]; then
                        local _rvalid=true
                        IFS=',' read -ra _rpparts <<< "$_rpick"
                        for _rpp in "${_rpparts[@]}"; do
                            _rpp="${_rpp// /}"
                            if ! [[ "$_rpp" =~ ^[0-9]+$ ]] || (( _rpp < 1 || _rpp > ${#_host_svc_arr[@]} )); then
                                echo "  Invalid: '${_rpp}'. Enter numbers 1–${#_host_svc_arr[@]}."
                                _rvalid=false; break
                            fi
                        done
                        if [[ "$_rvalid" == true ]]; then break; fi
                    elif [[ "$_rpick" =~ ^[0-9]+$ ]] && (( _rpick >= 1 && _rpick <= ${#_host_svc_arr[@]} )); then
                        break
                    else
                        echo "  Invalid choice."
                    fi
                done

                if [[ "$_rpick" == "0" ]]; then echo "  Cancelled."; continue; fi

                IFS=',' read -ra _rsel <<< "$_rpick"
                local _rblocked=false
                for _rsp in "${_rsel[@]}"; do
                    local _rridx=$(( ${_rsp// /} - 1 ))
                    local _rrsvc="${_host_svc_arr[$_rridx]}"
                    local _rrvar="${_host_vars[$_rridx]}"
                    local _rrurl="${_host_urls[$_rridx]}"
                    local _rrrem
                    _rrrem=$(_ec_remove_url "${!_rrvar}" "$_rrurl")
                    if [[ -z "$_rrrem" ]]; then
                        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                    echo "  !! WARNING                                               !!"
                    echo "  !! '${_chosen_host}' is the only server for ${_rrsvc}."
                    echo "  !! Add a replacement server before removing this one."
                    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        _rblocked=true
                    fi
                done
                if [[ "$_rblocked" == true ]]; then continue; fi

                echo ""
                echo "  Will remove ${_chosen_host} from:"
                for _rsp in "${_rsel[@]}"; do
                    echo "    - ${_host_svc_arr[$(( ${_rsp// /} - 1 ))]}"
                done
                echo ""
                if ! prompt_yn "  Confirm?" "n"; then echo "  Cancelled."; continue; fi

                for _rsp in "${_rsel[@]}"; do
                    local _rridx=$(( ${_rsp// /} - 1 ))
                    local _rrsvc="${_host_svc_arr[$_rridx]}"
                    local _rrvar="${_host_vars[$_rridx]}"
                    local _rrurl="${_host_urls[$_rridx]}"
                    local _rrrem
                    _rrrem=$(_ec_remove_url "${!_rrvar}" "$_rrurl")
                    declare -g "$_rrvar"="$_rrrem"
                    _ec_pending_log+=("- Remove  ${_rrsvc}  ${_rrurl}")
                done
                echo "  ✓ Removal staged — select [3] to apply & restart Traefik"

            # ----------------------------------------------------------
            # [N] Register for another service
            # ----------------------------------------------------------
            elif [[ "$_action" == "N" ]]; then
                echo ""
                echo "  Which service(s) would you like to add to ${_chosen_host}?"
                echo "  (Enter a number, or comma-separated for multiple e.g. 1,2)"
                echo ""
                local _mi=1
                for _msvc in "${_missing_svcs[@]}"; do
                    printf "  [%d] %-30s  (default port: %s)\n" \
                        "$_mi" "${_missing_labels[$(( _mi - 1 ))]} (${_msvc})" \
                        "${_missing_ports[$(( _mi - 1 ))]}"
                    _mi=$(( _mi + 1 ))
                done
                echo "  [0] Cancel"
                echo ""

                local _npick
                while true; do
                    read -p "Enter choice: " _npick
                    if [[ "$_npick" == "0" ]]; then break; fi
                    if [[ "$_npick" == *","* ]]; then
                        local _nvalid=true
                        IFS=',' read -ra _npparts <<< "$_npick"
                        for _npp in "${_npparts[@]}"; do
                            _npp="${_npp// /}"
                            if ! [[ "$_npp" =~ ^[0-9]+$ ]] || (( _npp < 1 || _npp > ${#_missing_svcs[@]} )); then
                                echo "  Invalid: '${_npp}'. Enter numbers 1–${#_missing_svcs[@]}."
                                _nvalid=false; break
                            fi
                        done
                        if [[ "$_nvalid" == true ]]; then break; fi
                    elif [[ "$_npick" =~ ^[0-9]+$ ]] && (( _npick >= 1 && _npick <= ${#_missing_svcs[@]} )); then
                        break
                    else
                        echo "  Invalid choice."
                    fi
                done

                if [[ "$_npick" == "0" ]]; then echo "  Cancelled."; continue; fi

                IFS=',' read -ra _nsel <<< "$_npick"
                for _nsp in "${_nsel[@]}"; do
                    local _ni=$(( ${_nsp// /} - 1 ))
                    local _nsvc="${_missing_svcs[$_ni]}"
                    local _nvar="${_missing_vars[$_ni]}"
                    local _nport="${_missing_ports[$_ni]}"
                    echo ""
                    # We already know the hostname — just confirm the port
                    local _nfinalport=""
                    while true; do
                        read -p "  Port for ${_nsvc} on ${_chosen_host} [default: ${_nport}]: " _nfinalport
                        _nfinalport="${_nfinalport:-$_nport}"
                        if [[ "$_nfinalport" =~ ^[0-9]+$ ]] && (( _nfinalport >= 1 && _nfinalport <= 65535 )); then break; fi
                        echo "  Error: Enter a valid port (1-65535)."
                    done
                    # Detect scheme from existing URLs for this service
                    local _nscheme="https"
                    local _nexisting="${!_nvar}"
                    if [[ "$_nexisting" =~ ^http:// ]]; then _nscheme="http"; fi
                    local _nu="${_nscheme}://${_chosen_host}:${_nfinalport}"
                    declare -g "$_nvar"="${!_nvar:+${!_nvar},}${_nu}"
                    echo "  ✓ Added ${_nu} → ${_nsvc}"
                    _ec_pending_log+=("+ Add  ${_nsvc}  ${_nu}")
                done
                echo "  Select [3] to apply & restart Traefik"

            # ----------------------------------------------------------
            # [A] Edit host for all services
            # ----------------------------------------------------------
            elif [[ "$_action" == "A" ]]; then
                echo ""
                echo "  Enter the new hostname for ${_chosen_host}:"
                local _new_host=""
                while [[ -z "$_new_host" ]]; do
                    read -p "  New hostname or IP: " _new_host
                    if [[ -z "$_new_host" ]]; then echo "  Cannot be empty."; fi
                done

                local _ai=0
                for _hsvc in "${_host_svc_arr[@]}"; do
                    local _old_u="${_host_urls[$_ai]}"
                    local _hv="${_host_vars[$_ai]}"
                    # Rebuild URL with new host, keeping scheme and port
                    local _scheme _port_part
                    _scheme=$(echo "$_old_u" | grep -oE '^https?')
                    _port_part=$(echo "$_old_u" | grep -oE ':[0-9]+$')
                    local _new_u="${_scheme}://${_new_host}${_port_part}"
                    local _updated
                    _updated=$(_ec_replace_url "${!_hv}" "$_old_u" "$_new_u")
                    declare -g "$_hv"="$_updated"
                    _ec_pending_log+=("~ Edit  ${_hsvc} host  ${_old_u}  →  ${_new_u}")
                    _ai=$(( _ai + 1 ))
                done
                echo "  ✓ All services on ${_chosen_host} updated to ${_new_host} — select [3] to apply & restart Traefik"

            # ----------------------------------------------------------
            # [D] Delete server from all services
            # ----------------------------------------------------------
            elif [[ "$_action" == "D" ]]; then
                # Guard: check no service would be left empty
                local _blocked=false
                local _di=0
                for _hsvc in "${_host_svc_arr[@]}"; do
                    local _hv="${_host_vars[$_di]}"
                    local _hu="${_host_urls[$_di]}"
                    local _rem
                    _rem=$(_ec_remove_url "${!_hv}" "$_hu")
                    if [[ -z "$_rem" ]]; then
                        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        echo "  !! WARNING                                               !!"
                        echo "  !! '${_chosen_host}' is the only server for ${_hsvc}."
                        echo "  !! Add a replacement server before removing this one."
                        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        _blocked=true
                    fi
                    _di=$(( _di + 1 ))
                done

                if [[ "$_blocked" == true ]]; then continue; fi

                echo ""
                echo "  This will remove ${_chosen_host} from all services:"
                for _hsvc in "${_host_svc_arr[@]}"; do echo "    - ${_hsvc}"; done
                echo ""
                if ! prompt_yn "  Confirm?" "n"; then echo "  Cancelled."; continue; fi

                local _di=0
                for _hsvc in "${_host_svc_arr[@]}"; do
                    local _hv="${_host_vars[$_di]}"
                    local _hu="${_host_urls[$_di]}"
                    local _rem
                    _rem=$(_ec_remove_url "${!_hv}" "$_hu")
                    declare -g "$_hv"="$_rem"
                    _ec_pending_log+=("- Remove  ${_hsvc}  ${_hu}")
                    _di=$(( _di + 1 ))
                done
                echo "  ✓ ${_chosen_host} removed from all services — select [3] to apply & restart Traefik"
            fi

        # ==================================================================
        # [3] Apply
        # ==================================================================
        elif [[ "$_sub" == "3" ]]; then
            break

        # ==================================================================
        # [4] Cancel
        # ==================================================================
        elif [[ "$_sub" == "4" ]]; then
            if [[ ${#_ec_pending_log[@]} -gt 0 ]]; then
                echo ""
                echo "  ⚠️  You have pending changes that have not been applied:"
                for _pl in "${_ec_pending_log[@]}"; do
                    echo "     ${_pl}"
                done
                echo ""
                echo "  [1] Apply changes & restart Traefik, then exit"
                echo "  [2] Discard changes and exit"
                echo "  [3] Go back and keep editing"
                echo ""
                local _cc
                while true; do
                    read -p "Enter choice [1-3]: " _cc
                    case "$_cc" in
                        1|2|3) break ;;
                        *) echo "  Please enter 1, 2, or 3." ;;
                    esac
                done
                case "$_cc" in
                    1) break ;;          # fall through to apply block
                    2)
                        echo "  Changes discarded."
                        _cancelled=true
                        break
                        ;;
                    3) continue ;;       # back to menu
                esac
            else
                echo ""
                echo "  Cancelled — no changes applied."
                _cancelled=true
                break
            fi
        fi

    done   # end main loop

    # ---- Apply changes (skipped on cancel) ----
    if [[ "${_cancelled:-false}" == "true" ]]; then
        return 0
    fi

    echo ""
    echo "  Applying changes..."

    # Ensure generate_clinical_conf won't re-prompt
    INITIAL_DEPLOYMENT_TYPE="$DEPLOYMENT_TYPE"
    generate_clinical_conf
    echo "✓ clinical_conf.yml written"

    # Push to backup nodes
    if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        echo ""
        echo "Pushing updated configuration to backup nodes..."
        for i in "${!BACKUP_NODES[@]}"; do
            local _n="${BACKUP_NODES[$i]}"
            local _ip="${BACKUP_IPS[$i]}"
            echo -n "  ${_n} (${_ip})... "
            ensure_SCRIPTS_DIR "${_ip}" || true
            copy_to_remote_root "${_dynamic_dir}/clinical_conf.yml" "${_ip}" "${_dynamic_dir}/clinical_conf.yml"
            echo "✓"
        done
    fi

    _extend_restart_traefik_all_nodes
    snapshot_config "COMPONENT" "Component server configuration changed"
    echo -n "  Saving configuration... "
    CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
    KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
    save_config
    echo "✓"
    echo "✓ Component servers updated"
}

# ==========================================
# Extend Mode — Option 5: Add/Edit HL7 Configuration
# ==========================================

extend_edit_hl7() {
    local _dynamic_dir="/opt/indica/traefik/config/dynamic"
    local _traefik_cfg="/opt/indica/traefik/config/traefik.yml"

    # ------------------------------------------------------------------
    # Build available-host list from saved service URLs (for backend picker)
    # ------------------------------------------------------------------
    local _hl7_host_list=""
    local _all_urls="${APP_SERVICE_URLS:-},${IDP_SERVICE_URLS:-},${API_SERVICE_URLS:-},${FILEMONITOR_SERVICE_URLS:-},${IMAGE_SERVICE_URLS:-}"
    while IFS= read -r _uhost; do
        if [[ -z "$_uhost" ]]; then continue; fi
        _hl7_host_list="${_hl7_host_list:+${_hl7_host_list},}${_uhost}"
    done < <(echo "$_all_urls" | tr ',' '\n' \
        | sed -E 's#^https?://##; s#:[0-9]+$##' \
        | sort -u | grep -v '^$')

    # ------------------------------------------------------------------
    # Parse existing HL7 config into three working arrays
    # ------------------------------------------------------------------
    local -a _hp=()   # listen ports
    local -a _hb=()   # comma-separated backends per port
    local -a _hc=()   # descriptions per port

    if [[ "$HL7_ENABLED" == "yes" && -n "$HL7_LISTEN_PORTS" ]]; then
        IFS='|' read -ra _hp <<< "$HL7_LISTEN_PORTS"
        IFS='|' read -ra _hb <<< "$HL7_PORT_BACKENDS"
        IFS='|' read -ra _hc <<< "$HL7_PORT_COMMENTS"
    fi

    # Track entrypoint names that existed at session start (for cleanup)
    local -a _original_ep_names=()
    local _oep_idx=0
    for _op in "${_hp[@]}"; do
        if [[ $_oep_idx -eq 0 ]]; then
            _original_ep_names+=("hl7")
        else
            _original_ep_names+=("hl7-${_op}")
        fi
        _oep_idx=$(( _oep_idx + 1 ))
    done

    # Pending changes log — accumulates human-readable lines for display
    local -a _pending_log=()

    # ------------------------------------------------------------------
    # Helper: display current HL7 config table
    # ------------------------------------------------------------------
    _hl7_show_current() {
        if [[ ${#_hp[@]} -eq 0 ]]; then
            echo "  (no HL7 ports configured)"
            echo ""
            return 0
        fi
        local _pi=0
        for _port in "${_hp[@]}"; do
            local _desc="${_hc[$_pi]:-}"
            local _label="Port $(( _pi + 1 ))"
            if [[ $_pi -eq 0 ]]; then _label="Port 1"; fi
            if [[ -n "$_desc" ]]; then
                echo "  ${_label} — :${_port}  (${_desc})"
            else
                echo "  ${_label} — :${_port}"
            fi
            local _bend="${_hb[$_pi]:-}"
            if [[ -n "$_bend" ]]; then
                IFS=',' read -ra _bservers <<< "$_bend"
                for _bs in "${_bservers[@]}"; do
                    if [[ -n "$_bs" ]]; then
                        printf "    ─ %s\n" "$_bs"
                    fi
                done
            else
                echo "    (no backends)"
            fi
            echo ""
            _pi=$(( _pi + 1 ))
        done
        return 0
    }

    # ------------------------------------------------------------------
    # Helper: build a flat numbered list of all backends across all ports
    # Writes to globals: _hfl_ports / _hfl_backends / _hfl_pidx
    # ------------------------------------------------------------------
    _hl7_build_flat_backends() {
        _hfl_ports=()
        _hfl_backends=()
        _hfl_pidx=()
        local _pi=0
        for _port in "${_hp[@]}"; do
            local _bend="${_hb[$_pi]:-}"
            if [[ -n "$_bend" ]]; then
                IFS=',' read -ra _bservers <<< "$_bend"
                for _bs in "${_bservers[@]}"; do
                    if [[ -n "$_bs" ]]; then
                        _hfl_ports+=("$_port")
                        _hfl_backends+=("$_bs")
                        _hfl_pidx+=("$_pi")
                    fi
                done
            fi
            _pi=$(( _pi + 1 ))
        done
        return 0
    }

    # ------------------------------------------------------------------
    # Helper: remove a backend from a port's backend string
    # _hl7_remove_backend PORT_IDX BACKEND  →  updates _hb[PORT_IDX]
    # ------------------------------------------------------------------
    _hl7_remove_backend() {
        local _pidx="$1" _needle="$2"
        local _new
        _new=$(echo "${_hb[$_pidx]}" | tr ',' '\n' | grep -vxF "$_needle" | paste -sd ',' -)
        _hb[$_pidx]="$_new"
        return 0
    }

    # ------------------------------------------------------------------
    # Helper: replace a backend in a port's backend string
    # _hl7_replace_backend PORT_IDX OLD NEW  →  updates _hb[PORT_IDX]
    # ------------------------------------------------------------------
    _hl7_replace_backend() {
        local _pidx="$1" _old="$2" _new_be="$3"
        local _updated
        _updated=$(echo "${_hb[$_pidx]}" | tr ',' '\n' \
            | awk -v old="$_old" -v new="$_new_be" \
                '$0==old{print new;next}{print}' \
            | paste -sd ',' -)
        _hb[$_pidx]="$_updated"
        return 0
    }

    # ------------------------------------------------------------------
    # Helper: prompt for a single backend address (host:port)
    # Writes to global _hl7_new_backend
    # ------------------------------------------------------------------
    _hl7_prompt_backend() {
        local _listen_port="${1:-1050}"
        local _existing_backends="${2:-}"   # comma-separated — re-prompt if duplicate
        local _exclude_backend="${3:-}"     # backend being replaced (edit) — exempt from dup check
        _hl7_new_backend=""

        while true; do
            # If known hosts available, offer picker
            if [[ -n "$_hl7_host_list" ]]; then
                local -a _ha=()
                IFS=',' read -ra _ha_all <<< "$_hl7_host_list"

                # Filter out hosts already configured on this port
                for _hh in "${_ha_all[@]}"; do
                    local _already=false
                    if [[ -n "$_existing_backends" ]]; then
                        IFS=',' read -ra _eb_list <<< "$_existing_backends"
                        for _eb in "${_eb_list[@]}"; do
                            local _eb_host="${_eb%%:*}"
                            if [[ "$_eb_host" == "$_hh" ]]; then
                                _already=true; break
                            fi
                        done
                    fi
                    if [[ "$_already" == false ]]; then
                        _ha+=("$_hh")
                    fi
                done

                echo ""
                echo "  Known hosts:"
                local _hn=1
                for _hh in "${_ha[@]}"; do
                    printf "    %d. %s\n" "$_hn" "$_hh"
                    _hn=$(( _hn + 1 ))
                done
                echo "    M. Enter manually"
                echo ""
                local _hpick
                while true; do
                    read -p "  Select host [1-${#_ha[@]}/M/0 to cancel] (or comma-separated for multiple, e.g. 1,2): " _hpick
                    _hpick_upper="${_hpick^^}"
                    if [[ "$_hpick_upper" == "0" ]]; then
                        _hl7_new_backend=""
                        return 0
                    fi
                    if [[ "$_hpick_upper" == "M" ]]; then
                        break
                    fi
                    # Check for comma-separated multi-select
                    if [[ "$_hpick" == *","* ]]; then
                        local _multi_backends="" _multi_valid=true
                        IFS=',' read -ra _mpicks <<< "$_hpick"
                        for _mp in "${_mpicks[@]}"; do
                            _mp="${_mp// /}"
                            if ! [[ "$_mp" =~ ^[0-9]+$ ]] || (( _mp < 1 || _mp > ${#_ha[@]} )); then
                                echo "  Invalid selection: '${_mp}'. Enter numbers 1–${#_ha[@]}."
                                _multi_valid=false; break
                            fi
                            local _mhost="${_ha[$(( _mp - 1 ))]}"
                            local _mbport=""
                            while true; do
                                read -p "  Backend port for ${_mhost} [default: ${_listen_port}]: " _mbport
                                _mbport="${_mbport:-$_listen_port}"
                                if [[ "$_mbport" =~ ^[0-9]+$ ]] && (( _mbport >= 1 && _mbport <= 65535 )); then
                                    break
                                fi
                                echo "  Error: Enter a valid port (1-65535)."
                            done
                            local _mbe="${_mhost}:${_mbport}"
                            # Duplicate check
                            if [[ -n "$_existing_backends" ]]; then
                                local _dup=false
                                IFS=',' read -ra _eb_chk <<< "$_existing_backends"
                                for _ec in "${_eb_chk[@]}"; do
                                    if [[ "$_ec" == "$_mbe" ]]; then _dup=true; break; fi
                                done
                                if [[ "$_dup" == true ]]; then
                                    echo "  Warning: ${_mbe} is already configured — skipping."
                                    continue
                                fi
                            fi
                            if [[ -z "$_multi_backends" ]]; then
                                _multi_backends="$_mbe"
                            else
                                _multi_backends="${_multi_backends},${_mbe}"
                            fi
                        done
                        if [[ "$_multi_valid" == true && -n "$_multi_backends" ]]; then
                            _hl7_new_backend="$_multi_backends"
                            return 0
                        fi
                        continue
                    fi
                    # Single numeric selection
                    if [[ "$_hpick" =~ ^[0-9]+$ ]] && (( _hpick >= 1 && _hpick <= ${#_ha[@]} )); then
                        local _chosen_host="${_ha[$(( _hpick - 1 ))]}"
                        local _bport=""
                        while true; do
                            read -p "  Backend port [default: ${_listen_port}]: " _bport
                            _bport="${_bport:-$_listen_port}"
                            if [[ "$_bport" =~ ^[0-9]+$ ]] && (( _bport >= 1 && _bport <= 65535 )); then
                                break
                            fi
                            echo "  Error: Enter a valid port (1-65535)."
                        done
                        _hl7_new_backend="${_chosen_host}:${_bport}"
                        break 2
                    fi
                    # Direct hostname entry — treat as manual input
                    if [[ "$_hpick" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
                        local _bport=""
                        while true; do
                            read -p "  Backend port [default: ${_listen_port}]: " _bport
                            _bport="${_bport:-$_listen_port}"
                            if [[ "$_bport" =~ ^[0-9]+$ ]] && (( _bport >= 1 && _bport <= 65535 )); then
                                break
                            fi
                            echo "  Error: Enter a valid port (1-65535)."
                        done
                        _hl7_new_backend="${_hpick}:${_bport}"
                        break 2
                    fi
                    echo "  Invalid choice."
                done
            fi

            # Manual entry
            local _mhost="" _mport=""
            while true; do
                read -p "  Hostname or IP (or 0 to cancel): " _mhost
                if [[ "$_mhost" == "0" ]]; then
                    _hl7_new_backend=""
                    return 0
                fi
                if [[ -n "$_mhost" ]]; then break; fi
                echo "  Error: Cannot be empty."
            done
            while true; do
                read -p "  Backend port [default: ${_listen_port}]: " _mport
                _mport="${_mport:-$_listen_port}"
                if [[ "$_mport" =~ ^[0-9]+$ ]] && (( _mport >= 1 && _mport <= 65535 )); then
                    break
                fi
                echo "  Error: Enter a valid port (1-65535)."
            done
            _hl7_new_backend="${_mhost}:${_mport}"
            break
        done

        # Duplicate check — skip if this is the backend being replaced in an edit
        if [[ -n "$_existing_backends" && "$_hl7_new_backend" != "$_exclude_backend" ]]; then
            IFS=',' read -ra _eb_arr <<< "$_existing_backends"
            for _eb in "${_eb_arr[@]}"; do
                if [[ "$_eb" == "$_hl7_new_backend" ]]; then
                    echo "  Error: ${_hl7_new_backend} is already configured as a backend for this port."
                    _hl7_new_backend=""
                    # Re-invoke to re-prompt — use recursion with same args
                    _hl7_prompt_backend "$_listen_port" "$_existing_backends" "$_exclude_backend"
                    return 0
                fi
            done
        fi
        return 0
    }

    # ------------------------------------------------------------------
    # Helper: write hl7.yml + patch traefik.yml + push + restart
    # ------------------------------------------------------------------
    _hl7_apply_changes() {
        # Rebuild globals from working arrays
        HL7_ENABLED="yes"
        HL7_LISTEN_PORTS=$(IFS='|'; echo "${_hp[*]}")
        HL7_PORT_BACKENDS=$(IFS='|'; echo "${_hb[*]}")
        HL7_PORT_COMMENTS=$(IFS='|'; echo "${_hc[*]}")

        mkdir -p "${_dynamic_dir}"

        echo ""
        echo "  Applying HL7 configuration..."
        echo ""

        # Write hl7.yml
        generate_hl7_conf "${_dynamic_dir}"
        echo "  ✓ hl7.yml written"

        # Patch traefik.yml — first remove any stale entrypoints (ports that
        # existed in the original config but are no longer in the new config)
        local -a _new_ep_names=()
        local _nep_idx=0
        for _np in "${_hp[@]}"; do
            if [[ $_nep_idx -eq 0 ]]; then
                _new_ep_names+=("hl7")
            else
                _new_ep_names+=("hl7-${_np}")
            fi
            _nep_idx=$(( _nep_idx + 1 ))
        done

        local _tmp_t
        _tmp_t=$(mktemp)
        cp "${_traefik_cfg}" "${_tmp_t}"

        # Remove entrypoints that are in original but not in new set
        for _oep in "${_original_ep_names[@]}"; do
            local _still_needed=false
            for _nep in "${_new_ep_names[@]}"; do
                if [[ "$_oep" == "$_nep" ]]; then
                    _still_needed=true
                    break
                fi
            done
            if [[ "$_still_needed" == false ]]; then
                # Remove the entrypoint block from traefik.yml.
                # Use indent-based detection: the entry name is at 2-space indent;
                # its children are at 4+ spaces. Stop skipping when we reach a
                # line that is NOT indented by 4+ spaces (next peer or top-level key).
                local _tmp_rm
                _tmp_rm=$(mktemp)
                awk -v ep="  ${_oep}:" '
                    $0 == ep       { skip=1; next }
                    skip && /^    / { next }
                    skip           { skip=0; print; next }
                    { print }
                ' "${_tmp_t}" > "${_tmp_rm}"
                cp "${_tmp_rm}" "${_tmp_t}"
                rm -f "${_tmp_rm}"
                echo "  ✓ traefik.yml entrypoint ${_oep} removed"
            fi
        done

        # Add/update entrypoints for all ports in new config
        local _pidx=0
        for _np in "${_hp[@]}"; do
            local _ep_name="hl7"
            if [[ $_pidx -gt 0 ]]; then _ep_name="hl7-${_np}"; fi
            local _cmt="${_hc[$_pidx]:-}"
            local _addr="    address: ':${_np}'"
            if [[ -n "$_cmt" ]]; then _addr="${_addr} # ${_cmt}"; fi

            if grep -q "^  ${_ep_name}:" "${_tmp_t}"; then
                local _tmp_upd
                _tmp_upd=$(mktemp)
                awk -v ep="  ${_ep_name}:" -v addr="${_addr}" '
                    $0 == ep                   { in_block=1; print; next }
                    in_block && /^    address:/ { print addr; next }
                    in_block && !/^    /        { in_block=0 }
                    { print }
                ' "${_tmp_t}" > "${_tmp_upd}"
                cp "${_tmp_upd}" "${_tmp_t}"
                rm -f "${_tmp_upd}"
                echo "  ✓ traefik.yml entrypoint ${_ep_name} updated"
            else
                local _tmp2
                _tmp2=$(mktemp)
                awk -v ep="${_ep_name}" -v addr="${_addr}" '
                    /^entryPoints:/                                    { in_ep=1 }
                    in_ep && /^[[:alpha:]]/ && !/^entryPoints:/ && !inserted {
                        print "  " ep ":"
                        print addr
                        print "    transport:"
                        print "      respondingTimeouts:"
                        print "        readTimeout: 0"
                        print "        idleTimeout: 0"
                        inserted=1
                    }
                    { print }
                ' "${_tmp_t}" > "${_tmp2}"
                cp "${_tmp2}" "${_tmp_t}"
                rm -f "${_tmp2}"
                echo "  ✓ traefik.yml entrypoint ${_ep_name} added"
            fi
            _pidx=$(( _pidx + 1 ))
        done

        cp "${_tmp_t}" "${_traefik_cfg}"
        rm -f "${_tmp_t}"
        echo "  ✓ traefik.yml updated"

        # Push to backup nodes
        if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
            echo ""
            echo "  Pushing HL7 configuration to backup nodes..."
            for i in "${!BACKUP_NODES[@]}"; do
                local _node="${BACKUP_NODES[$i]}"
                local _ip="${BACKUP_IPS[$i]}"
                echo -n "    ${_node} (${_ip})... "
                ensure_SCRIPTS_DIR "${_ip}" || true
                copy_to_remote_root "${_dynamic_dir}/hl7.yml" "${_ip}" "${_dynamic_dir}/hl7.yml"
                copy_to_remote_root "${_traefik_cfg}" "${_ip}" "${_traefik_cfg}"
                echo "✓"
            done
        fi

        snapshot_config "HL7" "HL7 configuration changed"
        _extend_restart_traefik_all_nodes
        echo -n "  Saving configuration... "
        CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
        KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
        save_config
        echo "✓"
        echo ""
        echo "  ✓ HL7 configuration applied successfully"
        return 0
    }

    # ==================================================================
    # Main loop
    # ==================================================================
    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Edit HL7 Configuration"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""

        # Pending changes block
        if [[ ${#_pending_log[@]} -gt 0 ]]; then
            echo ""
            echo "  ┌─ Pending changes (not yet applied) ─────────────────────────"
            for _pl in "${_pending_log[@]}"; do
                echo "  │  ${_pl}"
            done
            echo "  └──────────────────────────────────────────────────────────────"
        fi

        echo ""
        echo "Current HL7 configuration:"
        echo ""
        _hl7_show_current

        local _total_ports=${#_hp[@]}

        # Count total backends across all ports
        local _total_backends=0
        if [[ $_total_ports -gt 0 ]]; then
            for _bstr in "${_hb[@]}"; do
                IFS=',' read -ra _btmp <<< "$_bstr"
                for _be in "${_btmp[@]}"; do
                    if [[ -n "$_be" ]]; then _total_backends=$(( _total_backends + 1 )); fi
                done
            done
        fi

        echo "  ----------------------------------------"
        echo "  [1] Add a new HL7 port"
        if [[ $_total_ports -gt 0 ]]; then
            echo "  [2] Rename an HL7 port"
            echo "  [3] Add a component server to a port"
            echo "  [4] Edit component servers on a port"
            if [[ $_total_ports -gt 1 ]]; then
                echo "  [5] Remove an HL7 port"
            else
                echo "  [5] Remove an HL7 port  (n/a — only one port)"
            fi
            echo "  [6] Remove all HL7 configuration"
        else
            echo "  [2] Rename an HL7 port                  (n/a — no ports configured)"
            echo "  [3] Add a component server to a port    (n/a — no ports configured)"
            echo "  [4] Edit component servers on a port         (n/a — no ports configured)"
            echo "  [5] Remove an HL7 port                  (n/a — no ports configured)"
            echo "  [6] Remove all HL7 configuration        (n/a — no ports configured)"
        fi
        echo "  ─────────────────────────────────────────────────────"
        if [[ ${#_pending_log[@]} -gt 0 ]]; then
            echo "  [7] Apply changes & restart Traefik"
        else
            echo "  [7] Apply changes & restart Traefik  (n/a — no pending changes)"
        fi
        echo "  [8] Cancel — return to Extend menu"
        echo ""

        local _sub
        while true; do
            read -p "Enter choice [1-8]: " _sub
            case "$_sub" in
                1|8) break ;;
                2|3|4|5|6)
                    if [[ $_total_ports -eq 0 ]]; then
                        echo "  Option unavailable — no ports configured."
                    elif [[ "$_sub" == "5" && $_total_ports -le 1 ]]; then
                        echo "  Option unavailable — only one port configured."
                    else
                        break
                    fi ;;
                7)
                    if [[ ${#_pending_log[@]} -gt 0 ]]; then break
                    else echo "  No pending changes to apply."; fi
                    ;;
                *) echo "  Please enter 1–8." ;;
            esac
        done

        # ==============================================================
        # [1] Add a new HL7 port
        # ==============================================================
        if [[ "$_sub" == "1" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Add a new HL7 port"
            echo "  ----------------------------------------"
            echo ""

            # Port number
            local _new_port=""
            while true; do
                read -p "  Traefik listen port: " _new_port
                if [[ "$_new_port" =~ ^[0-9]+$ ]] && (( _new_port >= 1 && _new_port <= 65535 )); then
                    # Check for duplicates
                    local _dup=false
                    for _ep in "${_hp[@]}"; do
                        if [[ "$_ep" == "$_new_port" ]]; then _dup=true; break; fi
                    done
                    if [[ "$_dup" == true ]]; then
                        echo "  Error: Port ${_new_port} is already configured."
                        continue
                    fi
                    break
                fi
                echo "  Error: Enter a valid port number (1-65535)."
            done

            # Description
            local _new_desc=""
            read -p "  Description (e.g. Berlin, Main Lab): " _new_desc

            # Backend(s)
            echo ""
            echo "  Configure backend server(s) for port :${_new_port}."
            echo "  You can add multiple backend servers for load balancing / redundancy."
            echo ""
            _hl7_prompt_backend "$_new_port" ""
            if [[ -z "$_hl7_new_backend" ]]; then
                echo "  Cancelled."
                continue
            fi
            local _new_backends="$_hl7_new_backend"
            # If multi-select was used, _hl7_new_backend may already contain multiple backends
            if [[ "$_hl7_new_backend" == *","* ]]; then
                echo "  ✓ Added backends: ${_hl7_new_backend}"
            else
                echo "  ✓ Added backend: ${_hl7_new_backend}"
            fi

            while prompt_yn "  Add another backend server for this port?" "n"; do
                _hl7_prompt_backend "$_new_port" "$_new_backends"
                if [[ -z "$_hl7_new_backend" ]]; then
                    echo "  Cancelled."
                    break
                fi
                _new_backends="${_new_backends},${_hl7_new_backend}"
                if [[ "$_hl7_new_backend" == *","* ]]; then
                    echo "  ✓ Added backends: ${_hl7_new_backend}"
                else
                    echo "  ✓ Added backend: ${_hl7_new_backend}"
                fi
            done

            _hp+=("$_new_port")
            _hb+=("$_new_backends")
            _hc+=("$_new_desc")
            local _plog_desc="${_new_desc:+ (${_new_desc})}"
            _pending_log+=("+ Add port :${_new_port}${_plog_desc}  →  ${_new_backends}")
            echo ""
            echo "  ✓ Port :${_new_port} staged — select [7] to apply & restart Traefik"

        # ==============================================================
        # [2] Rename an HL7 port
        # ==============================================================
        elif [[ "$_sub" == "2" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Rename an HL7 port"
            echo "  ----------------------------------------"
            echo ""

            if [[ ${#_hp[@]} -eq 0 ]]; then
                echo "  No ports configured."
                continue
            fi

            echo "  Select a port (or 0 to cancel):"
            echo ""
            local _pn=1
            for _port in "${_hp[@]}"; do
                local _desc="${_hc[$(( _pn - 1 ))]:-}"
                if [[ -n "$_desc" ]]; then
                    printf "  [%d]  :%-6s  (%s)\n" "$_pn" "$_port" "$_desc"
                else
                    printf "  [%d]  :%-6s\n" "$_pn" "$_port"
                fi
                _pn=$(( _pn + 1 ))
            done
            echo ""

            local _pick
            while true; do
                read -p "  Enter number or 0 to cancel [0-${#_hp[@]}]: " _pick
                if [[ "$_pick" == "0" ]]; then break; fi
                if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_hp[@]} )); then break; fi
                echo "  Invalid selection."
            done

            if [[ "$_pick" == "0" ]]; then
                echo "  Cancelled."
                continue
            fi

            local _pidx=$(( _pick - 1 ))
            echo ""
            echo "  Port :${_hp[$_pidx]}  current description: '${_hc[$_pidx]:-}'"
            local _new_desc
            read -p "  New description: " _new_desc
            _hc[$_pidx]="$_new_desc"
            _pending_log+=("~ Edit :${_hp[$_pidx]} description  →  '${_new_desc}'")
            echo "  ✓ Description updated — select [7] to apply & restart Traefik"

        # ==============================================================
        # [3] Add a component server to a port
        # ==============================================================
        elif [[ "$_sub" == "3" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Add a component server to a port"
            echo "  ----------------------------------------"
            echo ""

            if [[ ${#_hp[@]} -eq 0 ]]; then
                echo "  No ports configured."
                continue
            fi

            echo "  Select a port (or 0 to cancel):"
            echo ""
            local _pn=1
            for _port in "${_hp[@]}"; do
                local _desc="${_hc[$(( _pn - 1 ))]:-}"
                if [[ -n "$_desc" ]]; then
                    printf "  [%d]  :%-6s  (%s)\n" "$_pn" "$_port" "$_desc"
                else
                    printf "  [%d]  :%-6s\n" "$_pn" "$_port"
                fi
                _pn=$(( _pn + 1 ))
            done
            echo ""

            local _pick
            while true; do
                read -p "  Enter number or 0 to cancel [0-${#_hp[@]}]: " _pick
                if [[ "$_pick" == "0" ]]; then break; fi
                if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_hp[@]} )); then break; fi
                echo "  Invalid selection."
            done

            if [[ "$_pick" == "0" ]]; then
                echo "  Cancelled."
                continue
            fi

            local _pidx=$(( _pick - 1 ))
            echo ""
            echo "  Adding backend to port :${_hp[$_pidx]}"
            _hl7_prompt_backend "${_hp[$_pidx]}" "${_hb[$_pidx]}"
            _hb[$_pidx]="${_hb[$_pidx]:+${_hb[$_pidx]},}${_hl7_new_backend}"
            _pending_log+=("+ Add backend ${_hl7_new_backend}  →  port :${_hp[$_pidx]}")
            echo "  ✓ Backend staged — select [7] to apply & restart Traefik"

        # ==============================================================
        # [4] Edit component servers on a port
        # ==============================================================
        elif [[ "$_sub" == "4" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Edit component servers on a port"
            echo "  ----------------------------------------"
            echo ""

            # Build flat list of backends grouped by port
            local -a _hfl_ports=() _hfl_backends=() _hfl_pidx=()
            _hl7_build_flat_backends

            if [[ ${#_hfl_backends[@]} -eq 0 ]]; then
                echo "  No backends configured."
                continue
            fi

            # Step 1: pick backend — grouped by port with separator
            echo "  Select a component server (or 0 to cancel):"
            echo ""
            local _n=1
            local _last_port=""
            for _bi in "${!_hfl_backends[@]}"; do
                local _bp="${_hfl_ports[$_bi]}"
                if [[ "$_bp" != "$_last_port" ]]; then
                    [[ -n "$_last_port" ]] && echo ""
                    echo "  ── Port :${_bp} ──────────────────────────────────────"
                    _last_port="$_bp"
                fi
                printf "  [%d]  %s\n" "$_n" "${_hfl_backends[$_bi]}"
                _n=$(( _n + 1 ))
            done
            echo ""

            local _pick
            while true; do
                read -p "Enter number or 0 to cancel [0-${#_hfl_backends[@]}]: " _pick
                if [[ "$_pick" == "0" ]]; then break; fi
                if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_hfl_backends[@]} )); then break; fi
                echo "  Invalid selection."
            done

            if [[ "$_pick" == "0" ]]; then echo "  Cancelled."; continue; fi

            local _bidx=$(( _pick - 1 ))
            local _old_be="${_hfl_backends[$_bidx]}"
            local _port_for_be="${_hfl_ports[$_bidx]}"
            local _pi="${_hfl_pidx[$_bidx]}"

            # Step 2: action menu
            echo ""
            echo "  ┌─ ${_old_be}  (port :${_port_for_be}) ────────────────────────"
            echo "  │"
            echo "  │  [1] Edit hostname for this backend"

            # Guard remove — only offer if not the last backend for this port
            local _remaining_check
            _remaining_check=$(echo "${_hb[$_pi]}" | tr ',' '\n' | grep -vxF "$_old_be" | paste -sd ',' -)
            if [[ -n "$_remaining_check" ]]; then
                echo "  │  [2] Delete this component server from this port"
            else
                echo "  │  [2] Delete this component server from this port  (n/a — only backend)"
            fi
            echo "  │"
            echo "  │  [0] Cancel"
            echo "  └────────────────────────────────────────────────────"
            echo ""

            local _be_action
            while true; do
                read -p "Enter choice [0-2]: " _be_action
                case "$_be_action" in
                    0|1) break ;;
                    2)
                        if [[ -n "$_remaining_check" ]]; then break
                        else echo "  Option unavailable — only backend on port :${_port_for_be}. Use [5] Remove an HL7 port instead."; fi ;;
                    *) echo "  Please enter 0, 1, or 2." ;;
                esac
            done

            if [[ "$_be_action" == "0" ]]; then echo "  Cancelled."; continue; fi

            if [[ "$_be_action" == "1" ]]; then
                # Edit hostname
                echo ""
                _hl7_prompt_backend "$_port_for_be" "${_hb[$_pi]}" "$_old_be"
                _hl7_replace_backend "$_pi" "$_old_be" "$_hl7_new_backend"
                _pending_log+=("~ Edit backend on :${_port_for_be}  ${_old_be}  →  ${_hl7_new_backend}")
                echo ""
                echo "  ✓ Staged:"
                echo "    Was : ${_old_be}"
                echo "    Now : ${_hl7_new_backend}"
                echo "  Select [7] to apply & restart Traefik"
            else
                # Delete backend
                echo ""
                echo "  Backend to remove : ${_old_be}"
                echo "  From port         : :${_port_for_be}"
                echo ""
                if ! prompt_yn "  Confirm removal?" "n"; then
                    echo "  Removal cancelled."
                    continue
                fi
                _hl7_remove_backend "$_pi" "$_old_be"
                _pending_log+=("- Remove backend ${_old_be}  from port :${_port_for_be}")
                echo "  ✓ Removal staged — select [7] to apply & restart Traefik"
            fi

        # ==============================================================
        # [5] Remove an HL7 port
        # ==============================================================
        elif [[ "$_sub" == "5" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Remove an HL7 port"
            echo "  ----------------------------------------"
            echo ""
            echo "  Select a port to remove (or 0 to cancel):"
            echo ""

            local _pn=1
            for _port in "${_hp[@]}"; do
                local _desc="${_hc[$(( _pn - 1 ))]:-}"
                local _bend="${_hb[$(( _pn - 1 ))]:-}"
                if [[ -n "$_desc" ]]; then
                    printf "  [%d]  :%-6s  (%s) — backends: %s\n" "$_pn" "$_port" "$_desc" "$_bend"
                else
                    printf "  [%d]  :%-6s  backends: %s\n" "$_pn" "$_port" "$_bend"
                fi
                _pn=$(( _pn + 1 ))
            done
            echo ""

            local _pick
            while true; do
                read -p "  Enter number or 0 to cancel [0-${#_hp[@]}]: " _pick
                if [[ "$_pick" == "0" ]]; then break; fi
                if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_hp[@]} )); then break; fi
                echo "  Invalid selection."
            done

            if [[ "$_pick" == "0" ]]; then
                echo "  Cancelled."
                continue
            fi

            local _pidx=$(( _pick - 1 ))
            local _del_port="${_hp[$_pidx]}"
            local _del_desc="${_hc[$_pidx]:-}"

            echo ""
            if [[ -n "$_del_desc" ]]; then
                echo "  Port to remove : :${_del_port}  (${_del_desc})"
            else
                echo "  Port to remove : :${_del_port}"
            fi
            echo "  Backends       : ${_hb[$_pidx]:-none}"
            echo ""
            if ! prompt_yn "  Confirm removal?" "n"; then
                echo "  Removal cancelled."
                continue
            fi

            # Remove from all three arrays
            local -a _new_hp=() _new_hb=() _new_hc=()
            local _ri=0
            for _rport in "${_hp[@]}"; do
                if [[ $_ri -ne $_pidx ]]; then
                    _new_hp+=("$_rport")
                    _new_hb+=("${_hb[$_ri]}")
                    _new_hc+=("${_hc[$_ri]}")
                fi
                _ri=$(( _ri + 1 ))
            done
            _hp=("${_new_hp[@]}")
            _hb=("${_new_hb[@]}")
            _hc=("${_new_hc[@]}")

            _pending_log+=("- Remove port :${_del_port}${_del_desc:+ (${_del_desc})}")
            echo "  ✓ Port :${_del_port} removal staged — select [7] to apply & restart Traefik"

        # ==============================================================
        # [6] Remove all HL7 configuration
        # ==============================================================
        elif [[ "$_sub" == "6" ]]; then
            echo ""
            echo "  ----------------------------------------"
            echo "  Remove all HL7 configuration"
            echo "  ----------------------------------------"
            echo ""
            echo "  This will remove ALL HL7 configuration:"
            local _di=0
            for _dp in "${_hp[@]}"; do
                local _ddesc="${_hc[$_di]:-}"
                if [[ -n "$_ddesc" ]]; then
                    printf "    Port :%-6s  (%s) — %s\n" "$_dp" "$_ddesc" "${_hb[$_di]}"
                else
                    printf "    Port :%-6s  — %s\n" "$_dp" "${_hb[$_di]}"
                fi
                _di=$(( _di + 1 ))
            done
            echo ""
            echo "  Traefik will no longer forward HL7 TCP traffic."
            echo ""
            if ! prompt_yn "  Confirm deletion of entire HL7 configuration?" "n"; then
                echo "  Deletion cancelled."
                continue
            fi
            _hp=()
            _hb=()
            _hc=()
            # Clear the log and replace with a single summary entry
            _pending_log=()
            _pending_log+=("✕ Delete entire HL7 configuration")
            echo "  ✓ HL7 configuration cleared. Select [7] Apply changes & restart Traefik to apply."

        # ==============================================================
        # [8] Done
        # ==============================================================
        elif [[ "$_sub" == "7" ]]; then
            if [[ ${#_hp[@]} -eq 0 ]]; then
                # User has cleared all ports — disable HL7 entirely
                echo ""
                if [[ "$HL7_ENABLED" != "yes" && ${#_original_ep_names[@]} -eq 0 ]]; then
                    echo "  No HL7 configuration to apply."
                    return 0
                fi
                echo "  Disabling HL7 integration..."
                HL7_ENABLED="no"
                HL7_LISTEN_PORTS=""
                HL7_PORT_BACKENDS=""
                HL7_PORT_COMMENTS=""

                # Remove hl7.yml
                if [[ -f "${_dynamic_dir}/hl7.yml" ]]; then
                    rm -f "${_dynamic_dir}/hl7.yml"
                    echo "  ✓ hl7.yml removed"
                fi

                # Strip HL7 entrypoints from traefik.yml
                if [[ ${#_original_ep_names[@]} -gt 0 ]]; then
                    local _tmp_t
                    _tmp_t=$(mktemp)
                    cp "${_traefik_cfg}" "${_tmp_t}"
                    for _oep in "${_original_ep_names[@]}"; do
                        local _tmp_rm
                        _tmp_rm=$(mktemp)
                        awk -v ep="  ${_oep}:" '
                            $0 == ep       { skip=1; next }
                            skip && /^    / { next }
                            skip           { skip=0; print; next }
                            { print }
                        ' "${_tmp_t}" > "${_tmp_rm}"
                        cp "${_tmp_rm}" "${_tmp_t}"
                        rm -f "${_tmp_rm}"
                        echo "  ✓ traefik.yml entrypoint ${_oep} removed"
                    done
                    cp "${_tmp_t}" "${_traefik_cfg}"
                    rm -f "${_tmp_t}"
                fi

                # Push to backup nodes
                if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
                    echo ""
                    echo "  Pushing updated configuration to backup nodes..."
                    for i in "${!BACKUP_NODES[@]}"; do
                        local _node="${BACKUP_NODES[$i]}"
                        local _ip="${BACKUP_IPS[$i]}"
                        echo -n "    ${_node} (${_ip})... "
                        ensure_SCRIPTS_DIR "${_ip}" || true
                        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                            sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                                "rm -f '${_dynamic_dir}/hl7.yml'" 2>/dev/null || true
                        else
                            ssh $SSH_OPTS -l "$CURRENT_USER" "$_ip" \
                                "rm -f '${_dynamic_dir}/hl7.yml'" 2>/dev/null || true
                        fi
                        copy_to_remote_root "${_traefik_cfg}" "${_ip}" "${_traefik_cfg}"
                        echo "✓"
                    done
                fi
 snapshot_config "HL7" "HL7 configuration changed"

                _extend_restart_traefik_all_nodes
                echo -n "  Saving configuration... "
                CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
                KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
                save_config
                echo "✓"
                echo "  ✓ HL7 integration disabled"
                return 0
            fi
            _hl7_apply_changes
            echo "✓ HL7 configuration updated"
            return 0

        # ==============================================================
        # [8] Cancel
        # ==============================================================
        elif [[ "$_sub" == "8" ]]; then
            if [[ ${#_pending_log[@]} -gt 0 ]]; then
                echo ""
                echo "  ⚠️  You have pending changes that have not been applied:"
                for _pl in "${_pending_log[@]}"; do
                    echo "     ${_pl}"
                done
                echo ""
                echo "  [1] Apply changes & restart Traefik, then exit"
                echo "  [2] Discard changes and exit"
                echo "  [3] Go back and keep editing"
                echo ""
                local _cc
                while true; do
                    read -p "Enter choice [1-3]: " _cc
                    case "$_cc" in
                        1|2|3) break ;;
                        *) echo "  Please enter 1, 2, or 3." ;;
                    esac
                done
                case "$_cc" in
                    1)
                        _hl7_apply_changes
                        echo "✓ HL7 configuration updated"
                        return 0
                        ;;
                    2)
                        echo "  Changes discarded."
                        return 0
                        ;;
                    3) continue ;;
                esac
            else
                echo ""
                echo "  Cancelled — no changes applied."
                return 0
            fi
        fi

    done
}

# ==========================================
# deploy_to_backup_nodes — Deploy Traefik + Keepalived to backup nodes
#
# Args: [start_idx]  — only deploy nodes at index >= start_idx (default 0)
#
# Relies on globals: BACKUP_NODES, BACKUP_IPS, BACKUP_INTERFACES,
#   CONFIG_FILE, SCRIPTS_DIR, SSH_OPTS, SUDO_PASS,
#   TRAEFIK_DYNAMIC_DIR (falls back to hardcoded path),
#   DISABLE_DOCKER_REPO (falls back to "no"),
#   proxy/SSL variables, HL7 variables, VRRP, VRID, VIRTUAL_IP, AUTH_PASS
# ==========================================

deploy_to_backup_nodes() {
    local start_idx="${1:-0}"

    # Ensure path and flag vars have sane defaults when called from extend mode
    TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/opt/indica/traefik/config/dynamic}"
    DISABLE_DOCKER_REPO="${DISABLE_DOCKER_REPO:-no}"

    echo ""
    echo ""
    echo ""
    echo ":: Deploying to Backup Nodes"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    for i in "${!BACKUP_NODES[@]}"; do
        # Skip nodes before start_idx (used by extend_add_nodes for new-only deploy)
        [ "$i" -lt "$start_idx" ] && continue

        local node="${BACKUP_NODES[$i]}"
        local ip="${BACKUP_IPS[$i]}"
        local priority=$((100 - (i * 10)))

        echo ""
        echo ":: Backup Node $((i+1))/${#BACKUP_NODES[@]}: $node ($ip)"
        echo "──────────────────────────────────────────────────"
        echo "  Priority: $priority"
        echo ""

        log "Creating installation script for $node..."

write_local_file "$SCRIPTS_DIR/install_backup_${node}.sh" <<'REMOTEINSTALL'
#!/bin/bash
set -e
set -x

echo ""
echo ""
echo ""
echo ":: Installing Traefik on Backup Node"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# Proxy configuration
PROXY="__PROXY__"
PROXY_STRATEGY="__PROXY_STRATEGY__"
INTERNAL_REPO_DOMAINS="__INTERNAL_REPO_DOMAINS__"
CURL_SSL_OPT="__CURL_SSL_OPT__"
APT_SSL_OPT="__APT_SSL_OPT__"
DNF_SSL_OPT="__DNF_SSL_OPT__"

# Setup proxy based on strategy
if [ -n "$PROXY" ]; then
    case "$PROXY_STRATEGY" in
        "all")
            echo "Proxy strategy: ALL (all repos via proxy)"
            export http_proxy="$PROXY"
            export https_proxy="$PROXY"
            export no_proxy="localhost,127.0.0.1"
            PROXY_CURL_OPTS="-x $PROXY"
            APT_PROXY_OPT="-o Acquire::http::Proxy=$PROXY -o Acquire::https::Proxy=$PROXY"
            APT_PROXY_OPT_PROXY="$APT_PROXY_OPT"
            DNF_PROXY_OPT="--setopt=proxy=$PROXY"
            ;;
        "external")
            echo "Proxy strategy: EXTERNAL (external via proxy, internal direct)"
            NO_PROXY_LIST="localhost,127.0.0.1"
            if [ -n "$INTERNAL_REPO_DOMAINS" ]; then
                NO_PROXY_LIST="$NO_PROXY_LIST,$INTERNAL_REPO_DOMAINS"
                echo "Internal domains (no proxy): $INTERNAL_REPO_DOMAINS"
            fi
            export http_proxy="$PROXY"
            export https_proxy="$PROXY"
            export no_proxy="$NO_PROXY_LIST"
            PROXY_CURL_OPTS="-x $PROXY"
            APT_PROXY_OPT="-o Acquire::http::Proxy=$PROXY -o Acquire::https::Proxy=$PROXY"
            APT_PROXY_OPT_PROXY="$APT_PROXY_OPT"
            DNF_PROXY_OPT=""
            ;;
        "none"|*)
            echo "Proxy strategy: NONE (no proxy)"
            unset http_proxy https_proxy
            PROXY_CURL_OPTS=""
            APT_PROXY_OPT=""
            DNF_PROXY_OPT=""
            ;;
    esac
else
    echo "No proxy configured"
    PROXY_CURL_OPTS=""
    APT_PROXY_OPT=""
    DNF_PROXY_OPT=""
fi

if [ -n "$APT_SSL_OPT" ]; then
    APT_PROXY_OPT="$APT_PROXY_OPT $APT_SSL_OPT"
fi
if [ -n "$DNF_SSL_OPT" ]; then
    DNF_PROXY_OPT="$DNF_PROXY_OPT $DNF_SSL_OPT"
fi

echo "=== Installing on $(hostname) ==="

CONFIG_FILE="/tmp/deployment.config"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "✓ Configuration loaded from $CONFIG_FILE"
else
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

_RAW_USER="${SUDO_USER:-$USER}"
_STRIPPED_USER="${_RAW_USER%%@*}"
if id "$_STRIPPED_USER" >/dev/null 2>&1; then
    CURRENT_USER="$_STRIPPED_USER"
else
    CURRENT_USER="$_RAW_USER"
fi
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi
CURRENT_GROUP=$(id -gn "$CURRENT_USER")

echo "Installing as user: $CURRENT_USER"
echo ""

export DEBIAN_FRONTEND=noninteractive
export NODE_ROLE="BACKUP"
export PRIORITY="BACKUP_PRIORITY_PLACEHOLDER"
export INSTALL_KEEPALIVED="yes"
export MULTI_NODE_DEPLOYMENT="no"
export BACKUP_NODE_INSTALL="yes"

# Install prerequisites
echo "Installing prerequisites..."
if command -v apt-get &>/dev/null; then
    sudo -E apt-get $APT_PROXY_OPT_PROXY update -qq
    sudo -E apt-get $APT_PROXY_OPT_PROXY install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release wget nano
elif command -v dnf &>/dev/null; then
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y ca-certificates curl dnf-plugins-core gnupg2 wget nano iproute python3 jq; then
        sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y ca-certificates curl dnf-plugins-core gnupg2 wget nano iproute python3 jq --nobest
    fi
fi

# Install container-selinux for RHEL/CentOS
if command -v dnf &>/dev/null && ! rpm -q container-selinux &>/dev/null; then
    echo "Installing container-selinux..."
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y container-selinux; then
        if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y container-selinux --nobest; then
            echo "Trying Rocky Linux repos..."
            if curl $PROXY_CURL_OPTS $CURL_SSL_OPT -o /tmp/rocky-repos.rpm \
                https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/r/rocky-repos-9.5-2.el9.noarch.rpm 2>/dev/null; then
                rpm -ivh /tmp/rocky-repos.rpm 2>/dev/null || true
                dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True --enablerepo=rocky-baseos install -y container-selinux 2>/dev/null || true
                rm -f /tmp/rocky-repos.rpm
            fi
        fi
    fi
    if rpm -q container-selinux &>/dev/null; then
        echo "✓ container-selinux installed"
    else
        echo "⚠️  WARNING: container-selinux not installed (Docker may fail)"
    fi
fi

# Install Docker
echo "Installing Docker..."
if command -v apt-get &>/dev/null; then
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        echo "Adding Docker repository..."
        install -m 0755 -d /etc/apt/keyrings
        curl $PROXY_CURL_OPTS $CURL_SSL_OPT -fsSL \
            https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo -E apt-get $APT_PROXY_OPT_PROXY update -qq
    fi
    echo "Installing Docker packages..."
    sudo -E apt-get $APT_PROXY_OPT_PROXY install -y docker-ce docker-ce-cli containerd.io
elif command -v dnf &>/dev/null; then
    if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
        echo "Downloading Docker repository..."
        if curl $PROXY_CURL_OPTS $CURL_SSL_OPT -fsSL \
            https://download.docker.com/linux/centos/docker-ce.repo \
            -o /tmp/docker-ce.repo; then
            mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
            echo "✓ Docker repository added"
        else
            echo "ERROR: Failed to download Docker repository"
            exit 1
        fi
    fi
    echo "Installing Docker packages..."
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y docker-ce docker-ce-cli containerd.io; then
        sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y docker-ce docker-ce-cli containerd.io --nobest
    fi
else
    echo "ERROR: No supported package manager found (apt or dnf)"
    exit 1
fi

echo "✓ Docker installed successfully"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker installation failed - docker command not found"
    exit 1
fi
docker --version

# Configure Docker proxy if needed
if [ -n "$PROXY" ]; then
    echo "Configuring Docker daemon to use proxy..."
    mkdir -p /etc/docker
    if [ -f "/etc/docker/daemon.json" ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi
    tee /etc/docker/daemon.json > /dev/null <<DOCKEREOF
{
  "proxies": {
    "http-proxy": "$PROXY",
    "https-proxy": "$PROXY",
    "no-proxy": "localhost,127.0.0.1"
  }
}
DOCKEREOF
    echo "✓ Docker proxy configured in daemon.json"
fi

echo "Starting Docker..."
systemctl enable docker
systemctl stop docker 2>/dev/null || true
sleep 2
systemctl start docker
sleep 3

if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker failed to start"
    exit 1
fi
echo "✓ Docker is running"

if ! groups "$CURRENT_USER" | grep -q docker; then
    usermod -aG docker "$CURRENT_USER"
fi

# Disable Docker repository based on master's configuration
DISABLE_DOCKER_REPO="__DISABLE_DOCKER_REPO__"
if [ "$DISABLE_DOCKER_REPO" = "yes" ]; then
    echo "Disabling Docker repositories (as configured on master node)..."
    if command -v apt-get &>/dev/null; then
        if [ -f /etc/apt/sources.list.d/docker.list ]; then
            mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled 2>/dev/null || true
            mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled 2>/dev/null || true
            echo "✓ Docker repository disabled"
        fi
    elif command -v dnf &>/dev/null; then
        if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
            dnf config-manager --set-disabled docker-ce-stable 2>/dev/null || \
                sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
            echo "✓ Docker repository disabled"
        fi
    fi
else
    echo "Docker repository kept enabled (as configured on master node)"
fi

# Create Traefik directories
mkdir -p /opt/indica/traefik/{certs,config,logs}
mkdir -p /opt/indica/traefik/config/dynamic
chown -R root:root /opt/indica

TRAEFIK_CONFIG_FILE="/opt/indica/traefik/config/traefik.yml"
TRAEFIK_DYNAMIC_DIR="/opt/indica/traefik/config/dynamic"
TRAEFIK_DYNAMIC_FILE="${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"
DOCKER_COMPOSE_FILE="/opt/indica/traefik/docker-compose.yaml"

# Guard against incorrectly typed paths
for _p in "$TRAEFIK_CONFIG_FILE" "$TRAEFIK_DYNAMIC_FILE" "$DOCKER_COMPOSE_FILE" \
          "/opt/indica/traefik/config/clinical_conf.yml"; do
    if [[ -d "$_p" ]]; then
        rm -rf "$_p" || { echo "Failed to remove directory $_p"; exit 1; }
    fi
done
if [[ -f "$TRAEFIK_DYNAMIC_DIR" ]]; then
    rm -f "$TRAEFIK_DYNAMIC_DIR" || exit 1
fi
mkdir -p "$TRAEFIK_DYNAMIC_DIR" || { echo "Failed to create dynamic config directory"; exit 1; }

if [[ -d "$CERT_FILE" ]]; then rm -rf "$CERT_FILE" || exit 1; fi
if [[ -d "$KEY_FILE"  ]]; then rm -rf "$KEY_FILE"  || exit 1; fi

# Copy certificates
if [ -n "$SSL_CERT_CONTENT" ] && [ -n "$SSL_KEY_CONTENT" ]; then
    echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
    echo "$SSL_KEY_CONTENT" > "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
fi

# Write custom CA certificate if configured
if [ "$USE_CUSTOM_CA" = "yes" ] && [ -n "$CUSTOM_CA_CERT_CONTENT" ]; then
    if [[ -d "/opt/indica/traefik/certs/customca.crt" ]]; then
        rm -rf /opt/indica/traefik/certs/customca.crt || exit 1
    fi
    echo "$CUSTOM_CA_CERT_CONTENT" > /opt/indica/traefik/certs/customca.crt
    chmod 644 /opt/indica/traefik/certs/customca.crt
    echo "✓ Custom CA certificate written"
fi

# Create docker-compose.yaml
cat > /opt/indica/traefik/docker-compose.yaml <<'DOCKERCOMPOSE'
services:
  traefik:
    image: docker.io/library/traefik:latest
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
      - label=type:container_runtime_t
    cap_add:
      - NET_BIND_SERVICE
    network_mode: "host"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./config/dynamic:/dynamic:ro
      - ./certs/cert.crt:/certs/cert.crt:ro
      - ./certs/server.key:/certs/server.key:ro
      - ./logs:/var/log
DOCKERCOMPOSE

if [ "$USE_CUSTOM_CA" = "yes" ] && [ -n "$CUSTOM_CA_CERT_CONTENT" ]; then
    sed -i '/      - \.\/certs\/server\.key:\/certs\/server\.key:ro/a\      - ./certs/customca.crt:/certs/customca.crt:ro' /opt/indica/traefik/docker-compose.yaml
    echo "✓ Custom CA volume mount added to docker-compose.yaml"
fi

# Create traefik.yml
cat > /opt/indica/traefik/config/traefik.yml <<'TRAEFIKCONF'
entryPoints:
  http:
    address: ':80'
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
    http:
      redirections:
        entryPoint:
          to: 'https'
          scheme: 'https'
      encodedCharacters:
        allowEncodedBackSlash: true
        allowEncodedSemicolon: true
        allowEncodedPercent: true
        allowEncodedHash: true
  https:
    address: ':443'
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
    http:
      encodedCharacters:
        allowEncodedBackSlash: true
        allowEncodedSemicolon: true
        allowEncodedPercent: true
        allowEncodedHash: true
  ping:
    address: ':8800'
TRAEFIKCONF

# Append HL7 entrypoints if integration is enabled
HL7_ENABLED_FLAG="HL7_ENABLED_PLACEHOLDER"
HL7_LISTEN_PORTS_VAL="HL7_PORTS_PLACEHOLDER"
HL7_PORT_COMMENTS_VAL="HL7_COMMENTS_PLACEHOLDER"
if [ "$HL7_ENABLED_FLAG" = "yes" ]; then
    _idx=0
    IFS='|' read -ra _b_ports    <<< "$HL7_LISTEN_PORTS_VAL"
    IFS='|' read -ra _b_comments <<< "$HL7_PORT_COMMENTS_VAL"
    for _b_port in "${_b_ports[@]}"; do
        _b_ep_name="hl7"
        [ "$_idx" -gt 0 ] && _b_ep_name="hl7-${_b_port}"
        _b_comment="${_b_comments[$_idx]:-}"
        _b_addr="    address: ':${_b_port}'"
        [ -n "$_b_comment" ] && _b_addr="${_b_addr} # ${_b_comment}"
        cat >> /opt/indica/traefik/config/traefik.yml <<HLEOF
  ${_b_ep_name}:
${_b_addr}
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
HLEOF
        _idx=$(( _idx + 1 ))
    done
fi

cat >> /opt/indica/traefik/config/traefik.yml <<'TRAEFIKCONF2'
ping:
  entryPoint: 'ping'

#log:
#  level: DEBUG
#  filePath: "/var/log/traefik.log"

#accessLog:
#  filePath: "/var/log/access.log"
#  bufferingSize: 100

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /dynamic
    watch: true
# experimental:
#   localPlugins:
#     traefik_is_admin:
#       moduleName: gitlab.com/indica1/traefik-is-admin
TRAEFIKCONF2

# Copy dynamic config files from /tmp
if [ -f "/tmp/clinical_conf.yml" ]; then
    cp /tmp/clinical_conf.yml "${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"
    echo "✓ clinical_conf.yml installed into dynamic directory"
fi
if [ -f "/tmp/hl7.yml" ]; then
    cp /tmp/hl7.yml "${TRAEFIK_DYNAMIC_DIR}/hl7.yml"
    echo "✓ hl7.yml installed into dynamic directory"
fi
if [ -f "/tmp/diagnostics_monitor.yml" ]; then
    cp /tmp/diagnostics_monitor.yml "${TRAEFIK_DYNAMIC_DIR}/diagnostics_monitor.yml"
    chmod 640 "${TRAEFIK_DYNAMIC_DIR}/diagnostics_monitor.yml"
    echo "✓ diagnostics_monitor.yml installed into dynamic directory"
fi

chown -R root:root /opt/indica

echo "Starting Traefik..."
# Use --pull never if image already exists locally, --pull always otherwise
if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "traefik"; then
    docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate --pull never
else
    docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate --pull always
fi
sleep 5

# Install Keepalived
echo "Installing Keepalived..."
if command -v apt-get &>/dev/null; then
    sudo -E apt-get $APT_PROXY_OPT_PROXY install -y keepalived
elif command -v dnf &>/dev/null; then
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y keepalived; then
        sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y keepalived --nobest
    fi
fi

if ! getent group keepalived_script > /dev/null 2>&1; then
    groupadd -r keepalived_script
fi
if ! id "keepalived_script" &>/dev/null; then
    useradd -r -s /sbin/nologin -G keepalived_script -g docker -M keepalived_script
fi

tee /bin/indica_service_check.sh > /dev/null <<'HEALTHCHECK'
#!/bin/bash
if curl -fs http://localhost:8800/ping > /dev/null; then
  exit 0
else
  exit 1
fi
HEALTHCHECK
chmod +x /bin/indica_service_check.sh
chown keepalived_script:docker /bin/indica_service_check.sh

# Auto-detect / apply network interface
BACKUP_NODE_IP="BACKUP_NODE_IP_PLACEHOLDER"
BACKUP_NODE_INTERFACE="BACKUP_INTERFACE_PLACEHOLDER"

echo "Using configured interface: $BACKUP_NODE_INTERFACE"

if ! ip link show "$BACKUP_NODE_INTERFACE" &>/dev/null; then
    echo "⚠️  WARNING: Interface $BACKUP_NODE_INTERFACE does not exist!"
    ip -o link show | awk '{print "  - " $2}' | sed 's/:$//'
    echo ""
    echo "Attempting auto-detection..."
    DETECTED_INTERFACE=$(ip -o addr show | grep "inet $BACKUP_NODE_IP" | awk '{print $2}' | head -1)
    if [ -n "$DETECTED_INTERFACE" ]; then
        echo "✓ Auto-detected: $DETECTED_INTERFACE"
        BACKUP_NODE_INTERFACE="$DETECTED_INTERFACE"
    else
        echo "❌ Auto-detection failed"
    fi
fi

tee /etc/keepalived/keepalived.conf > /dev/null <<KEEPALIVEDCONF
global_defs {
  enable_script_security
  script_user keepalived_script
  max_auto_priority
}
vrrp_script check_traefik {
  script "/bin/indica_service_check.sh"
  interval 2
  weight 50
}
vrrp_instance $VRRP {
  state BACKUP
  interface $BACKUP_NODE_INTERFACE
  virtual_router_id $VRID
  priority BACKUP_PRIORITY_PLACEHOLDER
  virtual_ipaddress {
    $VIRTUAL_IP
  }
  track_script {
    check_traefik
  }
  authentication {
    auth_type PASS
    auth_pass $AUTH_PASS
  }
}
KEEPALIVEDCONF

chmod 640 /etc/keepalived/keepalived.conf

echo "Starting Keepalived..."
systemctl enable keepalived
systemctl start keepalived
systemctl restart keepalived

echo ""
echo "✓ Installation complete on backup node"
echo "✓ Traefik: Running"
echo "✓ Keepalived: Running (BACKUP, priority BACKUP_PRIORITY_PLACEHOLDER)"
REMOTEINSTALL

        # ---- Substitute all placeholders ----

        # Compute proxy value
        local PROXY_VAL=""
        if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
            if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
                local ENCODED_PASS_DEP
                ENCODED_PASS_DEP=$(url_encode_password "${PROXY_PASSWORD}")
                PROXY_VAL="${PROXY_USER}:${ENCODED_PASS_DEP}@${PROXY_HOST}:${PROXY_PORT}"
            else
                PROXY_VAL="${PROXY_HOST}:${PROXY_PORT}"
            fi
        fi

        # Pass detected internal domains to backup node
        local _deploy_internal_domains="${INTERNAL_REPO_DOMAINS}"
        if [ "$PROXY_STRATEGY" = "external" ] && [ -n "${no_proxy:-}" ]; then
            local _extra_domains
            _extra_domains=$(echo "${no_proxy}" | tr ',' '\n' | \
                grep -v '^localhost$\|^127\.0\.0\.1$\|^::1$\|^\.local$' | \
                tr '\n' ',' | sed 's/,$//')
            if [ -z "${_deploy_internal_domains}" ] && [ -n "${_extra_domains}" ]; then
                _deploy_internal_domains="${_extra_domains}"
            fi
        fi

        sed -i "s/BACKUP_PRIORITY_PLACEHOLDER/$priority/g"                    "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_NODE_IP_PLACEHOLDER/$ip/g"                            "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_INTERFACE_PLACEHOLDER/${BACKUP_INTERFACES[$i]}/g"     "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__PROXY__|${PROXY_URL:-}|g"                                  "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__PROXY_STRATEGY__|${PROXY_STRATEGY}|g"                      "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__INTERNAL_REPO_DOMAINS__|${_deploy_internal_domains}|g"     "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__CURL_SSL_OPT__|${CURL_SSL_OPT}|g"                          "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__APT_SSL_OPT__|${APT_SSL_OPT}|g"                            "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__DNF_SSL_OPT__|${DNF_SSL_OPT}|g"                            "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__WGET_SSL_OPT__|${WGET_SSL_OPT}|g"                          "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__DISABLE_DOCKER_REPO__|${DISABLE_DOCKER_REPO}|g"            "$SCRIPTS_DIR/install_backup_${node}.sh"

        # HL7 values contain '|' — use python3 to avoid sed delimiter conflicts
        HL7_ENABLED_VAL="$HL7_ENABLED" \
        HL7_PORTS_VAL="$HL7_LISTEN_PORTS" \
        HL7_COMMENTS_VAL="$HL7_PORT_COMMENTS" \
        python3 - "$SCRIPTS_DIR/install_backup_${node}.sh" <<'PYEOF'
import os, sys
path = sys.argv[1]
content = open(path).read()
content = content.replace('HL7_ENABLED_PLACEHOLDER',  os.environ['HL7_ENABLED_VAL'])
content = content.replace('HL7_PORTS_PLACEHOLDER',    os.environ['HL7_PORTS_VAL'])
content = content.replace('HL7_COMMENTS_PLACEHOLDER', os.environ['HL7_COMMENTS_VAL'])
open(path, 'w').write(content)
PYEOF

        chmod 644 "$SCRIPTS_DIR/install_backup_${node}.sh"

        # ---- Stage dynamic config files for transfer ----
        if [ -f "${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml" ]; then
            cp "${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml" /tmp/clinical_conf.yml
        fi
        if [ -f "${TRAEFIK_DYNAMIC_DIR}/hl7.yml" ]; then
            cp "${TRAEFIK_DYNAMIC_DIR}/hl7.yml" /tmp/hl7.yml
        fi
        if [ -f "${TRAEFIK_DYNAMIC_DIR}/diagnostics_monitor.yml" ]; then
            cp "${TRAEFIK_DYNAMIC_DIR}/diagnostics_monitor.yml" /tmp/diagnostics_monitor.yml
        fi

        ensure_SCRIPTS_DIR "$ip" || true

        echo "Copying files to $node..."
        copy_to_remote "$CONFIG_FILE" "$ip" "/tmp/deployment.config" || true
        if [ -f "/tmp/clinical_conf.yml" ]; then
            copy_to_remote "/tmp/clinical_conf.yml" "$ip" "/tmp/clinical_conf.yml" || true
        fi
        if [ -f "/tmp/hl7.yml" ]; then
            copy_to_remote "/tmp/hl7.yml" "$ip" "/tmp/hl7.yml" || true
        fi
        if [ -f "/tmp/diagnostics_monitor.yml" ]; then
            copy_to_remote "/tmp/diagnostics_monitor.yml" "$ip" "/tmp/diagnostics_monitor.yml" || true
        fi
        copy_to_remote "$SCRIPTS_DIR/install_backup_${node}.sh" "$ip" "$SCRIPTS_DIR/install_backup.sh" || true

        echo "Starting installation on $node..."
        echo "This may take 5-10 minutes..."
        echo ""

        execute_remote_script "$ip" "$SCRIPTS_DIR/install_backup.sh"

        rm -f "$SCRIPTS_DIR/install_backup_${node}.sh" /tmp/clinical_conf.yml /tmp/hl7.yml /tmp/diagnostics_monitor.yml

        # ---- Verify deployment ----
        echo ""
        echo "Verifying deployment on $node..."

        local _verify_docker _verify_kv
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            _verify_docker=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
            _verify_kv=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
        else
            _verify_docker=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
            _verify_kv=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
        fi

        if echo "$_verify_docker" | grep -q "traefik"; then
            echo "✓ Traefik container is running on $node"
        else
            echo "⚠️  Warning: Could not verify Traefik on $node"
        fi

        if [ "$_verify_kv" = "active" ]; then
            echo "✓ Keepalived is running on $node"
        else
            echo "⚠️  Warning: Could not verify Keepalived on $node"
        fi

        echo ""
        echo "✓ Deployment to $node completed"
    done

    cleanup_remote_scripts_dirs

    echo ""
    echo ""
    echo ""
    echo ":: ✓ All backup nodes deployed successfully"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
}

# ==========================================
# Extend Mode — Main dispatcher
# ==========================================

# ==========================================
# Extend Mode — Option 3: Remove a Traefik Node
# ==========================================

extend_remove_nodes() {
    echo ""
    echo ""
    echo ""
    echo ":: Remove a Traefik Node"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    if [[ "$MULTI_NODE_DEPLOYMENT" != "yes" || ${#BACKUP_NODES[@]} -eq 0 ]]; then
        echo "  No backup nodes configured — nothing to remove."
        return 0
    fi

    echo "  Current nodes:"
    echo "  Master : ${MASTER_HOSTNAME} (${MASTER_IP}) — cannot be removed here"
    for i in "${!BACKUP_NODES[@]}"; do
        local p=$(( 100 - (i * 10) ))
        printf "  [%d] Backup %d: %-20s (%s) — Priority %d\n" \
            "$(( i + 1 ))" "$(( i + 1 ))" "${BACKUP_NODES[$i]}" "${BACKUP_IPS[$i]}" "$p"
    done
    echo ""

    # Selection — allow comma-separated for multi-remove
    local -a _to_remove_idx=()
    while true; do
        read -p "  Enter node number(s) to remove, comma-separated (or 0 to cancel): " _sel
        if [[ "$_sel" == "0" ]]; then
            echo "  Cancelled."
            return 0
        fi
        local _valid=true
        local -A _seen=()
        _to_remove_idx=()
        IFS=',' read -ra _picks <<< "$_sel"
        for _p in "${_picks[@]}"; do
            _p="${_p// /}"
            if [[ ! "$_p" =~ ^[0-9]+$ ]] || (( _p < 1 || _p > ${#BACKUP_NODES[@]} )); then
                echo "  Invalid selection: '${_p}'. Enter numbers 1–${#BACKUP_NODES[@]}."
                _valid=false
                break
            fi
            local _idx=$(( _p - 1 ))
            if [[ -z "${_seen[$_idx]+x}" ]]; then
                _seen[$_idx]=1
                _to_remove_idx+=("$_idx")
            fi
        done
        if [[ "$_valid" == true && ${#_to_remove_idx[@]} -gt 0 ]]; then break; fi
    done

    # Sort descending so array removals don't shift indices
    IFS=$'\n' _to_remove_idx=($(printf '%s\n' "${_to_remove_idx[@]}" | sort -rn))
    unset IFS

    # Show what will be cleaned
    echo ""
    echo "  Nodes to remove:"
    for _idx in "${_to_remove_idx[@]}"; do
        echo "    - ${BACKUP_NODES[$_idx]} (${BACKUP_IPS[$_idx]})"
    done
    echo ""
    echo "  This will:"
    echo "    - Stop and remove Traefik on each node"
    echo "    - Stop, disable and remove Keepalived on each node"
    echo "    - Remove /opt/indica/traefik on each node"
    echo "    - Remove the node(s) from the deployment configuration"
    echo "  You will be asked separately whether to also uninstall the"
    echo "  Keepalived and Docker packages from the removed node(s)."
    echo ""

    # Package removal options — match what --clean offers
    local _uninstall_keepalived=false
    local _uninstall_docker=false

    echo "  Package Removal Options:"
    echo ""
    if prompt_yn "  Uninstall Keepalived package on removed node(s)?" "y"; then
        _uninstall_keepalived=true
    fi

    if prompt_yn "  Uninstall Docker on removed node(s)?" "n"; then
        echo ""
        echo "  ⚠️  This will remove Docker and ALL containers/images on the removed node(s)!"
        if prompt_yn "  Are you absolutely sure?" "n"; then
            _uninstall_docker=true
        fi
    fi
    echo ""

    # Check if removing all backups
    local _removing_all=false
    if [[ ${#_to_remove_idx[@]} -eq ${#BACKUP_NODES[@]} ]]; then
        _removing_all=true
        echo "  ⚠️  You are removing ALL backup nodes."
        echo "     The deployment will revert to single-node."
        echo "     You will be asked whether to keep Keepalived running on"
        echo "     the master — recommended if your domain DNS uses the VIP."
        echo ""
    fi

    if ! prompt_yn "  Confirm removal?" "n"; then
        echo "  Removal cancelled."
        return 0
    fi

    # Get sudo password for remote operations if not already set
    if [[ -z "${SUDO_PASS:-}" ]]; then
        echo ""
        read -s -p "  Enter YOUR sudo password for remote hosts: " SUDO_PASS
        echo ""
        export SUDO_PASS
        SSH_OPTS="${SSH_OPTS:--i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no}"
    fi

    # Clean each node remotely
    for _idx in "${_to_remove_idx[@]}"; do
        local _node="${BACKUP_NODES[$_idx]}"
        local _ip="${BACKUP_IPS[$_idx]}"

        echo ""
        echo "  ----------------------------------------"
        echo "  Cleaning ${_node} (${_ip})..."
        echo "  ----------------------------------------"

        write_local_file "$SCRIPTS_DIR/cleanup_remote_${_node}.sh" <<'REMOVECLEANUP'
#!/bin/bash
set -e

echo "Starting cleanup on $(hostname)..."

DOCKER_ACCESSIBLE=true
if ! docker ps &>/dev/null 2>&1; then
    if sg docker -c "docker ps" &>/dev/null 2>&1; then
        DOCKER_ACCESSIBLE="sg"
    else
        DOCKER_ACCESSIBLE=false
    fi
fi

cleanup_docker_cmd() {
    if [ "$DOCKER_ACCESSIBLE" = "true" ]; then
        docker "$@"
    elif [ "$DOCKER_ACCESSIBLE" = "sg" ]; then
        sg docker -c "docker $*"
    else
        return 1
    fi
}

echo -n "Stopping Traefik... "
if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -q -f name=traefik 2>/dev/null | grep -q .; then
    cleanup_docker_cmd stop traefik 2>/dev/null || true
    echo "✓"
else
    echo "Not running"
fi

echo -n "Removing Traefik container... "
if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd ps -a -q -f name=traefik 2>/dev/null | grep -q .; then
    cleanup_docker_cmd rm traefik 2>/dev/null || true
    echo "✓"
else
    echo "Not found"
fi

echo -n "Removing Traefik directories... "
if [ -d "/opt/indica/traefik" ]; then
    rm -rf /opt/indica/traefik
    echo "✓"
else
    echo "Not found"
fi
if [ -d "/opt/indica" ] && [ -z "$(ls -A /opt/indica 2>/dev/null)" ]; then
    rm -rf /opt/indica 2>/dev/null || true
fi

echo -n "Stopping Keepalived... "
if systemctl is-active --quiet keepalived 2>/dev/null; then
    systemctl stop keepalived 2>/dev/null || true
    echo "✓"
else
    echo "Not running"
fi

echo -n "Disabling Keepalived... "
if systemctl is-enabled --quiet keepalived 2>/dev/null; then
    systemctl disable keepalived 2>/dev/null || true
    echo "✓"
else
    echo "Not enabled"
fi

if [[ "UNINSTALL_KEEPALIVED_FLAG" == "true" ]]; then
    echo -n "Uninstalling Keepalived package... "
    if command -v keepalived &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get -y purge keepalived 2>/dev/null || true
            apt-get -y autoremove 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf -y remove keepalived 2>/dev/null || true
        fi
        echo "✓"
    else
        echo "Not installed"
    fi
fi

echo -n "Removing Keepalived config... "
rm -f /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak* 2>/dev/null || true
echo "✓"

echo -n "Removing health check script... "
rm -f /bin/indica_service_check.sh 2>/dev/null || true
echo "✓"

echo -n "Removing keepalived_script user/group... "
id "keepalived_script" &>/dev/null && userdel keepalived_script 2>/dev/null || true
getent group keepalived_script > /dev/null 2>&1 && groupdel keepalived_script 2>/dev/null || true
echo "✓"

if [[ "UNINSTALL_DOCKER_FLAG" == "true" ]]; then
    echo -n "Stopping Docker... "
    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    echo "✓"

    echo -n "Uninstalling Docker... "
    if command -v apt-get &>/dev/null; then
        apt-get -y purge docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
        apt-get -y autoremove 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
    elif command -v dnf &>/dev/null; then
        dnf -y remove docker-ce docker-ce-cli containerd.io 2>/dev/null || true
    fi
    echo "✓"

    echo -n "Removing Docker data... "
    rm -rf /var/lib/docker 2>/dev/null || true
    rm -rf /var/lib/containerd 2>/dev/null || true
    rm -rf /etc/docker/daemon.json 2>/dev/null || true
    echo "✓"
fi

echo "✓ Cleanup complete on $(hostname)"
REMOVECLEANUP
        chmod 644 "$SCRIPTS_DIR/cleanup_remote_${_node}.sh"
        sed -i "s/UNINSTALL_KEEPALIVED_FLAG/${_uninstall_keepalived}/g" \
            "$SCRIPTS_DIR/cleanup_remote_${_node}.sh"
        sed -i "s/UNINSTALL_DOCKER_FLAG/${_uninstall_docker}/g" \
            "$SCRIPTS_DIR/cleanup_remote_${_node}.sh"

        ensure_SCRIPTS_DIR "${_ip}" || true
        copy_to_remote "$SCRIPTS_DIR/cleanup_remote_${_node}.sh" "${_ip}" \
            "$SCRIPTS_DIR/cleanup_node.sh" || true
        execute_remote_script "${_ip}" "$SCRIPTS_DIR/cleanup_node.sh" || true
        rm -f "$SCRIPTS_DIR/cleanup_remote_${_node}.sh"

        echo "  ✓ ${_node} cleaned"
    done

    # Remove nodes from arrays (already sorted descending so indices stay valid)
    for _idx in "${_to_remove_idx[@]}"; do
        local _removed_node="${BACKUP_NODES[$_idx]}"
        unset 'BACKUP_NODES[$_idx]'
        unset 'BACKUP_IPS[$_idx]'
        unset 'BACKUP_INTERFACES[$_idx]'
    done
    # Re-index arrays
    BACKUP_NODES=("${BACKUP_NODES[@]}")
    BACKUP_IPS=("${BACKUP_IPS[@]}")
    BACKUP_INTERFACES=("${BACKUP_INTERFACES[@]}")
    BACKUP_NODE_COUNT=${#BACKUP_NODES[@]}

    # If all backups removed → revert to single-node
    if [[ "$_removing_all" == "true" ]]; then
        MULTI_NODE_DEPLOYMENT="no"
        MASTER_HOSTNAME=""
        MASTER_IP=""

        echo ""
        echo "  All backup nodes removed — deployment is now single-node."
        echo ""
        echo "  Keepalived is still running on this master with Virtual IP: ${VIRTUAL_IP}"
        echo "  If your domain DNS points to this VIP, keeping Keepalived running"
        echo "  ensures traffic continues to reach this server."
        echo ""

        local _keep_kv=true
        if prompt_yn "  Keep Keepalived running on master (recommended if VIP is in DNS)?" "y"; then
            _keep_kv=true
            echo "  ✓ Keepalived left running — VIP ${VIRTUAL_IP} remains active on master"
        else
            _keep_kv=false
            echo ""
            echo "  Stopping and removing Keepalived on master..."

            echo -n "  Stopping Keepalived... "
            systemctl stop keepalived 2>/dev/null && echo "✓" || echo "Not running"

            echo -n "  Disabling Keepalived... "
            systemctl disable keepalived 2>/dev/null && echo "✓" || echo "Not enabled"

            echo -n "  Removing Keepalived config... "
            rm -f /etc/keepalived/keepalived.conf \
                       /etc/keepalived/keepalived.conf.bak* 2>/dev/null || true
            echo "✓"

            echo -n "  Removing health check script... "
            rm -f /bin/indica_service_check.sh 2>/dev/null || true
            echo "✓"

            echo -n "  Removing keepalived_script user/group... "
            id "keepalived_script" &>/dev/null && userdel keepalived_script 2>/dev/null || true
            getent group keepalived_script > /dev/null 2>&1 \
                && groupdel keepalived_script 2>/dev/null || true
            echo "✓"

            # Clear Keepalived-related config vars only if fully removed
            VIRTUAL_IP=""
            VRID=""
            AUTH_PASS=""
            VRRP=""
            NETWORK_INTERFACE=""

            echo "  ✓ Keepalived removed from master"
        fi
    snapshot_config "NODE_REMOVE" "Backup node(s) removed"
    fi

    # Clean up remote temp dirs and save
    cleanup_remote_scripts_dirs
    CERT_FILE="${CERT_FILE:-/opt/indica/traefik/certs/cert.crt}"
    KEY_FILE="${KEY_FILE:-/opt/indica/traefik/certs/server.key}"
    save_config

    echo ""
    if [[ "$_removing_all" == "true" ]]; then
        echo "  ✓ All backup nodes removed — deployment is now single-node"
    else
        echo "  ✓ Node(s) removed. Remaining backup nodes:"
        if [[ ${#BACKUP_NODES[@]} -eq 0 ]]; then
            echo "    (none)"
        else
            for i in "${!BACKUP_NODES[@]}"; do
                echo "    Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
            done
        fi
    fi
    echo "  ✓ Configuration saved"
}

# ==========================================
# Extend Mode — Nodes: unified add/remove menu
# ==========================================

# ==========================================
# Extend Mode — Option: Replace a Backup Node
# ==========================================

extend_replace_node() {
    echo ""
    echo ""
    echo ""
    echo ":: Replace a Backup Node"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo "  Use this option when a backup node has failed and cannot be"
    echo "  recovered. The dead node will be removed from the deployment"
    echo "  and replaced with a new server."
    echo ""

    if [[ "$MULTI_NODE_DEPLOYMENT" != "yes" || ${#BACKUP_NODES[@]} -eq 0 ]]; then
        echo "  No backup nodes configured — nothing to replace."
        return 0
    fi

    # Step 1 — pick node to replace
    echo "  Select the node to replace:"
    echo ""
    for i in "${!BACKUP_NODES[@]}"; do
        printf "  [%d] %s (%s)\n" "$(( i + 1 ))" "${BACKUP_NODES[$i]}" "${BACKUP_IPS[$i]}"
    done
    echo "  [0] Cancel"
    echo ""

    local _pick
    while true; do
        read -p "Enter number or 0 to cancel [0-${#BACKUP_NODES[@]}]: " _pick
        if [[ "$_pick" == "0" ]]; then echo "  Cancelled."; return 0; fi
        if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#BACKUP_NODES[@]} )); then break; fi
        echo "  Invalid selection."
    done

    local _ridx=$(( _pick - 1 ))
    local _old_node="${BACKUP_NODES[$_ridx]}"
    local _old_ip="${BACKUP_IPS[$_ridx]}"
    local _old_iface="${BACKUP_INTERFACES[$_ridx]}"
    local _priority=$(( 100 - (_ridx * 10) ))

    echo ""
    echo "  Replacing: ${_old_node} (${_old_ip})"
    echo ""

    # Step 2 — get new node details
    local _new_node=""
    while true; do
        read -p "  New node hostname: " _new_node
        _new_node="${_new_node// /}"
        if [[ -n "$_new_node" ]]; then break; fi
        echo "  Error: Hostname cannot be empty."
    done

    local _new_ip=""
    while true; do
        read -p "  New node IP address: " _new_ip
        _new_ip="${_new_ip// /}"
        if validate_ip "$_new_ip"; then break; fi
        echo "  Error: Invalid IPv4 address."
    done

    echo ""
    echo "  ┌─ Replacement Summary ──────────────────────────────────────────"
    printf "  │  %-10s  Old: %-28s New: %s\n" "Hostname" "$_old_node" "$_new_node"
    printf "  │  %-10s  Old: %-28s New: %s\n" "IP" "$_old_ip" "$_new_ip"
    printf "  │  %-10s  %s\n" "Priority" "$_priority (unchanged)"
    echo "  └────────────────────────────────────────────────────────────────"
    echo ""

    if ! prompt_yn "  Proceed with replacement?" "n"; then
        echo "  Cancelled."
        return 0
    fi

    # Step 3 — attempt cleanup on old node (best effort — may be unreachable)
    echo ""
    echo "  Attempting cleanup on old node (${_old_node})..."
    echo "  (This will be skipped if the node is unreachable)"
    echo ""

    local _reachable=false
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_old_ip" \
        "echo ok" >/dev/null 2>&1; then
        _reachable=true
    fi

    if [[ "$_reachable" == true ]]; then
        echo -n "  ${_old_node} is reachable — running cleanup... "
        write_local_file "$SCRIPTS_DIR/cleanup_replace_${_old_node}.sh" <<'REPLACECLEANUP'
#!/bin/bash
echo "Stopping Traefik..."
if docker ps -q -f name=traefik 2>/dev/null | grep -q .; then
    docker stop traefik 2>/dev/null || true
    docker rm traefik 2>/dev/null || true
fi
echo "Stopping Keepalived..."
systemctl stop keepalived 2>/dev/null || true
systemctl disable keepalived 2>/dev/null || true
echo "Removing Traefik files..."
rm -rf /opt/indica/traefik 2>/dev/null || true
echo "✓ Cleanup complete"
REPLACECLEANUP
        chmod 644 "$SCRIPTS_DIR/cleanup_replace_${_old_node}.sh"
        ensure_SCRIPTS_DIR "$_old_ip" || true
        copy_to_remote "$SCRIPTS_DIR/cleanup_replace_${_old_node}.sh" \ || true
            "$_old_ip" "$SCRIPTS_DIR/cleanup_replace.sh"
        execute_remote_script "$_old_ip" "$SCRIPTS_DIR/cleanup_replace.sh" 2>/dev/null || true
        rm -f "$SCRIPTS_DIR/cleanup_replace_${_old_node}.sh"
        echo "✓"
    else
        echo "  ⚠️  ${_old_node} is unreachable — skipping cleanup"
        echo "     Please decommission the old server manually when possible."
    fi

    # Step 4 — update config arrays
    BACKUP_NODES[$_ridx]="$_new_node"
    BACKUP_IPS[$_ridx]="$_new_ip"
    BACKUP_INTERFACES[$_ridx]=""   # Will be detected during deploy

    # Step 5 — copy SSH key to new node
    echo ""
    echo "  Setting up SSH access to new node..."
    echo "  ${_new_node} (${_new_ip}) — copying SSH key..."
    echo ""

    # Remove any stale known_hosts entries for the old node — the new server
    # will have a different host key and SSH will refuse to connect otherwise
    echo -n "  Clearing stale host key entries... "
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh-keygen -R "$_new_ip" 2>/dev/null || true
        sudo -u "$SUDO_USER" ssh-keygen -R "$_new_node" 2>/dev/null || true
    else
        ssh-keygen -R "$_new_ip" 2>/dev/null || true
        ssh-keygen -R "$_new_node" 2>/dev/null || true
    fi
    echo "✓"
    local _new_node_pass=""
    read -s -p "  Enter login password for ${CURRENT_USER}@${_new_ip}: " _new_node_pass
    echo ""

    local _copy_ok=false
    if command -v sshpass &>/dev/null && [[ -n "$_new_node_pass" ]]; then
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" sshpass -p "$_new_node_pass" \
                ssh-copy-id -o StrictHostKeyChecking=accept-new \
                -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                -o "User=$CURRENT_USER" "$_new_ip" 2>/dev/null && _copy_ok=true
        else
            sshpass -p "$_new_node_pass" \
                ssh-copy-id -o StrictHostKeyChecking=accept-new \
                -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                -o "User=$CURRENT_USER" "$_new_ip" 2>/dev/null && _copy_ok=true
        fi
    else
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" ssh-copy-id -o StrictHostKeyChecking=accept-new \
                -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                -o "User=$CURRENT_USER" "$_new_ip" 2>/dev/null && _copy_ok=true
        else
            ssh-copy-id -o StrictHostKeyChecking=accept-new \
                -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                -o "User=$CURRENT_USER" "$_new_ip" 2>/dev/null && _copy_ok=true
        fi
    fi
    [[ "$_copy_ok" == true ]] && echo "  ✓ SSH key copied" || \
        echo "  ⚠️  SSH key copy may have failed — proceeding anyway"

    # Ensure SUDO_PASS is set for deploy operations on the new node
    if [[ -z "${SUDO_PASS:-}" ]]; then
        echo ""
        read -s -p "  Enter sudo password for remote hosts: " SUDO_PASS
        echo ""
        export SUDO_PASS
    fi

    # Step 6 — detect network interface on new node
    echo ""
    echo "  Detecting network interface on ${_new_node}..."
    local _detected_iface=""
    _detected_iface=$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_new_ip" \
        "ip -o addr show | grep 'inet ${_new_ip}' | awk '{print \$2}' | head -1" 2>/dev/null \
        | sed 's/@.*//')

    if [[ -n "$_detected_iface" ]]; then
        echo "  ✓ Detected interface: ${_detected_iface}"
        echo ""
        echo "  Available interfaces on ${_new_node}:"
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_new_ip" \
            "ip -o link show | awk '{print \"    - \" \$2}' | sed 's/:$//' | grep -v lo" 2>/dev/null || true
        echo ""
        local _use_iface=""
        while true; do
            read -p "  Use '${_detected_iface}'? (y/n/other) [Y/n]: " _use_iface
            _use_iface="${_use_iface:-y}"
            case "${_use_iface,,}" in
                y) BACKUP_INTERFACES[$_ridx]="$_detected_iface"; break ;;
                n|other)
                    read -p "  Enter interface name: " _manual_iface
                    BACKUP_INTERFACES[$_ridx]="$_manual_iface"; break ;;
                *) echo "  Please enter y, n, or other." ;;
            esac
        done
    else
        echo "  ⚠️  Could not auto-detect interface"
        local _manual_iface=""
        while true; do
            read -p "  Enter interface name for ${_new_node}: " _manual_iface
            [[ -n "$_manual_iface" ]] && break
            echo "  Error: Interface cannot be empty."
        done
        BACKUP_INTERFACES[$_ridx]="$_manual_iface"
    fi

    # Step 7 — deploy to new node
    echo ""
    echo "  Deploying to new node ${_new_node}..."
    snapshot_config "NODE_REPLACE" \
        "Replaced backup node ${_old_node} → ${_new_node} (${_new_ip})"

    deploy_to_backup_nodes "$_ridx"

    audit_log "NODE_REPLACE" \
        "Replaced ${_old_node} (${_old_ip}) → ${_new_node} (${_new_ip})"

    echo ""
    echo "  ✓ Node replacement complete"
    echo "    ${_old_node} → ${_new_node} (${_new_ip})"
}

extend_edit_nodes() {
    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Edit Traefik Nodes"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""

        # Show current node list
        echo "  Current nodes:"
        echo ""
        printf "  %-12s %-28s %s\n" "Master" "${MASTER_HOSTNAME:-$(hostname -s)}" "(${MASTER_IP:-$(hostname -I | awk '{print $1}')})"
        if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
            for i in "${!BACKUP_NODES[@]}"; do
                local p=$(( 100 - (i * 10) ))
                printf "  %-12s %-28s %s\n" \
                    "Backup $(( i + 1 ))" "${BACKUP_NODES[$i]}" "(${BACKUP_IPS[$i]})"
            done
        else
            echo "  (no backup nodes — single-node deployment)"
        fi
        echo ""

        echo "  ----------------------------------------"
        echo "  [1] Add a backup node"
        if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
            echo "  [2] Remove a backup node"
            echo "  [3] Replace a backup node"
        else
            echo "  [2] Remove a backup node   (n/a — no backup nodes)"
            echo "  [3] Replace a backup node  (n/a — no backup nodes)"
        fi
        echo "  ─────────────────────────────────────────────────────"
        echo "  [4] Back"
        echo ""

        local _sub
        while true; do
            read -p "Enter choice [1-4]: " _sub
            case "$_sub" in
                1|4) break ;;
                2|3)
                    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
                        break
                    else
                        echo "  Option unavailable — no backup nodes configured."
                    fi ;;
                *) echo "  Please enter 1, 2, 3, or 4." ;;
            esac
        done

        case "$_sub" in
            1) extend_add_nodes     ;;
            2) extend_remove_nodes  ;;
            3) extend_replace_node  ;;
            4) return 0             ;;
        esac
    done
}

# ==========================================
# Status Check
# ==========================================

check_keepalived_state() {
    local _vip="${VIRTUAL_IP:-}"
    if [[ -z "$_vip" ]]; then return 0; fi

    echo ""
    echo "  Keepalived / Virtual IP:"
    echo ""

    # Check master
    local _master_has_vip=false
    if ip addr show 2>/dev/null | grep -q "$_vip"; then
        _master_has_vip=true
        printf "  %-12s %-28s →  MASTER  ✓  (VIP %s assigned)\n" \
            "Master" "${MASTER_HOSTNAME:-$(hostname -s)}" "$_vip"
    else
        printf "  %-12s %-28s →  BACKUP  (VIP not assigned)\n" \
            "Master" "${MASTER_HOSTNAME:-$(hostname -s)}"
    fi

    # Check backup nodes
    for i in "${!BACKUP_NODES[@]}"; do
        local _bn="${BACKUP_NODES[$i]}"
        local _bip="${BACKUP_IPS[$i]}"
        local _vip_held=false

        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_bip" \
            "ip addr show 2>/dev/null | grep -q '$_vip' && echo VIP_HELD" 2>/dev/null | grep -q VIP_HELD; then
            _vip_held=true
        fi

        local _kv_running=false
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_bip" \
            "systemctl is-active keepalived 2>/dev/null | grep -q active && echo RUNNING" 2>/dev/null | grep -q RUNNING; then
            _kv_running=true
        fi

        if [[ "$_vip_held" == true && "$_master_has_vip" == true ]]; then
            printf "  %-12s %-28s →  ⚠️  VIP held by BOTH nodes — split-brain!\n" \
                "Backup $(( i+1 ))" "$_bn"
        elif [[ "$_vip_held" == true ]]; then
            printf "  %-12s %-28s →  MASTER  ⚠️  (VIP %s held — master may be down)\n" \
                "Backup $(( i+1 ))" "$_bn" "$_vip"
        elif [[ "$_kv_running" == true ]]; then
            printf "  %-12s %-28s →  BACKUP  ✓  (VIP not assigned — correct)\n" \
                "Backup $(( i+1 ))" "$_bn"
        else
            printf "  %-12s %-28s →  ✗  unreachable or Keepalived not running\n" \
                "Backup $(( i+1 ))" "$_bn"
        fi
    done
}

check_ssh_key_rotation() {
    # Detect if the local SSH key has changed since keys were last copied
    # by testing key-based auth against each backup node
    if [[ ! -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]]; then return 0; fi
    if [[ "$MULTI_NODE_DEPLOYMENT" != "yes" || ${#BACKUP_NODES[@]} -eq 0 ]]; then return 0; fi

    local _key_issues=false
    for i in "${!BACKUP_NODES[@]}"; do
        local _bn="${BACKUP_NODES[$i]}"
        local _bip="${BACKUP_IPS[$i]}"
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_bip" \
            "echo ok" >/dev/null 2>&1; then
            if [[ "$_key_issues" == false ]]; then
                echo ""
                echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                echo "  !! WARNING — SSH key authentication failing              !!"
                echo "  !! This may mean the SSH key has been rotated.           !!"
                echo "  !! Affected nodes:                                       !!"
                _key_issues=true
            fi
            printf "  !!   %-52s!!\n" "${_bn} (${_bip})"
        fi
    done
    if [[ "$_key_issues" == true ]]; then
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo ""
        if prompt_yn "  Re-copy SSH key to affected nodes now?" "y"; then
            echo ""
            read -s -p "  Login password for ${CURRENT_USER} on remote nodes: " _rekey_pass
            echo ""
            for i in "${!BACKUP_NODES[@]}"; do
                local _bn="${BACKUP_NODES[$i]}"
                local _bip="${BACKUP_IPS[$i]}"
                if ! ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
                    -i "$ACTUAL_HOME/.ssh/id_rsa" -l "$CURRENT_USER" "$_bip" \
                    "echo ok" >/dev/null 2>&1; then
                    echo -n "  Re-copying key to ${_bn}... "
                    ssh-keygen -R "$_bip" 2>/dev/null || true
                    ssh-keygen -R "$_bn"  2>/dev/null || true
                    if command -v sshpass &>/dev/null; then
                        sshpass -p "$_rekey_pass" ssh-copy-id \
                            -o StrictHostKeyChecking=accept-new \
                            -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                            -o "User=$CURRENT_USER" "$_bip" 2>/dev/null \
                            && echo "✓" || echo "✗ failed"
                    else
                        ssh-copy-id -o StrictHostKeyChecking=accept-new \
                            -i "$ACTUAL_HOME/.ssh/id_rsa.pub" \
                            -o "User=$CURRENT_USER" "$_bip" 2>/dev/null \
                            && echo "✓" || echo "✗ failed"
                    fi
                fi
            done
        fi
    fi
}

show_status() {
    local _source_config="${1:-$CONFIG_FILE}"

    echo ""
    echo ""
    echo ""
    echo ":: Status Check"
    echo "──────────────────────────────────────────────────"
    echo ""

    # Load config if not already loaded
    if [[ -f "$_source_config" ]]; then
        source "$_source_config" 2>/dev/null || true
    fi

    local _ssh_key="-i $ACTUAL_HOME/.ssh/id_rsa"
    [[ ! -f "$ACTUAL_HOME/.ssh/id_rsa" ]] && _ssh_key=""

    # ── Traefik ──
    echo "  Traefik:"
    echo ""
    local _traefik_status="✗ Not running"
    if docker ps --filter name=traefik --filter status=running \
        --format '{{.Names}}' 2>/dev/null | grep -q traefik || \
       sg docker -c "docker ps --filter name=traefik --filter status=running \
        --format '{{.Names}}'" 2>/dev/null | grep -q traefik; then
        if curl -fs --max-time 3 http://localhost:8800/ping >/dev/null 2>&1; then
            _traefik_status="✓ Running (healthy)"
        else
            _traefik_status="✓ Running (health check pending)"
        fi
    fi
    printf "  %-12s %-28s →  %s\n" "Master" "${MASTER_HOSTNAME:-$(hostname -s)}" "$_traefik_status"

    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        for i in "${!BACKUP_NODES[@]}"; do
            local _bn="${BACKUP_NODES[$i]}"
            local _bip="${BACKUP_IPS[$i]}"
            local _bstatus="✗ unreachable"
            if ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no -l "$CURRENT_USER" "$_bip" \
                "echo ok" >/dev/null 2>&1; then
                local _bt
                _bt=$(ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=5 \
                    -o StrictHostKeyChecking=no -l "$CURRENT_USER" "$_bip" \
                    "docker ps --filter name=traefik --filter status=running \
                     --format '{{.Names}}' 2>/dev/null || sg docker -c \
                     \"docker ps --filter name=traefik --filter status=running \
                     --format '{{.Names}}'\") 2>/dev/null" 2>/dev/null) || true
                if echo "$_bt" | grep -q traefik; then
                    _bstatus="✓ Running"
                else
                    _bstatus="✗ Traefik not running"
                fi
            fi
            printf "  %-12s %-28s →  %s\n" "Backup $(( i+1 ))" "$_bn" "$_bstatus"
        done
    fi

    # ── SSL Certificate ──
    echo ""
    echo "  SSL Certificate:"
    echo ""
    if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
        local _expiry _days_left
        _expiry=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$_expiry" ]]; then
            local _exp_epoch _now_epoch
            _exp_epoch=$(date -d "$_expiry" +%s 2>/dev/null || \
                date -j -f "%b %d %T %Y %Z" "$_expiry" +%s 2>/dev/null)
            _now_epoch=$(date +%s)
            _days_left=$(( (_exp_epoch - _now_epoch) / 86400 ))
            if (( _days_left <= 0 )); then
                printf "  %-10s →  EXPIRED  ✗\n" "Status"
            elif (( _days_left <= 30 )); then
                printf "  %-10s →  Expires in %d days  ⚠\n" "Status" "$_days_left"
            else
                printf "  %-10s →  Valid (%d days remaining)  ✓\n" "Status" "$_days_left"
            fi
            printf "  %-10s →  %s\n" "Expiry" "$_expiry"
        fi
    else
        printf "  %-10s →  Certificate file not found\n" "Status"
    fi

    # ── Keepalived / VIP ──
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && -n "$VIRTUAL_IP" ]]; then
        echo ""
        echo "  Keepalived / Virtual IP:"
        echo ""
        if ip addr show 2>/dev/null | grep -q "$VIRTUAL_IP"; then
            printf "  %-12s %-28s →  MASTER  ✓  (VIP %s assigned)\n" \
                "Master" "${MASTER_HOSTNAME:-$(hostname -s)}" "$VIRTUAL_IP"
        else
            printf "  %-12s %-28s →  BACKUP  (VIP not assigned)\n" \
                "Master" "${MASTER_HOSTNAME:-$(hostname -s)}"
        fi
        for i in "${!BACKUP_NODES[@]}"; do
            local _bn="${BACKUP_NODES[$i]}"
            local _bip="${BACKUP_IPS[$i]}"
            local _vip_held=false _kv_running=false
            if ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no -l "$CURRENT_USER" "$_bip" \
                "ip addr show 2>/dev/null | grep -q '$VIRTUAL_IP' && echo VIP_HELD" \
                2>/dev/null | grep -q VIP_HELD; then
                _vip_held=true
            fi
            if ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no -l "$CURRENT_USER" "$_bip" \
                "systemctl is-active keepalived 2>/dev/null | grep -q active && echo RUNNING" \
                2>/dev/null | grep -q RUNNING; then
                _kv_running=true
            fi
            if [[ "$_vip_held" == true ]]; then
                printf "  %-12s %-28s →  MASTER  ⚠  (VIP held — check master)\n" \
                    "Backup $(( i+1 ))" "$_bn"
            elif [[ "$_kv_running" == true ]]; then
                printf "  %-12s %-28s →  BACKUP  ✓  (VIP not assigned)\n" \
                    "Backup $(( i+1 ))" "$_bn"
            else
                printf "  %-12s %-28s →  ✗  unreachable or Keepalived not running\n" \
                    "Backup $(( i+1 ))" "$_bn"
            fi
        done
    fi

    # ── SSH Key Health ──
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        echo ""
        echo "  SSH Key Health:"
        echo ""
        local _ssh_all_ok=true
        for i in "${!BACKUP_NODES[@]}"; do
            local _bn="${BACKUP_NODES[$i]}"
            local _bip="${BACKUP_IPS[$i]}"
            if ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no -l "$CURRENT_USER" "$_bip" \
                "echo ok" >/dev/null 2>&1; then
                printf "  %-12s %-28s →  ✓\n" "Backup $(( i+1 ))" "$_bn"
            else
                printf "  %-12s %-28s →  ✗  key auth failed\n" "Backup $(( i+1 ))" "$_bn"
                _ssh_all_ok=false
            fi
        done
        if [[ "$_ssh_all_ok" == false ]]; then
            echo ""
            echo "  Use Change Deployment → Edit Traefik Nodes → Replace Node, or run:"
            echo "    ssh-copy-id -i ~/.ssh/id_rsa.pub ${CURRENT_USER}@<node_ip>"
        fi
    fi

    echo ""
    echo "  ✓ Status check complete"
    echo ""
}

handle_extend_mode() {
    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Change Deployment"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""
        echo "  [1] Update SSL Certificate"
        echo "  [2] Update CA Certificate"
        echo "  [3] Edit Traefik Nodes"
        echo "  [4] Edit Component Servers/Services"
        echo "  [5] Edit HL7 Configuration"
        echo "  [6] Edit Diagnostics Monitor"
        echo "  [7] Status Check"
        echo "  ─────────────────────────────────────────────────────"
        echo "  [8] Back"
        echo "  [9] Exit"
        echo ""

        local _choice
        while true; do
            read -p "Enter choice [1-9]: " _choice
            if [[ "$_choice" =~ ^[1-9]$ ]]; then break; fi
            echo "  Please enter a number between 1 and 9."
        done

        case "$_choice" in
            1) extend_update_ssl      ;;
            2) extend_update_ca       ;;
            3) extend_edit_nodes      ;;
            4) extend_edit_components ;;
            5) extend_edit_hl7        ;;
            6) extend_edit_diag       ;;
            7) show_status            ;;
            8)
                if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
                    cleanup_remote_scripts_dirs
                fi
                echo ""
                return 0
                ;;
            9)
                echo ""
                echo "  Exiting."
                cleanup
                exit 0
                ;;
        esac
    done
}

# ==========================================
# Function to prompt user for using existing configuration
# ==========================================

prompt_use_existing_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "No existing configuration file found. Proceeding with new setup."
        return 0
    fi

    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Existing Deployment Detected"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""
        echo "  Configuration: $CONFIG_FILE"
        echo ""

        # Re-peek from disk on every iteration so the summary reflects any saves
        local _peek_type _peek_mode _peek_hl7 _peek_master
        local -a _peek_backups=()
        _peek_type=$(grep '^DEPLOYMENT_TYPE=' "$CONFIG_FILE" | cut -d'"' -f2)
        _peek_mode=$(grep '^MULTI_NODE_DEPLOYMENT=' "$CONFIG_FILE" | cut -d'"' -f2)
        _peek_hl7=$(grep '^HL7_ENABLED=' "$CONFIG_FILE" | cut -d'"' -f2)
        _peek_master=$(grep '^MASTER_HOSTNAME=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        mapfile -t _peek_backups < <(grep '^BACKUP_NODES\[' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        mapfile -t _peek_backup_ips < <(grep '^BACKUP_IPS\[' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
        local _peek_vip
        _peek_vip=$(grep '^VIRTUAL_IP=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        local _peek_hl7_ports
        _peek_hl7_ports=$(grep '^HL7_LISTEN_PORTS=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        local _peek_cert_file
        _peek_cert_file=$(grep '^CERT_FILE=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")
        local _peek_diag
        _peek_diag=$(grep '^DIAG_ENABLED=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "no")
        local _peek_diag_url
        _peek_diag_url=$(grep '^DIAG_URL=' "$CONFIG_FILE" | cut -d'"' -f2 2>/dev/null || echo "")

        # Format HL7 ports as :1050, :1051 etc
        local _peek_hl7_display=""
        if [[ "$_peek_hl7" == "yes" && -n "$_peek_hl7_ports" ]]; then
            _peek_hl7_display=$(echo "$_peek_hl7_ports" | tr '|' '\n' | sed 's/^/:/' | paste -sd ', ' -)
        fi

        # Format type label
        local _peek_type_label="${_peek_type:-unknown}"
        if [[ "$_peek_type" == "full" ]]; then _peek_type_label="Full Install"
        elif [[ "$_peek_type" == "image-site" ]]; then _peek_type_label="Image Site"; fi

        # SSL certificate expiry
        local _peek_cert_status="unknown"
        if [[ -f "$_peek_cert_file" ]]; then
            local _expiry _days_left
            _expiry=$(openssl x509 -noout -enddate -in "$_peek_cert_file" 2>/dev/null | cut -d= -f2)
            if [[ -n "$_expiry" ]]; then
                local _exp_epoch _now_epoch
                _exp_epoch=$(date -d "$_expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$_expiry" +%s 2>/dev/null)
                _now_epoch=$(date +%s)
                _days_left=$(( (_exp_epoch - _now_epoch) / 86400 ))
                if (( _days_left <= 0 )); then
                    _peek_cert_status="EXPIRED"
                elif (( _days_left <= 30 )); then
                    _peek_cert_status="Expires in ${_days_left} days  ⚠"
                else
                    _peek_cert_status="Valid  (${_days_left} days remaining)"
                fi
            fi
        elif [[ -n "$_peek_cert_file" ]]; then
            _peek_cert_status="File not found"
        fi

        # Traefik health check (local)
        local _peek_traefik_status="Not running"
        if docker ps --filter name=traefik --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q traefik || \
           sg docker -c "docker ps --filter name=traefik --filter status=running --format '{{.Names}}'" 2>/dev/null | grep -q traefik; then
            if curl -fs --max-time 3 http://localhost:8800/ping >/dev/null 2>&1; then
                _peek_traefik_status="Traefik running  ✓"
            else
                _peek_traefik_status="Traefik running (health check pending)"
            fi
        fi

        echo "  ┌─ Current Deployment ──────────────────────────────────────────"
        echo "  │"
        printf "  │  %-10s:  %s\n" "Type" "${_peek_type_label}"
        echo "  │"
        printf "  │  %-10s:  %s\n" "Config" "${CONFIG_FILE}"
        printf "  │  %-10s:  %s\n" "SSL Cert" "${_peek_cert_status}"
        echo "  │"
        if [ "${_peek_mode}" = "yes" ]; then
            printf "  │  %-10s:  %s\n" "HA Mode" "Multi-node"
            printf "  │  %-10s   Master  →  %s  →  %s\n" "" "${_peek_master:-unknown}" "${_peek_traefik_status}"
            local _bi=0
            for _bn in "${_peek_backups[@]}"; do
                local _bip="${_peek_backup_ips[$_bi]:-}"
                local _bstatus="unknown"
                if [[ -n "$_bip" ]]; then
                    local _ssh_key="-i $ACTUAL_HOME/.ssh/id_rsa"
                    [[ ! -f "$ACTUAL_HOME/.ssh/id_rsa" ]] && _ssh_key=""
                    if ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=3 \
                        -o StrictHostKeyChecking=no \
                        -l "$CURRENT_USER" "$_bip" \
                        "echo ok" >/dev/null 2>&1; then
                        local _btraefik
                        _btraefik=$(ssh $_ssh_key -o BatchMode=yes -o ConnectTimeout=3 \
                            -o StrictHostKeyChecking=no \
                            -l "$CURRENT_USER" "$_bip" \
                            "docker ps --filter name=traefik --filter status=running --format '{{.Names}}' 2>/dev/null || sg docker -c \"docker ps --filter name=traefik --filter status=running --format '{{.Names}}'\" 2>/dev/null" 2>/dev/null) || true
                        if echo "$_btraefik" | grep -q traefik; then
                            _bstatus="Traefik running  ✓"
                        else
                            _bstatus="✗ Traefik not running"
                        fi
                    else
                        _bstatus="✗ unreachable"
                    fi
                fi
                printf "  │  %-10s   Backup  →  %s  →  %s\n" "" "$_bn" "$_bstatus"
                _bi=$(( _bi + 1 ))
            done
            if [[ -n "$_peek_vip" ]]; then
                echo "  │"
                printf "  │  %-10s:  %s\n" "VIP" "$_peek_vip"
            fi
        else
            printf "  │  %-10s:  Single-node  →  %s\n" "HA Mode" "${_peek_traefik_status}"
        fi
        echo "  │"
        if [[ "$_peek_hl7" == "yes" && -n "$_peek_hl7_display" ]]; then
            printf "  │  %-10s:  Enabled  (%s)\n" "HL7" "$_peek_hl7_display"
        else
            printf "  │  %-10s:  Disabled\n" "HL7"
        fi
        if [[ "$_peek_diag" == "yes" && -n "$_peek_diag_url" ]]; then
            printf "  │  %-10s:  Enabled  (%s)\n" "Diag Mon" "$_peek_diag_url"
        else
            printf "  │  %-10s:  Disabled\n" "Diag Mon"
        fi
        echo "  └────────────────────────────────────────────────────────────────"
        echo ""

        echo "  What would you like to do?"
        echo ""
        echo "    [1] Reinstall — re-run setup using existing config"
        echo "    [2] Status Check — view health of current deployment"
        echo "    [3] Change — update certificates, servers, nodes or HL7"
        echo "    [4] Uninstall  — remove everything from all nodes"
        echo "    ─────────────────────────────────────────────────────"
        echo "    [5] Cancel"
        echo ""

        local _choice
        while true; do
            read -p "Enter choice [1-5]: " _choice
            case "$_choice" in
                1|2|3|4|5) break ;;
                *) echo "  Please enter 1, 2, 3, 4, or 5." ;;
            esac
        done

        case "$_choice" in
            1)
                echo ""
                log "User selected: Reinstall"
                local _r_date _r_time _r_backupdir
                _r_date=$(date +'%d_%b_%y' | tr '[:lower:]' '[:upper:]')
                _r_time=$(date +'%H_%M_%S')
                _r_backupdir="/opt/indica/traefik/backups/${_r_date}/${_r_time}/files"
                echo "  This will back up your current files and re-run the full setup"
                echo "  using your existing configuration as a starting point."
                echo ""
                echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                echo "  !! Current files will be moved to:                       !!"
                printf  "  !!   %-54s!!\n" "${_r_backupdir}"
                echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                echo ""
                if ! prompt_yn "  Are you sure you want to proceed with a reinstall?" "n"; then
                    echo "  Reinstall cancelled."
                    continue
                fi
                echo ""

                local _saved_deployment_type
                _saved_deployment_type=$(grep '^DEPLOYMENT_TYPE=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)

                if [ "${_peek_mode}" = "yes" ] && [ "${#_peek_backups[@]}" -gt 0 ]; then
                    source "$CONFIG_FILE"
                    echo "Multi-node deployment detected. Remote backup requires sudo access."
                    echo ""
                    read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
                    echo ""
                    export SUDO_PASS
                    SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
                    echo ""
                fi

                backup_existing_deployment
                load_config

                if [[ -n "$_saved_deployment_type" ]]; then
                    INITIAL_DEPLOYMENT_TYPE="$_saved_deployment_type"
                fi

                return 0
                ;;
            2)
                echo ""
                log "User selected: Status Check"
                source "$CONFIG_FILE" 2>/dev/null || true
                SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
                show_status
                ;;
            3)
                echo ""
                log "User selected: Change Deployment"

                source "$CONFIG_FILE"

                if [ "${MULTI_NODE_DEPLOYMENT:-no}" = "yes" ] && [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
                    echo "Multi-node deployment detected. Remote operations require sudo access."
                    echo ""
                    read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
                    echo ""
                    export SUDO_PASS
                    SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
                    echo ""

                    # Check SSH key health — detect rotation silently
                    check_ssh_key_rotation
                fi

                if ! docker ps &>/dev/null 2>&1; then
                    if sg docker -c "docker ps" &>/dev/null 2>&1; then
                        USE_DOCKER_GROUP=true
                    fi
                fi

                handle_extend_mode
                # Returns here when user chooses Back — loop redisplays the menu
                ;;
            4)
                echo ""
                log "User selected: Uninstall"
                echo "  ⚠️  This will run the full uninstall process."
                echo "     You will be prompted for options (backup nodes, Docker, etc.)"
                echo ""
                if prompt_yn "  Continue to uninstall?" "n"; then
                    exec bash "$0" --clean
                fi
                ;;
            5)
                echo "Operation cancelled."
                cleanup
                exit 0
                ;;
        esac
    done
}

# Prompt for deployment type
prompt_deployment_type() {
    echo ""
    echo ""
    echo ""
    echo ":: Select Traefik Deployment Type"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""

    local default_hint=""
    if [[ -n "$INITIAL_DEPLOYMENT_TYPE" ]]; then
        default_hint="(Detected: $INITIAL_DEPLOYMENT_TYPE)"
    fi

    while true; do
        echo "Please choose a deployment type: $default_hint"
        echo "  [1] Full Install"
        echo "  [2] Image Server Only"
        echo ""
        read -p "Enter choice [1 or 2]: " choice

        case "$choice" in
            1)
                DEPLOYMENT_TYPE="full"
                ;;
            2)
                DEPLOYMENT_TYPE="image-site"
                ;;
            *)
                echo "Invalid input. Please enter 1 or 2."
                continue
                ;;
        esac

        if [[ "$DEPLOYMENT_TYPE" != "$INITIAL_DEPLOYMENT_TYPE" && -n "$INITIAL_DEPLOYMENT_TYPE" ]]; then
            log "Deployment type changed from '$INITIAL_DEPLOYMENT_TYPE' to '$DEPLOYMENT_TYPE' - clearing previous configuration"
            clear_previous_configuration
        fi
        break
    done
}

# Function to clear previous config if detected deployment type from cnf is changed
clear_previous_configuration() {
    log "Resetting configuration for new deployment type - full cleanup"
    
    # Reset all service URLs
    unset APP_SERVICE_URLS IDP_SERVICE_URLS API_SERVICE_URLS FILEMONITOR_SERVICE_URLS IMAGE_SERVICE_URLS
    
    # Reset networking config
    unset VIRTUAL_IP VRID VRRP NETWORK_INTERFACE
    
    # Remove SSL configuration and files
    unset SSL_CERT_CONTENT SSL_KEY_CONTENT CERT_FILE KEY_FILE

    # Remove certificate/key paths (files or directories)
    if [[ -e "$CERT_FILE" ]]; then
        log "Removing existing certificate path: $CERT_FILE"
        rm -rf "$CERT_FILE" || exit_on_error "Failed to remove $CERT_FILE"
    fi
    if [[ -e "$KEY_FILE" ]]; then
        log "Removing existing key path: $KEY_FILE"
        rm -rf "$KEY_FILE" || exit_on_error "Failed to remove $KEY_FILE"
    fi
    
    # Remove existing config file
    if [[ -f "$CONFIG_FILE" ]]; then
        mv "$CONFIG_FILE" "$CONFIG_FILE.bak"
        log "Archived previous configuration to $CONFIG_FILE.bak"
    fi
}


# ==========================================
# Backup Infrastructure
# ==========================================

AUDIT_LOG="/opt/indica/traefik/audit.log"
TRAEFIK_ROOT="/opt/indica/traefik"

# Returns the timed backup directory path: backups/DD_MON_YY/HH_MM_SS/files
_backup_get_dir() {
    local _date _time
    _date=$(date +'%d_%b_%y' | tr '[:lower:]' '[:upper:]')
    _time=$(date +'%H_%M_%S')
    echo "${TRAEFIK_ROOT}/backups/${_date}/${_time}/files"
}

# Write an entry to the audit log
# Usage: audit_log "OPERATION" "description"
audit_log() {
    local _op="$1"
    local _desc="$2"
    local _ts
    _ts=$(date +'%Y-%m-%d %H:%M:%S')
    local _entry
    _entry="[${_ts}] [$(printf '%-14s' "$_op")] ${CURRENT_USER:-unknown} — ${_desc}"

    # Ensure audit log directory exists
    mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
    chown -R root:root "${TRAEFIK_ROOT}" 2>/dev/null || true

    echo "$_entry" >> "$AUDIT_LOG" 2>/dev/null || \
        bash -c "echo '$_entry' >> '$AUDIT_LOG'" 2>/dev/null || true
}

# Snapshot the current config/ directory to the timed backup dir
# Usage: snapshot_config "OPERATION_TYPE" "description"
snapshot_config() {
    local _op="${1:-CHANGE}"
    local _desc="${2:-Configuration change}"
    local _snap_dir
    _snap_dir=$(_backup_get_dir)

    mkdir -p "$_snap_dir"
    chown -R root:root "${TRAEFIK_ROOT}/backups" 2>/dev/null || true

    if [[ -d "${TRAEFIK_ROOT}/config" ]]; then
        cp -r "${TRAEFIK_ROOT}/config" "$_snap_dir/" 2>/dev/null || \
            cp -r "${TRAEFIK_ROOT}/config" "$_snap_dir/" 2>/dev/null || true
    fi
    if [[ -f "${TRAEFIK_ROOT}/deployment.config" ]]; then
        cp "${TRAEFIK_ROOT}/deployment.config" "$_snap_dir/" 2>/dev/null || \
            cp "${TRAEFIK_ROOT}/deployment.config" "$_snap_dir/" 2>/dev/null || true
    fi

    audit_log "$_op" "${_desc}  →  snapshot: ${_snap_dir}"
    log "Config snapshot → ${_snap_dir}"
}

# Backup a single file into the timed backup directory
# Replaces the old .bak.mostrecent / .bak.previous pattern
backup_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then return 0; fi

    local _bdir
    _bdir=$(_backup_get_dir)
    mkdir -p "$_bdir"
    chown -R root:root "${TRAEFIK_ROOT}/backups" 2>/dev/null || true

    local _dest="${_bdir}/$(basename "$file")"
    local file_owner
    file_owner=$(stat -c '%U' "$file" 2>/dev/null || stat -f '%Su' "$file" 2>/dev/null)

    if [[ "$file_owner" == "root" ]] || [[ ! -r "$file" ]]; then
        cp "$file" "$_dest" 2>/dev/null || true
    else
        cp "$file" "$_dest" 2>/dev/null || true
    fi

    log "Backed up $(basename "$file") → ${_dest}"
}

# ==========================================
# Package Management
# ==========================================

# Function to install packages using OS specific package manager only APT and dnf supported
install_packages() {
    local packages=("$@")
    log "Installing packages: ${packages[*]}"
    # Ensure proxy context exists in this scope (avoid calling other functions if sourced differently)
    if [ -z "${PROXY_STRATEGY:-}" ]; then
        log "Proxy strategy not set in current scope; restoring from environment..."
        # If env proxies are missing but proxy host is defined, rebuild minimal env
        if [ -z "${http_proxy:-}" ] && [ -n "${PROXY_HOST:-}" ] && [ -n "${PROXY_PORT:-}" ]; then
            local _encpass=""
            if [ -n "${PROXY_USER:-}" ] && [ -n "${PROXY_PASSWORD:-}" ]; then
                _encpass=$(url_encode_password "${PROXY_PASSWORD}")
                export http_proxy="http://${PROXY_USER}:${_encpass}@${PROXY_HOST}:${PROXY_PORT}"
                export https_proxy="$http_proxy"
            else
                export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
                export https_proxy="$http_proxy"
            fi
            # Prefer existing no_proxy; otherwise, build a smart list of direct repo hosts (no helper calls)
            if [ -z "${no_proxy:-}" ] || [ "${no_proxy}" = "localhost,127.0.0.1,::1,.local" ]; then
                local np_base="localhost,127.0.0.1,::1,.local"
                local detected_hosts=""
                # Parse repo hosts
                if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
                    # shellcheck disable=SC2013
                    while IFS= read -r h; do
                        # Probe direct reachability (bypass proxy entirely)
                        if timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "https://$h" >/dev/null 2>&1 || \
                           timeout 3 curl -sI --noproxy '*' ${CURL_SSL_OPT} "http://$h"  >/dev/null 2>&1; then
                            if ! echo ",$detected_hosts," | grep -q ",$h,"; then
                                detected_hosts="${detected_hosts}${detected_hosts:+,}$h"
                            fi
                        fi
                    done < <(grep -hE '^(baseurl|mirrorlist)' /etc/yum.repos.d/*.repo 2>/dev/null | \
                               grep -oE 'https?://[^/]+' | sed -E 's#^https?://##' | sort -u)
                fi
                # Add any user-provided internal domains
                if [ -n "$INTERNAL_REPO_DOMAINS" ]; then
                    detected_hosts="${detected_hosts}${detected_hosts:+,}${INTERNAL_REPO_DOMAINS}"
                fi
                if [ -n "$detected_hosts" ]; then
                    export no_proxy="${np_base},${detected_hosts}"
                else
                    export no_proxy="${np_base}"
                fi
            fi
            export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
            # Mask password inline without calling helpers
            if [ -n "$http_proxy" ]; then
                local _hp_masked
                _hp_masked=$(echo "$http_proxy" | sed -E 's#(https?://[^:]+:)[^@]*(@)#\1****\2#g')
                log "Reconstructed proxy env (env-only): http_proxy=${_hp_masked}, no_proxy=${no_proxy}"
            else
                log "Reconstructed proxy env (env-only): http_proxy=<unset>, no_proxy=${no_proxy}"
            fi
        fi
        # Mark strategy as env-only for logging purposes
        PROXY_STRATEGY="env-only"
    fi
    # Re-export in case a subshell cleared them
    export PROXY_STRATEGY DNF_PROXY_OPT APT_PROXY_OPT_PROXY http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
    
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        # Combine SSL and proxy options
        local APT_OPTS="${APT_SSL_OPT} ${APT_PROXY_OPT_PROXY}"
        sudo -E apt-get ${APT_OPTS} update > /tmp/apt_update.log 2>&1 || {
            log "Warning: Some repositories failed, continuing..."
        }
        sudo -E apt-get ${APT_OPTS} -yq install "${packages[@]}" || \
            exit_on_error "Failed to install: ${packages[*]}"

    elif command -v dnf &>/dev/null; then
        log "Installing via DNF (strategy: ${PROXY_STRATEGY}, dnf_proxy_opt: ${DNF_PROXY_OPT:+set}${DNF_PROXY_OPT:-none})..."
        sudo -E bash -c 'echo "[dnf env] http_proxy=${http_proxy:-<unset>} HTTPS_PROXY=${HTTPS_PROXY:-<unset>} no_proxy=${no_proxy:-<unset>}"' >> "$LOGFILE" 2>/dev/null || true
        # DNF uses environment proxy (http_proxy/https_proxy/no_proxy) automatically
        # Or explicit --setopt=proxy if DNF_PROXY_OPT is set
        if sudo -E dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install "${packages[@]}" 2>&1 | tee -a "$LOGFILE"; then
            log "✓ Packages installed"
        else
            log "Trying with --nobest..."
            if sudo -E dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install "${packages[@]}" --nobest 2>&1 | tee -a "$LOGFILE"; then
                log "✓ Packages installed (older versions)"
            else
                exit_on_error "Failed to install: ${packages[*]}"
            fi
        fi

    elif command -v yum &>/dev/null; then
        log "Installing via YUM (strategy: ${PROXY_STRATEGY})..."
        if sudo -E yum ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install "${packages[@]}" 2>&1 | tee -a "$LOGFILE"; then
            log "✓ Packages installed"
        else
            sudo -E yum ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install "${packages[@]}" --nobest 2>&1 | tee -a "$LOGFILE" || \
                exit_on_error "Failed to install: ${packages[*]}"
        fi
    else
        exit_on_error "No supported package manager found"
    fi

    log "✓ Package installation complete"
}

# Prompt for multi-node deployment configuration
prompt_multi_node_deployment() {
    echo ""
    echo ""
    echo ""
    echo ":: High Availability Configuration"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    
    # Check if we already have multi-node config loaded
    if [[ -n "$MULTI_NODE_DEPLOYMENT" && "$MULTI_NODE_DEPLOYMENT" == "yes" ]]; then
        echo "Existing multi-node configuration detected:"
        echo "  Master: $MASTER_HOSTNAME ($MASTER_IP)"
        for i in "${!BACKUP_NODES[@]}"; do
            echo "  Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]}) - Interface: ${BACKUP_INTERFACES[$i]:-auto}"
        done
        echo ""
        if prompt_yn "Use existing multi-node configuration?" "y"; then
            return 0
        fi
    fi
    
    # Main loop for configuration
    while true; do
        # Clear any previous configuration data from previous loop iterations
        BACKUP_NODES=()
        BACKUP_IPS=()
        BACKUP_INTERFACES=()
        unset IP_MAP
        declare -A IP_MAP
        
        # Prompt for number of backup nodes
        read -p "How many BACKUP nodes? [0]: " BACKUP_NODE_COUNT
        BACKUP_NODE_COUNT=${BACKUP_NODE_COUNT:-0}
        
        # Validate input
        if ! [[ "$BACKUP_NODE_COUNT" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Please enter a valid number"
            continue
        fi
        
        # If 0, single node mode
        if [ "$BACKUP_NODE_COUNT" -eq 0 ]; then
            MULTI_NODE_DEPLOYMENT="no"
            echo "Single-node deployment selected"
            return 0
        fi
        
        # Multi-node setup
        MULTI_NODE_DEPLOYMENT="yes"
        
        echo ""
        echo "Multi-node HA deployment:"
        echo "  - This node will be configured as MASTER (priority 110)"
        echo "  - $BACKUP_NODE_COUNT backup node(s) will be configured automatically"
        echo "  - Keepalived will manage failover with Virtual IP"
        echo ""
        
        # Get master node information (this node)
        echo "Master Node Configuration (this server):"
        
        # Smart default for hostname
        DEFAULT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
        read -p "  Master hostname [$DEFAULT_HOSTNAME]: " MASTER_HOSTNAME
        MASTER_HOSTNAME=${MASTER_HOSTNAME:-$DEFAULT_HOSTNAME}
        
        # Smart default for IP - get primary interface IP
        DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')
        read -p "  Master IP address [$DEFAULT_IP]: " MASTER_IP
        MASTER_IP=${MASTER_IP:-$DEFAULT_IP}
        
        # Validate master IP
        if ! validate_ip "$MASTER_IP"; then
            echo "ERROR: Invalid master IP address: $MASTER_IP"
            echo ""
            continue
        fi
        
        echo ""
        
        # Collect IP addresses for duplicate checking
        IP_MAP["$MASTER_IP"]=1
        
        # Get backup node information with interface detection
        local all_valid=true
        for i in $(seq 1 "$BACKUP_NODE_COUNT"); do
            local priority=$((100 - ((i - 1) * 10)))
    
            echo "Backup Node #$i (priority $priority):"
    
            # Get hostname
            local backup_hostname=""
            while [[ -z "$backup_hostname" ]]; do
                read -p "  Hostname: " backup_hostname
                if [[ -z "$backup_hostname" ]]; then
                    echo "  ERROR: Hostname cannot be empty"
                fi
            done
    
            # Get IP with validation
            local backup_ip=""
            local ip_valid=false
            while [ "$ip_valid" = false ]; do
                read -p "  IP address: " backup_ip
        
                # Validate IP format
                if ! validate_ip "$backup_ip"; then
                    echo "  ERROR: Invalid IP address format"
                    continue
                fi
        
                # Check for duplicates
                if [[ -n "${IP_MAP[$backup_ip]}" ]]; then
                    if [[ "$backup_ip" == "$MASTER_IP" ]]; then
                        echo "  ERROR: IP matches master node ($MASTER_IP)"
                    else
                        echo "  ERROR: IP already used by another backup node"
                    fi
                    continue
                fi
        
                # IP is valid and unique
                ip_valid=true
                IP_MAP["$backup_ip"]=1
            done
    
            # Store values - NO interface prompt yet
            BACKUP_NODES+=("$backup_hostname")
            BACKUP_IPS+=("$backup_ip")
            BACKUP_INTERFACES+=("")  # Empty - will be configured after SSH setup
    
            echo "  ✓ Node added"
            echo ""
        done

        echo ""
        echo "Note: Network interfaces will be configured after SSH setup"
        echo ""
        
        # Display summary with interfaces
        echo ""
        echo ""
        echo ":: Multi-Node Configuration Summary"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""
        echo "Master Node:"
        echo "  Hostname: $MASTER_HOSTNAME"
        echo "  IP: $MASTER_IP"
        echo "  Priority: 110"
        echo "  Interface: (Will be prompted for during installation)"
        echo ""
        echo "Backup Nodes:"
        for i in "${!BACKUP_NODES[@]}"; do
            priority=$((100 - (i * 10)))
            echo "  Backup $((i+1)): ${BACKUP_NODES[$i]}"
            echo "    IP: ${BACKUP_IPS[$i]}"
            echo "    Interface: ${BACKUP_INTERFACES[$i]}"
            echo "    Priority: $priority"
            echo ""
        done
        echo "Deployment Process:"
        echo "  1. Install and configure master node (this server)"
        echo "  2. Automatically deploy to all backup nodes"
        echo "  3. Configure Keepalived for automatic failover"
        echo "  4. Test and verify all nodes"
        echo ""
        echo "Note: Interfaces will be verified during deployment"
        echo "=========================================="
        echo ""
        
        # Confirm configuration
        if prompt_yn "Is this configuration correct?"; then
            echo "✓ Configuration confirmed"
            return 0
        else
            echo ""
            echo "Let's reconfigure the nodes..."
            echo ""
            # Loop will restart, allowing reconfiguration
        fi
    done
}

# ==========================================
# Service Configuration
# ==========================================

prompt_single_entry() {
    local service_name="$1"
    local default_port="$2"
    local enforce_http="${3:-false}"  # Default to false if not provided
    
    # Use terminal directly for all input/output
    exec 3>/dev/tty  # File descriptor for terminal output
    exec 4</dev/tty  # File descriptor for terminal input

    echo "" >&3
    echo "----------------------------------------" >&3
    echo "Configure $service_name" >&3
    echo "----------------------------------------" >&3
    echo "" >&3

    local host protocol port

    # Prompt for hostname with validation
    while true; do
        read -p "Enter the IP/hostname for $service_name (e.g. localhost): " host <&4
        if [[ -z "$host" ]]; then
            echo "Error: Hostname is required!" >&3
            continue
        fi
        break
    done

    # Prompt for protocol with validation
    while true; do
        if [[ "$enforce_http" == "true" ]]; then
            protocol="http"  # Enforce http for specific services
            break
        else
            read -p "Enter protocol (http/https) [default: https]: " protocol <&4
            protocol=${protocol:-https}
            if [[ "$protocol" != "http" && "$protocol" != "https" ]]; then
                echo "Error: Invalid protocol. Please enter 'http' or 'https'." >&3
                continue
            fi
            break
        fi
    done

    # Prompt for port with validation
    while true; do
        read -p "Enter port [default: $default_port]: " port <&4
        port=${port:-$default_port}
        if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            echo "Error: Invalid port. Please enter a number between 1 and 65535." >&3
            continue
        fi
        break
    done

    echo "$protocol://$host:$port"

    # Close file descriptors
    exec 3>&-
    exec 4<&-
}

# ==========================================
# HL7 / TCP Integration Functions
# ==========================================

# Prompt for optional HL7 TCP integration
# ==========================================
# HL7 / TCP Integration Functions
# ==========================================

# Helper: collect backend servers for one port group.
# Args: $1 = listen port for this group (used in prompts)
#       $2 = available-hosts comma string (may be empty → manual)
#       $3 = "primary" | "additional" (controls question wording)
# Writes result to _hl7_group_backends (caller reads this)
_hl7_collect_backends() {
    local _listen_port="$1"
    local _available_hosts="${2:-}"
    local _kind="${3:-primary}"
    _hl7_group_backends=""

    local -a _host_array=()
    if [[ -n "$_available_hosts" ]]; then
        IFS=',' read -ra _host_array <<< "$_available_hosts"
    fi

    if [[ ${#_host_array[@]} -gt 0 ]]; then
        # ---- Host picker ----
        echo "  The following hosts were configured as backend servers"
        echo "  during the service setup. Select the ones running the"
        echo "  HL7 integration."
        echo ""

        local _hl7_backend_port=""
        local -a _selected_hosts=()

        while true; do
            echo "  Available hosts:"
            local _n=1
            for _h in "${_host_array[@]}"; do
                echo "    ${_n}. ${_h}"
                (( ++_n ))
            done
            echo ""

            read -p "  Enter the number(s) of the HL7 host(s), comma-separated (e.g. 1,2): " _selection
            echo ""

            _selected_hosts=()
            local _valid=true
            IFS=',' read -ra _picks <<< "$_selection"
            for _pick in "${_picks[@]}"; do
                _pick="${_pick// /}"
                if [[ ! "$_pick" =~ ^[0-9]+$ ]] || (( _pick < 1 || _pick > ${#_host_array[@]} )); then
                    echo "  Error: '${_pick}' is not a valid option. Choose numbers between 1 and ${#_host_array[@]}."
                    _valid=false
                    break
                fi
                _selected_hosts+=("${_host_array[$(( _pick - 1 ))]}")
            done

            [[ "$_valid" == false ]] && continue

            if [[ ${#_selected_hosts[@]} -eq 0 ]]; then
                echo "  Error: No hosts selected."
                continue
            fi

            # Backend port question — wording differs for additional ports
            echo ""
            echo " ----------------------------------------"
            echo " Backend port"
            echo " ----------------------------------------"
            echo ""
            _hl7_backend_port=""
            if [[ "$_kind" == "additional" ]]; then
                while true; do
                    read -p "  The listening port configured in the API service for HL7 port ${_listen_port} [default: ${_listen_port}]: " _hl7_backend_port
                    _hl7_backend_port="${_hl7_backend_port:-$_listen_port}"
                    if [[ "$_hl7_backend_port" =~ ^[0-9]+$ ]] && (( _hl7_backend_port >= 1 && _hl7_backend_port <= 65535 )); then
                        break
                    fi
                    echo "  Error: Enter a valid port number (1-65535)."
                done
            else
                while true; do
                    read -p "  The listening port configured in the API service for HL7 [default: ${_listen_port}]: " _hl7_backend_port
                    _hl7_backend_port="${_hl7_backend_port:-$_listen_port}"
                    if [[ "$_hl7_backend_port" =~ ^[0-9]+$ ]] && (( _hl7_backend_port >= 1 && _hl7_backend_port <= 65535 )); then
                        break
                    fi
                    echo "  Error: Enter a valid port number (1-65535)."
                done
            fi
            echo ""

            # Confirm
            echo " ----------------------------------------"
            echo " Confirm selection"
            echo " ----------------------------------------"
            echo ""
            echo "  You selected:"
            for _sh in "${_selected_hosts[@]}"; do
                echo "    - ${_sh}:${_hl7_backend_port}"
            done
            echo ""

            if prompt_yn "  Is this correct?" "y"; then
                local _bsrv
                for _sh in "${_selected_hosts[@]}"; do
                    if [[ -n "$_hl7_group_backends" ]]; then
                        _hl7_group_backends="${_hl7_group_backends},${_sh}:${_hl7_backend_port}"
                    else
                        _hl7_group_backends="${_sh}:${_hl7_backend_port}"
                    fi
                done
                break
            fi
            echo ""
        done

    else
        # ---- Manual entry fallback ----
        echo "  Enter the hostname/IP and port of each server running the"
        echo "  HL7 integration. You can add multiple servers for high availability."
        echo ""

        local server_count=0
        while true; do
            (( server_count++ )) || true
            echo "  --- Backend Server ${server_count} ---"

            local _host=""
            while true; do
                read -p "  Hostname or IP address: " _host
                [[ -n "$_host" ]] && break
                echo "  Error: Hostname/IP cannot be empty."
            done

            local _port=""
            while true; do
                if [[ "$_kind" == "additional" ]]; then
                    read -p "  The listening port configured in the API service for HL7 port ${_listen_port} [default: ${_listen_port}]: " _port
                else
                    read -p "  Port [default: ${_listen_port}]: " _port
                fi
                _port="${_port:-$_listen_port}"
                if [[ "$_port" =~ ^[0-9]+$ ]] && (( _port >= 1 && _port <= 65535 )); then
                    break
                fi
                echo "  Error: Enter a valid port number (1-65535)."
            done

            if [[ -n "$_hl7_group_backends" ]]; then
                _hl7_group_backends="${_hl7_group_backends},${_host}:${_port}"
            else
                _hl7_group_backends="${_host}:${_port}"
            fi

            echo "  ✓ Added: ${_host}:${_port}"
            echo ""

            prompt_yn "  Add another backend server?" "n" || break
            echo ""
        done
    fi
}

# Usage: prompt_hl7_config [comma-separated-host-list]
prompt_hl7_config() {
    local _available_hosts="${1:-}"

    # ----------------------------------------
    # Re-run / existing config detection
    # ----------------------------------------
    if [[ "$HL7_ENABLED" == "yes" && -n "$HL7_LISTEN_PORTS" && -n "$HL7_PORT_BACKENDS" ]]; then
        echo ""
        echo ""
        echo ""
        echo ":: HL7 / TCP Integration (Optional)"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo ""
        echo "Existing HL7 integration configuration detected:"
        local _pi=1
        IFS='|' read -ra _existing_ports <<< "$HL7_LISTEN_PORTS"
        IFS='|' read -ra _existing_backends <<< "$HL7_PORT_BACKENDS"
        for _ep in "${_existing_ports[@]}"; do
            echo "  Port ${_pi}: Traefik :${_ep}  →  ${_existing_backends[$(( _pi - 1 ))]}"
            (( ++_pi ))
        done
        echo ""
        if prompt_yn "Use existing HL7 configuration?" "y"; then
            return 0
        fi
        HL7_ENABLED="no"
        HL7_LISTEN_PORTS=""
        HL7_PORT_BACKENDS=""
        HL7_PORT_COMMENTS=""
    fi

    echo ""
    echo ""
    echo ""
    echo ":: HL7 / TCP Integration (Optional)"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "An HL7 integration allows Traefik to forward raw TCP traffic"
    echo "(e.g. HL7 v2 messages) to one or more backend servers on a"
    echo "custom port. Multiple servers provide high availability —"
    echo "if one becomes unavailable, new connections are routed to"
    echo "the remaining servers."
    echo ""

    if ! prompt_yn "Configure an HL7 / TCP integration?" "n"; then
        HL7_ENABLED="no"
        log "HL7 integration skipped"
        return 0
    fi

    HL7_ENABLED="yes"
    HL7_LISTEN_PORTS=""
    HL7_PORT_BACKENDS=""
    HL7_PORT_COMMENTS=""
    local -a _port_comments_arr=()

    # ----------------------------------------
    # Collect one or more Traefik listen ports
    # ----------------------------------------
    echo ""
    echo " ----------------------------------------"
    echo " Step 1: Traefik HL7 listen port(s)"
    echo " ----------------------------------------"
    echo ""
    echo "  This is the port Traefik will open to receive HL7 traffic."
    echo "  You will be able to add additional ports if you have a deployment that utilises multiple"
    echo "  ports for HL7 messages."
    echo ""

    local -a _listen_ports_arr=()

    # Primary port
    local _primary_port=""
    while true; do
        read -p "  Traefik HL7 listen port [default: 1050]: " _primary_port
        _primary_port="${_primary_port:-1050}"
        if [[ "$_primary_port" =~ ^[0-9]+$ ]] && (( _primary_port >= 1 && _primary_port <= 65535 )); then
            break
        fi
        echo "  Error: Enter a valid port number (1-65535)."
    done
    _listen_ports_arr+=("$_primary_port")
    echo "  ✓ Primary port: ${_primary_port}"
    local _primary_comment=""
    read -p "  Short description for port ${_primary_port} (Recommended use site name e.g Berlin): " _primary_comment
    _port_comments_arr+=("${_primary_comment}")
    echo ""

    # Additional ports
    if prompt_yn "  Would you like to add additional HL7 ports?" "n"; then
        echo ""
        while true; do
            local _extra_port=""
            while true; do
                read -p "  Additional Traefik HL7 listen port: " _extra_port
                if [[ "$_extra_port" =~ ^[0-9]+$ ]] && (( _extra_port >= 1 && _extra_port <= 65535 )); then
                    # Check for duplicates
                    local _dup=false
                    for _existing_p in "${_listen_ports_arr[@]}"; do
                        [[ "$_existing_p" == "$_extra_port" ]] && _dup=true && break
                    done
                    if [[ "$_dup" == true ]]; then
                        echo "  Error: Port ${_extra_port} is already configured."
                        continue
                    fi
                    break
                fi
                echo "  Error: Enter a valid port number (1-65535)."
            done
            _listen_ports_arr+=("$_extra_port")
            echo "  ✓ Added port: ${_extra_port}"
            local _extra_comment=""
            read -p "  Short description for port ${_extra_port} (e.g. Main Lab, Radiology): " _extra_comment
            _port_comments_arr+=("${_extra_comment}")
            echo ""
            prompt_yn "  Add another HL7 port?" "n" || break
            echo ""
        done
    fi

    # Build HL7_LISTEN_PORTS and HL7_PORT_COMMENTS strings
    HL7_LISTEN_PORTS=$(IFS='|'; echo "${_listen_ports_arr[*]}")
    HL7_PORT_COMMENTS=$(IFS='|'; echo "${_port_comments_arr[*]}")

    # ----------------------------------------
    # For each port: collect backend servers
    # ----------------------------------------
    local _port_idx=1
    for _lport in "${_listen_ports_arr[@]}"; do
        echo ""
        echo " ----------------------------------------"
        if [[ ${#_listen_ports_arr[@]} -eq 1 ]]; then
            echo " Step 2: Backend server(s)"
        elif [[ $_port_idx -eq 1 ]]; then
            echo " Step 2: Backend server(s) for primary port :${_lport}"
        else
            echo " Step 2.${_port_idx}: Backend server(s) for additional port :${_lport}"
        fi
        echo " ----------------------------------------"
        echo ""

        local _kind="primary"
        [[ $_port_idx -gt 1 ]] && _kind="additional"

        _hl7_collect_backends "$_lport" "$_available_hosts" "$_kind"

        if [[ -n "$HL7_PORT_BACKENDS" ]]; then
            HL7_PORT_BACKENDS="${HL7_PORT_BACKENDS}|${_hl7_group_backends}"
        else
            HL7_PORT_BACKENDS="${_hl7_group_backends}"
        fi

        (( ++_port_idx ))
    done

    # ----------------------------------------
    # Summary
    # ----------------------------------------
    echo ""
    echo "HL7 integration summary:"
    IFS='|' read -ra _sum_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _sum_backends <<< "$HL7_PORT_BACKENDS"
    IFS='|' read -ra _sum_comments <<< "$HL7_PORT_COMMENTS"
    local _si=0
    for _sp in "${_sum_ports[@]}"; do
        local _label="Port $(( _si + 1 ))"
        [[ $_si -eq 0 ]] && _label="Primary port"
        echo "  ${_label}:"
        echo "    Description    : ${_sum_comments[$_si]}"
        echo "    Traefik listen : :${_sp}"
        echo "    Backend(s)     : ${_sum_backends[$_si]}"
        (( ++_si ))
    done
    echo ""
    log "HL7 integration configured: ports=${HL7_LISTEN_PORTS} backends=${HL7_PORT_BACKENDS}"
}

# Generate dynamic/hl7.yml — one router+service block per port
generate_hl7_conf() {
    local dynamic_dir="$1"

    if [[ "$HL7_ENABLED" != "yes" ]]; then
        return 0
    fi

    local hl7_file="${dynamic_dir}/hl7.yml"
    log "Generating hl7.yml at ${hl7_file}..."

    IFS='|' read -ra _ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _backends <<< "$HL7_PORT_BACKENDS"
    IFS='|' read -ra _comments <<< "$HL7_PORT_COMMENTS"

    # File header
    echo "tcp:" > "$hl7_file"
    echo "  routers:" >> "$hl7_file"

    local _idx=0
    for _port in "${_ports[@]}"; do
        local _router_name _service_name _ep_name
        if [[ $_idx -eq 0 ]]; then
            _ep_name="hl7"
            _router_name="hl7-router"
            _service_name="hl7-service"
        else
            _ep_name="hl7-${_port}"
            _router_name="hl7-router-${_port}"
            _service_name="hl7-service-${_port}"
        fi

        cat >> "$hl7_file" <<EOF
    ${_router_name}:
      entryPoints:
        - ${_ep_name}
      rule: "HostSNI(\`*\`)"
      service: ${_service_name}
      tls: false
EOF
        (( ++_idx ))
    done

    echo "  services:" >> "$hl7_file"

    _idx=0
    for _port in "${_ports[@]}"; do
        local _service_name _comment
        if [[ $_idx -eq 0 ]]; then
            _service_name="hl7-service"
        else
            _service_name="hl7-service-${_port}"
        fi
        _comment="${_comments[$_idx]:-}"

        if [[ -n "$_comment" ]]; then
            echo "    ${_service_name}: # ${_comment}" >> "$hl7_file"
        else
            echo "    ${_service_name}:" >> "$hl7_file"
        fi

        cat >> "$hl7_file" <<EOF
      loadBalancer:
        servers:
EOF
        IFS=',' read -ra _srvs <<< "${_backends[$_idx]}"
        for _srv in "${_srvs[@]}"; do
            echo "          - address: \"${_srv}\"" >> "$hl7_file"
        done

        (( ++_idx ))
    done

    chmod 640 "$hl7_file"
    log "hl7.yml generated (${#_ports[@]} port(s)) at ${hl7_file}"
}

# ==========================================
# Diagnostics Monitor — config generator
# ==========================================

generate_diag_conf() {
    local dynamic_dir="$1"
    local diag_file="${dynamic_dir}/diagnostics_monitor.yml"

    if [[ "$DIAG_ENABLED" != "yes" ]]; then
        # Write template with placeholder values so Traefik always has a valid file
        cat > "$diag_file" <<'DIAGTEMPLATE'
http:
  routers:
    diagmonitor-router:
      rule: PathPrefix(`/diagnostics`)
      middlewares:
        - SecurityHeaders
        - diagmonitor-rewrite
        # - diagmonitor-check-is-admin
        - diagmonitor-auth
        - diagmonitor-basicauth
        - compress
      service: diagmonitor-service
      tls: {}
  services:
    diagmonitor-service:
      loadBalancer:
        servers:
          - url: 'https://localhost:9090'
  middlewares:
    diagmonitor-rewrite:
      stripPrefix:
        prefixes:
          - '/diagnostics'
    # diagmonitor-check-is-admin:
    #   plugin:
    #     traefik_is_admin: {}
    diagmonitor-auth:
      forwardAuth:
        address: 'https://localhost/idsrv/connect/userinfo'
    diagmonitor-basicauth:
      headers:
        customRequestHeaders:
          Authorization: 'Basic dHJhZWZpazpfP0RMVypKfG9AZy91Izhn'
DIAGTEMPLATE
        chmod 640 "$diag_file"
        log "diagnostics_monitor.yml — template written (disabled)"
        return 0
    fi

    log "Generating diagnostics_monitor.yml at ${diag_file}..."

    cat > "$diag_file" <<EOF
http:
  routers:
    diagmonitor-router:
      rule: PathPrefix(\`/diagnostics\`)
      middlewares:
        - SecurityHeaders
        - diagmonitor-rewrite
        # - diagmonitor-check-is-admin
        - diagmonitor-auth
        - diagmonitor-basicauth
        - compress
      service: diagmonitor-service
      tls: {}
      priority: 100
  services:
    diagmonitor-service:
      loadBalancer:
        servers:
          - url: '${DIAG_URL}'
  middlewares:
    diagmonitor-rewrite:
      stripPrefix:
        prefixes:
          - '/diagnostics'
    # diagmonitor-check-is-admin:
    #   plugin:
    #     traefik_is_admin: {}
    diagmonitor-auth:
      forwardAuth:
        address: '${DIAG_AUTH_ADDRESS}'
    diagmonitor-basicauth:
      headers:
        customRequestHeaders:
          Authorization: 'Basic ${DIAG_AUTH_TOKEN}'
EOF

    chmod 640 "$diag_file"
    log "diagnostics_monitor.yml generated at ${diag_file}"
}

# ==========================================
# Diagnostics Monitor — main install prompt
# ==========================================

prompt_diag_config() {
    # Skip if already configured
    if [[ "$DIAG_ENABLED" == "yes" && -n "$DIAG_URL" && -n "$DIAG_AUTH_ADDRESS" && -n "$DIAG_AUTH_TOKEN" ]]; then
        log "Using existing diagnostics monitor configuration"
        return 0
    fi

    echo ""
    echo ""
    echo ""
    echo ":: Diagnostics Monitor (Optional)"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "  The diagnostics monitor integration configures Traefik to proxy"
    echo "  requests to a diagnostics service and authenticate via ForwardAuth."
    echo "  Basic authentication uses the username 'diagnostics' with a"
    echo "  password you provide."
    echo ""

    if ! prompt_yn "Configure the diagnostics monitor integration?" "n"; then
        DIAG_ENABLED="no"
        DIAG_URL=""
        DIAG_AUTH_ADDRESS=""
        DIAG_PASSWORD=""
        DIAG_AUTH_TOKEN=""
        log "Diagnostics monitor skipped"
        return 0
    fi

    DIAG_ENABLED="yes"

    # Service URL — offer known component server hostnames as a pick list
    echo ""
    echo "  Service URL"
    echo "  The diagnostics monitor is usually hosted on one of your component servers."
    echo ""

    # Build deduplicated hostname list from all service URL vars
    local -a _diag_hosts=()
    local _all_svc_urls="${APP_SERVICE_URLS},${IDP_SERVICE_URLS},${API_SERVICE_URLS},${FILEMONITOR_SERVICE_URLS},${IMAGE_SERVICE_URLS}"
    local -A _diag_seen=()
    while IFS= read -r _dh; do
        [[ -z "$_dh" ]] && continue
        if [[ -z "${_diag_seen[$_dh]+x}" ]]; then
            _diag_seen[$_dh]=1
            _diag_hosts+=("$_dh")
        fi
    done < <(echo "$_all_svc_urls" | tr ',' '\n' | sed -E 's#^https?://##; s#:[0-9]+$##' | grep -v '^$' | sort -u)

    local _diag_host=""
    if [[ ${#_diag_hosts[@]} -gt 0 ]]; then
        echo "  Known component servers:"
        local _dn=1
        for _dh in "${_diag_hosts[@]}"; do
            printf "    %d. %s\n" "$_dn" "$_dh"
            _dn=$(( _dn + 1 ))
        done
        echo "    M. Enter manually"
        echo ""

        while true; do
            read -p "  Select host [1-${#_diag_hosts[@]}/M]: " _dpick
            _dpick="${_dpick^^}"
            if [[ "$_dpick" == "M" ]]; then
                break
            elif [[ "$_dpick" =~ ^[0-9]+$ ]] && (( _dpick >= 1 && _dpick <= ${#_diag_hosts[@]} )); then
                _diag_host="${_diag_hosts[$(( _dpick - 1 ))]}"
                break
            else
                echo "  Invalid choice."
            fi
        done
    fi

    if [[ -z "$_diag_host" ]]; then
        while true; do
            read -p "  Hostname or IP: " _diag_host
            _diag_host="${_diag_host// /}"
            if [[ -n "$_diag_host" ]]; then break; fi
            echo "  Error: Hostname cannot be empty."
        done
    fi

    local _diag_port=""
    while true; do
        read -p "  Port [default: 9090]: " _diag_port
        _diag_port="${_diag_port:-9090}"
        if [[ "$_diag_port" =~ ^[0-9]+$ ]] && (( _diag_port >= 1 && _diag_port <= 65535 )); then break; fi
        echo "  Error: Enter a valid port (1-65535)."
    done
    DIAG_URL="https://${_diag_host}:${_diag_port}"

    # Auth address — derived from public origin
    echo ""
    local _diag_origin=""
    while true; do
        read -p "  Public origin hostname (e.g. demo.haloap.com): " _diag_origin
        _diag_origin="${_diag_origin// /}"
        if [[ -n "$_diag_origin" ]]; then break; fi
        echo "  Error: Hostname cannot be empty."
    done
    DIAG_AUTH_ADDRESS="https://${_diag_origin}/idsrv/connect/userinfo"

    # Basic auth password — with confirmation
    echo ""
    while true; do
        read -s -p "  Basic auth password for user 'diagnostics': " DIAG_PASSWORD
        echo ""
        if [[ -z "$DIAG_PASSWORD" ]]; then echo "  Error: Password cannot be empty."; continue; fi
        local _diag_confirm=""
        read -s -p "  Confirm password: " _diag_confirm
        echo ""
        if [[ "$DIAG_PASSWORD" == "$_diag_confirm" ]]; then break; fi
        echo "  Error: Passwords do not match. Please try again."
    done
    DIAG_AUTH_TOKEN=$(printf 'diagnostics:%s' "$DIAG_PASSWORD" | base64 | tr -d '\n')

    echo ""
    echo "  ✓ Diagnostics monitor configured"
    echo "    Service URL  : ${DIAG_URL}"
    echo "    Auth address : ${DIAG_AUTH_ADDRESS}"
    echo "    Basic auth   : diagnostics / ${DIAG_PASSWORD}"
}

# ==========================================
# Extend Mode — Option 6: Edit Diagnostics Monitor
# ==========================================

extend_edit_diag() {
    local TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/opt/indica/traefik/config/dynamic}"
    local _compose_dir="/opt/indica/traefik"
    local _traefik_yml="/opt/indica/traefik/config/traefik.yml"

    # Ensure the experimental plugin block exists in traefik.yml
    # (may be missing on installs that pre-date this feature)
    if [[ -f "$_traefik_yml" ]] && ! grep -q "traefik_is_admin" "$_traefik_yml"; then
        log "Adding traefik_is_admin plugin block to traefik.yml..."
        cat >> "$_traefik_yml" <<'PLUGINBLOCK'
# experimental:
#   localPlugins:
#     traefik_is_admin:
#       moduleName: gitlab.com/indica1/traefik-is-admin
PLUGINBLOCK
        log "✓ traefik_is_admin plugin block added"

        # Push updated traefik.yml to backup nodes if multi-node
        if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
            for i in "${!BACKUP_NODES[@]}"; do
                local _bip="${BACKUP_IPS[$i]}"
                copy_to_remote_root "$_traefik_yml" "$_bip" "$_traefik_yml"
            done
        fi
    fi

    while true; do
        echo ""
        echo ""
        echo ""
        echo ":: Edit Diagnostics Monitor"
        echo "──────────────────────────────────────────────────"
        echo ""

        # Show current state
        if [[ "$DIAG_ENABLED" == "yes" ]]; then
            echo "  Current configuration:"
            echo "    Service URL  : ${DIAG_URL}"
            echo "    Auth address : ${DIAG_AUTH_ADDRESS}"
            echo "    Basic auth   : diagnostics / ${DIAG_PASSWORD}"
        else
            echo "  Diagnostics monitor is not currently enabled."
        fi
        echo ""

        echo "  ----------------------------------------"
        if [[ "$DIAG_ENABLED" != "yes" ]]; then
            echo "  [1] Enable diagnostics monitor"
            echo "  [2] Update service URL         (n/a — not enabled)"
            echo "  [3] Update ForwardAuth public origin (n/a — not enabled)"
            echo "  [4] Update Basic auth password (n/a — not enabled)"
            echo "  [5] Disable / remove           (n/a — not enabled)"
        else
            echo "  [1] Enable diagnostics monitor (n/a — already enabled)"
            echo "  [2] Update service URL"
            echo "  [3] Update ForwardAuth public origin"
            echo "  [4] Update Basic auth password"
            echo "  [5] Disable / remove"
        fi
        echo "  ─────────────────────────────────────────────────────"
        echo "  [0] Back"
        echo ""

        local _sub
        while true; do
            read -p "Enter choice [0-5]: " _sub
            case "$_sub" in
                0) return 0 ;;
                1)
                    if [[ "$DIAG_ENABLED" == "yes" ]]; then
                        echo "  Already enabled."
                    else
                        break
                    fi ;;
                2|3|4|5)
                    if [[ "$DIAG_ENABLED" != "yes" ]]; then
                        echo "  Option unavailable — diagnostics monitor is not enabled."
                    else
                        break
                    fi ;;
                *) echo "  Please enter 0–5." ;;
            esac
        done

        case "$_sub" in
            1)
                # Enable — use component server picker for URL
                echo ""
                echo "  The diagnostics monitor is usually hosted on one of your component servers."
                echo ""
                local -a _diag_hosts=()
                local _all_svc_urls="${APP_SERVICE_URLS},${IDP_SERVICE_URLS},${API_SERVICE_URLS},${FILEMONITOR_SERVICE_URLS},${IMAGE_SERVICE_URLS}"
                local -A _diag_seen=()
                while IFS= read -r _dh; do
                    [[ -z "$_dh" ]] && continue
                    if [[ -z "${_diag_seen[$_dh]+x}" ]]; then
                        _diag_seen[$_dh]=1; _diag_hosts+=("$_dh")
                    fi
                done < <(echo "$_all_svc_urls" | tr ',' '\n' | sed -E 's#^https?://##; s#:[0-9]+$##' | grep -v '^$' | sort -u)

                local _diag_host=""
                if [[ ${#_diag_hosts[@]} -gt 0 ]]; then
                    echo "  Known component servers:"
                    local _dn=1
                    for _dh in "${_diag_hosts[@]}"; do
                        printf "    %d. %s\n" "$_dn" "$_dh"; _dn=$(( _dn + 1 ))
                    done
                    echo "    M. Enter manually"
                    echo ""
                    while true; do
                        read -p "  Select host [1-${#_diag_hosts[@]}/M]: " _dpick
                        _dpick="${_dpick^^}"
                        if [[ "$_dpick" == "M" ]]; then break
                        elif [[ "$_dpick" =~ ^[0-9]+$ ]] && (( _dpick >= 1 && _dpick <= ${#_diag_hosts[@]} )); then
                            _diag_host="${_diag_hosts[$(( _dpick - 1 ))]}"; break
                        else echo "  Invalid choice."; fi
                    done
                fi
                if [[ -z "$_diag_host" ]]; then
                    while true; do
                        read -p "  Hostname or IP: " _diag_host
                        _diag_host="${_diag_host// /}"
                        if [[ -n "$_diag_host" ]]; then break; fi
                        echo "  Error: Hostname cannot be empty."
                    done
                fi
                local _diag_port=""
                while true; do
                    read -p "  Port [default: 9090]: " _diag_port
                    _diag_port="${_diag_port:-9090}"
                    if [[ "$_diag_port" =~ ^[0-9]+$ ]] && (( _diag_port >= 1 && _diag_port <= 65535 )); then break; fi
                    echo "  Error: Enter a valid port (1-65535)."
                done
                DIAG_URL="https://${_diag_host}:${_diag_port}"
                echo ""
                local _diag_origin=""
                while true; do
                    read -p "  Public origin hostname (e.g. demo.haloap.com): " _diag_origin
                    _diag_origin="${_diag_origin// /}"
                    if [[ -n "$_diag_origin" ]]; then break; fi
                    echo "  Error: Hostname cannot be empty."
                done
                DIAG_AUTH_ADDRESS="https://${_diag_origin}/idsrv/connect/userinfo"
                echo ""
                while true; do
                    read -s -p "  Basic auth password for user 'diagnostics': " DIAG_PASSWORD
                    echo ""
                    if [[ -z "$DIAG_PASSWORD" ]]; then echo "  Error: Password cannot be empty."; continue; fi
                    local _diag_confirm=""
                    read -s -p "  Confirm password: " _diag_confirm
                    echo ""
                    if [[ "$DIAG_PASSWORD" == "$_diag_confirm" ]]; then break; fi
                    echo "  Error: Passwords do not match. Please try again."
                done
                DIAG_AUTH_TOKEN=$(printf 'diagnostics:%s' "$DIAG_PASSWORD" | base64 | tr -d '\n')
                DIAG_ENABLED="yes"
                echo ""
                echo "  ✓ Diagnostics monitor enabled"
                ;;
            2)
                # Update URL — use component server picker
                echo ""
                local -a _diag_hosts=()
                local _all_svc_urls="${APP_SERVICE_URLS},${IDP_SERVICE_URLS},${API_SERVICE_URLS},${FILEMONITOR_SERVICE_URLS},${IMAGE_SERVICE_URLS}"
                local -A _diag_seen=()
                while IFS= read -r _dh; do
                    [[ -z "$_dh" ]] && continue
                    if [[ -z "${_diag_seen[$_dh]+x}" ]]; then
                        _diag_seen[$_dh]=1; _diag_hosts+=("$_dh")
                    fi
                done < <(echo "$_all_svc_urls" | tr ',' '\n' | sed -E 's#^https?://##; s#:[0-9]+$##' | grep -v '^$' | sort -u)

                local _diag_host=""
                if [[ ${#_diag_hosts[@]} -gt 0 ]]; then
                    echo "  Known component servers:"
                    local _dn=1
                    for _dh in "${_diag_hosts[@]}"; do
                        printf "    %d. %s\n" "$_dn" "$_dh"; _dn=$(( _dn + 1 ))
                    done
                    echo "    M. Enter manually"
                    echo ""
                    while true; do
                        read -p "  Select host [1-${#_diag_hosts[@]}/M]: " _dpick
                        _dpick="${_dpick^^}"
                        if [[ "$_dpick" == "M" ]]; then break
                        elif [[ "$_dpick" =~ ^[0-9]+$ ]] && (( _dpick >= 1 && _dpick <= ${#_diag_hosts[@]} )); then
                            _diag_host="${_diag_hosts[$(( _dpick - 1 ))]}"; break
                        else echo "  Invalid choice."; fi
                    done
                fi
                if [[ -z "$_diag_host" ]]; then
                    local _cur_host="${DIAG_URL#https://}"; _cur_host="${_cur_host%%:*}"
                    while true; do
                        read -p "  Hostname or IP [current: ${_cur_host}]: " _diag_host
                        _diag_host="${_diag_host// /}"
                        _diag_host="${_diag_host:-$_cur_host}"
                        if [[ -n "$_diag_host" ]]; then break; fi
                        echo "  Error: Hostname cannot be empty."
                    done
                fi
                local _cur_port="${DIAG_URL##*:}"
                local _diag_port=""
                while true; do
                    read -p "  Port [current: ${_cur_port}]: " _diag_port
                    _diag_port="${_diag_port:-$_cur_port}"
                    if [[ "$_diag_port" =~ ^[0-9]+$ ]] && (( _diag_port >= 1 && _diag_port <= 65535 )); then break; fi
                    echo "  Error: Enter a valid port (1-65535)."
                done
                DIAG_URL="https://${_diag_host}:${_diag_port}"
                echo "  ✓ Service URL updated to: ${DIAG_URL}"
                ;;
            3)
                # Update auth address
                echo ""
                # Extract current origin for display
                local _cur_origin="${DIAG_AUTH_ADDRESS#https://}"
                _cur_origin="${_cur_origin%%/*}"
                local _diag_origin=""
                while true; do
                    read -p "  Public origin hostname [current: ${_cur_origin}]: " _diag_origin
                    _diag_origin="${_diag_origin// /}"
                    _diag_origin="${_diag_origin:-$_cur_origin}"
                    if [[ -n "$_diag_origin" ]]; then break; fi
                    echo "  Error: Hostname cannot be empty."
                done
                DIAG_AUTH_ADDRESS="https://${_diag_origin}/idsrv/connect/userinfo"
                echo "  ✓ Auth address updated to: ${DIAG_AUTH_ADDRESS}"
                ;;
            4)
                # Update password
                echo ""
                while true; do
                    read -s -p "  New Basic auth password for user 'diagnostics': " DIAG_PASSWORD
                    echo ""
                    if [[ -z "$DIAG_PASSWORD" ]]; then echo "  Error: Password cannot be empty."; continue; fi
                    local _diag_confirm=""
                    read -s -p "  Confirm new password: " _diag_confirm
                    echo ""
                    if [[ "$DIAG_PASSWORD" == "$_diag_confirm" ]]; then break; fi
                    echo "  Error: Passwords do not match. Please try again."
                done
                DIAG_AUTH_TOKEN=$(printf 'diagnostics:%s' "$DIAG_PASSWORD" | base64 | tr -d '\n')
                echo "  ✓ Basic auth password updated"
                ;;
            5)
                # Disable
                echo ""
                if ! prompt_yn "  Remove diagnostics monitor configuration?" "n"; then
                    echo "  Cancelled."
                    continue
                fi
                DIAG_ENABLED="no"
                DIAG_URL=""
                DIAG_AUTH_ADDRESS=""
                DIAG_PASSWORD=""
                DIAG_AUTH_TOKEN=""
                echo "  ✓ Diagnostics monitor disabled"
                ;;
        esac

        # Apply changes — regenerate file and restart Traefik
        echo ""
        echo "  Applying changes..."
        generate_diag_conf "$TRAEFIK_DYNAMIC_DIR"

        # Push to backup nodes if multi-node
        if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
            local _diag_file="${TRAEFIK_DYNAMIC_DIR}/diagnostics_monitor.yml"
            for i in "${!BACKUP_NODES[@]}"; do
                local _bn="${BACKUP_NODES[$i]}"
                local _bip="${BACKUP_IPS[$i]}"
                echo -n "  Pushing to ${_bn}... "
                if [[ "$DIAG_ENABLED" == "yes" && -f "$_diag_file" ]]; then
                    copy_to_remote "$_diag_file" "$_bip" \ || true
                        "/opt/indica/traefik/config/dynamic/diagnostics_monitor.yml"
                    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                        sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                            "chmod 640 /opt/indica/traefik/config/dynamic/diagnostics_monitor.yml" 2>/dev/null || true
                    else
                        ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                            "chmod 640 /opt/indica/traefik/config/dynamic/diagnostics_monitor.yml" 2>/dev/null || true
                    fi
                else
                    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                        sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                            "rm -f /opt/indica/traefik/config/dynamic/diagnostics_monitor.yml" 2>/dev/null || true
                    else
                        ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                            "rm -f /opt/indica/traefik/config/dynamic/diagnostics_monitor.yml" 2>/dev/null || true
                    fi
                fi
                echo "✓"
            done
        fi

        # Restart Traefik
        echo -n "  Restarting Traefik... "
        if docker_cmd compose -f "${_compose_dir}/docker-compose.yaml" \
            up -d --force-recreate >/dev/null 2>&1; then
            echo "✓"
        else
            sg docker -c "docker compose -f '${_compose_dir}/docker-compose.yaml' \
                up -d --force-recreate" >/dev/null 2>&1 && echo "✓" || echo "✗ restart failed"
        fi

        snapshot_config "DIAG_MONITOR" "Diagnostics monitor configuration changed"
        save_config
        echo "  ✓ Configuration saved"

    done
}

# Function to generate clinical_conf.yml based on deployment type (full or image-site) and prompts for service hostnames, protocols and ports using prompt_single_entry function
generate_clinical_conf() {
    local dynamic_dir="/opt/indica/traefik/config/dynamic"
    local config_file="${dynamic_dir}/clinical_conf.yml"
    local fresh_configuration=false

    # Ensure the dynamic directory exists
    mkdir -p "$dynamic_dir"

    # Check for deployment type change
    if [[ "$DEPLOYMENT_TYPE" != "$INITIAL_DEPLOYMENT_TYPE" ]]; then
        log "Fresh configuration required for changed deployment type"
        fresh_configuration=true
    fi

    if [[ "$DEPLOYMENT_TYPE" == "image-site" ]]; then
        # Image-site configuration
        local image_urls=""
        
        if [[ -n "$IMAGE_SERVICE_URLS" && "$fresh_configuration" == "false" ]]; then
            log "Using existing image service URLs from configuration"
            image_urls="$IMAGE_SERVICE_URLS"
        else
            # Prompt for new image service URLs
            local image_urls=""
            while true; do
                entry=$(prompt_single_entry "image-service" "8050")
                image_urls+="${image_urls:+,}$entry"
                
                prompt_yn "Add another image server?" "n" || break
            done
        fi

        # Store for config saving
        IMAGE_SERVICE_URLS="$image_urls"

        # Prompt for custom CA certificate for upstream HTTPS connections
        prompt_custom_ca

        # Generate config file
        cat > "$config_file" <<EOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: "/certs/cert.crt"
        keyFile: "/certs/server.key"
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
http:
EOF

        if [[ "$USE_CUSTOM_CA" == "yes" ]]; then
            cat >> "$config_file" <<EOF
  serversTransports:
    internalCA:
      rootcas:
        - /certs/customca.crt
EOF
        fi

        cat >> "$config_file" <<EOF
  services:
    image-service:
      loadBalancer:
EOF

        if [[ "$USE_CUSTOM_CA" == "yes" ]]; then
            echo "        serversTransport: internalCA" >> "$config_file"
        fi

        cat >> "$config_file" <<EOF
        healthCheck:
          path: /health
        servers:
EOF

        # Add servers
        IFS=',' read -ra urls <<< "$image_urls"
        for url in "${urls[@]}"; do
            echo "          - url: \"$url\"" >> "$config_file"
        done

        cat >> "$config_file" <<EOF
        sticky:
          cookie: {}
  routers:
    image-router:
      rule: "PathPrefix(\`/\`)"
      middlewares:
        - SecurityHeaders
        - compress
        - cors
      service: image-service
      tls: {}
      
  middlewares:
    SecurityHeaders:
      headers:
        customResponseHeaders:
          Strict-Transport-Security: 'max-age=31536000; includeSubDomains; preload'
          X-Content-Type-Options: 'nosniff'
          Server: ''
          X-Frame-Options: 'SAMEORIGIN'
        browserXssFilter: true
    compress:
      compress: {}

    cors:
      headers:
        accessControlAllowOriginList:
          - "*"
        accessControlAllowMethods:
          - "GET"
          - "OPTIONS"
        accessControlAllowHeaders:
          - "Authorization"
          - "Content-Type"
        accessControlAllowCredentials: false
        addVaryHeader: true
EOF

    else
        # Full deployment configuration
        if [[ "$fresh_configuration" == "true" ]]; then
            log "Resetting all service configurations for fresh full deployment"
            unset APP_SERVICE_URLS IDP_SERVICE_URLS API_SERVICE_URLS FILEMONITOR_SERVICE_URLS IMAGE_SERVICE_URLS
        fi

        # Ordered list of services
        local services_order=("app-service" "idp-service" "api-service" "filemonitor-service" "image-service")
        declare -A service_ports=(
            ["app-service"]="3000"
            ["idp-service"]="5002"
            ["api-service"]="4040"
            ["filemonitor-service"]="4444"
            ["image-service"]="8050"
        )

        declare -A service_urls
        # Load existing URLs from environment variables
        for service in "${services_order[@]}"; do
            sanitized_name="${service//-/_}_URLS"
            sanitized_name="${sanitized_name^^}"
            service_urls[$service]="${!sanitized_name}"
        done

        # Check if configuration is needed
        local need_configuration=0
        for service in "${services_order[@]}"; do
            if [[ -z "${service_urls[$service]}" ]]; then
                need_configuration=1
                break
            fi
        done

        # Run prompts if needed
        if [[ $need_configuration -eq 1 || "$fresh_configuration" == "true" ]]; then
            local batch_count=0
            local app_urls=""

            while true; do
                echo "" > /dev/tty
                echo "========================================" > /dev/tty
                echo " Host Configuration - Batch #$((batch_count + 1)) " > /dev/tty
                echo "========================================" > /dev/tty

                echo "Enter the details of the upstream Halo AP server for this batch." > /dev/tty
                echo "You will be prompted for the hostname (or IP), protocol, and port of the" > /dev/tty
                echo "App Service. You can then choose to apply the same host and protocol to" > /dev/tty
                echo "all other services (iDP, API, File Monitor, Image Service) on their" > /dev/tty
                echo "default ports, or configure each one individually." > /dev/tty
                echo "" > /dev/tty
                echo "If Halo AP is running across multiple servers, you can add further" > /dev/tty
                echo "batches when prompted. Each batch represents one upstream server node." > /dev/tty

                # Configure app-service
                current_app_entry=$(prompt_single_entry "app-service" "3000")
                app_urls+="${app_urls:+,}$current_app_entry"

                # Ask to apply to others
                printf "\n"

                # Clear batch_entries for this iteration
                unset batch_entries
                declare -A batch_entries

                if prompt_yn "Use the same HOST and PROTOCOL for the API, FM, iDP & Image Service using their default ports?" "n" < /dev/tty; then
                  if [[ $current_app_entry =~ ^(http[s]?)://([^:/]+):([0-9]+)$ ]]; then
                  protocol="${BASH_REMATCH[1]}"
                  host="${BASH_REMATCH[2]}"

              # Generate URLs for other services
              for service in "${services_order[@]}"; do
              [[ $service == "app-service" ]] && continue
              port="${service_ports[$service]}"
            
              new_entry="${protocol}://${host}:${port}"
            
              batch_entries[$service]+=",$new_entry"
              done
              fi
              else
              # Manual configuration
              for service in "${services_order[@]}"; do
                [[ $service == "app-service" ]] && continue
                entry=$(prompt_single_entry "$service" "${service_ports[$service]}")
            batch_entries[$service]+=",$entry"
            done
            fi

                # Merge URLs for other services
                for service in "${services_order[@]}"; do
                    [[ $service == "app-service" ]] && continue
                    IFS=',' read -ra existing_urls <<< "${service_urls[$service]}"
                    IFS=',' read -ra new_urls <<< "${batch_entries[$service]}"
                    
                    merged_urls=()
                    for url in "${existing_urls[@]}" "${new_urls[@]}"; do
                        if [[ -n "$url" && ! " ${merged_urls[@]} " =~ " ${url} " ]]; then
                            merged_urls+=("$url")
                        fi
                    done
                    service_urls[$service]=$(IFS=','; echo "${merged_urls[*]}")
                done

                printf "\n"
                prompt_yn "Add another batch?" "n" < /dev/tty || break
                
                # Increment batch count safely
                batch_count=$((batch_count + 1))
            done

            # Assign accumulated app_urls to app-service in service_urls after all batches
            service_urls["app-service"]="$app_urls"
        else
            log "Using existing service configurations from deployment.config"
            app_urls="${service_urls["app-service"]}"
        fi

        # Store URLs in global variables
        for service in "${services_order[@]}"; do
            sanitized_name="${service//-/_}_URLS"
            sanitized_name="${sanitized_name^^}"
            cleaned_value=$(echo "${service_urls[$service]}" | sed 's/^,//;s/,,/,/g')
            declare -g "$sanitized_name"="$cleaned_value"
        done

        # Prompt for custom CA certificate for upstream HTTPS connections
        prompt_custom_ca

        # Generate full configuration
        cat > "$config_file" <<EOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: "/certs/cert.crt"
        keyFile: "/certs/server.key"
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
http:
EOF

        if [[ "$USE_CUSTOM_CA" == "yes" ]]; then
            cat >> "$config_file" <<EOF
  serversTransports:
    internalCA:
      rootcas:
        - /certs/customca.crt
EOF
        fi

        echo "  services:" >> "$config_file"

        # Add services
        for service in "${services_order[@]}"; do
            cleaned_urls=$(echo "${service_urls[$service]}" | sed 's/^,//;s/,,/,/g')
            cat >> "$config_file" <<EOF
    $service:
      loadBalancer:
EOF

if [[ "$USE_CUSTOM_CA" == "yes" ]]; then
    echo "        serversTransport: internalCA" >> "$config_file"
fi

            cat >> "$config_file" <<EOF
        healthCheck:
          path: /health
EOF

# Sticky sessions
if [[ "$service" == "idp-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie: {}
EOF
elif [[ "$service" == "api-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie: {}
EOF
elif [[ "$service" == "image-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie: {}
EOF
fi

            # Servers
            cat >> "$config_file" <<EOF
        servers:
EOF
            IFS=',' read -ra urls <<< "$cleaned_urls"
            for url in "${urls[@]}"; do
                echo "          - url: \"$url\"" >> "$config_file"
            done
        done

        # Add static configuration
        cat >> "$config_file" <<EOF
  routers:
    idp-router-version:
      rule: "PathPrefix(\`/idsrv/version\`)"
      middlewares:
        - SecurityHeaders
        - idp-rewrite
        - compress
      service: idp-service
      tls: {}
    idp-router-health:
      rule: "PathPrefix(\`/idsrv/health\`)"
      middlewares:
        - SecurityHeaders
        - idp-rewrite
        - compress
      service: idp-service
      tls: {}
    idp-router:
      rule: "PathPrefix(\`/idsrv\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: idp-service
      tls: {}
    api-router-version:
      rule: "PathPrefix(\`/api/version\`)"
      middlewares:
        - SecurityHeaders
        - api-rewrite
        - compress
      service: api-service
      tls: {}
    api-router-health:
      rule: "PathPrefix(\`/api/health\`)"
      middlewares:
        - SecurityHeaders
        - api-rewrite
        - compress
      service: api-service
      tls: {}
    api-router:
      rule: "PathPrefix(\`/api\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: api-service
      tls: {}
    results-router:
      rule: "PathPrefix(\`/results\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: api-service
      tls: {}
    previews-router:
      rule: "PathPrefix(\`/previews\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: api-service
      tls: {}
    monitor-router:
      rule: "PathPrefix(\`/monitor\`)"
      middlewares:
        - monitor-rewrite
        - SecurityHeaders
        - compress
      service: filemonitor-service
      tls: {}
    image-router:
      rule: "PathPrefix(\`/image\`)"
      middlewares:
        - image-rewrite
        - SecurityHeaders
        - compress
      service: image-service
      tls: {}
    app-router:
      rule: "PathPrefix(\`/\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: app-service
      tls: {}
  middlewares:
    monitor-rewrite:
      stripPrefix:
        prefixes:
          - "/monitor"
    image-rewrite:
      stripPrefix:
        prefixes:
          - "/image"
    api-rewrite:
      stripPrefix:
        prefixes:
          - "/api"
    idp-rewrite:
      stripPrefix:
        prefixes:
          - "/idsrv"
    SecurityHeaders:
      headers:
        customResponseHeaders:
          Strict-Transport-Security: 'max-age=31536000; includeSubDomains; preload'
          X-Content-Type-Options: 'nosniff'
          Server: ''
          X-Frame-Options: 'SAMEORIGIN'
        browserXssFilter: true
    compress:
      compress: {}
EOF

    fi

    log "clinical_conf.yml file generated successfully at $config_file."
}

# ==========================================
# SSL Certificate Functions
# ==========================================

# Function to read multi-line input reliably for SSL input into terminal
read_multiline() {
    exec 3>/dev/tty  # Terminal output
    exec 4</dev/tty  # Terminal input

    echo "Paste your content below (include BEGIN/END lines)." >&3
    echo "Type 'EOF' on a separate line to finish:" >&3
    echo "" >&3

    local input=""
    local line
    
    while IFS= read -r line <&4; do
        # Trim whitespace and check for EOF
        local trimmed_line=$(echo "$line" | awk '{$1=$1;print}' | tr '[:lower:]' '[:upper:]')
        
        if [[ "$trimmed_line" == "EOF" ]]; then
            break
        fi
        
        # Preserve original line formatting
        input+="$line"$'\n'
    done

    # Remove trailing newline added by the loop
    input="${input%$'\n'}"

    exec 3>&-
    exec 4<&-
    
    echo -n "$input"
}

# Enhanced SSL CERTIFICATE INPUT Validation
validate_ssl_cert() {
    local cert="$1"

    # Check for empty input
    [[ -z "$cert" ]] && { echo -e "\nError: Certificate input is empty.\n" >&2; return 1; }

    # Check for extraneous text after PEM content
    if ! echo "$cert" | awk '/-----BEGIN CERTIFICATE-----/ {flag=1} flag; /-----END CERTIFICATE-----/ {flag=0}' | grep -q .; then
        echo -e "\nError: Certificate contains extra text outside PEM boundaries.\n" >&2
        return 1
    fi

    # Validate the certificate using openssl
    if ! echo "$cert" | openssl x509 -noout > /dev/null 2>&1; then
        echo -e "\nError: Invalid certificate format or content.\n" >&2
        return 1
    fi

    # If all checks pass, the certificate is valid
    echo -e "\nCertificate is valid.\n" >&2
    return 0
}

# CA Certificate Validation - CA certs share the same PEM format as regular certs
validate_ssl_ca() {
    validate_ssl_cert "$1"
}

# Enhanced SSL KEY INPUT Validation
validate_ssl_key() {
    local key="$1"

    # Check for empty input
    [[ -z "$key" ]] && { echo -e "\nError: Key input is empty.\n" >&2; return 1; }

    # Check for extraneous text after PEM content
    if ! echo "$key" | awk '/-----BEGIN.*PRIVATE KEY-----/ {flag=1} flag; /-----END.*PRIVATE KEY-----/ {flag=0}' | grep -q .; then
        echo -e "\nError: Key contains extra text outside PEM boundaries.\n" >&2
        return 1
    fi

    # Validate the key using openssl
    if ! echo "$key" | openssl pkey -noout > /dev/null 2>&1; then
        echo -e "\nError: Invalid key format or content.\n" >&2
        return 1
    fi

    # If all checks pass, the key is valid
    echo -e "\nKey is valid.\n" >&2
    return 0
}

# Enhanced SSL CERTIFICATE and SSL KEY Prompt
prompt_ssl_input() {
    local type="$1"
    local header_type="CERTIFICATE"
    local example=""

    case "$type" in
        "certificate")
            header_type="CERTIFICATE"
            example=$'-----BEGIN CERTIFICATE-----\nMIIDXTCCAkWgAwIBAgIJAN...\n-----END CERTIFICATE-----'
            validation_func="validate_ssl_cert"
            ;;
        "key")
            header_type="PRIVATE KEY"
            example=$'-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG...\n-----END PRIVATE KEY-----'
            validation_func="validate_ssl_key"
            ;;
        *) return 1 ;;
    esac

    local prompt_message=$(cat <<EOF

________________________________________________
# Paste SSL ${type} in PEM format including headers #
________________________________________________


Required format:
-----BEGIN ${header_type}-----
[Your base64-encoded content]
-----END ${header_type}-----

________________________________________________

EOF
)

    local attempts=0
    local max_attempts=3
    local input

    while (( attempts < max_attempts )); do
        printf "%s\n\n" "$prompt_message" > /dev/tty
        input=$(read_multiline)

        # Check for empty input
        [[ -z "$input" ]] && continue

        # Validate using the appropriate function
        if $validation_func "$input"; then
            echo -n "$input"
            return 0
        fi

    echo "Invalid ${type} format. Please check:" > /dev/tty
    echo "1. First line must be: -----BEGIN ${header_type}-----" > /dev/tty
    echo "2. Last line must be: -----END ${header_type}-----" > /dev/tty
    echo "3. No extra text before/after headers" > /dev/tty
    echo "4. Valid ${type} content between headers" > /dev/tty
        ((attempts++))
    done

    echo "Too many failed attempts. Exiting..." > /dev/tty
    exit 1
}

# Prompt for custom CA certificate for upstream TLS verification
prompt_custom_ca() {
    # Skip if already configured (re-run scenario)
    if [[ "$USE_CUSTOM_CA" == "yes" && -n "$CUSTOM_CA_CERT_CONTENT" ]]; then
        log "Using existing custom CA certificate from configuration"
        return 0
    fi

    echo ""
    echo ""
    echo ""
    echo ":: Custom CA Certificate (Optional)"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "  If your component servers use TLS certificates signed by a private"
    echo "  or internal CA, Traefik needs that CA certificate to verify upstream"
    echo "  connections."
    echo ""

    read -p "Would you like to use a custom CA certificate for upstream TLS? [y/N]: " ca_choice < /dev/tty
    ca_choice=${ca_choice:-n}
    ca_choice=$(echo "$ca_choice" | tr '[:upper:]' '[:lower:]')

    if [[ "$ca_choice" == "y" || "$ca_choice" == "yes" ]]; then
        USE_CUSTOM_CA="yes"
        echo "" > /dev/tty
        echo "Please paste your CA certificate (PEM format) below." > /dev/tty
        CUSTOM_CA_CERT_CONTENT=$(prompt_ssl_input "certificate")
    else
        USE_CUSTOM_CA="no"
        CUSTOM_CA_CERT_CONTENT=""
    fi
}

# Function to check if SSL CERTIFICATE matches the provided SSL KEY
check_key_cert_match() {
    local CERT_FILE="$1"
    local KEY_FILE="$2"

    # Extract SHA-256 hash of public keys
    cert_pubkey_hash=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform der | sha256sum | awk '{print $1}')
    key_pubkey_hash=$(openssl pkey -in "$KEY_FILE" -pubout -outform der | sha256sum | awk '{print $1}')

    # Compare hashes
    if [ "$cert_pubkey_hash" != "$key_pubkey_hash" ]; then
        exit_on_error "The certificate and private key do not match!"
    else
        log "The certificate and private key match!"
    fi
}

# ==========================================
# Configuration Saving
# ==========================================

# Function to save configuration settings
save_config() {
    # Read the content of the certificate and key files
    SSL_CERT_CONTENT=$(cat "$CERT_FILE")
    SSL_KEY_CONTENT=$(cat "$KEY_FILE")

    # Save all configuration values to deployment.config
    cat > "$CONFIG_FILE" <<EOF
DEPLOYMENT_TYPE="$DEPLOYMENT_TYPE"
CERT_DIR="$CERT_DIR"
CERT_FILE="$CERT_FILE"
KEY_FILE="$KEY_FILE"
SSL_CERT_CONTENT="$SSL_CERT_CONTENT"
SSL_KEY_CONTENT="$SSL_KEY_CONTENT"
USE_CUSTOM_CA="$USE_CUSTOM_CA"
CUSTOM_CA_CERT_CONTENT="$CUSTOM_CA_CERT_CONTENT"
VRRP="$VRRP"
VIRTUAL_IP="$VIRTUAL_IP"
VRID="$VRID"
AUTH_PASS="$AUTH_PASS"
NETWORK_INTERFACE="$NETWORK_INTERFACE"
MULTI_NODE_DEPLOYMENT="$MULTI_NODE_DEPLOYMENT"
HL7_ENABLED="$HL7_ENABLED"
HL7_LISTEN_PORTS="$HL7_LISTEN_PORTS"
HL7_PORT_BACKENDS="$HL7_PORT_BACKENDS"
HL7_PORT_COMMENTS="$HL7_PORT_COMMENTS"
DIAG_ENABLED="$DIAG_ENABLED"
DIAG_URL="$DIAG_URL"
DIAG_AUTH_ADDRESS="$DIAG_AUTH_ADDRESS"
DIAG_PASSWORD="$DIAG_PASSWORD"
DIAG_AUTH_TOKEN="$DIAG_AUTH_TOKEN"
EOF

    # Save multi-node configuration if applicable
    if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
        cat >> "$CONFIG_FILE" <<EOF
MASTER_HOSTNAME="$MASTER_HOSTNAME"
MASTER_IP="$MASTER_IP"
BACKUP_NODE_COUNT="${#BACKUP_NODES[@]}"
EOF
        # Save backup nodes with interfaces
        for i in "${!BACKUP_NODES[@]}"; do
            echo "BACKUP_NODES[$i]=\"${BACKUP_NODES[$i]}\"" >> "$CONFIG_FILE"
            echo "BACKUP_IPS[$i]=\"${BACKUP_IPS[$i]}\"" >> "$CONFIG_FILE"
            echo "BACKUP_INTERFACES[$i]=\"${BACKUP_INTERFACES[$i]}\"" >> "$CONFIG_FILE"
        done
    fi

    # Conditionally save service URLs based on deployment type
    if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
        cat >> "$CONFIG_FILE" <<EOF
APP_SERVICE_URLS="$APP_SERVICE_URLS"
IDP_SERVICE_URLS="$IDP_SERVICE_URLS"
API_SERVICE_URLS="$API_SERVICE_URLS"
FILEMONITOR_SERVICE_URLS="$FILEMONITOR_SERVICE_URLS"
IMAGE_SERVICE_URLS="$IMAGE_SERVICE_URLS"
EOF
    else
        cat >> "$CONFIG_FILE" <<EOF
IMAGE_SERVICE_URLS="$IMAGE_SERVICE_URLS"
EOF
    fi
    
    log "Configuration saved to $CONFIG_FILE"

    # Push a backup copy of deployment.config to each backup node
    # so the config can be recovered if the master is lost
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        local _backup_dest="/opt/indica/traefik/backups/master_config"
        local _readme_tmp
        _readme_tmp=$(mktemp)
        cat > "$_readme_tmp" <<READMETXT
Master Node Configuration Backup
═════════════════════════════════════════════════════════════════
This directory contains a backup copy of the master node's
deployment configuration, automatically pushed after every change.

To recover if the master node is permanently lost:

  1. Set up a new server with the same OS
  2. Copy deployment.config to the new master:
       scp deployment.config user@new-master:/opt/indica/traefik/
  3. Run the setup script on the new master — it will detect the
     config and offer to reinstall using the existing settings

Master details at time of last backup:
  Hostname : ${MASTER_HOSTNAME:-$(hostname -s)}
  IP       : ${MASTER_IP:-$(hostname -I | awk '{print $1}')}
  Updated  : $(date +'%Y-%m-%d %H:%M:%S')
READMETXT

        for i in "${!BACKUP_NODES[@]}"; do
            local _bip="${BACKUP_IPS[$i]}"
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                    "mkdir -p ${_backup_dest}" 2>/dev/null || true
            else
                ssh $SSH_OPTS -l "$CURRENT_USER" "$_bip" \
                    "mkdir -p ${_backup_dest}" 2>/dev/null || true
            fi
            copy_to_remote "$CONFIG_FILE"  "$_bip" "${_backup_dest}/deployment.config"    2>/dev/null || true
            copy_to_remote "$_readme_tmp"  "$_bip" "${_backup_dest}/RECOVERY_README.txt"  2>/dev/null || true
        done
        rm -f "$_readme_tmp"
        log "deployment.config backup pushed to backup nodes → ${_backup_dest}"
    fi
}

# ==========================================
# MAIN SCRIPT EXECUTION
# ==========================================

# Create scripts directory with correct ownership
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    rm -rf -- "$SCRIPTS_DIR"
    sudo -u "$SUDO_USER" mkdir -p -- "$SCRIPTS_DIR"
    sudo -u "$SUDO_USER" chmod 755 -- "$SCRIPTS_DIR"
else
    rm -rf -- "$SCRIPTS_DIR"
    mkdir -p -- "$SCRIPTS_DIR"
    chmod 755 -- "$SCRIPTS_DIR"
fi

# ==========================================
# Migrate legacy clinical_traefik.env → deployment.config
# ==========================================

# Check for legacy env file in the script directory or current directory
_legacy_env=""
if [[ -f "${SCRIPT_DIR}/clinical_traefik.env" ]]; then
    _legacy_env="${SCRIPT_DIR}/clinical_traefik.env"
elif [[ -f "${PWD}/clinical_traefik.env" ]]; then
    _legacy_env="${PWD}/clinical_traefik.env"
fi

if [[ -n "$_legacy_env" && ! -f "$CONFIG_FILE" ]]; then
    echo ""
    echo ":: Legacy Configuration Detected"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo "  Found: ${_legacy_env}"
    echo ""
    echo "  This file was used by a previous version of this script."
    echo "  It will be migrated to the new deployment.config format."
    echo ""

    if prompt_yn "  Migrate now?" "y"; then
        # Copy to deployment.config location
        mkdir -p "$(dirname "$CONFIG_FILE")"
        chown -R root:root /opt/indica 2>/dev/null || true
        cp "$_legacy_env" "$CONFIG_FILE"

        # Add any missing newer variables with defaults
        _add_vars=()
        grep -q '^HL7_ENABLED=' "$CONFIG_FILE"       || _add_vars+=('HL7_ENABLED="no"')
        grep -q '^HL7_LISTEN_PORTS=' "$CONFIG_FILE"  || _add_vars+=('HL7_LISTEN_PORTS=""')
        grep -q '^HL7_PORT_BACKENDS=' "$CONFIG_FILE" || _add_vars+=('HL7_PORT_BACKENDS=""')
        grep -q '^HL7_PORT_COMMENTS=' "$CONFIG_FILE" || _add_vars+=('HL7_PORT_COMMENTS=""')
        grep -q '^USE_CUSTOM_CA=' "$CONFIG_FILE"     || _add_vars+=('USE_CUSTOM_CA="no"')
        grep -q '^CUSTOM_CA_CERT_CONTENT=' "$CONFIG_FILE" || _add_vars+=('CUSTOM_CA_CERT_CONTENT=""')
        grep -q '^DIAG_ENABLED=' "$CONFIG_FILE"      || _add_vars+=('DIAG_ENABLED="no"')
        grep -q '^DIAG_URL=' "$CONFIG_FILE"          || _add_vars+=('DIAG_URL=""')
        grep -q '^DIAG_AUTH_ADDRESS=' "$CONFIG_FILE" || _add_vars+=('DIAG_AUTH_ADDRESS=""')
        grep -q '^DIAG_PASSWORD=' "$CONFIG_FILE"     || _add_vars+=('DIAG_PASSWORD=""')
        grep -q '^DIAG_AUTH_TOKEN=' "$CONFIG_FILE"   || _add_vars+=('DIAG_AUTH_TOKEN=""')

        for _var in "${_add_vars[@]}"; do
            echo "$_var" >> "$CONFIG_FILE"
        done

        # Archive the original
        mv "$_legacy_env" "${_legacy_env}.migrated.$(date +'%Y%m%d%H%M%S')"

        audit_log "MIGRATION" "Migrated ${_legacy_env} → ${CONFIG_FILE}"

        echo ""
        echo "  ✓ Migration complete"
        echo "    Config saved to : ${CONFIG_FILE}"
        echo "    Original renamed: ${_legacy_env}.migrated.*"
        echo ""
    else
        echo "  Migration skipped. The legacy file will not be used."
        echo ""
    fi
fi


# ==========================================
# Migrate legacy /home/haloap install → /opt/indica
# ==========================================

if [[ -d "/home/haloap/traefik" && ! -d "/opt/indica/traefik" ]]; then
    echo ""
    echo ":: Legacy Installation Detected"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo "  An existing installation was found at /home/haloap/traefik."
    echo "  This will be migrated to /opt/indica/traefik."
    echo "  All file paths in config files will be updated automatically."
    echo ""

    if prompt_yn "  Migrate now?" "y"; then

        echo ""
        echo -n "  Stopping Traefik... "
        (cd /home/haloap/traefik && docker compose down 2>/dev/null) || true
        echo "✓"

        echo -n "  Moving files to /opt/indica/traefik... "
        mkdir -p /opt/indica
        mv /home/haloap/traefik /opt/indica/traefik
        echo "✓"

        echo -n "  Updating path references in config files... "
        sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/deployment.config 2>/dev/null || true
        sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/config/traefik.yml 2>/dev/null || true
        sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/docker-compose.yaml 2>/dev/null || true
        find /opt/indica/traefik/config/dynamic -name "*.yml" \
            -exec sed -i 's|/home/haloap|/opt/indica|g' {} \; 2>/dev/null || true
        echo "✓"

        echo -n "  Setting ownership to root:root... "
        chown -R root:root /opt/indica/traefik
        chmod -R 755 /opt/indica/traefik
        chmod 600 /opt/indica/traefik/certs/server.key 2>/dev/null || true
        echo "✓"

        # Update CONFIG_FILE
        CONFIG_FILE="/opt/indica/traefik/deployment.config"

        # Migrate backup nodes if multi-node
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE" 2>/dev/null || true
        fi

        if [[ "${MULTI_NODE_DEPLOYMENT:-no}" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
            echo ""
            echo "  Migrating backup nodes..."

            if [[ -z "${SUDO_PASS:-}" ]]; then
                read -s -p "  Enter sudo password for remote hosts: " SUDO_PASS
                echo ""
                export SUDO_PASS
                SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
            fi

            for i in "${!BACKUP_NODES[@]}"; do
                _bn="${BACKUP_NODES[$i]}"
                _bip="${BACKUP_IPS[$i]}"
                echo -n "  ${_bn} (${_bip})... "

                _migrate_script="$SCRIPTS_DIR/migrate_${_bn}.sh"
                write_local_file "$_migrate_script" <<'MIGRATESCRIPT'
#!/bin/bash
set -e
if [[ ! -d "/home/haloap/traefik" ]]; then
    echo "Nothing to migrate — /home/haloap/traefik not found"
    exit 0
fi
if [[ -d "/opt/indica/traefik" ]]; then
    echo "Already migrated — /opt/indica/traefik exists"
    exit 0
fi
mkdir -p /opt/indica
mv /home/haloap/traefik /opt/indica/traefik
sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/deployment.config 2>/dev/null || true
sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/config/traefik.yml 2>/dev/null || true
sed -i 's|/home/haloap|/opt/indica|g' /opt/indica/traefik/docker-compose.yaml 2>/dev/null || true
find /opt/indica/traefik/config/dynamic -name "*.yml" \
    -exec sed -i 's|/home/haloap|/opt/indica|g' {} \; 2>/dev/null || true
chown -R root:root /opt/indica/traefik
chmod -R 755 /opt/indica/traefik
chmod 600 /opt/indica/traefik/certs/server.key 2>/dev/null || true
docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate 2>/dev/null || \
    sg docker -c "docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate" 2>/dev/null || true
echo "✓ Migration complete"
MIGRATESCRIPT

                chmod 644 "$_migrate_script"
                ensure_SCRIPTS_DIR "$_bip" || true
                copy_to_remote "$_migrate_script" "$_bip" "$_migrate_script" || true
                _out=$(execute_remote_script "$_bip" "$_migrate_script" 2>&1) \
                    && echo "✓" \
                    || { echo "⚠️  check manually"; echo "$_out" | grep -v "^Connection to\|^Shared" | sed 's/^/    /'; }
                rm -f "$_migrate_script"
            done
        fi

        # Restart Traefik from new location
        echo -n "  Starting Traefik from new location... "
        docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate 2>/dev/null \
            && echo "✓" || echo "⚠️  Please start manually: docker compose -f /opt/indica/traefik/docker-compose.yaml up -d"

        audit_log "MIGRATION" "Migrated /home/haloap/traefik → /opt/indica/traefik, ownership → root:root"

        echo ""
        echo "  ✓ Migration complete"
        echo "    New path : /opt/indica/traefik"
        echo "    Owner    : root:root"
        echo ""
    else
        echo "  Migration skipped."
        echo "  Note: This script now uses /opt/indica/traefik."
        echo ""
    fi
fi

# ==========================================
# Status Mode — must be after all function definitions
# ==========================================

if [[ "$1" == "--status" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
    fi
    show_status
    exit 0
fi

# Prompt user to use existing configuration if file exists
prompt_use_existing_config

# Prompt for deployment type (full or image-site)
prompt_deployment_type

# Prompt for multi-node deployment
prompt_multi_node_deployment

######################################################
### START Multi-Node SSH Setup (if applicable)
######################################################

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo ""
    echo ""
    echo ""
    echo ":: Multi-Node SSH Setup"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "Setting up SSH keys for passwordless access..."
    echo ""
    
    # Check if SSH key exists
    if [ ! -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]; then
        echo "No SSH key found for $CURRENT_USER. Generating one..."
        mkdir -p "$ACTUAL_HOME/.ssh"
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown -R "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/.ssh"
            chmod 700 "$ACTUAL_HOME/.ssh"
            sudo -u "$SUDO_USER" ssh-keygen -t rsa -b 4096 -N "" -f "$ACTUAL_HOME/.ssh/id_rsa"
        else
            chmod 700 "$ACTUAL_HOME/.ssh"
            ssh-keygen -t rsa -b 4096 -N "" -f "$ACTUAL_HOME/.ssh/id_rsa"
        fi
        
        chmod 600 "$ACTUAL_HOME/.ssh/id_rsa"
        chmod 644 "$ACTUAL_HOME/.ssh/id_rsa.pub"
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/.ssh/id_rsa"
            chown "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/.ssh/id_rsa.pub"
        fi
    else
        echo "SSH key already exists for $CURRENT_USER"
    fi
    
    echo "SSH Key: $ACTUAL_HOME/.ssh/id_rsa.pub"
    ssh-keygen -lf "$ACTUAL_HOME/.ssh/id_rsa.pub"
    echo ""
    
    # Copy SSH keys to all backup nodes
    for i in "${!BACKUP_NODES[@]}"; do
        node="${BACKUP_NODES[$i]}"
        ip="${BACKUP_IPS[$i]}"
        
        echo "Copying SSH key to $node ($ip)..."
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            sudo -u "$SUDO_USER" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$ACTUAL_HOME/.ssh/id_rsa.pub" -o "User=$CURRENT_USER" "$ip" || {
                echo "⚠️  Warning: Failed to copy SSH key to $node"
                echo "   You may need to manually copy the key or enter password during deployment"
            }
        else
            ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$ACTUAL_HOME/.ssh/id_rsa.pub" -o "User=$CURRENT_USER" "$ip" || {
                echo "⚠️  Warning: Failed to copy SSH key to $node"
                echo "   You may need to manually copy the key or enter password during deployment"
            }
        fi
    done
    
    echo ""
    echo "✓ SSH keys configured"
    echo ""
    
    # Verify passwordless SSH
    echo "Verifying passwordless SSH to backup nodes..."
    echo ""
    
    SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
    SSH_FAILED=0
    FAILED_SSH_NODES=()
    
    for i in "${!BACKUP_NODES[@]}"; do
        node="${BACKUP_NODES[$i]}"
        ip="${BACKUP_IPS[$i]}"
        
        echo -n "Testing SSH to $node ($ip)... "
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            TEST_RESULT=$(sudo -u "$SUDO_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" "echo SSH_TEST_OK" 2>/dev/null)
        else
            TEST_RESULT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" "echo SSH_TEST_OK" 2>/dev/null)
        fi
        
        if echo "$TEST_RESULT" | grep -q "SSH_TEST_OK"; then
            echo "✓ Passwordless SSH working"
        else
            echo "❌ FAILED"
            SSH_FAILED=1
            FAILED_SSH_NODES+=("$node ($ip)")
        fi
    done
    
    if [ $SSH_FAILED -eq 1 ]; then
        echo ""
        echo "ERROR: Passwordless SSH failed for:"
        for failed in "${FAILED_SSH_NODES[@]}"; do
            echo "  - $failed"
        done
        echo ""
        exit_on_error "Cannot proceed without passwordless SSH access to all nodes"
    fi
    
    echo ""
    echo "✓ Passwordless SSH verified on all backup nodes"
    echo ""
    
    # Get and verify sudo password
    read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
    echo ""
    export SUDO_PASS
    
    # Test sudo on all backup nodes
    echo "Verifying sudo access on backup nodes..."
    SUDO_TEST_FAILED=0
    FAILED_SUDO_NODES=()
    
    set +e
    
    for i in "${!BACKUP_NODES[@]}"; do
        node="${BACKUP_NODES[$i]}"
        ip="${BACKUP_IPS[$i]}"
        
        echo -n "Testing sudo on $node... "
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            SUDO_EXISTS=$(sudo -u "$SUDO_USER" ssh -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" "command -v sudo" 2>/dev/null)
        else
            SUDO_EXISTS=$(ssh -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" "command -v sudo" 2>/dev/null)
        fi
        
        if [ -z "$SUDO_EXISTS" ]; then
            echo "❌ sudo not installed"
            SUDO_TEST_FAILED=1
            FAILED_SUDO_NODES+=("$node ($ip) - sudo not installed")
            continue
        fi
        
        PASS_B64=$(printf '%s' "$SUDO_PASS" | base64 -w0 2>/dev/null || printf '%s' "$SUDO_PASS" | base64)
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            TEST_RESULT=$(sudo -u "$SUDO_USER" ssh -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "echo \"$PASS_B64\" | base64 -d | sudo -S -k echo SUDO_OK 2>&1" 2>/dev/null | tail -1)
        else
            TEST_RESULT=$(ssh -o ConnectTimeout=5 $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                "echo \"$PASS_B64\" | base64 -d | sudo -S -k echo SUDO_OK 2>&1" 2>/dev/null | tail -1)
        fi
        
        if echo "$TEST_RESULT" | grep -q "SUDO_OK"; then
            echo "✓"
        elif echo "$TEST_RESULT" | grep -qi "sorry"; then
            echo "❌ incorrect password"
            SUDO_TEST_FAILED=1
            FAILED_SUDO_NODES+=("$node ($ip) - incorrect password")
        elif echo "$TEST_RESULT" | grep -qi "not in the sudoers"; then
            echo "❌ no sudo privileges"
            SUDO_TEST_FAILED=1
            FAILED_SUDO_NODES+=("$node ($ip) - no sudo privileges")
        else
            echo "❌ FAILED"
            SUDO_TEST_FAILED=1
            FAILED_SUDO_NODES+=("$node ($ip) - unexpected error")
        fi
    done
    
    set -e
    
    if [ $SUDO_TEST_FAILED -eq 1 ]; then
        echo ""
        echo "ERROR: Sudo verification failed on:"
        for failed in "${FAILED_SUDO_NODES[@]}"; do
            echo "  - $failed"
        done
        echo ""
        exit_on_error "Cannot proceed without sudo access on all nodes"
    fi
    
    echo "✓ Sudo verified on all backup nodes"
    echo ""
fi

######################################################
### START Attempt to auto-detect network interfaces on backup nodes

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo ""
    echo ""
    echo ""
    echo ":: Network Interface Configuration"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "Configuring network interfaces for Keepalived Virtual IP... Please set the network interface on each node the VIP should bind to"
    echo ""
    
    # ==========================================
    # Configure Master Node Interface
    # ==========================================
    
    echo "Master Node Configuration ($MASTER_HOSTNAME - $MASTER_IP):"
    echo ""
    
    # Attempt auto-detection for master
    echo "Attempting to detect network interface..."
    master_detected_interface=$(ip -o addr show | grep "inet $MASTER_IP" | awk '{print $2}' | head -1)
    
    if [ -n "$master_detected_interface" ]; then
        echo "  ✓ Detected interface: $master_detected_interface"
        echo ""
        
        # Show all available interfaces
        echo "  All available interfaces on this system:"
        ip -o link show | awk '{print "    - " $2}' | sed 's/:$//' | grep -v lo
        echo ""
        
        # Prompt user
        while true; do
            read -p "  Use detected interface '$master_detected_interface'? (y/n/other) [Y/n]: " use_detected
            use_detected=${use_detected:-y}
            
            case "${use_detected,,}" in
                y)
                    NETWORK_INTERFACE="$master_detected_interface"
                    echo "  ✓ Master interface set to: $NETWORK_INTERFACE"
                    break
                    ;;
                n|other)
                    echo ""
                    echo "  Available interfaces:"
                    ip -o link show | awk '{print "    - " $2}' | sed 's/:$//' | grep -v lo
                    echo ""
                    read -p "  Enter interface name: " custom_interface
                    
                    if ip link show "$custom_interface" &>/dev/null; then
                        NETWORK_INTERFACE="$custom_interface"
                        echo "  ✓ Master interface set to: $NETWORK_INTERFACE"
                        break
                    else
                        echo "  ⚠️  Interface '$custom_interface' not found"
                        if prompt_yn "  Use it anyway?" "n"; then
                            NETWORK_INTERFACE="$custom_interface"
                            echo "  ⚠️  Master interface set to: $NETWORK_INTERFACE (unverified)"
                            break
                        fi
                    fi
                    ;;
                *)
                    echo "  ERROR: Please enter 'yes', 'no', or 'other'"
                    continue
                    ;;
            esac
        done
    else
        echo "  ⚠️  Auto-detection failed"
        echo ""
        echo ""
        echo "  Available interfaces on this system:"
        ip -o link show | awk '{print "    - " $2}' | sed 's/:$//' | grep -v lo
        echo ""
        
        while true; do
            read -p "  Enter interface name: " manual_interface
            if [ -z "$manual_interface" ]; then
                echo "  ERROR: Interface name cannot be empty"
                continue
            fi
            
            if ip link show "$manual_interface" &>/dev/null; then
                NETWORK_INTERFACE="$manual_interface"
                echo "  ✓ Master interface set to: $NETWORK_INTERFACE"
                break
            else
                echo "  ⚠️  Interface '$manual_interface' not found"
                if prompt_yn "  Use it anyway?" "n"; then
                    NETWORK_INTERFACE="$manual_interface"
                    echo "  ⚠️  Master interface set to: $NETWORK_INTERFACE (unverified)"
                    break
                fi
            fi
        done
    fi
    
    echo ""
    
    # ==========================================
    # Configure Backup Node Interfaces
    # ==========================================
    
    if [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        echo "Backup Nodes Configuration:"
        echo ""
        
        for i in "${!BACKUP_NODES[@]}"; do
            node="${BACKUP_NODES[$i]}"
            ip="${BACKUP_IPS[$i]}"
            
            echo "  Configuring $node ($ip):"
            
            # Attempt auto-detection
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                detected_interface=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "ip -o addr show | grep 'inet $ip' | awk '{print \$2}' | head -1" 2>/dev/null)
            else
                detected_interface=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                    "ip -o addr show | grep 'inet $ip' | awk '{print \$2}' | head -1" 2>/dev/null)
            fi
            
            if [ -n "$detected_interface" ]; then
                echo "    ✓ Detected interface: $detected_interface"
                
                # Show available interfaces
                echo ""
                echo "    Available interfaces on $node:"
                if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                    sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                else
                    ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                fi
                echo ""
                
                # Prompt user
                while true; do
                    read -p "    Use detected interface '$detected_interface'? (y/n/other) [Y/n]: " use_detected
                    use_detected=${use_detected:-y}
                    
                    case "${use_detected,,}" in
                        y)
                            BACKUP_INTERFACES[$i]="$detected_interface"
                            echo "    ✓ Interface set to: $detected_interface"
                            break
                            ;;
                        n|other)
                            echo ""
                            read -p "    Enter interface name: " custom_interface
                            
                            # Validate on remote
                            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                                interface_exists=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                                    "ip link show $custom_interface 2>/dev/null" 2>/dev/null)
                            else
                                interface_exists=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                                    "ip link show $custom_interface 2>/dev/null" 2>/dev/null)
                            fi
                            
                            if [ -n "$interface_exists" ]; then
                                BACKUP_INTERFACES[$i]="$custom_interface"
                                echo "    ✓ Interface set to: $custom_interface"
                                break
                            else
                                echo "    ⚠️  Interface '$custom_interface' not found on $node"
                                if prompt_yn "    Use it anyway?" "n"; then
                                    BACKUP_INTERFACES[$i]="$custom_interface"
                                    echo "    ⚠️  Interface set to: $custom_interface (unverified)"
                                    break
                                fi
                            fi
                            ;;
                        *)
                            echo "    Please enter 'y', 'n', or 'other'"
                            continue
                            ;;
                    esac
                done
            else
                echo "    ⚠️  Auto-detection failed"
                echo ""
                echo "    Available interfaces on $node:"
                if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                    sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                else
                    ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                fi
                echo ""
                
                while true; do
                    read -p "    Enter interface name for $node: " manual_interface
                    if [ -z "$manual_interface" ]; then
                        echo "    ERROR: Interface name cannot be empty"
                        continue
                    fi
                    
                    # Validate on remote
                    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                        interface_exists=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "ip link show $manual_interface 2>/dev/null" 2>/dev/null)
                    else
                        interface_exists=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" \
                            "ip link show $manual_interface 2>/dev/null" 2>/dev/null)
                    fi
                    
                    if [ -n "$interface_exists" ]; then
                        BACKUP_INTERFACES[$i]="$manual_interface"
                        echo "    ✓ Interface set to: $manual_interface"
                        break
                    else
                        echo "    ⚠️  Interface '$manual_interface' not found on $node"
                        if prompt_yn "    Use it anyway?" "n"; then
                            BACKUP_INTERFACES[$i]="$manual_interface"
                            echo "    ⚠️  Interface set to: $manual_interface (unverified)"
                            break
                        fi
                    fi
                done
            fi
            
            echo ""
        done
    fi
    
    echo ""
    echo ""
    echo ":: ✓ Network Interface Configuration Complete"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "Summary:"
    echo "  Master: $MASTER_HOSTNAME - Interface: $NETWORK_INTERFACE"
    if [ "${#BACKUP_NODES[@]}" -gt 0 ]; then
        for i in "${!BACKUP_NODES[@]}"; do
            echo "  Backup $((i+1)): ${BACKUP_NODES[$i]} - Interface: ${BACKUP_INTERFACES[$i]}"
        done
    fi
    echo ""
fi

### END Auto-detect network interfaces on backup nodes
######################################################

### END Multi-Node SSH Setup
######################################################

######################################################
### START Attempt to detect the OS

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
OS_VERSION=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release | tr -d '"')

  # If VERSION_CODENAME is missing, try VERSION_ID
  if [[ -z "$OS_VERSION" ]]; then
    OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')
  fi
  # If still empty and RHEL-based, extract from /etc/redhat-release
  if [[ -z "$OS_VERSION" && -f /etc/redhat-release ]]; then
    OS_VERSION=$(grep -oP '[0-9]+(\.[0-9]+)?' /etc/redhat-release)
  fi
  # Final check if OS detection was successful
  if [[ -z "$OS_ID" || -z "$OS_VERSION" ]]; then
    exit_on_error "Failed to detect the operating system."
  fi

log "Detected OS: $OS_ID"
log "Detected Version: $OS_VERSION"

### END Attempt to detect the OS
######################################################

######################################################
### START Detect package manager

if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
  else
    exit_on_error "Unsupported package manager. Only apt and dnf are supported."
fi

log "Detected package manager: $PKG_MANAGER"

### END Detect package manager
######################################################

######################################################
### START Repository Connectivity Check

check_repository_connectivity

### END Repository Connectivity Check
######################################################

######################################################
### START Pre-Flight Check Summary

echo ""
echo ""
echo ""
echo ":: Pre-Flight Check Summary"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo "✓ Operating System: Validated ($OS_ID $OS_VERSION)"
echo "✓ Execution Context: Validated (sudo by ${CURRENT_USER})"
echo "✓ Package Manager: $PKG_MANAGER"
echo "✓ Sudo Access: Verified"
echo "✓ Repository Access: Verified"

if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        echo "✓ Proxy: ${PROXY_HOST}:${PROXY_PORT} (authenticated as ${PROXY_USER})"
    else
        echo "✓ Proxy: ${PROXY_HOST}:${PROXY_PORT}"
    fi
else
    echo "✓ Proxy: Not configured"
fi

if [ "$SKIP_SSL_VERIFY" = "true" ]; then
    echo "⚠️  WARNING: SSL verification is disabled!"
    echo "   This is insecure and should only be used temporarily."
fi

echo ""
echo "Deployment Configuration:"
echo "  - Deployment Type: $DEPLOYMENT_TYPE"

if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    echo "  - Services: app, idp, api, filemonitor, image (full stack)"
else
    echo "  - Services: image-service only"
fi

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo "  - HA Mode: Multi-node (1 master + ${#BACKUP_NODES[@]} backup nodes)"
    echo "  - Master: $MASTER_HOSTNAME ($MASTER_IP)"
    for i in "${!BACKUP_NODES[@]}"; do
        echo "  - Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
    done
else
    echo "  - HA Mode: Single node"
fi

echo ""
echo "Installation Plan:"
echo "  1. Install prerequisites (curl, wget, ipcalc, etc.)"
echo "  2. Install Docker CE"
echo "  3. Configure SSL certificates"
echo "  4. Configure backend service URLs and ports"
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    echo "  5. Configure HL7 / TCP integration (optional)"
    _next_step=6
else
    _next_step=5
fi
echo "  ${_next_step}. Deploy Traefik reverse proxy"
(( _next_step++ ))

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo "  ${_next_step}. Install and configure Keepalived (MASTER on this node)"
    (( _next_step++ ))
    echo "  ${_next_step}. Deploy to ${#BACKUP_NODES[@]} backup node(s)"
elif [[ -z "$INSTALL_KEEPALIVED" ]]; then
    echo "  ${_next_step}. Keepalived installation (will prompt)"
fi

echo ""
echo "Estimated time: $([ "$MULTI_NODE_DEPLOYMENT" = "yes" ] && echo "$((5 + ${#BACKUP_NODES[@]} * 5))-$((10 + ${#BACKUP_NODES[@]} * 5)) minutes" || echo "5-10 minutes")"
echo ""
echo "Note: The script will prompt for:"
echo "  - SSL certificate and private key"
echo "  - Backend service URLs and ports"
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    echo "  - HL7 / TCP integration (optional, full install only)"
fi
if [[ -z "$INSTALL_KEEPALIVED" ]]; then
    echo "  - Keepalived installation (y/n)"
fi
echo ""

if ! prompt_yn "Proceed with installation?" "n"; then
    echo "Installation cancelled by user."
    cleanup
    exit 0
fi

echo ""
log "User confirmed proceeding with installation"

### END Pre-Flight Check Summary
######################################################

######################################################
### START installing Prerequisites

echo ""
echo ""
echo ""
echo ":: Install Prerequisites"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# Define prerequisites based on package manager
if [[ "$PKG_MANAGER" == "apt" ]]; then
    PREREQ_PACKAGES=(
        apt-transport-https ca-certificates curl 
        gnupg lsb-release 
        wget nano ipcalc
    )
    log "Updating apt package lists..."
    apt-get $APT_PROXY_OPT_PROXY update || exit_on_error "Failed to update package lists"
elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    PREREQ_PACKAGES=(
        ca-certificates curl dnf-plugins-core
        gnupg2 wget nano iproute python3 jq
    )
    log "Cleaning dnf metadata..."
    dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True clean all || {
        log "Warning: dnf clean had issues, continuing..."
    }
fi

# Install prerequisites using install_packages function
log "Installing base packages..."
bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
    export http_proxy='${http_proxy:-}'; \
    export https_proxy='${https_proxy:-}'; \
    export no_proxy='${no_proxy:-}'; \
    PKG_MANAGER=$PKG_MANAGER \
    PROXY_HOST='$PROXY_HOST' \
    PROXY_PORT='$PROXY_PORT' \
    PROXY_USER='$PROXY_USER' \
    PROXY_PASSWORD='$PROXY_PASSWORD' \
    APT_SSL_OPT='$APT_SSL_OPT' \
    DNF_SSL_OPT='$DNF_SSL_OPT' \
    DNF_PROXY_OPT='$DNF_PROXY_OPT' \
    APT_PROXY_OPT_PROXY='$APT_PROXY_OPT_PROXY' \
    PROXY_STRATEGY='$PROXY_STRATEGY' \
    LOGFILE='$LOGFILE' \
    install_packages ${PREREQ_PACKAGES[*]}"

### END installing Prerequisites 
######################################################

######################################################
### START Docker Dependency Pre-installation
######################################################

if [[ "$PKG_MANAGER" == "dnf" ]]; then
    if ! rpm -q container-selinux &>/dev/null; then
        log "Installing container-selinux..."
        
        # Try from configured repos (respects proxy strategy)
        if dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install container-selinux 2>&1 | tee -a "$LOGFILE"; then
            log "✓ container-selinux installed"
            
        elif dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install container-selinux --nobest 2>&1 | tee -a "$LOGFILE"; then
            log "✓ container-selinux installed (older version)"
            
        else
            # Fallback to Rocky Linux
            log "Trying Rocky Linux repos..."
            
            if curl ${PROXY_CURL_OPTS} ${CURL_SSL_OPT} -o /tmp/rocky-repos.rpm \
                https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/r/rocky-repos-9.5-2.el9.noarch.rpm 2>&1 | tee -a "$LOGFILE"; then
                
                rpm -ivh /tmp/rocky-repos.rpm 2>&1 | tee -a "$LOGFILE" || true
                rm -f /tmp/rocky-repos.rpm
                
                # Try installing from Rocky
                dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True --enablerepo=rocky-baseos -y install container-selinux 2>&1 | tee -a "$LOGFILE" || true
            fi
        fi
        
        if ! rpm -q container-selinux &>/dev/null; then
            exit_on_error "Failed to install container-selinux"
        fi
    fi
fi

### END Docker Dependency Pre-installation
######################################################

######################################################
### START Docker Installation

echo ""
echo ""
echo ""
echo ":: Installing Docker"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# OS-specific Docker installation
if [[ "$PKG_MANAGER" == "apt" ]]; then
    log "Installing Docker via apt..."
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    
    # Download GPG key (respects proxy strategy via curl)
    if curl ${PROXY_CURL_OPTS} ${CURL_SSL_OPT} -fsSL \
        https://download.docker.com/linux/$OS_ID/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>&1 | tee -a "$LOGFILE"; then
        log "✓ Docker GPG key added"
    else
        exit_on_error "Failed to download Docker GPG key"
    fi
    
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$OS_ID $OS_VERSION stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package lists (respects proxy strategy)
    apt-get ${APT_PROXY_OPT_PROXY} ${APT_SSL_OPT} update || exit_on_error "Failed to update package lists"
    
    # Install Docker packages
    bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
        export http_proxy='${http_proxy:-}'; \
        export https_proxy='${https_proxy:-}'; \
        export no_proxy='${no_proxy:-}'; \
        PKG_MANAGER=$PKG_MANAGER \
        APT_SSL_OPT='$APT_SSL_OPT' \
        APT_PROXY_OPT_PROXY='$APT_PROXY_OPT_PROXY' \
        PROXY_STRATEGY='$PROXY_STRATEGY' \
        LOGFILE='$LOGFILE' \
        install_packages docker-ce docker-ce-cli containerd.io"

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    log "Installing Docker via dnf..."
    
    # Download Docker repository file using curl (external resource - uses proxy)
    log "Downloading Docker repository configuration..."
    
    if curl ${PROXY_CURL_OPTS} ${CURL_SSL_OPT} -fsSL \
        https://download.docker.com/linux/centos/docker-ce.repo \
        -o /tmp/docker-ce.repo 2>&1 | tee -a "$LOGFILE"; then
        
        mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
        log "✓ Docker repository added"
    else
        exit_on_error "Failed to download Docker repository"
    fi
    
    # Install Docker packages (DNF respects proxy strategy)
    log "Installing Docker packages..."
    bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
        export http_proxy='${http_proxy:-}'; \
        export https_proxy='${https_proxy:-}'; \
        export no_proxy='${no_proxy:-}'; \
        PKG_MANAGER=$PKG_MANAGER \
        DNF_SSL_OPT='$DNF_SSL_OPT' \
        DNF_PROXY_OPT='$DNF_PROXY_OPT' \
        PROXY_STRATEGY='$PROXY_STRATEGY' \
        LOGFILE='$LOGFILE' \
        install_packages docker-ce docker-ce-cli containerd.io"
fi

# Verify Docker installation
docker --version || exit_on_error "Docker installation failed"
log "✓ Docker installed successfully: $(docker --version)"

# Configure Docker daemon to use proxy (if configured)

if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    log "Configuring Docker daemon to use proxy..."
    mkdir -p /etc/docker
    
    # Backup existing daemon.json if it exists
    if [ -f "/etc/docker/daemon.json" ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        log "Backed up existing daemon.json"
    fi
    
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
        PROXY_URL="http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
    else
        PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    fi
    
    # Create daemon.json with proxy configuration
    tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "proxies": {
    "http-proxy": "${PROXY_URL}",
    "https-proxy": "${PROXY_URL}",
    "no-proxy": "localhost,127.0.0.1"
  }
}
EOF
    
    log "✓ Docker proxy configuration created in daemon.json"
fi

# Start Docker (no need for daemon-reload with daemon.json)
log "Starting and enabling Docker..."
systemctl enable docker || exit_on_error "Failed to enable Docker"
systemctl stop docker 2>/dev/null || true
sleep 2
systemctl start docker || exit_on_error "Failed to start Docker"
sleep 3

# Verify Docker is running
echo -n "Verifying Docker service... "
if systemctl is-active --quiet docker; then
    echo "✓ Running"
else
    exit_on_error "Docker service is not running"
fi

# Verify proxy is working
if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    log "Verifying Docker proxy configuration..."
    if docker info 2>/dev/null | grep -qi proxy; then
        log "✓ Docker proxy configured"
    else
        log "⚠️  Warning: Docker proxy may not be active"
    fi
fi

# Add current user to docker group
log "Adding user $CURRENT_USER to docker group..."
if ! id -nG "$CURRENT_USER" | grep -qw docker; then
    usermod -aG docker "$CURRENT_USER" || exit_on_error "Failed to add user to docker group"
    log "✓ User added to docker group"
    echo ""
    echo "Note: User $CURRENT_USER has been added to the 'docker' group."
    echo "      For future sessions, you'll need to log out and back in."
    echo "      For this script, we'll use the docker group context."
    echo ""
else
    log "✓ User $CURRENT_USER already in docker group"
fi

# Verify Docker socket is accessible
echo -n "Verifying Docker socket access... "
# Try with current permissions first
if docker ps &>/dev/null; then
    echo "✓ Accessible"
elif sudo -u "$CURRENT_USER" sg docker -c "docker ps" &>/dev/null; then
    echo "✓ Accessible (via docker group)"
    log "Note: Using docker group context for remainder of script"
    # Set a flag to use sg docker for docker commands
    USE_DOCKER_GROUP=true
else
    exit_on_error "Cannot access Docker socket even after adding user to docker group"
fi

log "✓ Docker verification complete"

### END Docker Installation
######################################################

######################################################
### START Docker Repository Management
######################################################

if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    echo ""
    echo ""
    echo ""
    echo ":: Docker Repository Management"
    echo "──────────────────────────────────────────────────"
    echo ""
    echo ""
    echo ""
    echo "Docker has been installed successfully: $(docker --version)"
    echo ""
    echo "You are using a proxy configuration. External Docker repositories may cause"
    echo "future system update failures (apt update / dnf update) due to:"
    echo "  • Proxy authentication issues"
    echo "  • SSL inspection/certificate problems"
    echo "  • Network connectivity issues"
    echo ""
    echo "Options:"
    echo ""
    echo "  [1] Disable Docker repository (RECOMMENDED)"
    echo "      ✓ Prevents 'apt update' / 'dnf update' failures"
    echo "      ✓ Docker version stays stable"
    echo "      ✓ Can be re-enabled when needed for updates"
    echo "      ✓ Docker pulls still work (daemon.json handles proxy)"
    echo ""
    echo "  [2] Keep Docker repository enabled"
    echo "      ✓ Allows automatic Docker package updates"
    echo "      ✗ May cause 'apt update' / 'dnf update' to fail"
    echo "      ✗ Requires working proxy for all system updates"
    echo ""
    
    if prompt_yn "Disable Docker repository?" "y"; then
        DISABLE_DOCKER_REPO="yes"
        log "Disabling Docker repository..."
        
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            # Debian/Ubuntu - disable Docker repository
            if [ -f /etc/apt/sources.list.d/docker.list ]; then
                mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled
                log "✓ Docker repository disabled"
                log "  Moved to: /etc/apt/sources.list.d/docker.list.disabled"
            fi
            
            # Also disable Docker GPG key (prevents apt update warnings)
            if [ -f /etc/apt/keyrings/docker.gpg ]; then
                mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled 2>/dev/null || true
            fi
            
            echo ""
            echo "✓ Docker repository disabled"
            echo ""
            echo "To re-enable Docker repository for updates:"
            echo "  sudo mv /etc/apt/sources.list.d/docker.list.disabled /etc/apt/sources.list.d/docker.list"
            echo "  sudo mv /etc/apt/keyrings/docker.gpg.disabled /etc/apt/keyrings/docker.gpg"
            echo "  sudo -E apt-get update"
            
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            # RHEL/CentOS/Rocky/AlmaLinux - disable Docker repository
            if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
                if command -v dnf &>/dev/null && dnf config-manager --help &>/dev/null 2>&1; then
                    dnf config-manager --set-disabled docker-ce-stable 2>/dev/null
                else
                    sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
                fi
                log "✓ Docker repository disabled"
            fi
            
            echo ""
            echo "✓ Docker repository disabled"
            echo ""
            echo "To re-enable Docker repository for updates:"
            echo "  sudo dnf config-manager --set-enabled docker-ce-stable"
            echo "  sudo -E dnf update"
        fi
        
        echo ""
        log "Docker version locked at: $(docker --version)"
        
    else
        log "Docker repository kept enabled"
        echo ""
        echo "⚠️  Note: Future 'apt update' or 'dnf update' commands may fail if"
        echo "   the proxy configuration or SSL certificates cause issues with"
        echo "   external Docker repositories."
        echo ""
    fi
    
else
    log "No proxy configured - Docker repository remains enabled for automatic updates"
fi

### END Docker Repository Management
######################################################

######################################################
### START Prompt for SSL and KEY and then validate

# If cert is loaded from config (reinstall path), check it's valid and not expired
if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]]; then
    log "Checking existing certificate validity..."
    _cert_expiry=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    if [[ -n "$_cert_expiry" ]]; then
        _cert_epoch=$(date -d "$_cert_expiry" +%s 2>/dev/null || \
            date -j -f "%b %d %T %Y %Z" "$_cert_expiry" +%s 2>/dev/null)
        _now_epoch=$(date +%s)
        _days_left=$(( (_cert_epoch - _now_epoch) / 86400 ))

        if (( _days_left <= 0 )); then
            echo ""
            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "  !! WARNING — SSL Certificate is EXPIRED                  !!"
            echo "  !! Expired: ${_cert_expiry}"
            echo "  !! You should update the certificate before proceeding.   !!"
            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo ""
            if ! prompt_yn "  Continue anyway with the expired certificate?" "n"; then
                echo "  Please obtain a new certificate and run the script again."
                exit 1
            fi
        elif (( _days_left <= 30 )); then
            echo ""
            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "  !! WARNING — SSL Certificate expires in ${_days_left} days          !!"
            echo "  !! Expiry: ${_cert_expiry}"
            echo "  !! Consider updating the certificate soon.                !!"
            echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo ""
            prompt_yn "  Continue with existing certificate?" "y" || exit 1
        else
            log "✓ Certificate valid — ${_days_left} days remaining"
        fi
    fi
fi

# Prompt user for certificates (if not already loaded)
if [[ -z "$CERT_FILE" ]]; then
    log "Prompting user for certificates..."
    CERT_DIR="/opt/indica/traefik/certs"
    
    # Create directory structure
    log "Creating certificate directory..."
    mkdir -p "$CERT_DIR"
    mkdir -p /opt/indica/traefik/config/dynamic
    mkdir -p /opt/indica/traefik/logs
    
    # Set proper ownership - REMOVE the || true to catch failures!
    log "Setting ownership to $CURRENT_USER..."
    chown -R root:root /opt/indica || exit_on_error "Failed to set ownership on /opt/indica"
    
    # Verify permissions
    if [ ! -w "$CERT_DIR" ]; then
        log "ERROR: Cannot write to $CERT_DIR after ownership change"
        ls -la "$CERT_DIR"
        exit_on_error "Certificate directory is not writable"
    fi
    
    log "✓ Certificate directory permissions verified"
    
    CERT_FILE="$CERT_DIR/cert.crt"
    KEY_FILE="$CERT_DIR/server.key"

    # Backup existing certificate and key files
    backup_file "$CERT_FILE"
    backup_file "$KEY_FILE"

    # Ensure CERT_FILE and KEY_FILE are not directories
    if [[ -d "$CERT_FILE" ]]; then
      log "Removing directory $CERT_FILE"
      rm -rf "$CERT_FILE" || exit_on_error "Failed to remove directory $CERT_FILE"
    fi
    if [[ -d "$KEY_FILE" ]]; then
      log "Removing directory $KEY_FILE"
      rm -rf "$KEY_FILE" || exit_on_error "Failed to remove directory $KEY_FILE"
    fi

    # Prompt user for SSL certificate
    SSL_CERT=""
    while true; do
    SSL_CERT=$(prompt_ssl_input "certificate")
    
    # Show preview
    echo -e "\nCertificate content preview:"
    echo "------------------------------"
    echo "$SSL_CERT"
    echo "------------------------------"
    
    if prompt_yn "Does this look correct?" "n"; then
            break
        else
            echo "Please try again..."
        fi
    done

    # Validate the certificate
    if ! validate_ssl_cert "$SSL_CERT"; then
    exit_on_error "Invalid SSL certificate provided."
    fi

    # Save the certificate to file (as current user since we own the directory)
    echo "$SSL_CERT" | tee "$CERT_FILE" > /dev/null || exit_on_error "Failed to write certificate"


    # Prompt user for SSL private key
    SSL_KEY=""
    while true; do
    SSL_KEY=$(prompt_ssl_input "key")
    
    # Show preview
    echo -e "\nPrivate Key content preview:"
    echo "------------------------------"
    echo "$SSL_KEY"
    echo "------------------------------"
    
    if prompt_yn "Does this look correct?" "n"; then
            break
        else
            echo "Please try again..."
        fi
    done

    # Validate the key
    if ! validate_ssl_key "$SSL_KEY"; then
    exit_on_error "Invalid SSL key provided."
    fi

    # Save the key to file (as current user since we own the directory)
    echo "$SSL_KEY" | tee "$KEY_FILE" > /dev/null || exit_on_error "Failed to write key."
    
    # Ensure proper permissions on cert files
    chmod 644 "$CERT_FILE" || exit_on_error "Failed to set permissions on certificate"
    chmod 600 "$KEY_FILE" || exit_on_error "Failed to set permissions on key"
fi

# Check if the certificate matches the private key using the check_key_cert_match function
check_key_cert_match "$CERT_FILE" "$KEY_FILE"

### END Prompt for SSL and KEY and then validate
######################################################

######################################################
### START TRAEFIK Docker Container Configuration

echo ""
echo ""
echo ""
echo ":: Deploying Traefik Docker Container"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# Create Docker & Traefik directories with proper ownership
log "Creating Docker and Traefik directories..."
mkdir -p /opt/indica/traefik/{certs,config,logs}
mkdir -p /opt/indica/traefik/config/dynamic
chown -R root:root /opt/indica 2>/dev/null || true

# Guard: if cert/key paths were incorrectly created as directories in a
# previous or partial run, remove them so they can be written as files.
if [[ -n "$CERT_FILE" && -d "$CERT_FILE" ]]; then
    log "Removing incorrectly created directory: $CERT_FILE"
    rm -rf "$CERT_FILE" || exit_on_error "Failed to remove directory $CERT_FILE"
fi
if [[ -n "$KEY_FILE" && -d "$KEY_FILE" ]]; then
    log "Removing incorrectly created directory: $KEY_FILE"
    rm -rf "$KEY_FILE" || exit_on_error "Failed to remove directory $KEY_FILE"
fi

# Verify ownership
if [[ ! -w "/opt/indica/traefik" ]]; then
    log "Warning: /opt/indica/traefik not writable, attempting to fix ownership..."
    chown -R root:root /opt/indica || exit_on_error "Failed to set ownership on /opt/indica"
fi

# Create a Docker network for Traefik
#log "Creating Docker network 'proxynet'..."
#if ! docker_cmd network inspect proxynet > /dev/null 2>&1; then
#    docker_cmd network create proxynet || exit_on_error "Failed to create Docker network"
#fi

# Create the docker-compose.yaml file for Traefik
log "Creating docker-compose.yaml file..."
DOCKER_COMPOSE_FILE="/opt/indica/traefik/docker-compose.yaml"

# Ensure docker-compose.yaml is not a directory
if [[ -d "$DOCKER_COMPOSE_FILE" ]]; then
    log "Removing incorrectly created directory: $DOCKER_COMPOSE_FILE"
    rm -rf "$DOCKER_COMPOSE_FILE" || exit_on_error "Failed to remove directory"
fi

backup_file "$DOCKER_COMPOSE_FILE"

tee "$DOCKER_COMPOSE_FILE" > /dev/null <<EOF
services:
  traefik:
    image: docker.io/library/traefik:latest
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
      - label=type:container_runtime_t
    cap_add:
      - NET_BIND_SERVICE
    network_mode: "host"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./config/dynamic:/dynamic:ro
      - ./certs/cert.crt:/certs/cert.crt:ro
      - ./certs/server.key:/certs/server.key:ro
      - ./logs:/var/log
EOF

 # Set docker-compose.yaml permissions
log "Setting permissions on $DOCKER_COMPOSE_FILE"
chmod 640 "$DOCKER_COMPOSE_FILE"

# Create a basic traefik.yml configuration file
log "Creating traefik.yml configuration file..."
TRAEFIK_CONFIG_FILE="/opt/indica/traefik/config/traefik.yml"

# Ensure traefik.yml is not a directory from previous failed runs
if [[ -d "$TRAEFIK_CONFIG_FILE" ]]; then
    log "Removing incorrectly created directory: $TRAEFIK_CONFIG_FILE"
    rm -rf "$TRAEFIK_CONFIG_FILE" || exit_on_error "Failed to remove directory $TRAEFIK_CONFIG_FILE"
fi

backup_file "$TRAEFIK_CONFIG_FILE"

# NOTE: traefik.yml is written after prompt_hl7_config so the HL7 entrypoint
# can be included conditionally based on the user's answer.

# Create the dynamic config directory and generate config files
log "Creating dynamic config directory and configuration files..."
TRAEFIK_DYNAMIC_DIR="/opt/indica/traefik/config/dynamic"
TRAEFIK_DYNAMIC_FILE="${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"

# Ensure dynamic dir is not a stale file from old layout
if [[ -f "${TRAEFIK_DYNAMIC_DIR}" ]]; then
    log "Removing stale file at dynamic dir path: ${TRAEFIK_DYNAMIC_DIR}"
    rm -f "${TRAEFIK_DYNAMIC_DIR}" || exit_on_error "Failed to remove stale path ${TRAEFIK_DYNAMIC_DIR}"
fi

# Ensure clinical_conf.yml is not a directory from previous failed runs
if [[ -d "$TRAEFIK_DYNAMIC_FILE" ]]; then
    log "Removing incorrectly created directory: $TRAEFIK_DYNAMIC_FILE"
    rm -rf "$TRAEFIK_DYNAMIC_FILE" || exit_on_error "Failed to remove directory $TRAEFIK_DYNAMIC_FILE"
fi

# Remove legacy clinical_conf.yml directory from the old single-file layout
# (Docker creates a directory if the bind-mount source file didn't exist)
_legacy_conf="/opt/indica/traefik/config/clinical_conf.yml"
if [[ -d "$_legacy_conf" ]]; then
    log "Removing legacy directory from old layout: $_legacy_conf"
    rm -rf "$_legacy_conf" || exit_on_error "Failed to remove legacy directory $_legacy_conf"
fi

mkdir -p "$TRAEFIK_DYNAMIC_DIR" || exit_on_error "Failed to create dynamic config directory"
backup_file "$TRAEFIK_DYNAMIC_FILE"

echo ""
echo ""
echo ""
echo ":: Configure Traefik"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# Call the function to generate the clinical_conf.yml services section
# (HL7 prompt follows after so we can offer host selection from entered URLs)
generate_clinical_conf

# Prompt for optional HL7 / TCP integration (full deployment only)
# Extract unique hostnames from service URLs entered during generate_clinical_conf
# so the user can pick which servers run the HL7 integration
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    _hl7_host_list=""
    _all_service_urls="${APP_SERVICE_URLS},${IDP_SERVICE_URLS},${API_SERVICE_URLS},${FILEMONITOR_SERVICE_URLS},${IMAGE_SERVICE_URLS}"
    # Strip protocols, extract host portion only (drop port), deduplicate
    while IFS= read -r _uhost; do
        [[ -z "$_uhost" ]] && continue
        if [[ -n "$_hl7_host_list" ]]; then
            _hl7_host_list="${_hl7_host_list},${_uhost}"
        else
            _hl7_host_list="${_uhost}"
        fi
    done < <(echo "$_all_service_urls" \
        | tr ',' '\n' \
        | sed -E 's#^https?://##; s#:[0-9]+$##' \
        | sort -u \
        | grep -v '^$')
    prompt_hl7_config "$_hl7_host_list"
else
    # Ensure HL7 is disabled for image-site deployments
    HL7_ENABLED="no"
    HL7_LISTEN_PORTS=""
    HL7_PORT_BACKENDS=""
fi

# Diagnostics monitor prompt (full deployment only)
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    prompt_diag_config
fi

# Generate hl7.yml if HL7 integration is enabled (full deployment only)
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    generate_hl7_conf "$TRAEFIK_DYNAMIC_DIR"
fi

# Generate diagnostics_monitor.yml if enabled (full deployment only)
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    generate_diag_conf "$TRAEFIK_DYNAMIC_DIR"
fi

# Write traefik.yml now that HL7_ENABLED is definitively set
log "Writing traefik.yml configuration file..."
tee "$TRAEFIK_CONFIG_FILE" > /dev/null <<EOF
entryPoints:
  http:
    address: ':80'
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
    http:
      redirections:
        entryPoint:
          to: 'https'
          scheme: 'https'
      encodedCharacters:
        allowEncodedBackSlash: true   # \  (UNC paths)
        allowEncodedSemicolon: true   # ;
        allowEncodedPercent: true     # %
        allowEncodedHash: true        # #
  https:
    address: ':443'
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
    http:
      encodedCharacters:
        allowEncodedBackSlash: true   # \  (UNC paths)
        allowEncodedSemicolon: true   # ;
        allowEncodedPercent: true     # %
        allowEncodedHash: true        # #
  ping:
    address: ':8800'
EOF

# Append HL7 entrypoints now that HL7_ENABLED is confirmed from user input
if [[ "$HL7_ENABLED" == "yes" ]]; then
    _ep_idx=0
    IFS='|' read -ra _ep_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _ep_comments <<< "$HL7_PORT_COMMENTS"
    for _ep_port in "${_ep_ports[@]}"; do
        _ep_name="hl7"
        [[ $_ep_idx -gt 0 ]] && _ep_name="hl7-${_ep_port}"
        _ep_comment="${_ep_comments[$_ep_idx]:-}"
        _ep_addr_line="    address: ':${_ep_port}'"
        [[ -n "$_ep_comment" ]] && _ep_addr_line="${_ep_addr_line} # ${_ep_comment}"
        cat >> "$TRAEFIK_CONFIG_FILE" <<EOF
  ${_ep_name}:
${_ep_addr_line}
    transport:
      respondingTimeouts:
        readTimeout: 0
        idleTimeout: 0
EOF
        (( ++_ep_idx ))
    done
fi

cat >> "$TRAEFIK_CONFIG_FILE" <<EOF
ping:
  entryPoint: 'ping'

#log:
#  level: DEBUG
#  filePath: "/var/log/traefik.log"

#accessLog:
#  filePath: "/var/log/access.log"
#  bufferingSize: 100

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /dynamic
    watch: true
# experimental:
#   localPlugins:
#     traefik_is_admin:
#       moduleName: gitlab.com/indica1/traefik-is-admin
EOF

# Write custom CA certificate and update docker-compose volume mount if configured
if [[ "$USE_CUSTOM_CA" == "yes" && -n "$CUSTOM_CA_CERT_CONTENT" ]]; then
    log "Writing custom CA certificate to $CERT_DIR/customca.crt..."
    # Guard: remove if it was incorrectly created as a directory in a previous run
    if [[ -d "$CERT_DIR/customca.crt" ]]; then
        log "Removing incorrectly created directory: $CERT_DIR/customca.crt"
        rm -rf "$CERT_DIR/customca.crt" || exit_on_error "Failed to remove directory $CERT_DIR/customca.crt"
    fi
    echo "$CUSTOM_CA_CERT_CONTENT" | tee "$CERT_DIR/customca.crt" > /dev/null || exit_on_error "Failed to write custom CA certificate"
    chmod 644 "$CERT_DIR/customca.crt" || exit_on_error "Failed to set permissions on custom CA certificate"
    log "Custom CA certificate written successfully"

    log "Adding custom CA volume mount to docker-compose.yaml..."
    # Insert customca volume mount after server.key line
    sed -i '/      - \.\/certs\/server\.key:\/certs\/server\.key:ro/a\      - ./certs/customca.crt:/certs/customca.crt:ro' "$DOCKER_COMPOSE_FILE"
fi

# Check if the container named 'traefik' exists (whether running or stopped)
if docker_cmd ps -a -q -f name=traefik 2>/dev/null | grep -q .; then
    # Stop the 'traefik' container if it's running
    log "Stopping existing Traefik container"
    docker_cmd stop traefik 2>/dev/null || true

    # Remove the 'traefik' container (even if stopped)
    log "Deleting existing Traefik Container"
    docker_cmd rm traefik || true
fi


# Enhanced retry logic for pulling Traefik image
log "Attempting to pull Traefik image from known sources..."

try_pull() {
    local image=$1
    log "Trying to pull $image..."
    if docker_cmd pull "$image"; then
        sed -i "s|image:.*|image: $image|" "$DOCKER_COMPOSE_FILE"
        log "Successfully pulled $image"
        return 0
    else
        log "Failed to pull $image"
        return 1
    fi
}

# Check if image already exists locally (pre-loaded on restricted networks)
_traefik_image_local=false
if docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "traefik"; then
    _existing_image=$(docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep traefik | head -1)
    log "Found existing local Traefik image: ${_existing_image}"
    echo ""
    echo "  Found existing local Traefik image: ${_existing_image}"
    if prompt_yn "  Use existing local image instead of pulling?" "y"; then
        sed -i "s|image:.*|image: ${_existing_image}|" "$DOCKER_COMPOSE_FILE"
        _traefik_image_local=true
        log "Using local image: ${_existing_image}"
    fi
fi

if [[ "$_traefik_image_local" == false ]]; then
    # Pull Traefik from Docker Hub
    log "Pulling Traefik image from Docker Hub..."
    if ! try_pull "docker.io/library/traefik:latest"; then
        echo ""
        echo ""
        echo ""
        echo ":: ERROR: Cannot Pull Traefik Image"
        echo "──────────────────────────────────────────────────"
        echo ""
        echo ""
        echo "Docker Hub is not accessible from this server."
        echo ""
        echo "This typically means the firewall is blocking one or more of these endpoints:"
        echo "  - registry-1.docker.io  (registry API)"
        echo "  - auth.docker.io        (authentication)"
        echo "  - production.cloudflare.docker.com (image layers)"
        echo ""
        echo "Options:"
        echo ""
        echo "  1. Load a pre-exported image:"
        echo "       gunzip -c traefik.tar.gz | docker load"
        echo "       Then re-run this script — it will detect the local image."
        echo ""
        echo "  2. Export from an internet-connected machine:"
        echo "       docker pull docker.io/library/traefik:latest"
        echo "       docker save docker.io/library/traefik:latest | gzip > traefik.tar.gz"
        echo "       # Transfer traefik.tar.gz to this server, then load as above."
        echo ""
        echo "  3. Ask your network admin to whitelist Docker Hub endpoints."
        echo "=========================================="
        exit_on_error "Failed to pull Traefik from Docker Hub"
    fi
fi

# Navigate to the Traefik directory and start the Docker Compose setup
log "Starting Traefik with Docker Compose..."

# Use --pull never if we're using a pre-loaded local image — avoids trying
# to reach Docker Hub on restricted networks
_compose_pull_flag="--pull always"
if [[ "$_traefik_image_local" == true ]]; then
    _compose_pull_flag="--pull never"
    log "Using local image — skipping pull"
fi

if [ "${USE_DOCKER_GROUP:-false}" = "true" ]; then
    sg docker -c "docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate ${_compose_pull_flag}" \
        || exit_on_error "Failed to start Traefik with Docker Compose"
else
    docker compose -f /opt/indica/traefik/docker-compose.yaml up -d --force-recreate ${_compose_pull_flag} \
        || exit_on_error "Failed to start Traefik with Docker Compose"
fi

# Verify Traefik container is running
echo ""
echo "Verifying Traefik deployment..."
echo -n "Waiting for Traefik container to start... "
for i in {1..30}; do
    if docker_cmd ps --filter name=traefik --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q traefik; then
        echo "✓ Running"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ FAILED"
        echo ""
        echo "ERROR: Traefik container failed to start"
        echo ""
        echo "Troubleshooting:"
        echo "  docker ps -a | grep traefik"
        echo "  docker logs traefik"
        exit 1
    fi
    sleep 1
done

# Verify Traefik health endpoint
echo -n "Verifying Traefik health endpoint... "
sleep 3  # Give Traefik a moment to fully initialize
for i in {1..10}; do
    if curl -fs http://localhost:8800/ping > /dev/null 2>&1; then
        echo "✓ Healthy"
        break
    fi
    if [ $i -eq 10 ]; then
        echo "⚠️  Warning: Health check endpoint not responding"
        echo "   Traefik may still be initializing. Check logs if issues persist:"
        echo "   docker logs traefik"
    fi
    sleep 1
done

log "✓ Traefik deployed successfully"
echo ""

### END TRAEFIK Docker Container Configuration
######################################################

######################################################
### START KeepAlived Installation

# Keepalived is ONLY for multi-node deployments
if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    INSTALL_KEEPALIVED="yes"
    log "Multi-node deployment: Keepalived will be installed for HA"
else
    INSTALL_KEEPALIVED="no"
    log "Single-node deployment: Keepalived not needed"
fi

if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then

echo ""
echo ""
echo ""
echo ":: Installing KeepAlived"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""

# Install Keepalived
log "Installing Keepalived..."
bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
    export http_proxy='${http_proxy:-}'; \
    export https_proxy='${https_proxy:-}'; \
    export no_proxy='${no_proxy:-}'; \
    PKG_MANAGER=$PKG_MANAGER \
    PROXY_HOST='$PROXY_HOST' \
    PROXY_PORT='$PROXY_PORT' \
    PROXY_USER='$PROXY_USER' \
    PROXY_PASSWORD='$PROXY_PASSWORD' \
    APT_SSL_OPT='$APT_SSL_OPT' \
    DNF_SSL_OPT='$DNF_SSL_OPT' \
    DNF_PROXY_OPT='$DNF_PROXY_OPT' \
    APT_PROXY_OPT_PROXY='$APT_PROXY_OPT_PROXY' \
    PROXY_STRATEGY='$PROXY_STRATEGY' \
    LOGFILE='$LOGFILE' \
    install_packages keepalived"

log "Deferring KeepAlived Startup until configuration file generated"

# Adding Keepalived group for script check permissions
log "Adding Keepalived group for script check permissions..."
if ! getent group keepalived_script > /dev/null 2>&1; then
    groupadd -r keepalived_script || exit_on_error "Failed to create keepalived_script group"
    echo "Group 'keepalived_script' created."
else
    echo "Group 'keepalived_script' already exists."
fi

# Adding Keepalived user and add to Keepalived group
log "Adding Keepalived user to Keepalived group..."
if ! id "keepalived_script" &>/dev/null; then
    useradd -r -s /sbin/nologin -G keepalived_script -g docker -M keepalived_script || exit_on_error "Failed to create keepalived_script user"
    echo "User 'keepalived_script' created."
else
    echo "User 'keepalived_script' already exists."
fi

# Create Traefik health check script
log "Creating Traefik health check script..."
TRAEFIK_CHECK_SCRIPT="/bin/indica_service_check.sh"
tee $TRAEFIK_CHECK_SCRIPT > /dev/null <<EOF
#!/bin/bash

# Check if the Traefik ping endpoint is alive on its dedicated port
if curl -fs http://localhost:8800/ping > /dev/null; then
  exit 0
else
  exit 1
fi
EOF
chmod +x $TRAEFIK_CHECK_SCRIPT || exit_on_error "Failed to make Traefik health check script executable"
chown keepalived_script:docker $TRAEFIK_CHECK_SCRIPT || exit_on_error "Failed to set permissions for Traefik health check script"

# Determine node role and priority
if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    # Multi-node mode: This is always the MASTER
    NODE_ROLE="MASTER"
    STATE="MASTER"
    PRIORITY="110"
    log "Multi-node mode: Configuring this node as MASTER (priority 110)"
else
    # Single-node mode: Prompt user for MASTER or BACKUP
    while true; do
        echo ""
        echo "------------------------------"
        echo "Please select this node role"
        echo "------------------------------"
        echo ""
        read -p "Is this node the MASTER or BACKUP? (Enter MASTER or BACKUP): " NODE_ROLE
        NODE_ROLE=$(echo "$NODE_ROLE" | tr '[:lower:]' '[:upper:]')
        if [[ "$NODE_ROLE" == "MASTER" || "$NODE_ROLE" == "BACKUP" ]]; then
            break
        else
            log "Invalid input. Please enter MASTER or BACKUP."
        fi
    done
    
    # Set state and priority based on user input
    if [[ "$NODE_ROLE" == "MASTER" ]]; then
        STATE="MASTER"
        PRIORITY="110"
    else
        STATE="BACKUP"
        PRIORITY="100"
    fi
fi

# Configure Keepalived
log "Configuring Keepalived..."
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"

# Function to get the IP address of a network interface
get_interface_ip() {
    local interface=$1
    local ip_address

    # Get the list of IP addresses (if any) for the interface
    ip_address=$(ip -o addr show "$interface" | awk '/inet / {print $4}' | cut -d'/' -f1 | paste -sd, -)

    if [[ -z "$ip_address" ]]; then
        echo "N/A"
    else
        echo "$ip_address"
    fi
}

get_network_interface() {
    local interfaces=()
    local interface
    local ip_address

    # List all network interfaces with valid IPv4 addresses (excluding loopback, docker, veth, br-, and interfaces with '@')
    mapfile -t interfaces < <(ip -o addr show | awk '/inet / && !/127.0.0.1|docker|br-|veth|@/ {print $2}' | sort -u)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log "No usable network interfaces found. Please check your network configuration."
        exit_on_error "No usable network interfaces detected."
    else
        # Display header directly to terminal
        echo "" > /dev/tty
        echo "----------------------------------------" > /dev/tty
        echo "Please select network interface for VIP" > /dev/tty
        echo "----------------------------------------" > /dev/tty
        echo "" > /dev/tty

        # Display detected interfaces to terminal
        echo "Detected network interfaces:" > /dev/tty
        for i in "${!interfaces[@]}"; do
            ip_address=$(get_interface_ip "${interfaces[$i]}")
            printf "%2d. %-15s (IP: %s)\n" "$((i + 1))" "${interfaces[$i]}" "${ip_address:-N/A}" > /dev/tty
        done

        # Add manual option
        printf "%2d. Enter a custom interface manually\n" "$((${#interfaces[@]} + 1))" > /dev/tty

    while true; do
        # Adding a blank line before the prompt, using /dev/tty to ensure it prints correctly
        echo "" > /dev/tty

        # Optional: Adding a separator line before the prompt
        echo "----------------------------------------" > /dev/tty

        # Prompt user to select network interface and add a blank line after the prompt
        read -p "Select the network interface to use (1-$((${#interfaces[@]} + 1))): " selection < /dev/tty

        # Adding a blank line after the prompt
        echo "" > /dev/tty

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le $((${#interfaces[@]} + 1)) ]]; then
                if [[ "$selection" -le ${#interfaces[@]} ]]; then
                    interface="${interfaces[$((selection - 1))]}"
                else
                    read -p "Enter the name of the network interface: " interface < /dev/tty
                fi
                break
            else
                echo "Invalid selection. Please enter a number between 1 and $((${#interfaces[@]} + 1))." > /dev/tty
            fi
    done

    fi

    # Validate interface exists
    if ! ip link show "$interface" > /dev/null 2>&1; then
        exit_on_error "Invalid network interface: $interface"
    fi

    echo "$interface"
}

if [[ -z "$NETWORK_INTERFACE" ]]; then
    log "⚠️  Network interface not set, prompting for configuration..."
    NETWORK_INTERFACE=$(get_network_interface)
else
    log "Using previously configured network interface: $NETWORK_INTERFACE"
fi

# Prompt for virtual IP address (if not already loaded)
if [[ -z "$VIRTUAL_IP" ]]; then
    echo ""
    echo "----------------------------------------"
    echo "Enter Keepalived Virtual IP"
    echo "----------------------------------------"
    echo ""
    while true; do
        read -p "Enter the virtual IP address for Keepalived: " VIRTUAL_IP
        if validate_ip "$VIRTUAL_IP"; then
            break
        else
            log "Invalid IP address. Please enter a valid IPv4 address."
        fi
    done
fi

# Prompt user for VRID or generate based on Virtual IP (if not already loaded)
if [[ -z "$VRID" ]]; then
    read -p "Enter the Virtual Router ID (VRID) [1-255] or press Enter to generate: " VRID
    if [[ -z "$VRID" ]]; then
        # Generate VRID from Virtual IP hash
        VRID=$(echo "$VIRTUAL_IP" | cksum | awk '{print $1 % 255 + 1}')
    elif ! [[ "$VRID" =~ ^[0-9]+$ ]] || ((VRID < 1 || VRID > 255)); then
        exit_on_error "VRID must be between 1 and 255."
    fi
fi

# Generate a random authentication password (if not already loaded)
if [[ -z "$AUTH_PASS" ]]; then
    AUTH_PASS=$(openssl rand -base64 6 | tr -dc 'A-Za-z0-9' | cut -c1-8)
fi

# Generate a random VRRP instance name (e.g., VI_01_AB12)
if [[ -z "$VRRP" ]]; then
    # Generate two random uppercase letters
    random_letters=$(head /dev/urandom | tr -dc 'A-Z' | fold -w 2 | head -n 1)

    # Generate two random digits
    random_numbers=$(head /dev/urandom | tr -dc '0-9' | fold -w 2 | head -n 1)

    # Combine into the VRRP instance name
    VRRP="VI_01_${random_letters}${random_numbers}"
fi

log "Generated VRRP instance name: $VRRP"

# Log the generated password for reference
log "Generated Keepalived authentication password: $AUTH_PASS"

backup_file "$KEEPALIVED_CONF"

tee $KEEPALIVED_CONF > /dev/null <<EOF
global_defs {
  enable_script_security
  script_user keepalived_script
  max_auto_priority
}
vrrp_script check_traefik {
  script "/bin/indica_service_check.sh"
  interval 2
  weight 50
}
vrrp_instance $VRRP {
  state $STATE
  interface $NETWORK_INTERFACE
  virtual_router_id $VRID
  priority $PRIORITY
  virtual_ipaddress {
    $VIRTUAL_IP
  }
  track_script {
    check_traefik
  }
  authentication {
    auth_type PASS
    auth_pass $AUTH_PASS
  }
}
EOF

  # Set Keepalived.conf permissions
  log "Setting permissions on $KEEPALIVED_CONF"
  chmod 640 $KEEPALIVED_CONF

  # Restart Keepalived to apply the configuration
  log "Starting and enabling KeepAlived..."
  systemctl enable keepalived || exit_on_error "Failed to enable Keepalived"
  systemctl start keepalived || exit_on_error "Failed to start Keepalived"
  
  # Verify Keepalived is running
  echo ""
  echo "Verifying Keepalived deployment..."
  echo -n "Checking Keepalived service status... "
  sleep 2  # Give Keepalived time to start
  if systemctl is-active --quiet keepalived; then
      echo "✓ Running"
  else
      echo "⚠️  Warning: Keepalived may not be running properly"
      echo "   Check status with: sudo systemctl status keepalived"
  fi
  
  # Check if VIP is assigned (for MASTER) or ready (for BACKUP)
  echo -n "Checking Virtual IP configuration... "
  sleep 2
  if ip addr show "$NETWORK_INTERFACE" | grep -q "$VIRTUAL_IP"; then
      echo "✓ Virtual IP $VIRTUAL_IP is assigned"
      if [[ "$NODE_ROLE" == "BACKUP" ]]; then
          echo "   Note: Virtual IP is assigned to BACKUP (master may be down)"
      fi
  else
      if [[ "$NODE_ROLE" == "MASTER" ]]; then
          echo "⚠️  Virtual IP not yet assigned (may take a few seconds)"
          echo "   Check with: ip addr show $NETWORK_INTERFACE"
      else
          echo "✓ Virtual IP not assigned (expected for BACKUP)"
      fi
  fi
  
  log "✓ Keepalived configured successfully"
  echo ""

fi  # End of Keepalived installation conditional

### END Finish KeelAlived Configuration & Start Service
######################################################

######################################################
### START Deploy to Backup Nodes (Multi-Node Mode)
######################################################

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    # Save configuration before deploying to backups
    save_config
    deploy_to_backup_nodes
fi

### END Deploy to Backup Nodes
######################################################
######################################################

######################################################
### START Final restart of services

systemctl restart docker
if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    systemctl restart keepalived
fi

### END Final restart of services
######################################################

# Save configuration (if this is the MASTER node or Keepalived not installed)
if [[ "$NODE_ROLE" == "MASTER" ]] || [[ "$INSTALL_KEEPALIVED" != "yes" && "$INSTALL_KEEPALIVED" != "y" ]]; then
    save_config
fi

log "Installation and basic configuration complete!"

echo ""
echo ""
echo ""
echo ":: ✓✓✓ INSTALLATION COMPLETE ✓✓✓"
echo "──────────────────────────────────────────────────"
echo ""
echo ""
echo ""
echo "Deployment Summary:"
echo "  - Type: $DEPLOYMENT_TYPE"
echo "  - Docker: Installed and running"
echo "  - Traefik: Deployed and running"

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo "  - HA Mode: Multi-node (1 master + ${#BACKUP_NODES[@]} backup nodes)"
    echo "  - Master Node: $MASTER_HOSTNAME ($MASTER_IP) - Priority 110"
    for i in "${!BACKUP_NODES[@]}"; do
        priority=$((100 - (i * 10)))
        echo "  - Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]}) - Priority $priority"
    done
    echo "  - Virtual IP: $VIRTUAL_IP"
    echo "  - VRRP Instance: $VRRP"
elif [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    echo "  - Keepalived: Installed (Role: $NODE_ROLE)"
    echo "  - Virtual IP: $VIRTUAL_IP"
    echo "  - VRRP Instance: $VRRP"
else
    echo "  - Keepalived: Not installed"
fi

echo ""
echo "Configuration Files:"
echo "  - Config: $CONFIG_FILE"
echo "  - Installation Log: $LOGFILE"
echo "  - Docker Compose: $DOCKER_COMPOSE_FILE"
echo "  - Traefik Config: $TRAEFIK_CONFIG_FILE"
echo "  - Dynamic Config Dir: $TRAEFIK_DYNAMIC_DIR"
echo "    - clinical_conf.yml: ${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"
if [[ "$HL7_ENABLED" == "yes" ]]; then
    echo "    - hl7.yml: ${TRAEFIK_DYNAMIC_DIR}/hl7.yml"
fi
echo "  - Certificates: $CERT_DIR"

if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    echo "  - Keepalived Config: $KEEPALIVED_CONF"
fi

if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        echo "  - Proxy: ${PROXY_HOST}:${PROXY_PORT} (authenticated as ${PROXY_USER})"
    else
        echo "  - Proxy: ${PROXY_HOST}:${PROXY_PORT}"
    fi
    echo "  - Docker Proxy Config: /etc/docker/daemon.json"
fi


echo ""
echo "Services Status:"
echo "  - Docker: $(systemctl is-active docker)"

# Get Traefik status using docker_cmd
TRAEFIK_STATUS=$(docker_cmd ps --filter name=traefik --format '{{.Status}}' 2>/dev/null | cut -d' ' -f1)
if [ -n "$TRAEFIK_STATUS" ]; then
    echo "  - Traefik: $TRAEFIK_STATUS"
else
    echo "  - Traefik: Unknown (check with: docker ps)"
fi

if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    echo "  - Keepalived: $(systemctl is-active keepalived)"
fi

echo ""
echo "Access Information:"
echo "  - HTTP: http://$(hostname -I | awk '{print $1}')"
echo "  - HTTPS: https://$(hostname -I | awk '{print $1}')"

if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    echo "  - Virtual IP: https://$VIRTUAL_IP"
fi

if [[ "$HL7_ENABLED" == "yes" ]]; then
    IFS='|' read -ra _hl7_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _hl7_comments <<< "$HL7_PORT_COMMENTS"
    IFS='|' read -ra _hl7_backends <<< "$HL7_PORT_BACKENDS"
    _hl7_idx=0
    for _hl7_p in "${_hl7_ports[@]}"; do
        _hl7_cmt="${_hl7_comments[$_hl7_idx]:-}"
        [[ -n "$_hl7_cmt" ]] && _hl7_cmt=" (${_hl7_cmt})"
        echo "  - HL7 TCP :${_hl7_p}${_hl7_cmt} → $(hostname -I | awk '{print $1}'):${_hl7_p}"
        (( ++_hl7_idx ))
    done
fi

echo ""
echo "Verification Commands:"
echo "  Check Docker status:"
echo "    docker ps"
echo ""
echo "  Check Traefik logs:"
echo "    docker logs traefik"
echo ""
echo "  Check Traefik health:"
echo "    curl http://localhost:8800/ping"
echo ""

if [[ "$HL7_ENABLED" == "yes" ]]; then
    echo "  Verify HL7 entrypoint(s) (Traefik should be listening):"
    IFS='|' read -ra _vcmd_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _vcmd_backends <<< "$HL7_PORT_BACKENDS"
    IFS='|' read -ra _vcmd_comments <<< "$HL7_PORT_COMMENTS"
    _vcmd_idx=0
    for _vcmd_port in "${_vcmd_ports[@]}"; do
        _vcmd_cmt="${_vcmd_comments[$_vcmd_idx]:-}"
        [[ -n "$_vcmd_cmt" ]] && echo "    # ${_vcmd_cmt} (port ${_vcmd_port})"
        echo "    ss -tlnp | grep :${_vcmd_port}"
        echo "    # Or test connectivity to backend(s):"
        IFS=',' read -ra _vcmd_srvs <<< "${_vcmd_backends[$_vcmd_idx]}"
        for _vsrv in "${_vcmd_srvs[@]}"; do
            echo "    curl -v telnet://${_vsrv}"
        done
        echo ""
        (( ++_vcmd_idx ))
    done
fi

if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    echo "  Check Keepalived status:"
    echo "    sudo systemctl status keepalived"
    echo ""
    echo "  Check Virtual IP assignment:"
    echo "    ip addr show $NETWORK_INTERFACE"
    echo ""
fi

echo "Next Steps:"

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo "  - All nodes have been configured automatically"
    echo "  - Master node ($MASTER_HOSTNAME) should have Virtual IP: $VIRTUAL_IP"
    echo "  - Test failover by stopping Keepalived on master"
    echo ""
    echo "  Verify all nodes:"
    echo "    # Check Traefik on all nodes"
    for i in "${!BACKUP_NODES[@]}"; do
        if [ $i -eq 0 ]; then
            echo "    ssh $MASTER_HOSTNAME 'docker ps | grep traefik'"
        fi
        echo "    ssh ${BACKUP_NODES[$i]} 'docker ps | grep traefik'"
    done
    echo ""
    echo "    # Check Keepalived status on all nodes"
    echo "    ssh $MASTER_HOSTNAME 'sudo systemctl status keepalived'"
    for node in "${BACKUP_NODES[@]}"; do
        echo "    ssh $node 'sudo systemctl status keepalived'"
    done
    echo ""
    echo "    # Check which node has the Virtual IP"
    echo "    ssh $MASTER_HOSTNAME 'ip addr show | grep $VIRTUAL_IP'"
    for node in "${BACKUP_NODES[@]}"; do
        echo "    ssh $node 'ip addr show | grep $VIRTUAL_IP'"
    done
fi
echo "  - Test your services through Traefik"
echo "  - Monitor logs for any issues"
echo "  - Configure any additional backend services"
echo ""
echo "Troubleshooting:"
echo "  View installation log:"
echo "    cat $LOGFILE"
echo ""

if [ "${USE_DOCKER_GROUP:-false}" = "true" ]; then
    echo "⚠️  IMPORTANT: Docker Group Membership"
    echo "  You were added to the 'docker' group during installation."
    echo "  For the group membership to take full effect, you must:"
    echo "    1. Log out of your current session"
    echo "    2. Log back in"
    echo ""
    echo "  Until you do this, you'll need to use 'sudo' or 'sg docker -c'"
    echo "  prefix for docker commands in new terminal sessions."
    echo ""
fi

echo "=========================================="
echo ""
echo ""
echo ""
echo ":: Repository Configuration"
echo "──────────────────────────────────────────────────"
echo ""
echo ""

if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    if [[ "$DISABLE_DOCKER_REPO" =~ ^[Yy] ]]; then
        echo "Docker Repository: DISABLED"
        echo "  Current version: $(docker --version)"
        echo "  This prevents proxy/SSL issues during system updates"
        echo ""
        
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            echo "To update Docker in the future:"
            echo "  1. sudo mv /etc/apt/sources.list.d/docker.list.disabled /etc/apt/sources.list.d/docker.list"
            echo "  2. sudo mv /etc/apt/keyrings/docker.gpg.disabled /etc/apt/keyrings/docker.gpg"
            echo "  3. export http_proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            echo "     export https_proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            echo "  4. sudo -E apt-get update && sudo -E apt-get upgrade docker-ce"
            echo "  5. sudo mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled"
            echo "     sudo mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled"
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            echo "To update Docker in the future:"
            echo "  1. sudo dnf config-manager --set-enabled docker-ce-stable"
            echo "  2. export http_proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            echo "     export https_proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            echo "  3. sudo -E dnf upgrade docker-ce docker-ce-cli containerd.io"
            echo "  4. sudo dnf config-manager --set-disabled docker-ce-stable"
        fi
    else
        echo "Docker Repository: ENABLED"
        echo "  Docker updates available via normal system updates"
        echo "  ⚠️  Note: System updates may fail if proxy/SSL issues occur"
    fi
else
    echo "Docker Repository: ENABLED"
    echo "  No proxy configured - automatic updates available"
fi

# Cleanup temporary scripts directory
cleanup