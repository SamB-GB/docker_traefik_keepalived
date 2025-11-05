#!/bin/bash

# Enhanced Clinical Traefik Reverse Proxy Setup
#
# USAGE:
#   ./clinicalrp.sh           # Normal installation
#   ./clinicalrp.sh --clean   # Remove Traefik/Keepalived/Docker

set -e

# ==========================================
# Configuration
# ==========================================

# HTTP/HTTPS proxy for outbound downloads (curl/wget/apt/dnf)
# Leave blank if no proxy is needed
# Note: Passwords with special characters will be automatically URL-encoded
PROXY_HOST="10.0.60.61"  # Example: "proxy.company.com"
PROXY_PORT="3128"  # Example: "8080"
PROXY_USER="sbarr"
PROXY_PASSWORD="98lrxfn0a!" # Special characters will be handled automatically
SKIP_SSL_VERIFY="true"  # Set to "true" to disable SSL verification (not recommended)

# Multi-node deployment variables
MULTI_NODE_DEPLOYMENT="no"
BACKUP_NODE_COUNT=0
MASTER_HOSTNAME=""
MASTER_IP=""
BACKUP_NODES=()
BACKUP_IPS=()
BACKUP_INTERFACES=()

# Logging setup
LOGFILE="/var/log/installation.log"

# Get the actual user running the script (before sudo elevation)
CURRENT_USER="${SUDO_USER:-$USER}"

# Get the actual user's home directory (not root's when using sudo)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Get the directory where the script is located
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_FILE="$SCRIPT_DIR/clinical_traefik.env"

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
        sudo -u "$SUDO_USER" -- bash -lc "echo \"$SUDO_PASS\" | ssh $SSH_OPTS '$CURRENT_USER@$ip' 'sudo -S bash -c \"$cmd\"'"
    else
        echo "$SUDO_PASS" | ssh $SSH_OPTS "$CURRENT_USER@$ip" "sudo -S bash -c \"$cmd\""
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
        if ! sudo -u "$SUDO_USER" scp -q $KEY_OPT $COPYS_OPTS "$file" "$CURRENT_USER@$ip:$dest" 2>/tmp/scp_err.$$; then
            # Fallback: stream over ssh without SFTP/SCP
            sudo -u "$SUDO_USER" ssh $KEY_OPT $COPYS_OPTS "$CURRENT_USER@$ip" "cat > '$dest'" < "$file"
        fi
    else
        if ! scp -q $KEY_OPT $COPYS_OPTS "$file" "$CURRENT_USER@$ip:$dest" 2>/tmp/scp_err.$$; then
            ssh $KEY_OPT $COPYS_OPTS "$CURRENT_USER@$ip" "cat > '$dest'" < "$file"
        fi
    fi
    rm -f /tmp/scp_err.$$
}

