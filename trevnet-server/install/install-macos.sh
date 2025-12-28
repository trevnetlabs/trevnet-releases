#!/bin/bash
set -euo pipefail

# Default configuration
METADATA_URL="${TREVNET_METADATA_URL:-https://raw.githubusercontent.com/trevnetlabs/trevnet-releases/main/trevnet-server/latest.json}"
BINARY_NAME="trevnet-server"
SERVICE_LABEL="${TREVNET_SERVICE_LABEL:-com.trevnetlabs.trevnet-server}"
INSTALL_DIR="${TREVNET_INSTALL_DIR:-$HOME/.trevnet}"
BINARY_INSTALL_DIR="${TREVNET_BINARY_INSTALL_DIR:-$INSTALL_DIR/bin}"
ENV_FILE="${TREVNET_ENV_FILE:-$INSTALL_DIR/trevnet-server.env}"
LAUNCH_AGENTS_DIR="${TREVNET_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${TREVNET_LOG_DIR:-$HOME/Library/Logs}"
STDOUT_LOG="${TREVNET_STDOUT_LOG:-$LOG_DIR/trevnet-server.log}"
STDERR_LOG="${TREVNET_STDERR_LOG:-$LOG_DIR/trevnet-server.err.log}"

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

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "$s"
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command not found: $cmd"
    fi
}

# Check platform
if [[ "${EUID}" -eq 0 ]]; then
    error "Do not run this script with sudo. It installs a user LaunchAgent."
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This script only supports macOS."
fi

detect_platform() {
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac
    echo "darwin-${arch}"
}

fetch_metadata() {
    local url="$1"
    local temp_file

    temp_file=$(mktemp)
    trap "rm -f $temp_file" EXIT

    info "Fetching release metadata from $url..."
    if ! curl -fsSL "$url" -o "$temp_file"; then
        error "Failed to fetch metadata from $url"
    fi

    if [[ ! -s "$temp_file" ]]; then
        error "Downloaded metadata file is empty or does not exist"
    fi

    if ! jq empty "$temp_file" > /dev/null 2>&1; then
        local file_contents
        file_contents=$(cat "$temp_file")
        error "Invalid JSON in metadata file. Contents: $file_contents"
    fi

    if ! jq -e '.version and .downloads' "$temp_file" > /dev/null 2>&1; then
        local file_contents
        file_contents=$(cat "$temp_file")
        error "Invalid metadata format. Missing 'version' or 'downloads' field. Contents: $file_contents"
    fi

    cat "$temp_file"
    rm -f "$temp_file"
    trap - EXIT
}

download_and_extract() {
    local download_url="$1"
    local platform="$2"
    local dest_dir="$3"
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

    mkdir -p "$dest_dir"

    info "Installing binary to ${dest_dir}/${BINARY_NAME}..."
    install -m 755 "$extracted_binary" "${dest_dir}/${BINARY_NAME}"

    if command -v xattr >/dev/null 2>&1; then
        xattr -dr com.apple.quarantine "${dest_dir}/${BINARY_NAME}" >/dev/null 2>&1 || true
    fi

    rm -rf "$temp_dir"
    trap - EXIT
}

