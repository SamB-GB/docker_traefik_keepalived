#!/bin/bash

# Enhanced Clinical Traefik Reverse Proxy Setup
#
# USAGE:
#   ./clinicalrp.sh                    # Normal installation
#   ./clinicalrp.sh --clean            # Remove Traefik/Keepalived/Docker
#   ./clinicalrp.sh --integration-setup  # Add/update HL7 integration on existing install

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

# Custom CA certificate for upstream TLS verification
USE_CUSTOM_CA="no"
CUSTOM_CA_CERT_CONTENT=""

# Logging setup
LOGFILE="/var/log/installation.log"

# Get the actual user running the script (before sudo elevation)
_RAW_USER="${SUDO_USER:-$USER}"
CURRENT_USER="${_RAW_USER%%@*}"
CURRENT_GROUP=$(id -gn "$CURRENT_USER")

# Get the actual user's home directory (not root's when using sudo)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Get the directory where the script is located
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_FILE="/home/haloap/traefik/deployment.config"

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

    # Use legacy SCP protocol (-O) to avoid SFTP subsystem requirement
    local COPYS_OPTS="-O -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
    local KEY_OPT="-i $ACTUAL_HOME/.ssh/id_rsa"

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        # Try scp first with legacy protocol
        if ! sudo -u "$SUDO_USER" scp -q -o "User=$CURRENT_USER" $KEY_OPT $COPYS_OPTS "$file" "$ip:$dest" 2>/tmp/scp_err.$$; then
            # Fallback: stream over ssh without SFTP/SCP
            sudo -u "$SUDO_USER" ssh $KEY_OPT $COPYS_OPTS -l "$CURRENT_USER" "$ip" "cat > '$dest'" < "$file"
        fi
    else
        if ! scp -q -o "User=$CURRENT_USER" $KEY_OPT $COPYS_OPTS "$file" "$ip:$dest" 2>/tmp/scp_err.$$; then
            ssh $KEY_OPT $COPYS_OPTS -l "$CURRENT_USER" "$ip" "cat > '$dest'" < "$file"
        fi
    fi
    rm -f /tmp/scp_err.$$
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
        echo "  Proxy: Not configured"
        return 0
    fi
    
    echo ""
    echo "=========================================="
    echo "Validating Proxy Configuration"
    echo "=========================================="
    
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
    echo "=========================================="
    echo "Cleaning Up Temporary Files on Remote Nodes"
    echo "=========================================="
    
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

    ensure_SCRIPTS_DIR "$ip"
    copy_to_remote "$SCRIPTS_DIR/run_script_wrapper.sh" "$ip" "$SCRIPTS_DIR/run_script.sh"

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh -tt $SSH_OPTS -l "$CURRENT_USER" "$ip" "env SUDO_PASS_B64='$PASS_B64' PROXY_HOST='${PROXY_HOST}' PROXY_PORT='${PROXY_PORT}' PROXY_USER='${PROXY_USER}' PROXY_PASSWORD='${PROXY_PASSWORD}' INTERNAL_REPO_DOMAINS='${INTERNAL_REPO_DOMAINS}' SKIP_SSL_VERIFY='${SKIP_SSL_VERIFY}' PROXY_STRATEGY='${PROXY_STRATEGY}' bash '$SCRIPTS_DIR/run_script.sh' && rm -f '$SCRIPTS_DIR/run_script.sh'"
    else
        ssh -tt $SSH_OPTS -l "$CURRENT_USER" "$ip" "env SUDO_PASS_B64='$PASS_B64' PROXY_HOST='${PROXY_HOST}' PROXY_PORT='${PROXY_PORT}' PROXY_USER='${PROXY_USER}' PROXY_PASSWORD='${PROXY_PASSWORD}' INTERNAL_REPO_DOMAINS='${INTERNAL_REPO_DOMAINS}' SKIP_SSL_VERIFY='${SKIP_SSL_VERIFY}' PROXY_STRATEGY='${PROXY_STRATEGY}' bash '$SCRIPTS_DIR/run_script.sh' && rm -f '$SCRIPTS_DIR/run_script.sh'"
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
        sudo touch "$LOGFILE" 2>/dev/null || LOGFILE="$ACTUAL_HOME/traefik_installation.log"
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
        sudo chmod 666 "$LOGFILE" 2>/dev/null || true
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
    echo "=========================================="
    echo "Checking operating system compatibility..."
    echo "=========================================="
    
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
    echo "=========================================="
    echo "Validating Execution Context"
    echo "=========================================="
    
    # Check 1: Ensure script is NOT run with sudo
    if [ "$EUID" -eq 0 ] || [ "$USER" = "root" ]; then
        echo "❌ ERROR: This script should NOT be run with sudo or as root"
        echo ""
        echo "Why:"
        echo "  - Running as root can cause permission issues with files"
        echo "  - Generated files will be owned by root instead of your user"
        echo "  - The script uses sudo internally when needed"
        echo ""
        echo "Correct usage:"
        echo "  ./$(basename "$0")           # ✓ Run as regular user"
        echo ""
        echo "Incorrect usage:"
        echo "  sudo ./$(basename "$0")      # ✗ Don't run with sudo"
        echo ""
        exit 1
    fi
    
    echo "✓ Script is being run as user: $CURRENT_USER"
    echo "✓ Home directory: $ACTUAL_HOME"
    
    # Check 2: Verify user has sudo privileges
    echo -n "Checking if $CURRENT_USER has sudo privileges... "
    echo ""
    echo ""
    # Test sudo access without prompting for password yet
    if sudo -n true 2>/dev/null; then
        echo "✓ (cached/passwordless)"
    else
        # Try with password prompt
        if sudo -v 2>/dev/null; then
            echo "✓ Password verified"
        else
            echo "❌ FAILED"
            echo ""
            echo "=========================================="
            echo "ERROR: User $CURRENT_USER lacks sudo privileges"
            echo "=========================================="
            echo ""
            echo "This script requires sudo access to:"
            echo "  - Install packages (Docker, Keepalived)"
            echo "  - Configure system files"
            echo "  - Manage services"
            echo ""
            echo "To fix this issue:"
            echo ""
            echo "On Ubuntu/Debian:"
            echo "  1. Log in as root: su -"
            echo "  2. Add user to sudo group: usermod -aG sudo $CURRENT_USER"
            echo "  3. Log out and back in"
            echo ""
            echo "On CentOS/RHEL:"
            echo "  1. Log in as root: su -"
            echo "  2. Add user to wheel group: usermod -aG wheel $CURRENT_USER"
            echo "  3. Log out and back in"
            echo ""
            exit 1
        fi
    fi
    
    echo "✓ Execution context validated"
}