# Ensure remote user's scripts dir exists
ensure_SCRIPTS_DIR() {
    local ip=$1
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" "mkdir -p $SCRIPTS_DIR && chmod 755 $SCRIPTS_DIR"
    else
        ssh $SSH_OPTS "$CURRENT_USER@$ip" "mkdir -p $SCRIPTS_DIR && chmod 755 $SCRIPTS_DIR"
    fi
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
            if sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" "rm -rf '$SCRIPTS_DIR' 2>/dev/null" 2>/dev/null; then
                echo "✓ Done"
            else
                echo "⚠️  Warning (cleanup failed, but not critical)"
                cleanup_failed=1
                failed_cleanups+=("$name")
            fi
        else
            if ssh $SSH_OPTS "$CURRENT_USER@$ip" "rm -rf '$SCRIPTS_DIR' 2>/dev/null" 2>/dev/null; then
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
SUDO_PASS="$(printf %s "$SUDO_PASS_B64" | base64 -d)"
echo "$SUDO_PASS" | sudo -S bash SCRIPT_PATH 2>&1 || true
rm -f SCRIPT_PATH || true
exit 0
WRAPPER
    chmod 644 "$SCRIPTS_DIR/run_script_wrapper.sh"
    sed -i "s|SCRIPT_PATH|$script_path|g" "$SCRIPTS_DIR/run_script_wrapper.sh"

    ensure_SCRIPTS_DIR "$ip"
    copy_to_remote "$SCRIPTS_DIR/run_script_wrapper.sh" "$ip" "$SCRIPTS_DIR/run_script.sh"

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" ssh -tt $SSH_OPTS "$CURRENT_USER@$ip" "env SUDO_PASS_B64='$PASS_B64' bash $SCRIPTS_DIR/run_script.sh && rm -f $SCRIPTS_DIR/run_script.sh"
    else
        ssh -tt $SSH_OPTS "$CURRENT_USER@$ip" "env SUDO_PASS_B64='$PASS_B64' bash $SCRIPTS_DIR/run_script.sh && rm -f $SCRIPTS_DIR/run_script.sh"
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
            read -p "Continue anyway? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
                echo "Installation cancelled"
                exit 0
            fi
            ;;
    esac
    
    # Check version for Ubuntu
    if [ "$OS_ID" = "ubuntu" ]; then
        case "$VERSION_ID" in
            20.04|22.04|24.04)
                echo "✓ Version: $VERSION_ID (supported)"
                ;;
            *)
                echo "⚠️  Version: $VERSION_ID (untested, may work)"
                read -p "Continue anyway? [y/N]: " CONTINUE
                if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
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
            read -p "Continue anyway? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
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
                read -p "Continue with multi-node deployment? [y/N]: " CONTINUE_MULTI
                if [[ ! "$CONTINUE_MULTI" =~ ^[Yy]$ ]]; then
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
        export no_proxy="localhost,127.0.0.1"
    else
        PROXY_CURL_OPT="${CURL_SSL_OPT}"
    fi
    
    # Helper function to run command locally or remotely
    run_check() {
        local cmd="$1"
        if [ "$check_type" = "remote" ]; then
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$node_ip" "$cmd" 2>/dev/null
            else
                ssh $SSH_OPTS "$CURRENT_USER@$node_ip" "$cmd" 2>/dev/null
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
            
            read -p "  Continue anyway? Docker pulls will likely fail. [y/N]: " CONTINUE_ANYWAY
            if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
                echo "  Installation cancelled."
                cleanup
                exit 1
            fi
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
            read -p "Do you want to clean backup nodes as well? (yes/no) [yes]: " CLEAN_BACKUPS
            CLEAN_BACKUPS=${CLEAN_BACKUPS:-yes}
            
            if [[ "$CLEAN_BACKUPS" =~ ^[Yy] ]]; then
                CLEAN_BACKUP_NODES=true
                
                # Ask about package removal
                echo ""
                echo "Package Removal Options for Backup Nodes:"
                echo ""
                read -p "Uninstall Keepalived package on backup nodes? (yes/no) [yes]: " UNINSTALL_KA_REMOTE
                UNINSTALL_KA_REMOTE=${UNINSTALL_KA_REMOTE:-yes}
                if [[ "$UNINSTALL_KA_REMOTE" =~ ^[Yy] ]]; then
                    UNINSTALL_KEEPALIVED_REMOTE=true
                fi
                
                read -p "Uninstall Docker on backup nodes? (yes/no) [no]: " UNINSTALL_DOCKER_REMOTE_INPUT
                UNINSTALL_DOCKER_REMOTE_INPUT=${UNINSTALL_DOCKER_REMOTE_INPUT:-no}
                if [[ "$UNINSTALL_DOCKER_REMOTE_INPUT" =~ ^[Yy] ]]; then
                    echo ""
                    echo "⚠️  WARNING: This will remove Docker and ALL containers/images on backup nodes!"
                    read -p "Are you absolutely sure? Type 'yes' to continue: " CONFIRM_DOCKER_REMOTE
                    if [[ "$CONFIRM_DOCKER_REMOTE" == "yes" ]]; then
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
    echo "  - Docker network (proxynet)"
    echo "  - Traefik configuration files (/home/haloap/traefik)"
    echo "  - SSL certificates"
    echo "  - Keepalived (if installed)"
    echo "  - Configuration file (clinical_traefik.env)"
    echo ""
    echo "⚠️  WARNING: This operation cannot be undone!"
    echo ""
    read -p "Are you sure? Type 'yes' to continue: " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
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
echo -n "Removing Docker network 'proxynet'... "
if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd network inspect proxynet >/dev/null 2>&1; then
    cleanup_docker_cmd network rm proxynet 2>/dev/null || true
    echo "✓ Removed"
else
    echo "Not found"
fi

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
            echo -n "Removing Docker network 'proxynet'... "
            if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd network inspect proxynet >/dev/null 2>&1; then
                cleanup_docker_cmd network rm proxynet 2>/dev/null || true
                echo "✓ Removed"
            else
                echo "Not found or Docker not accessible"
            fi
            
            # Remove Traefik image (optional)
            if [ "$DOCKER_ACCESSIBLE" != "false" ] && cleanup_docker_cmd images 2>/dev/null | grep -q traefik; then
                echo ""
                read -p "Remove Traefik Docker image? (yes/no) [no]: " REMOVE_IMAGE
                if [[ "$REMOVE_IMAGE" == "yes" || "$REMOVE_IMAGE" == "y" ]]; then
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
                read -p "Uninstall Keepalived package? (yes/no) [no]: " UNINSTALL_KEEPALIVED
                if [[ "$UNINSTALL_KEEPALIVED" == "yes" || "$UNINSTALL_KEEPALIVED" == "y" ]]; then
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
                read -p "Uninstall Docker? (yes/no) [no]: " UNINSTALL_DOCKER
                if [[ "$UNINSTALL_DOCKER" == "yes" || "$UNINSTALL_DOCKER" == "y" ]]; then
                    echo ""
                    echo "⚠️  WARNING: This will remove Docker and ALL containers/images!"
                    read -p "Are you absolutely sure? Type 'yes' to continue: " CONFIRM_DOCKER
                    
                    if [[ "$CONFIRM_DOCKER" == "yes" ]]; then
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
# Configuration Management
# ==========================================

INITIAL_DEPLOYMENT_TYPE=""

# Function to load existing values from clinical_traefik.env
load_config() {
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
        read -p "Do you want to use the existing configuration? (yes/no): " USE_EXISTING_CONFIG
        USE_EXISTING_CONFIG=$(echo "$USE_EXISTING_CONFIG" | tr '[:upper:]' '[:lower:]')

        if [[ "$USE_EXISTING_CONFIG" == "yes" || "$USE_EXISTING_CONFIG" == "y" ]]; then
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
            read -p "Continue anyway with potentially broken encoding? [y/N]: " CONTINUE
            if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
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
    
    # Set proxy for package managers if configured
    local apt_proxy_opts=""
    local dnf_proxy_opts=""
    
    if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
        if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
            # URL-encode the password to handle special characters
            ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
            apt_proxy_opts="-o Acquire::http::Proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT} -o Acquire::https::Proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            dnf_proxy_opts="--setopt=proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
        else
            apt_proxy_opts="-o Acquire::http::Proxy=http://${PROXY_HOST}:${PROXY_PORT} -o Acquire::https::Proxy=http://${PROXY_HOST}:${PROXY_PORT}"
            dnf_proxy_opts="--setopt=proxy=http://${PROXY_HOST}:${PROXY_PORT}"
        fi
    fi
    
    # Add SSL options if configured
    if [ -n "$APT_SSL_OPT" ]; then
        apt_proxy_opts="$apt_proxy_opts $APT_SSL_OPT"
    fi
    
    if [ -n "$DNF_SSL_OPT" ]; then
        dnf_proxy_opts="$dnf_proxy_opts $DNF_SSL_OPT"
    fi
    
    # Detect package manager and install
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get $apt_proxy_opts update > /tmp/apt_update.log 2>&1 || {
            log "Warning: Some repositories failed, continuing with available ones..."
        }
        apt-get $apt_proxy_opts -yq install "${packages[@]}" || exit_on_error "Failed to install packages: ${packages[*]}"
    elif command -v dnf &>/dev/null; then
        dnf $dnf_proxy_opts $DNF_SSL_OPT -y install "${packages[@]}" || exit_on_error "Failed to install packages: ${packages[*]}"
    elif command -v dnf &>/dev/null; then
        dnf $dnf_proxy_opts $DNF_SSL_OPT -y install "${packages[@]}" || exit_on_error "Failed to install packages: ${packages[*]}"
    else
        exit_on_error "No supported package manager found (apt-get, dnf, or dnf)"
    fi
    
    log "✓ Packages installed successfully"
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
        read -p "Use existing multi-node configuration? (yes/no) [yes]: " USE_EXISTING
        USE_EXISTING=${USE_EXISTING:-yes}
        if [[ "$USE_EXISTING" =~ ^[Yy] ]]; then
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
        read -p "Is this configuration correct? (yes/no): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy] ]]; then
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
            read -p "Enter protocol (http/https) [default: http]: " protocol <&4
            protocol=${protocol:-http}
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

# Function to generate clinical_conf.yml based on deployment type (full or image-site) and prompts for service hostnames, protocols and ports using prompt_single_entry function
generate_clinical_conf() {
    local config_file="/home/haloap/traefik/config/clinical_conf.yml"
    local fresh_configuration=false

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
                
                read -p "Add another image server? (yes/no) [no]: " add_more
                [[ "${add_more,,}" != "yes" && "${add_more,,}" != "y" ]] && break
            done
        fi

        # Store for config saving
        IMAGE_SERVICE_URLS="$image_urls"
        
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
  services:
    image-service:
      loadBalancer:
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
  routers:
    image-router:
      rule: "PathPrefix(\`/\`)"
      middlewares:
        - SecurityHeaders
        - compress
      service: image-service
      tls: {}
      
  middlewares:
    SecurityHeaders:
      headers:
        customResponseHeaders:
          Strict-Transport-Security: "max-age=31536000; includeSubDomains; preload"
          X-Content-Type-Options: "nosniff"
          Server: ""
          X-Frame-Options: ""
          Content-Security-Policy: "frame-ancestors 'self' https://iframetester.com;"
        frameDeny: false
        browserXssFilter: true
    compress:
      compress: {}
    cookiesmanager:
      plugin:
        cookiesmanager:
          adder:
            - name: "SameSite"
              value: "none"

serversTransport:
  default:
    idleTimeout: 90m
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

                echo "needs description of what its looking for" > /dev/tty

                # Configure app-service
                current_app_entry=$(prompt_single_entry "app-service" "3000")
                app_urls+="${app_urls:+,}$current_app_entry"

                # Ask to apply to others
                printf "\n"
                read -p "Use the same HOST and PROTOCOL and apply it to all the other services on their default ports (API, FM, iDP & Image Service)? (yes/no) [default: no]: " apply_all < /dev/tty
                apply_all=${apply_all:-no}
                apply_all=$(echo "$apply_all" | tr '[:upper:]' '[:lower:]')

                # Clear batch_entries for this iteration
                unset batch_entries
                declare -A batch_entries

                if [[ "$apply_all" == "yes" || "$apply_all" == "y" ]]; then
                  if [[ $current_app_entry =~ ^(http[s]?)://([^:/]+):([0-9]+)$ ]]; then
                  protocol="${BASH_REMATCH[1]}"
                  host="${BASH_REMATCH[2]}"

              # Generate URLs for other services
              for service in "${services_order[@]}"; do
              [[ $service == "app-service" ]] && continue
              port="${service_ports[$service]}"
            
              # Override protocol to http for filemonitor-service
              if [[ "$service" == "filemonitor-service" ]]; then
                new_entry="http://${host}:${port}"
              else
                new_entry="${protocol}://${host}:${port}"
              fi
            
              batch_entries[$service]+=",$new_entry"
              done
              fi
              else
              # Manual configuration
              for service in "${services_order[@]}"; do
                [[ $service == "app-service" ]] && continue
                  if [[ "$service" == "filemonitor-service" ]]; then
            # Enforce http for filemonitor-service
              entry=$(prompt_single_entry "$service" "${service_ports[$service]}" "true")
            else
            entry=$(prompt_single_entry "$service" "${service_ports[$service]}")
              fi
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
                read -p "Add another batch? (yes/no) [default: no]: " add_more < /dev/tty
                add_more=${add_more:-no}
                [[ "$add_more" != "yes" && "$add_more" != "y" ]] && break
                
                # Increment batch count safely
                batch_count=$((batch_count + 1))
            done

            # Assign accumulated app_urls to app-service in service_urls after all batches
            service_urls["app-service"]="$app_urls"
        else
            log "Using existing service configurations from clinical_traefik.env"
            app_urls="${service_urls["app-service"]}"
        fi

        # Store URLs in global variables
        for service in "${services_order[@]}"; do
            sanitized_name="${service//-/_}_URLS"
            sanitized_name="${sanitized_name^^}"
            cleaned_value=$(echo "${service_urls[$service]}" | sed 's/^,//;s/,,/,/g')
            declare -g "$sanitized_name"="$cleaned_value"
        done

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
  services:
EOF

        # Add services
        for service in "${services_order[@]}"; do
            cleaned_urls=$(echo "${service_urls[$service]}" | sed 's/^,//;s/,,/,/g')
            cat >> "$config_file" <<EOF
    $service:
      loadBalancer:
        healthCheck:
          path: /health
EOF

# Sticky sessions
if [[ "$service" == "idp-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie:
            name: "idp-session"
            secure: true
EOF
elif [[ "$service" == "api-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie:
            name: "api-session"
            secure: true
EOF
elif [[ "$service" == "image-service" ]]; then
    cat >> "$config_file" <<EOF
        sticky:
          cookie:
            name: "image-session"
            secure: true
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
          X-Forwarded-Proto: "https"
          X-Frame-Options: "SAMEORIGIN"
          X-XSS-Protection: "1; mode=block"
          Strict-Transport-Security: "max-age=31536000; includeSubDomains"
          X-Content-Type-Options: "nosniff"
          Content-Security-Policy: "frame-ancestors 'self' https://iframetester.com;"
        frameDeny: false
        sslRedirect: true
        browserXssFilter: true
    compress:
      compress: {}
    cookiesmanager:
      plugin:
        cookiesmanager:
          adder:
            - name: "SameSite"
              value: "none"
            - name: "Secure"
              value: "true"

serversTransport:
  default:
    idleTimeout: 90m
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

    # Save all configuration values to clinical_traefik.env
    cat > "$CONFIG_FILE" <<EOF
DEPLOYMENT_TYPE="$DEPLOYMENT_TYPE"
CERT_DIR="$CERT_DIR"
CERT_FILE="$CERT_FILE"
KEY_FILE="$KEY_FILE"
SSL_CERT_CONTENT="$SSL_CERT_CONTENT"
SSL_KEY_CONTENT="$SSL_KEY_CONTENT"
VRRP="$VRRP"
VIRTUAL_IP="$VIRTUAL_IP"
VRID="$VRID"
AUTH_PASS="$AUTH_PASS"
NETWORK_INTERFACE="$NETWORK_INTERFACE"
MULTI_NODE_DEPLOYMENT="$MULTI_NODE_DEPLOYMENT"
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
            sudo -u "$SUDO_USER" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$ACTUAL_HOME/.ssh/id_rsa.pub" "$CURRENT_USER@$ip" || {
                echo "⚠️  Warning: Failed to copy SSH key to $node"
                echo "   You may need to manually copy the key or enter password during deployment"
            }
        else
            ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$ACTUAL_HOME/.ssh/id_rsa.pub" "$CURRENT_USER@$ip" || {
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
            TEST_RESULT=$(sudo -u "$SUDO_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" "echo SSH_TEST_OK" 2>/dev/null)
        else
            TEST_RESULT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" "echo SSH_TEST_OK" 2>/dev/null)
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
            SUDO_EXISTS=$(sudo -u "$SUDO_USER" ssh -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" "command -v sudo" 2>/dev/null)
        else
            SUDO_EXISTS=$(ssh -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" "command -v sudo" 2>/dev/null)
        fi
        
        if [ -z "$SUDO_EXISTS" ]; then
            echo "❌ sudo not installed"
            SUDO_TEST_FAILED=1
            FAILED_SUDO_NODES+=("$node ($ip) - sudo not installed")
            continue
        fi
        
        PASS_B64=$(printf '%s' "$SUDO_PASS" | base64 -w0 2>/dev/null || printf '%s' "$SUDO_PASS" | base64)
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            TEST_RESULT=$(sudo -u "$SUDO_USER" ssh -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" \
                "echo '$PASS_B64' | base64 -d | sudo -S -k echo SUDO_OK 2>&1" 2>/dev/null | head -1)
        else
            TEST_RESULT=$(ssh -o ConnectTimeout=5 $SSH_OPTS "$CURRENT_USER@$ip" \
                "echo '$PASS_B64' | base64 -d | sudo -S -k echo SUDO_OK 2>&1" 2>/dev/null | head -1)
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
    echo "Configuring network interfaces for Keepalived Virtual IP..."
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
            read -p "  Use detected interface '$master_detected_interface'? (yes/no/other) [yes]: " use_detected
            use_detected=${use_detected:-yes}
            
            case "${use_detected,,}" in
                yes|y)
                    NETWORK_INTERFACE="$master_detected_interface"
                    echo "  ✓ Master interface set to: $NETWORK_INTERFACE"
                    break
                    ;;
                no|n|other|l)
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
                        read -p "  Use it anyway? (yes/no) [no]: " use_anyway
                        if [[ "$use_anyway" =~ ^[Yy] ]]; then
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
                read -p "  Use it anyway? (yes/no) [no]: " use_anyway
                if [[ "$use_anyway" =~ ^[Yy] ]]; then
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
                detected_interface=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                    "ip -o addr show | grep 'inet $ip' | awk '{print \$2}' | head -1" 2>/dev/null)
            else
                detected_interface=$(ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                    "ip -o addr show | grep 'inet $ip' | awk '{print \$2}' | head -1" 2>/dev/null)
            fi
            
            if [ -n "$detected_interface" ]; then
                echo "    ✓ Detected interface: $detected_interface"
                
                # Show available interfaces
                echo "    Available interfaces on $node:"
                if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                    sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                else
                    ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                fi
                echo ""
                
                # Prompt user
                while true; do
                    read -p "    Use detected interface '$detected_interface'? (yes/no/other) [yes]: " use_detected
                    use_detected=${use_detected:-yes}
                    
                    case "${use_detected,,}" in
                        yes|y)
                            BACKUP_INTERFACES[$i]="$detected_interface"
                            echo "    ✓ Interface set to: $detected_interface"
                            break
                            ;;
                        no|n|other|l)
                            echo ""
                            read -p "    Enter interface name: " custom_interface
                            
                            # Validate on remote
                            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                                interface_exists=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                                    "ip link show $custom_interface 2>/dev/null" 2>/dev/null)
                            else
                                interface_exists=$(ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                                    "ip link show $custom_interface 2>/dev/null" 2>/dev/null)
                            fi
                            
                            if [ -n "$interface_exists" ]; then
                                BACKUP_INTERFACES[$i]="$custom_interface"
                                echo "    ✓ Interface set to: $custom_interface"
                                break
                            else
                                echo "    ⚠️  Interface '$custom_interface' not found on $node"
                                read -p "    Use it anyway? (yes/no) [no]: " use_anyway
                                if [[ "$use_anyway" =~ ^[Yy] ]]; then
                                    BACKUP_INTERFACES[$i]="$custom_interface"
                                    echo "    ⚠️  Interface set to: $custom_interface (unverified)"
                                    break
                                fi
                            fi
                            ;;
                        *)
                            echo "    ERROR: Please enter 'yes', 'no', or 'other'"
                            continue
                            ;;
                    esac
                done
            else
                echo "    ⚠️  Auto-detection failed"
                echo "    Available interfaces on $node:"
                if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                    sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                        "ip -o link show | awk '{print \"      - \" \$2}' | sed 's/:$//' | grep -v lo"
                else
                    ssh $SSH_OPTS "$CURRENT_USER@$ip" \
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
                        interface_exists=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                            "ip link show $manual_interface 2>/dev/null" 2>/dev/null)
                    else
                        interface_exists=$(ssh $SSH_OPTS "$CURRENT_USER@$ip" \
                            "ip link show $manual_interface 2>/dev/null" 2>/dev/null)
                    fi
                    
                    if [ -n "$interface_exists" ]; then
                        BACKUP_INTERFACES[$i]="$manual_interface"
                        echo "    ✓ Interface set to: $manual_interface"
                        break
                    else
                        echo "    ⚠️  Interface '$manual_interface' not found on $node"
                        read -p "    Use it anyway? (yes/no) [no]: " use_anyway
                        if [[ "$use_anyway" =~ ^[Yy] ]]; then
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
echo "  4. Deploy Traefik reverse proxy"

if [ "$MULTI_NODE_DEPLOYMENT" = "yes" ]; then
    echo "  5. Install and configure Keepalived (MASTER on this node)"
    echo "  6. Deploy to ${#BACKUP_NODES[@]} backup node(s)"
elif [[ -z "$INSTALL_KEEPALIVED" ]]; then
    echo "  5. Keepalived installation (will prompt)"
fi

echo ""
echo "Estimated time: $([ "$MULTI_NODE_DEPLOYMENT" = "yes" ] && echo "$((5 + ${#BACKUP_NODES[@]} * 5))-$((10 + ${#BACKUP_NODES[@]} * 5)) minutes" || echo "5-10 minutes")"
echo ""
echo "Note: The script will prompt for:"
echo "  - SSL certificate and private key"
echo "  - Backend service URLs and ports"
if [[ -z "$INSTALL_KEEPALIVED" ]]; then
    echo "  - Keepalived installation (yes/no)"
fi
echo ""

read -p "Proceed with installation? [y/N]: " PROCEED_INSTALL
if [[ ! "$PROCEED_INSTALL" =~ ^[Yy]$ ]]; then
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

# Set proxy options for package managers
APT_PROXY_OPT=""
dnf_PROXY_OPT=""
if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
    if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
        ENCODED_PASS=$(printf '%s' "${PROXY_PASSWORD}" | jq -sRr @uri 2>/dev/null || python3 -c "import urllib.parse; print(urllib.parse.quote(input()))" <<< "${PROXY_PASSWORD}" 2>/dev/null || echo "${PROXY_PASSWORD}")
        APT_PROXY_OPT="-o Acquire::http::Proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT} -o Acquire::https::Proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
        dnf_PROXY_OPT="--setopt=proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
    else
        APT_PROXY_OPT="-o Acquire::http::Proxy=http://${PROXY_HOST}:${PROXY_PORT} -o Acquire::https::Proxy=http://${PROXY_HOST}:${PROXY_PORT}"
        dnf_PROXY_OPT="--setopt=proxy=http://${PROXY_HOST}:${PROXY_PORT}"
    fi
fi

# Define prerequisites based on package manager
if [[ "$PKG_MANAGER" == "apt" ]]; then
    PREREQ_PACKAGES=(
        apt-transport-https ca-certificates curl 
        software-properties-common gnupg lsb-release 
        wget nano ipcalc
    )
    log "Updating apt package lists..."
    sudo apt-get $APT_PROXY_OPT update || exit_on_error "Failed to update package lists"
  elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    PREREQ_PACKAGES=(
        ca-certificates curl dnf-utils
        gnupg2 wget nano iproute ipcalc dnf-plugins-core
    )
    log "Cleaning dnf metadata..."
    sudo dnf $dnf_PROXY_OPT clean all || exit_on_error "Failed to clean dnf metadata"
fi

# Install prerequisites using install_packages function
log "Installing base packages..."
sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); PKG_MANAGER=$PKG_MANAGER PROXY_HOST='$PROXY_HOST' PROXY_PORT='$PROXY_PORT' PROXY_USER='$PROXY_USER' PROXY_PASSWORD='$PROXY_PASSWORD' APT_SSL_OPT='$APT_SSL_OPT' DNF_SSL_OPT='$DNF_SSL_OPT' LOGFILE='$LOGFILE' install_packages ${PREREQ_PACKAGES[*]}"

### END installing Prerequisites 
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
    
    if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
        if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
            curl -x "http://${PROXY_HOST}:${PROXY_PORT}" --proxy-user "${PROXY_USER}:${PROXY_PASSWORD}" -fsSL https://download.docker.com/linux/$OS_ID/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        else
            curl -x "http://${PROXY_HOST}:${PROXY_PORT}" -fsSL https://download.docker.com/linux/$OS_ID/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        fi
    else
        curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$OS_ID $OS_VERSION stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get $APT_PROXY_OPT update || exit_on_error "Failed to update package lists"
    sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); PKG_MANAGER=$PKG_MANAGER PROXY_HOST='$PROXY_HOST' PROXY_PORT='$PROXY_PORT' PROXY_USER='$PROXY_USER' PROXY_PASSWORD='$PROXY_PASSWORD' APT_SSL_OPT='$APT_SSL_OPT' DNF_SSL_OPT='$DNF_SSL_OPT' LOGFILE='$LOGFILE' install_packages docker-ce docker-ce-cli containerd.io"
elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    log "Installing Docker via dnf..."
    # Add Docker repo

    # Global package-manager options (proxy + SSL)
    DNF_OPTS=""

    if [ -n "${PROXY_HOST}" ] && [ -n "${PROXY_PORT}" ]; then
        if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASSWORD}" ]; then
            ENCODED_PASS=$(url_encode_password "${PROXY_PASSWORD}")
            DNF_OPTS+=" --setopt=proxy=http://${PROXY_USER}:${ENCODED_PASS}@${PROXY_HOST}:${PROXY_PORT}"
        else
            DNF_OPTS+=" --setopt=proxy=http://${PROXY_HOST}:${PROXY_PORT}"
        fi
    fi

    [ -n "$DNF_SSL_OPT" ] && DNF_OPTS+=" $DNF_SSL_OPT"

    sudo dnf $DNF_OPTS $DNF_SSL_OPT config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); PKG_MANAGER=$PKG_MANAGER PROXY_HOST='$PROXY_HOST' PROXY_PORT='$PROXY_PORT' PROXY_USER='$PROXY_USER' PROXY_PASSWORD='$PROXY_PASSWORD' APT_SSL_OPT='$APT_SSL_OPT' DNF_SSL_OPT='$DNF_SSL_OPT' LOGFILE='$LOGFILE' install_packages docker-ce docker-ce-cli containerd.io"
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
### START Prompt for SSL and KEY and then validate

# Prompt user for certificates (if not already loaded)
if [[ -z "$CERT_FILE" ]]; then
    log "Prompting user for certificates..."
    CERT_DIR="/home/haloap/traefik/certs"
    
    # Create directory with sudo and set proper ownership
    sudo mkdir -p "$CERT_DIR"
    sudo chown -R "$CURRENT_USER:$CURRENT_USER" /home/haloap 2>/dev/null || true
    
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
    
    read -p "Does this look correct? (yes/no) [no]: " confirm
        if [[ "${confirm,,}" == "yes" || "${confirm,,}" == "y" ]]; then
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
    
    read -p "Does this look correct? (yes/no) [no]: " confirm
        if [[ "${confirm,,}" == "yes" || "${confirm,,}" == "y" ]]; then
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
sudo chown -R "$CURRENT_USER:$CURRENT_USER" /home/haloap 2>/dev/null || true

# Verify ownership
if [[ ! -w "/home/haloap/traefik" ]]; then
    log "Warning: /home/haloap/traefik not writable, attempting to fix ownership..."
    sudo chown -R "$CURRENT_USER:$CURRENT_USER" /home/haloap || exit_on_error "Failed to set ownership on /home/haloap"
fi

# Create a Docker network for Traefik
log "Creating Docker network 'proxynet'..."
if ! docker_cmd network inspect proxynet > /dev/null 2>&1; then
    docker_cmd network create proxynet || exit_on_error "Failed to create Docker network"
fi

# Create the docker-compose.yaml file for Traefik
log "Creating docker-compose.yaml file..."
DOCKER_COMPOSE_FILE="/home/haloap/traefik/docker-compose.yaml"
backup_file "$DOCKER_COMPOSE_FILE"

tee "$DOCKER_COMPOSE_FILE" > /dev/null <<EOF
services:
  traefik:
    image: docker.io/library/traefik:latest
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxynet
    ports:
      - 80:80
      - 443:443
      - 8800:8800 # only required for keepalived check script
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./config/clinical_conf.yml:/clinical_conf.yml:ro
      - ./certs/cert.crt:/certs/cert.crt:ro
      - ./certs/server.key:/certs/server.key:ro
      - ./logs:/var/log

networks:
  proxynet:
    external: true
EOF

 # Set docker-compose.yaml permissions
log "Setting permissions on $DOCKER_COMPOSE_FILE"
chmod 640 "$DOCKER_COMPOSE_FILE"

# Create a basic traefik.yml configuration file
log "Creating traefik.yml configuration file..."
TRAEFIK_CONFIG_FILE="/home/haloap/traefik/config/traefik.yml"

backup_file "$TRAEFIK_CONFIG_FILE"

tee "$TRAEFIK_CONFIG_FILE" > /dev/null <<EOF
entryPoints:
  http:
    address: ':80'
    http:
      redirections:
        entryPoint:
          to: 'https'
          scheme: 'https'
  https:
    address: ':443'
  ping:
    address: ':8800'
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
    filename: /clinical_conf.yml
EOF

# Create a complete clinical_conf.yml configuration file
log "Creating clinical_conf.yml configuration file..."
TRAEFIK_DYNAMIC_FILE="/home/haloap/traefik/config/clinical_conf.yml"

backup_file "$TRAEFIK_DYNAMIC_FILE"

echo ""
echo "=========================================="
echo "Configure Traefik"
echo "=========================================="
echo ""

# Call the function to generate the clinical_conf.yml services section
generate_clinical_conf

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
sudo bash -c "$(declare -f install_packages exit_on_error log url_encode_password); PKG_MANAGER=$PKG_MANAGER PROXY_HOST='$PROXY_HOST' PROXY_PORT='$PROXY_PORT' PROXY_USER='$PROXY_USER' PROXY_PASSWORD='$PROXY_PASSWORD' APT_SSL_OPT='$APT_SSL_OPT' DNF_SSL_OPT='$DNF_SSL_OPT' LOGFILE='$LOGFILE' install_packages keepalived"

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

# Get the network interface
NETWORK_INTERFACE=$(get_network_interface)
log "Using network interface: $NETWORK_INTERFACE"

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

# Proxy support
PROXY="__PROXY__"
APT_SSL_OPT="__APT_SSL_OPT__"
WGET_SSL_OPT="__WGET_SSL_OPT__"

if [ -n "$PROXY" ]; then
    if echo "$PROXY" | grep -q '@'; then
        # Authenticated proxy
        PROXY_DISPLAY="${PROXY#*@}"
        PROXY_USER="${PROXY%@*}"
        PROXY_USER="${PROXY_USER%%:*}"
        echo "Using authenticated proxy: $PROXY_DISPLAY (user: $PROXY_USER)"
    else
        # No authentication
        PROXY_DISPLAY="$PROXY"
        echo "Using proxy: $PROXY_DISPLAY"
    fi
    
    export http_proxy="http://$PROXY"
    export https_proxy="http://$PROXY"
    export no_proxy="localhost,127.0.0.1"
    APT_PROXY_OPT="-o Acquire::http::Proxy=http://$PROXY -o Acquire::https::Proxy=http://$PROXY"
else
    APT_PROXY_OPT=""
fi

# Use proxy and SSL options if configured
        CURL_DOWNLOAD_OPTS="$CURL_SSL_OPT"
        if [ -n "$PROXY" ]; then
            if echo "$PROXY" | grep -q '@'; then
                # Authenticated proxy - extract components
                PROXY_AUTH="${PROXY%@*}"
                PROXY_HOST="${PROXY#*@}"
                PROXY_USER="${PROXY_AUTH%%:*}"
                PROXY_PASS="${PROXY_AUTH#*:}"
                CURL_DOWNLOAD_OPTS="$CURL_DOWNLOAD_OPTS -x http://${PROXY_HOST} -U ${PROXY_USER}:${PROXY_PASS}"
            else
                CURL_DOWNLOAD_OPTS="$CURL_DOWNLOAD_OPTS -x http://$PROXY"
            fi
        fi

# Add SSL options if configured
if [ -n "$APT_SSL_OPT" ]; then
    APT_PROXY_OPT="$APT_PROXY_OPT $APT_SSL_OPT"
fi

echo "=== Installing on $(hostname) ==="

CONFIG_FILE="/tmp/clinical_traefik.env"

# Source the configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "✓ Configuration loaded from $CONFIG_FILE"
else
    echo "ERROR: Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Get current user
CURRENT_USER="${SUDO_USER:-$USER}"
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

echo "Installing as user: $CURRENT_USER"
echo ""

# Set environment for non-interactive installation
export DEBIAN_FRONTEND=noninteractive
export NODE_ROLE="BACKUP"
export PRIORITY="BACKUP_PRIORITY_PLACEHOLDER"
export INSTALL_KEEPALIVED="yes"
export MULTI_NODE_DEPLOYMENT="no"
export BACKUP_NODE_INSTALL="yes"  # Flag to skip prompts

# Install prerequisites
echo "Installing prerequisites..."
if command -v apt-get &>/dev/null; then
    sudo apt-get $APT_PROXY_OPT update -qq
    sudo apt-get $APT_PROXY_OPT install -y -qq apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release wget nano ipcalc
elif command -v dnf &>/dev/null; then
    sudo dnf $dnf_PROXY_OPT install -y ca-certificates curl dnf-utils gnupg2 wget nano iproute ipcalc
fi

# Install Docker
if command -v apt-get &>/dev/null; then
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        sudo install -m 0755 -d /etc/apt/keyrings
        curl $CURL_DOWNLOAD_OPTS -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get $APT_PROXY_OPT update -qq
    fi
    sudo apt-get $APT_PROXY_OPT install -y docker-ce docker-ce-cli containerd.io
fi

# Configure Docker proxy if needed
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
    "http-proxy": "http://$PROXY",
    "https-proxy": "http://$PROXY",
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

# Create Traefik directories
sudo mkdir -p /home/haloap/traefik/{certs,config,logs}
sudo chown -R "$CURRENT_USER:$CURRENT_USER" /home/haloap

# Copy certificates
if [ -n "$SSL_CERT_CONTENT" ] && [ -n "$SSL_KEY_CONTENT" ]; then
    echo "$SSL_CERT_CONTENT" > "$CERT_FILE"
    echo "$SSL_KEY_CONTENT" > "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
fi

# Create docker-compose.yaml (same as master)
cat > /home/haloap/traefik/docker-compose.yaml <<'DOCKERCOMPOSE'
services:
  traefik:
    image: docker.io/library/traefik:latest
    # Using official Docker Hub image: docker.io/traefik/traefik:latest
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_add:
      - NET_BIND_SERVICE
    networks:
      - proxynet
    ports:
      - 80:80
      - 443:443
      - 8800:8800
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./config/clinical_conf.yml:/clinical_conf.yml:ro
      - ./certs/cert.crt:/certs/cert.crt:ro
      - ./certs/server.key:/certs/server.key:ro
      - ./logs:/var/log

networks:
  proxynet:
    external: true
DOCKERCOMPOSE

# Create traefik.yml (same as master)
cat > /home/haloap/traefik/config/traefik.yml <<'TRAEFIKCONF'
entryPoints:
  http:
    address: ':80'
    http:
      redirections:
        entryPoint:
          to: 'https'
          scheme: 'https'
  https:
    address: ':443'
  ping:
    address: ':8800'
ping:
  entryPoint: 'ping'

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    filename: /clinical_conf.yml
TRAEFIKCONF

# Copy clinical_conf.yml from config
if [ -f "/tmp/clinical_conf.yml" ]; then
    cp /tmp/clinical_conf.yml /home/haloap/traefik/config/clinical_conf.yml
fi

# Create Docker network
if ! docker network inspect proxynet > /dev/null 2>&1; then
    docker network create proxynet
fi

# Start Traefik
echo "Starting Traefik..."
cd /home/haloap/traefik
docker compose up -d --force-recreate

# Wait for Traefik to start
sleep 5

# Install Keepalived
echo "Installing Keepalived..."
if command -v apt-get &>/dev/null; then
    sudo apt-get $APT_PROXY_OPT install -y keepalived
elif command -v dnf &>/dev/null; then
    sudo dnf $dnf_PROXY_OPT install -y keepalived
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

# Auto-detect network interface for this backup node's IP
echo "Auto-detecting network interface..."
BACKUP_NODE_IP="BACKUP_NODE_IP_PLACEHOLDER"
# Use the interface specified during configuration
BACKUP_NODE_INTERFACE="BACKUP_INTERFACE_PLACEHOLDER"

echo "Using configured interface: $BACKUP_NODE_INTERFACE"

# Verify the interface exists on this node
if ! ip link show "$BACKUP_NODE_INTERFACE" &>/dev/null; then
    echo "⚠️  WARNING: Interface $BACKUP_NODE_INTERFACE does not exist on this node!"
    echo "Available interfaces:"
    ip -o link show | awk '{print "  - " $2}' | sed 's/:$//'
    echo ""
    echo "Attempting auto-detection as fallback..."
    
    BACKUP_NODE_IP="BACKUP_NODE_IP_PLACEHOLDER"
    DETECTED_INTERFACE=$(ip -o addr show | grep "inet $BACKUP_NODE_IP" | awk '{print $2}' | head -1)
    
    if [ -n "$DETECTED_INTERFACE" ]; then
        echo "✓ Auto-detected: $DETECTED_INTERFACE"
        BACKUP_NODE_INTERFACE="$DETECTED_INTERFACE"
    else
        echo "❌ Auto-detection failed. Using configured interface anyway."
        echo "   Keepalived may not work correctly!"
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
        
        # Replace priority placeholder and backup node IP
        sed -i "s/BACKUP_PRIORITY_PLACEHOLDER/$priority/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_NODE_IP_PLACEHOLDER/$ip/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s/BACKUP_INTERFACE_PLACEHOLDER/${BACKUP_INTERFACES[$i]}/g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__PROXY__|${PROXY_VAL}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__APT_SSL_OPT__|${APT_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        sed -i "s|__WGET_SSL_OPT__|${WGET_SSL_OPT}|g" "$SCRIPTS_DIR/install_backup_${node}.sh"
        chmod 644 "$SCRIPTS_DIR/install_backup_${node}.sh"
        
        # Also need to copy clinical_conf.yml to remote
        if [ -f "/home/haloap/traefik/config/clinical_conf.yml" ]; then
            cp /home/haloap/traefik/config/clinical_conf.yml /tmp/clinical_conf.yml
        fi
        
        # Ensure remote scripts directory exists
        ensure_SCRIPTS_DIR "$ip"
        
        # Copy files to backup node
        echo "Copying files to $node..."
        copy_to_remote "$CONFIG_FILE" "$ip" "/tmp/clinical_traefik.env"
        if [ -f "/tmp/clinical_conf.yml" ]; then
            copy_to_remote "/tmp/clinical_conf.yml" "$ip" "/tmp/clinical_conf.yml"
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
        
        # Verify deployment
        echo ""
        echo "Verifying deployment on $node..."
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            VERIFY_DOCKER=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
        else
            VERIFY_DOCKER=$(ssh $SSH_OPTS "$CURRENT_USER@$ip" "docker ps --filter name=traefik --format '{{.Names}}'" 2>/dev/null || echo "")
        fi
        
        if echo "$VERIFY_DOCKER" | grep -q "traefik"; then
            echo "✓ Traefik container is running on $node"
        else
            echo "⚠️  Warning: Could not verify Traefik on $node"
        fi
        
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            VERIFY_KEEPALIVED=$(sudo -u "$SUDO_USER" ssh $SSH_OPTS "$CURRENT_USER@$ip" "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
        else
            VERIFY_KEEPALIVED=$(ssh $SSH_OPTS "$CURRENT_USER@$ip" "systemctl is-active keepalived" 2>/dev/null || echo "inactive")
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
echo "  - Dynamic Config: $TRAEFIK_DYNAMIC_FILE"
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

# Cleanup temporary scripts directory
cleanup
