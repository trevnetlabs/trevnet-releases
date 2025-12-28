#!/bin/bash
set -euo pipefail

# Default configuration
METADATA_URL="${TREVNET_METADATA_URL:-https://raw.githubusercontent.com/trevnetlabs/trevnet-releases/main/trevnet-server/latest.json}"
BINARY_NAME="trevnet-server"
SERVICE_NAME="trevnet-server"
INSTALL_USER="${TREVNET_USER:-trevnet}"
INSTALL_GROUP="${TREVNET_GROUP:-trevnet}"
INSTALL_DIR="${TREVNET_INSTALL_DIR:-/opt/trevnet}"
BINARY_INSTALL_DIR="${TREVNET_BINARY_INSTALL_DIR:-$INSTALL_DIR}"
ENV_FILE="${TREVNET_ENV_FILE:-/etc/trevnet-server.env}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${GREEN}Info:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}Warning:${NC} $1" >&2
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

# Detect platform
detect_platform() {
    local os
    local arch
    
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="darwin" ;;
        *)       error "Unsupported OS: $(uname -s)" ;;
    esac
    
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)       error "Unsupported architecture: $(uname -m)" ;;
    esac
    
    echo "${os}-${arch}"
}

# Fetch metadata
fetch_metadata() {
    local url="$1"
    local temp_file
    
    temp_file=$(mktemp)
    trap "rm -f $temp_file" EXIT
    
    info "Fetching release metadata from $url..."
    if ! curl -fsSL "$url" -o "$temp_file"; then
        error "Failed to fetch metadata from $url"
    fi
    
    # Check if file was downloaded and is not empty
    if [[ ! -s "$temp_file" ]]; then
        error "Downloaded metadata file is empty or does not exist"
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed. Please install jq first."
    fi
    
    # Validate metadata is valid JSON
    if ! jq empty "$temp_file" > /dev/null 2>&1; then
        local file_contents
        file_contents=$(cat "$temp_file")
        error "Invalid JSON in metadata file. Contents: $file_contents"
    fi
    
    # Validate metadata structure
    if ! jq -e '.version and .downloads' "$temp_file" > /dev/null 2>&1; then
        local file_contents
        file_contents=$(cat "$temp_file")
        error "Invalid metadata format. Missing 'version' or 'downloads' field. Contents: $file_contents"
    fi
    
    cat "$temp_file"
    rm -f "$temp_file"
    trap - EXIT
}