# Check repository connectivity
check_repository_connectivity() {
    echo ""
    echo "=========================================="
    echo "Checking Repository Connectivity"
    echo "=========================================="
    
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
                ensure_SCRIPTS_DIR "$ip"
                copy_to_remote "$_prereq_script" "$ip" "$_prereq_script"
                execute_remote_script "$ip" "$_prereq_script"
                rm -f "$_prereq_script"

                check_single_node "remote" "$node" "$ip"
                if [ $? -ne 0 ]; then
                    REMOTE_FAILURES=$((REMOTE_FAILURES + 1))
                fi
            done
            
            if [ $REMOTE_FAILURES -gt 0 ]; then
                echo ""
                echo "=========================================="
                echo "⚠️  $REMOTE_FAILURES backup node(s) failed repository checks"
                echo "=========================================="
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
                echo "=========================================="
                echo "✓ All Nodes: Repository Access Verified"
                echo "=========================================="
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
        sudo apt-get update -qq 2>/dev/null
        sudo apt-get install -y -qq $_early_missing || {
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
        sudo dnf --setopt=skip_if_unavailable=True install -y $_early_missing || {
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
    validate_os
    check_execution_context
    
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
        echo "=========================================="
        echo "Multi-Node Deployment Detected"
        echo "=========================================="
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
    echo "=========================================="
    echo "Traefik/Keepalived Cleanup"
    echo "=========================================="
    if [[ "$CLEAN_BACKUP_NODES" == "true" ]]; then
        echo "This will completely remove Traefik and Keepalived from:"
        echo "  - This system (master node)"
        echo "  - ${#BACKUP_NODES[@]} backup node(s)"
        if [[ "$UNINSTALL_KEEPALIVED_REMOTE" == "true" ]]; then
            echo "  - Keepalived package will be UNINSTALLED from backup nodes"
        fi
        if [[ "$UNINSTALL_DOCKER_REMOTE" == "true" ]]; then
            echo "  - Docker will be UNINSTALLED from backup nodes"
        fi
    else
        echo "This will completely remove Traefik and Keepalived from this system!"
    fi
    echo ""
    echo "Components to be removed:"
    echo "  - Traefik Docker container"
    echo "  - Traefik configuration files (/home/haloap/traefik)"
    echo "  - SSL certificates"
    echo "  - Keepalived (if installed)"
    echo "  - Configuration file ($CONFIG_FILE)"
    echo ""
    echo "⚠️  WARNING: This operation cannot be undone!"
    echo ""
    if ! prompt_yn "Are you sure you want to proceed?" "n"; then
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
            echo "=========================================="
            echo "Cleaning $node_name ($node_ip)"
            echo "=========================================="
            
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
if [ -d "/home/haloap/traefik" ]; then
    rm -rf /home/haloap/traefik
    echo "✓ Removed"
else
    echo "Not found"
fi

if [ -d "/home/haloap" ] && [ -z "$(ls -A /home/haloap 2>/dev/null)" ]; then
    rm -rf /home/haloap 2>/dev/null || true
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
if [ -f "/bin/haloap_service_check.sh" ]; then
    rm -f /bin/haloap_service_check.sh
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
            ensure_SCRIPTS_DIR "$node_ip"
            copy_to_remote "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh" "$node_ip" "$SCRIPTS_DIR/cleanup_traefik.sh"
            execute_remote_script "$node_ip" "$SCRIPTS_DIR/cleanup_traefik.sh"
            
            # Cleanup temp files
            rm -f "$SCRIPTS_DIR/cleanup_remote_${node_name}.sh"
            
            echo "✓ Cleanup completed on $node_name"
            
        else
            # Local cleanup
            echo ""
            echo "=========================================="
            echo "Starting Cleanup Process (Local)"
            echo "=========================================="
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
            if [ -d "/home/haloap/traefik" ]; then
                sudo rm -rf /home/haloap/traefik || exit_on_error "Failed to remove Traefik directory"
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            if [ -d "/home/haloap" ]; then
                if [ -z "$(ls -A /home/haloap 2>/dev/null)" ]; then
                    sudo rm -rf /home/haloap 2>/dev/null || true
                    echo "✓ Removed empty /home/haloap directory"
                fi
            fi
            
            # Stop and remove Keepalived
            echo -n "Stopping Keepalived service... "
            if systemctl is-active --quiet keepalived 2>/dev/null; then
                sudo systemctl stop keepalived 2>/dev/null || true
                echo "✓ Stopped"
            else
                echo "Not running"
            fi
            
            echo -n "Disabling Keepalived service... "
            if systemctl is-enabled --quiet keepalived 2>/dev/null; then
                sudo systemctl disable keepalived 2>/dev/null || true
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
                            sudo apt-get -y purge keepalived 2>/dev/null || true
                            sudo apt-get -y autoremove 2>/dev/null || true
                        elif command -v dnf &>/dev/null; then
                            sudo dnf -y remove keepalived 2>/dev/null || true
                        fi
                    fi
                    echo "✓ Uninstalled"
                fi
            fi
            
            # Remove Keepalived configuration
            echo -n "Removing Keepalived configuration... "
            if [ -f "/etc/keepalived/keepalived.conf" ]; then
                sudo rm -f /etc/keepalived/keepalived.conf || true
                sudo rm -f /etc/keepalived/keepalived.conf.bak* || true
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            # Remove health check script
            echo -n "Removing health check script... "
            if [ -f "/bin/haloap_service_check.sh" ]; then
                sudo rm -f /bin/haloap_service_check.sh || true
                echo "✓ Removed"
            else
                echo "Not found"
            fi
            
            # Remove keepalived_script user and group
            echo -n "Removing keepalived_script user and group... "
            if id "keepalived_script" &>/dev/null; then
                sudo userdel keepalived_script 2>/dev/null || true
            fi
            if getent group keepalived_script > /dev/null 2>&1; then
                sudo groupdel keepalived_script 2>/dev/null || true
            fi
            echo "✓ Removed"
            
            # Remove Docker proxy configuration
            echo -n "Removing Docker proxy configuration... "
            if [ -f "/etc/docker/daemon.json" ]; then
                sudo rm -f /etc/docker/daemon.json || true
                sudo systemctl daemon-reload 2>/dev/null || true
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
                        sudo systemctl stop docker 2>/dev/null || true
                        sudo systemctl disable docker 2>/dev/null || true
                        echo "✓ Stopped"
                        
                        echo -n "Uninstalling Docker... "
                        if command -v apt-get &>/dev/null; then
                            sudo apt-get -y purge docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
                            sudo apt-get -y autoremove 2>/dev/null || true
                            sudo rm -f /etc/apt/sources.list.d/docker.list
                            sudo rm -f /etc/apt/keyrings/docker.gpg
                        elif command -v dnf &>/dev/null; then
                            sudo dnf -y remove docker-ce docker-ce-cli containerd.io 2>/dev/null || true
                        fi
                        echo "✓ Uninstalled"
                        
                        echo -n "Removing Docker data... "
                        sudo rm -rf /var/lib/docker 2>/dev/null || true
                        sudo rm -rf /var/lib/containerd 2>/dev/null || true
                        sudo rm -rf /etc/docker/daemon.json 2>/dev/null || true
                        echo "✓ Removed"
                        
                        if groups "$CURRENT_USER" | grep -q docker; then
                            echo -n "Removing $CURRENT_USER from docker group... "
                            sudo gpasswd -d "$CURRENT_USER" docker 2>/dev/null || true
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
    echo "=========================================="
    echo "✓✓✓ CLEANUP COMPLETE ✓✓✓"
    echo "=========================================="
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
# Integration Setup Mode
# ==========================================

if [[ "$1" == "--integration-setup" ]]; then
    validate_os
    check_execution_context

    echo ""
    echo "=========================================="
    echo "Integration Setup Mode"
    echo "=========================================="
    echo ""
    echo "This mode adds or updates an HL7 / TCP integration on an"
    echo "existing Traefik installation without performing a full"
    echo "reinstall."
    echo ""

    # ----------------------------------------
    # Load existing config
    # ----------------------------------------
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "❌ ERROR: No existing configuration found at $CONFIG_FILE"
        echo ""
        echo "This mode requires a prior installation. Run the script"
        echo "without arguments to perform a full install first."
        exit 1
    fi

    echo "Loading existing configuration..."
    source "$CONFIG_FILE"
    echo "✓ Configuration loaded"
    echo ""

    # ----------------------------------------
    # Guard: full deployment only
    # ----------------------------------------
    if [[ "$DEPLOYMENT_TYPE" != "full" ]]; then
        echo "❌ ERROR: HL7 integration is only supported on a full"
        echo "   deployment (not image-site)."
        echo ""
        echo "   Current deployment type: $DEPLOYMENT_TYPE"
        exit 1
    fi

    # ----------------------------------------
    # Verify Traefik is installed and running
    # ----------------------------------------
    TRAEFIK_CONFIG_FILE="/home/haloap/traefik/config/traefik.yml"
    TRAEFIK_DYNAMIC_DIR="/home/haloap/traefik/config/dynamic"
    DOCKER_COMPOSE_FILE="/home/haloap/traefik/docker-compose.yaml"

    if [[ ! -f "$TRAEFIK_CONFIG_FILE" ]]; then
        echo "❌ ERROR: Traefik config not found at $TRAEFIK_CONFIG_FILE"
        echo "   Is Traefik installed on this node?"
        exit 1
    fi

    # ----------------------------------------
    # Multi-node: collect sudo password + set SSH opts
    # ----------------------------------------
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        echo "Multi-node deployment detected:"
        echo "  Master : $MASTER_HOSTNAME ($MASTER_IP)"
        for i in "${!BACKUP_NODES[@]}"; do
            echo "  Backup $((i+1)): ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
        done
        echo ""
        echo "The integration will be applied to all nodes."
        echo ""
        read -s -p "Enter YOUR sudo password for remote hosts: " SUDO_PASS
        echo ""
        export SUDO_PASS
        SSH_OPTS="-i $ACTUAL_HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"
    fi

    # ----------------------------------------
    # Prompt for HL7 configuration
    # Extract unique hostnames from service URLs saved in the config
    # so the user can pick which servers run the HL7 integration
    # ----------------------------------------
    _hl7_host_list=""
    _all_service_urls="${APP_SERVICE_URLS:-},${IDP_SERVICE_URLS:-},${API_SERVICE_URLS:-},${FILEMONITOR_SERVICE_URLS:-},${IMAGE_SERVICE_URLS:-}"
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

    if [[ "$HL7_ENABLED" != "yes" ]]; then
        echo ""
        echo "No HL7 integration configured. Exiting."
        cleanup
        exit 0
    fi
    # ----------------------------------------
    echo ""
    echo "=========================================="
    echo "Applying HL7 Integration"
    echo "=========================================="
    echo ""

    mkdir -p "$TRAEFIK_DYNAMIC_DIR"

    echo -n "Writing hl7.yml... "
    generate_hl7_conf "$TRAEFIK_DYNAMIC_DIR"
    echo "✓ Done"

    # ----------------------------------------
    # Patch traefik.yml: add hl7 entrypoint if absent
    # ----------------------------------------
    echo -n "Updating traefik.yml entryPoints... "
    _tmp_traefik=$(mktemp)
    cp "$TRAEFIK_CONFIG_FILE" "$_tmp_traefik"

    IFS='|' read -ra _patch_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _patch_comments <<< "$HL7_PORT_COMMENTS"
    _patch_idx=0
    for _patch_port in "${_patch_ports[@]}"; do
        _patch_ep="hl7"
        [[ $_patch_idx -gt 0 ]] && _patch_ep="hl7-${_patch_port}"
        _patch_cmt="${_patch_comments[$_patch_idx]:-}"
        _patch_addr="    address: ':${_patch_port}'"
        [[ -n "$_patch_cmt" ]] && _patch_addr="${_patch_addr} # ${_patch_cmt}"

        if grep -q "^  ${_patch_ep}:" "$_tmp_traefik"; then
            # Already present — update address line in place
            sed -i "/^  ${_patch_ep}:/,/^  [a-z]/{s|address:.*|${_patch_addr}|}" "$_tmp_traefik"
        else
            # Inject before the 'ping:' section
            _tmp2=$(mktemp)
            awk -v ep="$_patch_ep" -v addr="$_patch_addr" '
                /^ping:/ && !inserted {
                    print "  " ep ":"
                    print addr
                    print "    transport:"
                    print "      respondingTimeouts:"
                    print "        readTimeout: 0"
                    print "        idleTimeout: 0"
                    inserted=1
                }
                { print }
            ' "$_tmp_traefik" > "$_tmp2"
            cp "$_tmp2" "$_tmp_traefik"
            rm -f "$_tmp2"
        fi
        (( ++_patch_idx ))
    done

    cp "$_tmp_traefik" "$TRAEFIK_CONFIG_FILE"
    rm -f "$_tmp_traefik"
    echo "✓ Done"

    # ----------------------------------------
    # Restart Traefik on master to pick up new entrypoint
    # ----------------------------------------
    echo -n "Restarting Traefik container... "
    cd /home/haloap/traefik
    if [ "${USE_DOCKER_GROUP:-false}" = "true" ]; then
        sg docker -c "docker compose up -d --force-recreate" 2>/dev/null \
            || { echo "❌ Failed"; exit_on_error "Traefik restart failed"; }
    else
        docker compose up -d --force-recreate 2>/dev/null \
            || { echo "❌ Failed"; exit_on_error "Traefik restart failed"; }
    fi
    echo "✓ Done"

    # Wait for Traefik to be healthy
    echo -n "Verifying Traefik health... "
    for i in {1..15}; do
        if curl -fs http://localhost:8800/ping > /dev/null 2>&1; then
            echo "✓ Healthy"
            break
        fi
        if [[ $i -eq 15 ]]; then
            echo "⚠️  Warning: health check not responding — check: docker logs traefik"
        fi
        sleep 1
    done

    # ----------------------------------------
    # Push to backup nodes if multi-node
    # ----------------------------------------
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        echo ""
        echo "Pushing integration to backup nodes..."
        echo ""

        # Stage files for transfer
        cp "${TRAEFIK_DYNAMIC_DIR}/hl7.yml" /tmp/hl7.yml

        for i in "${!BACKUP_NODES[@]}"; do
            node="${BACKUP_NODES[$i]}"
            ip="${BACKUP_IPS[$i]}"

            echo "  Updating $node ($ip)..."

            # Create a small remote patch script
            write_local_file "$SCRIPTS_DIR/integration_patch_${node}.sh" <<REMOTEPATCH
#!/bin/bash
set -e

TRAEFIK_CONFIG_FILE="/home/haloap/traefik/config/traefik.yml"
TRAEFIK_DYNAMIC_DIR="/home/haloap/traefik/config/dynamic"
HL7_LISTEN_PORTS="${HL7_LISTEN_PORTS}"
HL7_PORT_COMMENTS="${HL7_PORT_COMMENTS}"

# Install hl7.yml into dynamic directory
mkdir -p "\$TRAEFIK_DYNAMIC_DIR"
if [ -f "/tmp/hl7.yml" ]; then
    cp /tmp/hl7.yml "\${TRAEFIK_DYNAMIC_DIR}/hl7.yml"
    chmod 640 "\${TRAEFIK_DYNAMIC_DIR}/hl7.yml"
    echo "  ✓ hl7.yml installed"
fi

# Patch traefik.yml: add/update all HL7 entrypoints
_tmp_traefik=\$(mktemp)
cp "\$TRAEFIK_CONFIG_FILE" "\$_tmp_traefik"

_patch_idx=0
IFS='|' read -ra _r_ports    <<< "\$HL7_LISTEN_PORTS"
IFS='|' read -ra _r_comments <<< "\$HL7_PORT_COMMENTS"
for _r_port in "\${_r_ports[@]}"; do
    _r_ep="hl7"
    [ "\$_patch_idx" -gt 0 ] && _r_ep="hl7-\${_r_port}"
    _r_cmt="\${_r_comments[\$_patch_idx]:-}"
    _r_addr="    address: ':\${_r_port}'"
    [ -n "\$_r_cmt" ] && _r_addr="\${_r_addr} # \${_r_cmt}"

    if grep -q "^  \${_r_ep}:" "\$_tmp_traefik"; then
        sed -i "/^  \${_r_ep}:/,/^  [a-z]/{s|address:.*|\${_r_addr}|}" "\$_tmp_traefik"
        echo "  ✓ traefik.yml entrypoint \${_r_ep} updated"
    else
        _tmp2=\$(mktemp)
        awk -v ep="\$_r_ep" -v addr="\$_r_addr" '
            /^ping:/ && !inserted {
                print "  " ep ":"
                print addr
                print "    transport:"
                print "      respondingTimeouts:"
                print "        readTimeout: 0"
                print "        idleTimeout: 0"
                inserted=1
            }
            { print }
        ' "\$_tmp_traefik" > "\$_tmp2"
        cp "\$_tmp2" "\$_tmp_traefik"
        rm -f "\$_tmp2"
        echo "  ✓ traefik.yml entrypoint \${_r_ep} added"
    fi
    _patch_idx=\$(( _patch_idx + 1 ))
done

cp "\$_tmp_traefik" "\$TRAEFIK_CONFIG_FILE"
rm -f "\$_tmp_traefik"

# Restart Traefik
cd /home/haloap/traefik
docker compose up -d --force-recreate
echo "  ✓ Traefik restarted"

# Verify health
for i in \$(seq 1 15); do
    if curl -fs http://localhost:8800/ping > /dev/null 2>&1; then
        echo "  ✓ Traefik healthy"
        break
    fi
    if [ "\$i" -eq 15 ]; then
        echo "  ⚠️  Warning: health check not responding"
    fi
    sleep 1
done
REMOTEPATCH

            chmod 644 "$SCRIPTS_DIR/integration_patch_${node}.sh"

            ensure_SCRIPTS_DIR "$ip"
            copy_to_remote "/tmp/hl7.yml" "$ip" "/tmp/hl7.yml"
            copy_to_remote "$SCRIPTS_DIR/integration_patch_${node}.sh" \
                "$ip" "$SCRIPTS_DIR/integration_patch.sh"

            execute_remote_script "$ip" "$SCRIPTS_DIR/integration_patch.sh"

            rm -f "$SCRIPTS_DIR/integration_patch_${node}.sh"
            echo "  ✓ $node updated"
        done

        rm -f /tmp/hl7.yml
        cleanup_remote_scripts_dirs
    fi

    # ----------------------------------------
    # Save updated config
    # ----------------------------------------
    echo ""
    echo -n "Saving configuration... "
    save_config
    echo "✓ Done"

    # ----------------------------------------
    # Summary
    # ----------------------------------------
    echo ""
    echo "=========================================="
    echo "✓✓✓ INTEGRATION SETUP COMPLETE ✓✓✓"
    echo "=========================================="
    echo ""
    echo "HL7 Integration:"
    IFS='|' read -ra _isrv_ports    <<< "$HL7_LISTEN_PORTS"
    IFS='|' read -ra _isrv_backends <<< "$HL7_PORT_BACKENDS"
    IFS='|' read -ra _isrv_comments <<< "$HL7_PORT_COMMENTS"
    _iidx=0
    for _ip in "${_isrv_ports[@]}"; do
        _icmt="${_isrv_comments[$_iidx]:-}"
        [[ -n "$_icmt" ]] && echo "  Port $(( _iidx + 1 )) : :${_ip} # ${_icmt}" || echo "  Port $(( _iidx + 1 )) : :${_ip}"
        IFS=',' read -ra _isrvs <<< "${_isrv_backends[$_iidx]}"
        for _isrv in "${_isrvs[@]}"; do
            echo "    Backend : ${_isrv}"
        done
        (( ++_iidx ))
    done
    echo ""
    echo "Files updated:"
    echo "  - ${TRAEFIK_DYNAMIC_DIR}/hl7.yml"
    echo "  - $TRAEFIK_CONFIG_FILE"
    echo "  - $CONFIG_FILE"
    if [[ "$MULTI_NODE_DEPLOYMENT" == "yes" && ${#BACKUP_NODES[@]} -gt 0 ]]; then
        echo ""
        echo "  Applied to backup nodes:"
        for i in "${!BACKUP_NODES[@]}"; do
            echo "    - ${BACKUP_NODES[$i]} (${BACKUP_IPS[$i]})"
        done
    fi
    echo ""
    echo "Verification:"
    IFS='|' read -ra _iv_ports <<< "$HL7_LISTEN_PORTS"
    for _iv_port in "${_iv_ports[@]}"; do
        echo "  ss -tlnp | grep :${_iv_port}"
    done
    echo "  docker logs traefik"
    echo "=========================================="
    echo ""

    cleanup
    exit 0
fi

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
        sudo mkdir -p "$CERT_DIR"
        sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap || exit_on_error "Failed to set ownership on /home/haloap"

        touch "$CERT_FILE"
        touch "$KEY_FILE"
        echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
        echo "$SSL_KEY_CONTENT" > "$KEY_FILE"
    else
        log "No existing configuration found. Proceeding with new setup."
    fi
}

# Function to prompt user for using existing configuration
prompt_use_existing_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo ""
        echo "=========================================="
        echo "Existing configuration file detected!"
        echo "=========================================="
        echo ""
        if prompt_yn "Do you want to use the existing configuration?"; then
            log "User chose to use existing configuration."
            load_config
            return 0
        else
            log "User chose not to use existing configuration. Renaming file to $CONFIG_FILE.bak."
            mv "$CONFIG_FILE" "$CONFIG_FILE.bak" || exit_on_error "Failed to rename existing configuration file."
            return 0
        fi
    else
        log "No existing configuration file found. Proceeding with new setup."
        return 0
    fi
}

# Prompt for deployment type
prompt_deployment_type() {
    echo ""
    echo "=========================================="
    echo "Select Traefik Deployment Type"
    echo "=========================================="
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


# Function to backup existing configuration files limit to two with most recent named .bak.mostrecent
backup_file() {
    local file="$1"
    local timestamp=$(date +'%Y%m%d%H%M%S')
    local most_recent_backup="${file}.bak.mostrecent"
    local previous_backup="${file}.bak.previous"

    if [[ -f "$file" ]]; then
        # Determine if we need sudo based on file ownership
        local file_owner=$(stat -c '%U' "$file" 2>/dev/null || stat -f '%Su' "$file" 2>/dev/null)
        local use_sudo=false
        
        if [[ "$file_owner" == "root" ]] || [[ ! -w "$(dirname "$file")" ]]; then
            use_sudo=true
        fi
        
        if [[ "$use_sudo" == "true" ]]; then
            if [[ -f "$most_recent_backup" ]]; then
                log "Renaming existing backup $most_recent_backup to $previous_backup"
                sudo mv "$most_recent_backup" "$previous_backup" || exit_on_error "Failed to rename existing backup"
            fi

            log "Backing up $file to $most_recent_backup"
            sudo cp "$file" "$most_recent_backup" || exit_on_error "Failed to backup $file"
        else
            if [[ -f "$most_recent_backup" ]]; then
                log "Renaming existing backup $most_recent_backup to $previous_backup"
                mv "$most_recent_backup" "$previous_backup" || exit_on_error "Failed to rename existing backup"
            fi

            log "Backing up $file to $most_recent_backup"
            cp "$file" "$most_recent_backup" || exit_on_error "Failed to backup $file"
        fi
    fi
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
    echo "=========================================="
    echo "High Availability Configuration"
    echo "=========================================="
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
        echo "=========================================="
        echo "Multi-Node Configuration Summary"
        echo "=========================================="
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
        echo "=========================================="
        echo "HL7 / TCP Integration (Optional)"
        echo "=========================================="
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
    echo "=========================================="
    echo "HL7 / TCP Integration (Optional)"
    echo "=========================================="
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
    read -p "  Short description for port ${_primary_port} (e.g. Main Lab, Radiology): " _primary_comment
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

# Function to generate clinical_conf.yml based on deployment type (full or image-site) and prompts for service hostnames, protocols and ports using prompt_single_entry function
generate_clinical_conf() {
    local dynamic_dir="/home/haloap/traefik/config/dynamic"
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

    printf "\n" > /dev/tty
    read -p "Would you like to use a custom CA certificate for upstream TLS? (y/n) [default: n]: " ca_choice < /dev/tty
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
}

# ==========================================
# MAIN SCRIPT EXECUTION
# ==========================================

# Validate execution context and OS
validate_os
check_execution_context
validate_proxy_config
setup_proxy_strategy || exit_on_error "Failed to setup proxy strategy"

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
    echo "=========================================="
    echo "Multi-Node SSH Setup"
    echo "=========================================="
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
    echo "=========================================="
    echo "Network Interface Configuration"
    echo "=========================================="
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
    
    echo "=========================================="
    echo "✓ Network Interface Configuration Complete"
    echo "=========================================="
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
echo "=========================================="
echo "Pre-Flight Check Summary"
echo "=========================================="
echo "✓ Operating System: Validated ($OS_ID $OS_VERSION)"
echo "✓ Execution Context: Validated (running as $CURRENT_USER)"
echo "✓ Package Manager: $PKG_MANAGER"
echo "✓ Sudo Access: Verified"
echo "✓ Repository Access: Verified"

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
echo "=========================================="
echo "Install Prerequisites"
echo "=========================================="
echo ""

# Define prerequisites based on package manager
if [[ "$PKG_MANAGER" == "apt" ]]; then
    PREREQ_PACKAGES=(
        apt-transport-https ca-certificates curl 
        gnupg lsb-release 
        wget nano ipcalc
    )
    log "Updating apt package lists..."
    sudo apt-get $APT_PROXY_OPT_PROXY update || exit_on_error "Failed to update package lists"
elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    PREREQ_PACKAGES=(
        ca-certificates curl dnf-plugins-core
        gnupg2 wget nano iproute python3 jq
    )
    log "Cleaning dnf metadata..."
    sudo dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True clean all || {
        log "Warning: dnf clean had issues, continuing..."
    }
fi

# Install prerequisites using install_packages function
log "Installing base packages..."
sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
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
        if sudo dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install container-selinux 2>&1 | tee -a "$LOGFILE"; then
            log "✓ container-selinux installed"
            
        elif sudo dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True -y install container-selinux --nobest 2>&1 | tee -a "$LOGFILE"; then
            log "✓ container-selinux installed (older version)"
            
        else
            # Fallback to Rocky Linux
            log "Trying Rocky Linux repos..."
            
            if curl ${PROXY_CURL_OPTS} ${CURL_SSL_OPT} -o /tmp/rocky-repos.rpm \
                https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/r/rocky-repos-9.5-2.el9.noarch.rpm 2>&1 | tee -a "$LOGFILE"; then
                
                sudo rpm -ivh /tmp/rocky-repos.rpm 2>&1 | tee -a "$LOGFILE" || true
                rm -f /tmp/rocky-repos.rpm
                
                # Try installing from Rocky
                sudo dnf ${DNF_SSL_OPT} ${DNF_PROXY_OPT} --setopt=skip_if_unavailable=True --enablerepo=rocky-baseos -y install container-selinux 2>&1 | tee -a "$LOGFILE" || true
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
echo "=========================================="
echo "Installing Docker"
echo "=========================================="
echo ""

# OS-specific Docker installation
if [[ "$PKG_MANAGER" == "apt" ]]; then
    log "Installing Docker via apt..."
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    
    # Download GPG key (respects proxy strategy via curl)
    if curl ${PROXY_CURL_OPTS} ${CURL_SSL_OPT} -fsSL \
        https://download.docker.com/linux/$OS_ID/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>&1 | tee -a "$LOGFILE"; then
        log "✓ Docker GPG key added"
    else
        exit_on_error "Failed to download Docker GPG key"
    fi
    
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$OS_ID $OS_VERSION stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package lists (respects proxy strategy)
    sudo apt-get ${APT_PROXY_OPT_PROXY} ${APT_SSL_OPT} update || exit_on_error "Failed to update package lists"
    
    # Install Docker packages
    sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
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
        
        sudo mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
        log "✓ Docker repository added"
    else
        exit_on_error "Failed to download Docker repository"
    fi
    
    # Install Docker packages (DNF respects proxy strategy)
    log "Installing Docker packages..."
    sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
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
    sudo mkdir -p /etc/docker
    
    # Backup existing daemon.json if it exists
    if [ -f "/etc/docker/daemon.json" ]; then
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        log "Backed up existing daemon.json"
    fi
    
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
        PROXY_URL="http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
    else
        PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    fi
    
    # Create daemon.json with proxy configuration
    sudo tee /etc/docker/daemon.json > /dev/null <<EOF
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
sudo systemctl enable docker || exit_on_error "Failed to enable Docker"
sudo systemctl stop docker 2>/dev/null || true
sleep 2
sudo systemctl start docker || exit_on_error "Failed to start Docker"
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
    sudo usermod -aG docker "$CURRENT_USER" || exit_on_error "Failed to add user to docker group"
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
    echo "=========================================="
    echo "Docker Repository Management"
    echo "=========================================="
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
                sudo mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled
                log "✓ Docker repository disabled"
                log "  Moved to: /etc/apt/sources.list.d/docker.list.disabled"
            fi
            
            # Also disable Docker GPG key (prevents apt update warnings)
            if [ -f /etc/apt/keyrings/docker.gpg ]; then
                sudo mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled 2>/dev/null || true
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
                    sudo dnf config-manager --set-disabled docker-ce-stable 2>/dev/null
                else
                    sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
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

# Prompt user for certificates (if not already loaded)
if [[ -z "$CERT_FILE" ]]; then
    log "Prompting user for certificates..."
    CERT_DIR="/home/haloap/traefik/certs"
    
    # Create directory structure
    log "Creating certificate directory..."
    sudo mkdir -p "$CERT_DIR"
    sudo mkdir -p /home/haloap/traefik/config/dynamic
    sudo mkdir -p /home/haloap/traefik/logs
    
    # Set proper ownership - REMOVE the || true to catch failures!
    log "Setting ownership to $CURRENT_USER..."
    sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap || exit_on_error "Failed to set ownership on /home/haloap"
    
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
      rm -rf "$CERT_FILE" || sudo rm -rf "$CERT_FILE" || exit_on_error "Failed to remove directory $CERT_FILE"
    fi
    if [[ -d "$KEY_FILE" ]]; then
      log "Removing directory $KEY_FILE"
      rm -rf "$KEY_FILE" || sudo rm -rf "$KEY_FILE" || exit_on_error "Failed to remove directory $KEY_FILE"
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
echo "=========================================="
echo "Deploying Traefik Docker Container"
echo "=========================================="
echo ""

# Create Docker & Traefik directories with proper ownership
log "Creating Docker and Traefik directories..."
sudo mkdir -p /home/haloap/traefik/{certs,config,logs}
sudo mkdir -p /home/haloap/traefik/config/dynamic
sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap 2>/dev/null || true

# Verify ownership
if [[ ! -w "/home/haloap/traefik" ]]; then
    log "Warning: /home/haloap/traefik not writable, attempting to fix ownership..."
    sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap || exit_on_error "Failed to set ownership on /home/haloap"
fi

# Create a Docker network for Traefik
#log "Creating Docker network 'proxynet'..."
#if ! docker_cmd network inspect proxynet > /dev/null 2>&1; then
#    docker_cmd network create proxynet || exit_on_error "Failed to create Docker network"
#fi

# Create the docker-compose.yaml file for Traefik
log "Creating docker-compose.yaml file..."
DOCKER_COMPOSE_FILE="/home/haloap/traefik/docker-compose.yaml"

# Ensure docker-compose.yaml is not a directory
if [[ -d "$DOCKER_COMPOSE_FILE" ]]; then
    log "Removing incorrectly created directory: $DOCKER_COMPOSE_FILE"
    sudo rm -rf "$DOCKER_COMPOSE_FILE" || exit_on_error "Failed to remove directory"
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
TRAEFIK_CONFIG_FILE="/home/haloap/traefik/config/traefik.yml"

# Ensure traefik.yml is not a directory from previous failed runs
if [[ -d "$TRAEFIK_CONFIG_FILE" ]]; then
    log "Removing incorrectly created directory: $TRAEFIK_CONFIG_FILE"
    sudo rm -rf "$TRAEFIK_CONFIG_FILE" || exit_on_error "Failed to remove directory $TRAEFIK_CONFIG_FILE"
fi

backup_file "$TRAEFIK_CONFIG_FILE"

# NOTE: traefik.yml is written after prompt_hl7_config so the HL7 entrypoint
# can be included conditionally based on the user's answer.

# Create the dynamic config directory and generate config files
log "Creating dynamic config directory and configuration files..."
TRAEFIK_DYNAMIC_DIR="/home/haloap/traefik/config/dynamic"
TRAEFIK_DYNAMIC_FILE="${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"

# Ensure dynamic dir is not a stale file from old layout
if [[ -f "${TRAEFIK_DYNAMIC_DIR}" ]]; then
    log "Removing stale file at dynamic dir path: ${TRAEFIK_DYNAMIC_DIR}"
    sudo rm -f "${TRAEFIK_DYNAMIC_DIR}" || exit_on_error "Failed to remove stale path ${TRAEFIK_DYNAMIC_DIR}"
fi

# Ensure clinical_conf.yml is not a directory from previous failed runs
if [[ -d "$TRAEFIK_DYNAMIC_FILE" ]]; then
    log "Removing incorrectly created directory: $TRAEFIK_DYNAMIC_FILE"
    sudo rm -rf "$TRAEFIK_DYNAMIC_FILE" || exit_on_error "Failed to remove directory $TRAEFIK_DYNAMIC_FILE"
fi

# Remove legacy clinical_conf.yml directory from the old single-file layout
# (Docker creates a directory if the bind-mount source file didn't exist)
_legacy_conf="/home/haloap/traefik/config/clinical_conf.yml"
if [[ -d "$_legacy_conf" ]]; then
    log "Removing legacy directory from old layout: $_legacy_conf"
    sudo rm -rf "$_legacy_conf" || exit_on_error "Failed to remove legacy directory $_legacy_conf"
fi

mkdir -p "$TRAEFIK_DYNAMIC_DIR" || exit_on_error "Failed to create dynamic config directory"
backup_file "$TRAEFIK_DYNAMIC_FILE"

echo ""
echo "=========================================="
echo "Configure Traefik"
echo "=========================================="
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

# Generate hl7.yml if HL7 integration is enabled (full deployment only)
if [[ "$DEPLOYMENT_TYPE" == "full" ]]; then
    generate_hl7_conf "$TRAEFIK_DYNAMIC_DIR"
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
EOF

# Write custom CA certificate and update docker-compose volume mount if configured
if [[ "$USE_CUSTOM_CA" == "yes" && -n "$CUSTOM_CA_CERT_CONTENT" ]]; then
    log "Writing custom CA certificate to $CERT_DIR/customca.crt..."
    # Guard: remove if it was incorrectly created as a directory in a previous run
    if [[ -d "$CERT_DIR/customca.crt" ]]; then
        log "Removing incorrectly created directory: $CERT_DIR/customca.crt"
        sudo rm -rf "$CERT_DIR/customca.crt" || exit_on_error "Failed to remove directory $CERT_DIR/customca.crt"
    fi
    echo "$CUSTOM_CA_CERT_CONTENT" | tee "$CERT_DIR/customca.crt" > /dev/null || exit_on_error "Failed to write custom CA certificate"
    chmod 644 "$CERT_DIR/customca.crt" || exit_on_error "Failed to set permissions on custom CA certificate"
    log "Custom CA certificate written successfully"

    log "Adding custom CA volume mount to docker-compose.yaml..."
    sed -i 's|      - ./certs/server.key:/certs/server.key:ro|      - ./certs/server.key:/certs/server.key:ro\n      - ./certs/customca.crt:/certs/customca.crt:ro|' "$DOCKER_COMPOSE_FILE"
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

# Pull Traefik from Docker Hub
log "Pulling Traefik image from Docker Hub..."
if ! try_pull "docker.io/library/traefik:latest"; then
    echo ""
    echo "=========================================="
    echo "ERROR: Cannot Pull Traefik Image"
    echo "=========================================="
    echo "Docker Hub is not accessible from this server."
    echo ""
    echo "This typically means the firewall is blocking one or more of these endpoints:"
    echo "  - registry-1.docker.io (registry API)"
    echo "  - auth.docker.io (authentication)"
    echo "  - production.cloudflare.docker.com (image layer downloads)"
    echo ""
    echo "Solutions:"
    echo "  1. Contact your network admin to whitelist Docker Hub endpoints"
    echo "  2. Manually transfer the image from an internet-connected machine:"
    echo ""
    echo "     On internet-connected machine:"
    echo "       docker pull docker.io/library/traefik:latest"
    echo "       docker save docker.io/library/traefik:latest | gzip > traefik.tar.gz"
    echo ""
    echo "     Transfer traefik.tar.gz to this server, then:"
    echo "       gunzip -c traefik.tar.gz | docker load"
    echo ""
    echo "     Re-run this script after loading the image"
    echo "=========================================="
    exit_on_error "Failed to pull Traefik from Docker Hub"
fi

# Navigate to the Traefik directory and start the Docker Compose setup
log "Starting Traefik with Docker Compose..."
cd /home/haloap/traefik
if [ "${USE_DOCKER_GROUP:-false}" = "true" ]; then
    sg docker -c "docker compose up -d --force-recreate --pull always" || exit_on_error "Failed to start Traefik with Docker Compose"
else
    docker compose up -d --force-recreate --pull always || exit_on_error "Failed to start Traefik with Docker Compose"
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
echo "=========================================="
echo "Installing KeepAlived"
echo "=========================================="
echo ""

# Install Keepalived
log "Installing Keepalived..."
sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); \
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
    sudo groupadd -r keepalived_script || exit_on_error "Failed to create keepalived_script group"
    echo "Group 'keepalived_script' created."
else
    echo "Group 'keepalived_script' already exists."
fi

# Adding Keepalived user and add to Keepalived group
log "Adding Keepalived user to Keepalived group..."
if ! id "keepalived_script" &>/dev/null; then
    sudo useradd -r -s /sbin/nologin -G keepalived_script -g docker -M keepalived_script || exit_on_error "Failed to create keepalived_script user"
    echo "User 'keepalived_script' created."
else
    echo "User 'keepalived_script' already exists."
fi

# Create Traefik health check script
log "Creating Traefik health check script..."
TRAEFIK_CHECK_SCRIPT="/bin/haloap_service_check.sh"
sudo tee $TRAEFIK_CHECK_SCRIPT > /dev/null <<EOF
#!/bin/bash

# Check if the Traefik ping endpoint is alive on its dedicated port
if curl -fs http://localhost:8800/ping > /dev/null; then
  exit 0
else
  exit 1
fi
EOF
sudo chmod +x $TRAEFIK_CHECK_SCRIPT || exit_on_error "Failed to make Traefik health check script executable"
sudo chown keepalived_script:docker $TRAEFIK_CHECK_SCRIPT || exit_on_error "Failed to set permissions for Traefik health check script"

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

sudo tee $KEEPALIVED_CONF > /dev/null <<EOF
global_defs {
  enable_script_security
  script_user keepalived_script
  max_auto_priority
}
vrrp_script check_traefik {
  script "/bin/haloap_service_check.sh"
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
  sudo chmod 640 $KEEPALIVED_CONF

  # Restart Keepalived to apply the configuration
  log "Starting and enabling KeepAlived..."
  sudo systemctl enable keepalived || exit_on_error "Failed to enable Keepalived"
  sudo systemctl start keepalived || exit_on_error "Failed to start Keepalived"
  
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
    echo ""
    echo "=========================================="
    echo "Deploying to Backup Nodes"
    echo "=========================================="
    echo ""
    
    # Save configuration before deploying to backups
    save_config
    
    # Deploy to each backup node
    for i in "${!BACKUP_NODES[@]}"; do
        node="${BACKUP_NODES[$i]}"
        ip="${BACKUP_IPS[$i]}"
        priority=$((100 - (i * 10)))
        
        echo ""
        echo "=========================================="
        echo "Backup Node $((i+1))/${#BACKUP_NODES[@]}: $node ($ip)"
        echo "Priority: $priority"
        echo "=========================================="
        echo ""
        
        # Create remote installation script
        log "Creating installation script for $node..."
        
write_local_file "$SCRIPTS_DIR/install_backup_${node}.sh" <<'REMOTEINSTALL'
#!/bin/bash
set -e
set -x

echo ""
echo "=========================================="
echo "Installing Traefik on Backup Node"
echo "=========================================="
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
            # All connections via proxy - for strict firewall environments
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
            # External via proxy, internal direct
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
            DNF_PROXY_OPT=""  # DNF respects environment proxy with no_proxy
            ;;
        "none"|*)
            # No proxy
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

# Add SSL options if configured
if [ -n "$APT_SSL_OPT" ]; then
    APT_PROXY_OPT="$APT_PROXY_OPT $APT_SSL_OPT"
fi

if [ -n "$DNF_SSL_OPT" ]; then
    DNF_PROXY_OPT="$DNF_PROXY_OPT $DNF_SSL_OPT"
fi

echo "=== Installing on $(hostname) ==="

CONFIG_FILE="/tmp/deployment.config"

# Source the configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "✓ Configuration loaded from $CONFIG_FILE"
else
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Get current user

# Get the actual user running the script (before sudo elevation)
_RAW_USER="${SUDO_USER:-$USER}"
CURRENT_USER="${_RAW_USER%%@*}"
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

CURRENT_GROUP=$(id -gn "$CURRENT_USER")

echo "Installing as user: $CURRENT_USER"
echo ""

# Set environment for non-interactive installation
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
    # Try normal install first
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y ca-certificates curl dnf-plugins-core gnupg2 wget nano iproute python3 jq; then
        # Try with --nobest if normal install fails
        sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y ca-certificates curl dnf-plugins-core gnupg2 wget nano iproute python3 jq --nobest
    fi
fi

# Install container-selinux for RHEL/CentOS (required for Docker)
if command -v dnf &>/dev/null && ! rpm -q container-selinux &>/dev/null; then
    echo "Installing container-selinux..."
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y container-selinux; then
        if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y container-selinux --nobest; then
            # Try Rocky repos as fallback (download with curl using proxy)
            echo "Trying Rocky Linux repos..."
            if curl $PROXY_CURL_OPTS $CURL_SSL_OPT -o /tmp/rocky-repos.rpm \
                https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/r/rocky-repos-9.5-2.el9.noarch.rpm 2>/dev/null; then
                sudo rpm -ivh /tmp/rocky-repos.rpm 2>/dev/null || true
                sudo dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True --enablerepo=rocky-baseos install -y container-selinux 2>/dev/null || true
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
    # Debian/Ubuntu Docker installation
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        echo "Adding Docker repository..."
        sudo install -m 0755 -d /etc/apt/keyrings
        
        # Download GPG key with curl (uses proxy)
        curl $PROXY_CURL_OPTS $CURL_SSL_OPT -fsSL \
            https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo -E apt-get $APT_PROXY_OPT_PROXY update -qq
    fi
    
    echo "Installing Docker packages..."
    sudo -E apt-get $APT_PROXY_OPT_PROXY install -y docker-ce docker-ce-cli containerd.io
    
elif command -v dnf &>/dev/null; then
    # RHEL/Rocky/CentOS Docker installation
    if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
        echo "Downloading Docker repository..."
        # Download repo file with curl (uses proxy)
        if curl $PROXY_CURL_OPTS $CURL_SSL_OPT -fsSL \
            https://download.docker.com/linux/centos/docker-ce.repo \
            -o /tmp/docker-ce.repo; then
            sudo mv /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
            echo "✓ Docker repository added"
        else
            echo "ERROR: Failed to download Docker repository"
            exit 1
        fi
    fi
    
    echo "Installing Docker packages..."
    # Try normal install first
    if ! sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y docker-ce docker-ce-cli containerd.io; then
        # Try with --nobest if normal install fails
        sudo -E dnf $DNF_PROXY_OPT $DNF_SSL_OPT --setopt=skip_if_unavailable=True install -y docker-ce docker-ce-cli containerd.io --nobest
    fi
    
else
    echo "ERROR: No supported package manager found (apt or dnf)"
    exit 1
fi

echo "✓ Docker installed successfully"

# Verify Docker installation
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker installation failed - docker command not found"
    exit 1
fi

docker --version

# Configure Docker proxy if needed (for container pulls)
if [ -n "$PROXY" ]; then
    echo "Configuring Docker daemon to use proxy..."
    sudo mkdir -p /etc/docker
    
    # Backup existing daemon.json if it exists
    if [ -f "/etc/docker/daemon.json" ]; then
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi
    
    # Create daemon.json with proxy configuration
    sudo tee /etc/docker/daemon.json > /dev/null <<DOCKEREOF
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

# Start Docker
echo "Starting Docker..."
sudo systemctl enable docker
sudo systemctl stop docker 2>/dev/null || true
sleep 2
sudo systemctl start docker
sleep 3

# Verify Docker is running
if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker failed to start"
    exit 1
fi
echo "✓ Docker is running"

# Add user to docker group
if ! groups "$CURRENT_USER" | grep -q docker; then
    sudo usermod -aG docker "$CURRENT_USER"
fi

# Disable Docker repository based on master's configuration
DISABLE_DOCKER_REPO="__DISABLE_DOCKER_REPO__"

if [ "$DISABLE_DOCKER_REPO" = "yes" ]; then
    echo "Disabling Docker repositories (as configured on master node)..."
    
    if command -v apt-get &>/dev/null; then
        if [ -f /etc/apt/sources.list.d/docker.list ]; then
            sudo mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled 2>/dev/null || true
            sudo mv /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.gpg.disabled 2>/dev/null || true
            echo "✓ Docker repository disabled"
        fi
    elif command -v dnf &>/dev/null; then
        if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
            sudo dnf config-manager --set-disabled docker-ce-stable 2>/dev/null || \
                sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/docker-ce.repo
            echo "✓ Docker repository disabled"
        fi
    fi
else
    echo "Docker repository kept enabled (as configured on master node)"
fi

# Create Traefik directories
sudo mkdir -p /home/haloap/traefik/{certs,config,logs}
sudo mkdir -p /home/haloap/traefik/config/dynamic
sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap

TRAEFIK_CONFIG_FILE="/home/haloap/traefik/config/traefik.yml"
TRAEFIK_DYNAMIC_DIR="/home/haloap/traefik/config/dynamic"
TRAEFIK_DYNAMIC_FILE="${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml"
DOCKER_COMPOSE_FILE="/home/haloap/traefik/docker-compose.yaml"

# Ensure traefik.yml is not a directory
if [[ -d "$TRAEFIK_CONFIG_FILE" ]]; then
    echo "Removing incorrectly created directory: $TRAEFIK_CONFIG_FILE"
    sudo rm -rf "$TRAEFIK_CONFIG_FILE" || { echo "Failed to remove directory"; exit 1; }
fi

# Ensure dynamic dir is not a stale file
if [[ -f "${TRAEFIK_DYNAMIC_DIR}" ]]; then
    echo "Removing stale file at dynamic dir path: ${TRAEFIK_DYNAMIC_DIR}"
    sudo rm -f "${TRAEFIK_DYNAMIC_DIR}" || { echo "Failed to remove stale path"; exit 1; }
fi

# Ensure clinical_conf.yml is not a directory
if [[ -d "$TRAEFIK_DYNAMIC_FILE" ]]; then
    echo "Removing incorrectly created directory: $TRAEFIK_DYNAMIC_FILE"
    sudo rm -rf "$TRAEFIK_DYNAMIC_FILE" || { echo "Failed to remove directory"; exit 1; }
fi

# Remove legacy clinical_conf.yml directory from the old single-file layout
if [[ -d "/home/haloap/traefik/config/clinical_conf.yml" ]]; then
    echo "Removing legacy directory from old layout: /home/haloap/traefik/config/clinical_conf.yml"
    sudo rm -rf "/home/haloap/traefik/config/clinical_conf.yml" || { echo "Failed to remove legacy directory"; exit 1; }
fi

# Create dynamic config directory
mkdir -p "$TRAEFIK_DYNAMIC_DIR" || { echo "Failed to create dynamic config directory"; exit 1; }

# Ensure docker-compose.yaml is not a directory
if [[ -d "$DOCKER_COMPOSE_FILE" ]]; then
    echo "Removing incorrectly created directory: $DOCKER_COMPOSE_FILE"
    sudo rm -rf "$DOCKER_COMPOSE_FILE" || { echo "Failed to remove directory"; exit 1; }
fi

# Ensure CERT_FILE and KEY_FILE are not directories
if [[ -d "$CERT_FILE" ]]; then
    echo "Removing directory $CERT_FILE"
    rm -rf "$CERT_FILE" || exit 1
fi
if [[ -d "$KEY_FILE" ]]; then
    echo "Removing directory $KEY_FILE"
    rm -rf "$KEY_FILE" || exit 1
fi

# Copy certificates
if [ -n "$SSL_CERT_CONTENT" ] && [ -n "$SSL_KEY_CONTENT" ]; then
    echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
    echo "$SSL_KEY_CONTENT" > "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
fi

# Write custom CA certificate if configured
if [ "$USE_CUSTOM_CA" = "yes" ] && [ -n "$CUSTOM_CA_CERT_CONTENT" ]; then
    echo "$CUSTOM_CA_CERT_CONTENT" > /home/haloap/traefik/certs/customca.crt
    chmod 644 /home/haloap/traefik/certs/customca.crt
    echo "✓ Custom CA certificate written"
fi

# Create docker-compose.yaml
cat > /home/haloap/traefik/docker-compose.yaml <<'DOCKERCOMPOSE'
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

# Add custom CA cert volume mount if configured
if [ "$USE_CUSTOM_CA" = "yes" ] && [ -n "$CUSTOM_CA_CERT_CONTENT" ]; then
    sed -i 's|      - ./certs/server.key:/certs/server.key:ro|      - ./certs/server.key:/certs/server.key:ro\n      - ./certs/customca.crt:/certs/customca.crt:ro|' /home/haloap/traefik/docker-compose.yaml
    echo "✓ Custom CA volume mount added to docker-compose.yaml"
fi

# Create traefik.yml
cat > /home/haloap/traefik/config/traefik.yml <<'TRAEFIKCONF'
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

# Append HL7 entrypoint if integration is enabled (placeholder replaced by sed below)
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
        cat >> /home/haloap/traefik/config/traefik.yml <<HLEOF
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

cat >> /home/haloap/traefik/config/traefik.yml <<'TRAEFIKCONF2'
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

# Set ownership
sudo chown -R "$CURRENT_USER:$CURRENT_GROUP" /home/haloap

# Start Traefik
echo "Starting Traefik..."
cd /home/haloap/traefik
docker compose up -d --force-recreate --pull always

# Wait for Traefik to start
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

# Create keepalived_script user/group
if ! getent group keepalived_script > /dev/null 2>&1; then
    sudo groupadd -r keepalived_script
fi
if ! id "keepalived_script" &>/dev/null; then
    sudo useradd -r -s /sbin/nologin -G keepalived_script -g docker -M keepalived_script
fi

# Create health check script
sudo tee /bin/haloap_service_check.sh > /dev/null <<'HEALTHCHECK'
#!/bin/bash
if curl -fs http://localhost:8800/ping > /dev/null; then
  exit 0
else
  exit 1
fi
HEALTHCHECK
sudo chmod +x /bin/haloap_service_check.sh
sudo chown keepalived_script:docker /bin/haloap_service_check.sh

# Auto-detect network interface
echo "Auto-detecting network interface..."
BACKUP_NODE_IP="BACKUP_NODE_IP_PLACEHOLDER"
BACKUP_NODE_INTERFACE="BACKUP_INTERFACE_PLACEHOLDER"

echo "Using configured interface: $BACKUP_NODE_INTERFACE"

# Verify the interface exists
if ! ip link show "$BACKUP_NODE_INTERFACE" &>/dev/null; then
    echo "⚠️  WARNING: Interface $BACKUP_NODE_INTERFACE does not exist!"
    echo "Available interfaces:"
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

# Configure Keepalived
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<KEEPALIVEDCONF
global_defs {
  enable_script_security
  script_user keepalived_script
  max_auto_priority
}
vrrp_script check_traefik {
  script "/bin/haloap_service_check.sh"
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

sudo chmod 640 /etc/keepalived/keepalived.conf

# Start Keepalived
echo "Starting Keepalived..."
sudo systemctl enable keepalived
sudo systemctl start keepalived
sudo systemctl restart keepalived

echo ""
echo "✓ Installation complete on backup node"
echo "✓ Traefik: Running"
echo "✓ Keepalived: Running (BACKUP, priority BACKUP_PRIORITY_PLACEHOLDER)"
REMOTEINSTALL

# Compute proxy value
PROXY_VAL=""
if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then 
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
        PROXY_VAL="${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
    else
        PROXY_VAL="${PROXY_HOST}:${PROXY_PORT}"
    fi
fi

# Extract detected internal domains from current no_proxy setting
# This ensures backup nodes get the same no_proxy list as master
if [ "$PROXY_STRATEGY" = "external" ] && [ -n "${no_proxy:-}" ]; then
    # Extract domains from no_proxy, excluding localhost entries
    DETECTED_INTERNAL_DOMAINS=$(echo "${no_proxy}" | tr ',' '\n' | \
        grep -v '^localhost$\|^127\.0\.0\.1$\|^::1$\|^\.local$' | \
        tr '\n' ',' | sed 's/,$//')
    
    # Use detected domains if INTERNAL_REPO_DOMAINS is empty
    if [ -z "${INTERNAL_REPO_DOMAINS}" ] && [ -n "${DETECTED_INTERNAL_DOMAINS}" ]; then
        INTERNAL_REPO_DOMAINS="${DETECTED_INTERNAL_DOMAINS}"
        log "Passing detected internal domains to backup node: ${INTERNAL_REPO_DOMAINS}"
    fi
fi
        
        # Replace priority placeholder and backup node IP
        sed -i "s/BACKUP_PRIORITY_PLACEHOLDER/$priority/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_NODE_IP_PLACEHOLDER/$ip/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_INTERFACE_PLACEHOLDER/${BACKUP_INTERFACES[$i]}/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__PROXY__|${PROXY_URL:-}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__PROXY_STRATEGY__|${PROXY_STRATEGY}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__INTERNAL_REPO_DOMAINS__|${INTERNAL_REPO_DOMAINS}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__CURL_SSL_OPT__|${CURL_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__APT_SSL_OPT__|${APT_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__DNF_SSL_OPT__|${DNF_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__WGET_SSL_OPT__|${WGET_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__DISABLE_DOCKER_REPO__|${DISABLE_DOCKER_REPO}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        # Substitute HL7 placeholders — values contain '|' so cannot use sed.
        # Pass values via environment variables to avoid all quoting/delimiter issues.
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
        
        # Stage dynamic config files for transfer
        # clinical_conf.yml
        if [ -f "${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml" ]; then
            cp "${TRAEFIK_DYNAMIC_DIR}/clinical_conf.yml" /tmp/clinical_conf.yml
        fi
        # hl7.yml (only present when HL7 is enabled)
        if [ -f "${TRAEFIK_DYNAMIC_DIR}/hl7.yml" ]; then
            cp "${TRAEFIK_DYNAMIC_DIR}/hl7.yml" /tmp/hl7.yml
        fi
        
        # Ensure remote scripts directory exists
        ensure_SCRIPTS_DIR "$ip"
        
        # Copy files to backup node
        echo "Copying files to $node..."
        copy_to_remote "$CONFIG_FILE" "$ip" "/tmp/deployment.config"
        if [ -f "/tmp/clinical_conf.yml" ]; then
            copy_to_remote "/tmp/clinical_conf.yml" "$ip" "/tmp/clinical_conf.yml"
        fi
        if [ -f "/tmp/hl7.yml" ]; then
            copy_to_remote "/tmp/hl7.yml" "$ip" "/tmp/hl7.yml"
        fi
        copy_to_remote "$SCRIPTS_DIR/install_backup_${node}.sh" "$ip" "$SCRIPTS_DIR/install_backup.sh"
        
        # Execute installation on backup node
        echo "Starting installation on $node..."
        echo "This may take 5-10 minutes..."
        echo ""
        
        execute_remote_script "$ip" "$SCRIPTS_DIR/install_backup.sh"
        
        # Cleanup local temp files
        rm -f "$SCRIPTS_DIR/install_backup_${node}.sh"
        rm -f /tmp/clinical_conf.yml
        rm -f /tmp/hl7.yml
        
        # Verify deployment
        echo ""
        echo "Verifying deployment on $node..."
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            VERIFY_DOCKER=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
        else
            VERIFY_DOCKER=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
        fi
        
        if echo "$VERIFY_DOCKER" | grep -q "traefik"; then
            echo "✓ Traefik container is running on $node"
        else
            echo "⚠️  Warning: Could not verify Traefik on $node"
        fi
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            VERIFY_KEEPALIVED=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
        else
            VERIFY_KEEPALIVED=$(ssh $SSH_OPTS -l "$CURRENT_USER" "$ip" "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
        fi
        
        if [ "$VERIFY_KEEPALIVED" = "active" ]; then
            echo "✓ Keepalived is running on $node"
        else
            echo "⚠️  Warning: Could not verify Keepalived on $node"
        fi
        
        echo ""
        echo "✓ Deployment to $node completed"
    done
    
    # Cleanup remote scripts directories
    cleanup_remote_scripts_dirs
    
    echo ""
    echo "=========================================="
    echo "✓ All backup nodes deployed successfully"
    echo "=========================================="
    echo ""
fi

### END Deploy to Backup Nodes
######################################################

######################################################
### START Final restart of services

sudo systemctl restart docker
if [[ "$INSTALL_KEEPALIVED" == "yes" || "$INSTALL_KEEPALIVED" == "y" ]]; then
    sudo systemctl restart keepalived
fi

### END Final restart of services
######################################################

# Save configuration (if this is the MASTER node or Keepalived not installed)
if [[ "$NODE_ROLE" == "MASTER" ]] || [[ "$INSTALL_KEEPALIVED" != "yes" && "$INSTALL_KEEPALIVED" != "y" ]]; then
    save_config
fi

log "Installation and basic configuration complete!"

echo ""
echo "=========================================="
echo "✓✓✓ INSTALLATION COMPLETE ✓✓✓"
echo "=========================================="
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
echo "=========================================="
echo "Repository Configuration"
echo "=========================================="

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