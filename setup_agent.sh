#!/bin/bash

# ==============================================================================
# VivuCloud Agent Setup Script
# This script automates the full installation and configuration of the
# VivuCloud agent, including Node.js setup and systemd service creation.
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
AGENT_DOWNLOAD_URL="https://raw.githubusercontent.com/caotranquochoai/VLAN-agent/refs/heads/main/client-agent.zip"
INSTALL_DIR="/opt/vivucloud-agent"
SERVICE_NAME="vivucloud-agent"

# --- Helper Functions ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- 1. Pre-flight Checks ---
log_info "Starting VivuCloud Agent setup..."

# Check for root privileges
if [ "x$(id -u)" != 'x0' ]; then
    log_error "This script must be executed by root."
fi

# Check the operating system
if [ ! -f /etc/os-release ]; then
    log_error "Could not detect operating system. Unable to proceed."
fi

os_type=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
log_info "Detected OS: $os_type"

# --- 2. Install Dependencies ---
log_info "Installing required dependencies..."
if [ "$os_type" == "ubuntu" ] || [ "$os_type" == "debian" ]; then
    apt-get update -y
    apt-get install -y curl unzip
elif [ "$os_type" == "centos" ] || [ "$os_type" == "almalinux" ] || [ "$os_type" == "rocky" ]; then
    yum install -y curl unzip
else
    log_error "Unsupported operating system: $os_type"
fi

# --- 3. Install Node.js ---
if command -v node &> /dev/null; then
    log_info "Node.js is already installed. Skipping installation."
else
    log_info "Installing Node.js (LTS version)..."
    if [ "$os_type" == "ubuntu" ] || [ "$os_type" == "debian" ]; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
    elif [ "$os_type" == "centos" ] || [ "$os_type" == "almalinux" ] || [ "$os_type" == "rocky" ]; then
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
        yum install -y nodejs
    fi
fi
log_info "Node.js installation complete. Version: $(node -v), npm Version: $(npm -v)"

# --- 4. Download and Extract Agent ---
log_info "Downloading and setting up the agent in $INSTALL_DIR..."
# Clean up previous installations
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Download and unzip
curl -L "$AGENT_DOWNLOAD_URL" -o "/tmp/client-agent.zip"
unzip "/tmp/client-agent.zip" -d "$INSTALL_DIR"
rm "/tmp/client-agent.zip"

log_info "Setting execute permissions on shell scripts..."
chmod +x ${INSTALL_DIR}/*.sh

# --- 5. Install Agent Dependencies ---
log_info "Installing agent's npm dependencies..."
cd "$INSTALL_DIR"
npm install

# --- 6. Register Agent and Create .env File ---
log_info "Registering agent with the server..."
# Hardcode the server URL as requested
SERVER_URL_INPUT="https://svlan.vivucloud.com"
log_info "Using hardcoded server URL: $SERVER_URL_INPUT"

# Sanitize URL to ensure it's just the base
SERVER_BASE_URL=$(echo $SERVER_URL_INPUT | sed 's|/$||')

# Gather fingerprint data
log_info "Gathering machine fingerprint..."
SYS_UUID=$(dmidecode -s system-uuid 2>/dev/null || echo "no-uuid")
MAC_ADDR=$(ip link | grep -o -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n 1 2>/dev/null || echo "no-mac")
CPU_INFO=$(cat /proc/cpuinfo | grep 'model name' | head -n 1 | sed 's/model name\s*:\s*//' 2>/dev/null || echo "no-cpu")
HOSTNAME=$(hostname)

# Create a consistent string for hashing
FINGERPRINT_STRING="${SYS_UUID}-${MAC_ADDR}-${CPU_INFO}-${HOSTNAME}"
FINGERPRINT_HASH=$(echo -n "$FINGERPRINT_STRING" | sha256sum | awk '{print $1}')

log_info "Fingerprint Hash: $FINGERPRINT_HASH"

# Call the registration API
API_URL="${SERVER_BASE_URL}/api/register-agent"
log_info "Contacting server at $API_URL..."

API_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{
        "fingerprint_hash": "'"${FINGERPRINT_HASH}"'",
        "system_uuid": "'"${SYS_UUID}"'",
        "mac_address": "'"${MAC_ADDR}"'",
        "cpu_info": "'"${CPU_INFO}"'",
        "hostname": "'"${HOSTNAME}"'"
    }' \
    "$API_URL")

# Check curl exit code
if [ $? -ne 0 ]; then
    log_error "Failed to connect to the server. Please check the URL and network connection."
fi

# Parse response
SUCCESS=$(echo "$API_RESPONSE" | grep -o '"success":true' || echo "")
if [ -z "$SUCCESS" ]; then
    ERROR_MSG=$(echo "$API_RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
    log_error "Failed to register agent: ${ERROR_MSG:-Unknown server error}"
fi

ACCESS_CODE=$(echo "$API_RESPONSE" | sed -n 's/.*"access_code":"\([^"]*\)".*/\1/p')
log_info "Agent registered successfully."

# Create .env file
WS_URL=$(echo $SERVER_BASE_URL | sed 's/^https/wss/')
cat > ${INSTALL_DIR}/.env << EOL
# WebSocket Server URL
SERVER_URL=${WS_URL}

# Unique identifier for this agent (uses hostname)
AGENT_ID=agent-${HOSTNAME}

# Auto-generated unique access code for this agent
AGENT_ACCESS_CODE=${ACCESS_CODE}

# The machine's unique fingerprint hash
FINGERPRINT_HASH=${FINGERPRINT_HASH}
EOL

log_info ".env file created successfully."

# --- 7. Create systemd Service ---
log_info "Creating systemd service file for the agent..."

# Dynamically find the path to the node executable's directory
NODE_PATH=$(which node)
if [ -z "$NODE_PATH" ]; then
    log_error "Could not find 'node' executable. Please ensure Node.js is installed and in the root's PATH."
fi
NODE_BIN_DIR=$(dirname "$NODE_PATH")

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOL
[Unit]
Description=VivuCloud Agent Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
# Dynamically provide the PATH to the node binary for tsx to find it
Environment="PATH=${NODE_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${INSTALL_DIR}/node_modules/.bin/tsx ${INSTALL_DIR}/agent.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

log_info "Service file created at /etc/systemd/system/${SERVICE_NAME}.service"

# --- 8. Enable and Start Service ---
log_info "Enabling and starting the ${SERVICE_NAME} service..."
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME} # Use restart to ensure it picks up the new .env file

# --- 9. Final Status ---
log_info "Setup complete!"
log_info "================================================================"
log_info "  Your User Access Code is: ${ACCESS_CODE}"
log_info "================================================================"
log_info "The VivuCloud agent is now running as a service."
log_info "You can check its status with: systemctl status ${SERVICE_NAME}"
log_info "If needed, logs can be viewed with: journalctl -u ${SERVICE_NAME} -f"

exit 0