build_env_block() {
    local env_file="$1"
    local env_block_file="$2"
    local entries_file

    entries_file=$(mktemp)
    trap "rm -f $entries_file" RETURN

    if [[ -f "$env_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%$'\r'}"
            if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            line="${line#export }"
            if [[ "$line" != *"="* ]]; then
                warn "Skipping invalid env line: $line"
                continue
            fi

            local key value
            key=$(trim "${line%%=*}")
            value=$(trim "${line#*=}")

            if [[ -z "$key" ]]; then
                warn "Skipping env line with empty key: $line"
                continue
            fi

            if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
                value="${value:1:-1}"
            fi

            key=$(xml_escape "$key")
            value=$(xml_escape "$value")
            printf '    <key>%s</key>\n    <string>%s</string>\n' "$key" "$value" >> "$entries_file"
        done < "$env_file"
    fi

    if [[ -s "$entries_file" ]]; then
        {
            echo "  <key>EnvironmentVariables</key>"
            echo "  <dict>"
            cat "$entries_file"
            echo "  </dict>"
        } > "$env_block_file"
    else
        : > "$env_block_file"
    fi

    rm -f "$entries_file"
    trap - RETURN
}

generate_plist_file() {
    local template_path="$1"
    local output_path="$2"
    local label="$3"
    local program="$4"
    local working_dir="$5"
    local stdout_path="$6"
    local stderr_path="$7"
    local env_block_file="$8"

    if [[ ! -f "$template_path" ]]; then
        error "Template file not found: $template_path"
    fi

    sed -e "s|@LABEL@|$label|g" \
        -e "s|@PROGRAM@|$program|g" \
        -e "s|@WORKING_DIR@|$working_dir|g" \
        -e "s|@STDOUT@|$stdout_path|g" \
        -e "s|@STDERR@|$stderr_path|g" \
        "$template_path" | awk -v env_file="$env_block_file" '
            /@ENV_VARS@/ {
                if (env_file != "" && (getline line < env_file) > 0) {
                    print line
                    while ((getline line < env_file) > 0) print line
                    close(env_file)
                }
                next
            }
            { gsub(/@ENV_VARS@/, ""); print }
        ' > "$output_path"
}

install_service() {
    local plist_path="$1"

    info "Installing LaunchAgent at $plist_path..."
    mkdir -p "$LAUNCH_AGENTS_DIR"
    mkdir -p "$LOG_DIR"

    if [[ -f "$plist_path" ]]; then
        launchctl unload "$plist_path" >/dev/null 2>&1 || true
    fi

    launchctl load -w "$plist_path"
    info "LaunchAgent loaded. It will start on next login."
}

main() {
    local platform
    local metadata
    local version
    local download_url
    local template_path
    local plist_path
    local env_block_file

    info "Starting Trevnet Server installation for macOS..."

    require_command curl
    require_command jq
    require_command tar
    require_command launchctl

    platform=$(detect_platform)
    info "Detected platform: $platform"

    metadata=$(fetch_metadata "$METADATA_URL")
    if [[ -z "$metadata" ]]; then
        error "Failed to fetch metadata or metadata is empty"
    fi

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

    mkdir -p "$INSTALL_DIR"
    download_and_extract "$download_url" "$platform" "$BINARY_INSTALL_DIR"

    template_path="$(dirname "$0")/trevnet-server.launchd.plist.template"
    if [[ ! -f "$template_path" ]]; then
        error "Launchd template not found: $template_path"
    fi

    mkdir -p "$LAUNCH_AGENTS_DIR"
    plist_path="${LAUNCH_AGENTS_DIR}/${SERVICE_LABEL}.plist"
    env_block_file=$(mktemp)
    trap "rm -f $env_block_file" EXIT

    build_env_block "$ENV_FILE" "$env_block_file"
    generate_plist_file \
        "$template_path" \
        "$plist_path" \
        "$SERVICE_LABEL" \
        "${BINARY_INSTALL_DIR}/${BINARY_NAME}" \
        "$INSTALL_DIR" \
        "$STDOUT_LOG" \
        "$STDERR_LOG" \
        "$env_block_file"

    chmod 644 "$plist_path"

    install_service "$plist_path"

    rm -f "$env_block_file"
    trap - EXIT

    info "Installation complete!"
    info ""
    info "Next steps:"
    info "  1. Optional env file: $ENV_FILE"
    info "  2. Start immediately: launchctl unload $plist_path && launchctl load -w $plist_path"
    info "  3. Check status: launchctl list | grep $SERVICE_LABEL"
    info "  4. Logs: $STDOUT_LOG"
    if [[ "$BINARY_INSTALL_DIR" == "$INSTALL_DIR/bin" ]]; then
        info "  5. Add to PATH (optional): export PATH=\"$BINARY_INSTALL_DIR:\$PATH\""
    fi
}

main "$@"