# Download and extract binary into an application-owned directory
download_and_extract() {
    local download_url="$1"
    local platform="$2"
    local dest_dir="$3"
    local owner="$4"
    local group="$5"
    local temp_dir
    
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    local archive="${temp_dir}/download.tar.gz"
    
    info "Downloading binary for $platform..."
    if ! curl -fsSL "$download_url" -o "$archive"; then
        error "Failed to download binary from $download_url"
    fi
    
    info "Extracting binary..."
    if ! tar -xzf "$archive" -C "$temp_dir" "$BINARY_NAME" 2>/dev/null; then
        error "Failed to extract binary from archive"
    fi
    
    local extracted_binary="${temp_dir}/${BINARY_NAME}"
    if [[ ! -f "$extracted_binary" ]]; then
        error "Binary $BINARY_NAME not found in archive"
    fi
    
    # Create destination directory and ensure ownership
    mkdir -p "$dest_dir"
    chown "$owner:$group" "$dest_dir"

    # Install binary
    info "Installing binary to ${dest_dir}/${BINARY_NAME}..."
    install -m 755 "$extracted_binary" "${dest_dir}/${BINARY_NAME}"
    chown "$owner:$group" "${dest_dir}/${BINARY_NAME}"
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Create user and group
create_user_group() {
    local user="$1"
    local group="$2"
    local home_dir="$3"
    
    # Create group if it doesn't exist
    if ! getent group "$group" > /dev/null 2>&1; then
        info "Creating group: $group"
        groupadd -r "$group" || error "Failed to create group $group"
    else
        info "Group $group already exists"
    fi
    
    # Create user if it doesn't exist
    if ! getent passwd "$user" > /dev/null 2>&1; then
        info "Creating user: $user"
        useradd -r -g "$group" -d "$home_dir" -s /usr/sbin/nologin "$user" || \
            error "Failed to create user $user"
    else
        info "User $user already exists"
    fi
    
    # Create home directory
    if [[ ! -d "$home_dir" ]]; then
        info "Creating home directory: $home_dir"
        mkdir -p "$home_dir"
        chown "${user}:${group}" "$home_dir"
        chmod 755 "$home_dir"
    fi
}

# Generate service file from template
generate_service_file() {
    local template_path="$1"
    local output_path="$2"
    local user="$3"
    local group="$4"
    local working_dir="$5"
    local env_file="$6"
    local exec_start="$7"
    
    if [[ ! -f "$template_path" ]]; then
        error "Template file not found: $template_path"
    fi
    
    info "Generating service file from template..."
    sed -e "s|@USER@|$user|g" \
        -e "s|@GROUP@|$group|g" \
        -e "s|@WORKING_DIR@|$working_dir|g" \
        -e "s|@ENV_FILE@|$env_file|g" \
        -e "s|@EXEC_START@|$exec_start|g" \
        "$template_path" > "$output_path"
}

# Install systemd service
install_service() {
    local service_file="$1"
    local service_name="$2"
    local working_dir="$3"
    local user="$4"
    local group="$5"
    
    info "Installing systemd service..."
    cp "$service_file" "/etc/systemd/system/${service_name}.service"
    
    # Set ownership of working directory
    chown -R "${user}:${group}" "$working_dir"
    
    info "Reloading systemd daemon..."
    systemctl daemon-reload
    
    info "Enabling service..."
    systemctl enable "$service_name"
    
    info "Service installed and enabled. Start it with: systemctl start $service_name"
}

# Main installation flow
main() {
    local platform
    local metadata
    local version
    local download_url
    local template_path
    local service_file
    
    info "Starting Trevnet Server installation..."
    
    # Detect platform
    platform=$(detect_platform)
    info "Detected platform: $platform"
    
    # Fetch metadata
    metadata=$(fetch_metadata "$METADATA_URL")
    
    # Validate metadata was received
    if [[ -z "$metadata" ]]; then
        error "Failed to fetch metadata or metadata is empty"
    fi
    
    # Parse version with better error handling
    local jq_stderr
    jq_stderr=$(mktemp)
    version=$(echo "$metadata" | jq -r '.version' 2>"$jq_stderr") || {
        local jq_error
        jq_error=$(cat "$jq_stderr")
        rm -f "$jq_stderr"
        error "Failed to parse version from metadata. jq error: $jq_error. Metadata preview: ${metadata:0:200}"
    }
    rm -f "$jq_stderr"
    
    if [[ -z "$version" || "$version" == "null" ]]; then
        error "Version is missing or null in metadata. Metadata preview: ${metadata:0:200}"
    fi
    
    # Parse download URL with better error handling
    jq_stderr=$(mktemp)
    download_url=$(echo "$metadata" | jq -r ".downloads[\"$platform\"]" 2>"$jq_stderr") || {
        local jq_error
        jq_error=$(cat "$jq_stderr")
        rm -f "$jq_stderr"
        error "Failed to parse download URL from metadata. jq error: $jq_error. Metadata preview: ${metadata:0:200}"
    }
    rm -f "$jq_stderr"
    
    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        error "No download available for platform: $platform"
    fi
    
    info "Latest version: $version"
    info "Download URL: $download_url"
    
    # Create user and group
    create_user_group "$INSTALL_USER" "$INSTALL_GROUP" "$INSTALL_DIR"
    
    # Download and install binary
    download_and_extract "$download_url" "$platform" "$BINARY_INSTALL_DIR" "$INSTALL_USER" "$INSTALL_GROUP"
    
    # Find or fetch template
    local template_is_temp=false
    template_path="$(dirname "$0")/trevnet-server.service.template"
    if [[ ! -f "$template_path" ]]; then
        # Try relative to script location
        script_dir="$(cd "$(dirname "$0")" && pwd)"
        template_path="${script_dir}/trevnet-server.service.template"
    fi
    
    if [[ ! -f "$template_path" ]]; then
        # Fetch template from GitHub
        info "Template not found locally, fetching from GitHub..."
        template_path=$(mktemp)
        template_is_temp=true
        if ! curl -fsSL "https://raw.githubusercontent.com/trevnetlabs/trevnet-releases/main/trevnet-server/install/trevnet-server.service.template" -o "$template_path"; then
            error "Failed to fetch service template from GitHub"
        fi
    fi
    
    service_file=$(mktemp)
    trap "rm -f $service_file${template_is_temp:+ $template_path}" EXIT
    
    generate_service_file \
        "$template_path" \
        "$service_file" \
        "$INSTALL_USER" \
        "$INSTALL_GROUP" \
        "$INSTALL_DIR" \
        "$ENV_FILE" \
        "${BINARY_INSTALL_DIR}/${BINARY_NAME}"
    
    # Install service
    install_service "$service_file" "$SERVICE_NAME" "$INSTALL_DIR" "$INSTALL_USER" "$INSTALL_GROUP"
    
    # Cleanup
    rm -f "$service_file"
    if [[ "$template_is_temp" == "true" ]]; then
        rm -f "$template_path"
    fi
    trap - EXIT
    
    info "Installation complete!"
    info ""
    info "Next steps:"
    info "  1. Create/edit environment file: $ENV_FILE (optional)"
    info "  2. Start the service: systemctl start $SERVICE_NAME"
    info "  3. Check status: systemctl status $SERVICE_NAME"
    info "  4. View logs: journalctl -u $SERVICE_NAME -f"
}

main "$@"
