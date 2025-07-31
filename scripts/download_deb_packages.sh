#!/bin/bash

# Simple script to download Caido .deb packages from API
# Usage: ./scripts/download_deb_packages.sh
# This script is designed for GitHub Actions with verbose error logging

set -uo pipefail

# Configuration
API_URL="https://api.caido.io/releases/latest"
PACKAGES_DIR="packages"
MAX_RETRIES=5
RETRY_DELAY=3

# Colors for output (for GitHub Actions compatibility)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install: ${missing_deps[*]}"
        exit 1
    fi
    
    log_info "All dependencies are available"
}

# Create packages directory
setup_directories() {
    log_info "Setting up directories..."
    
    if [[ ! -d "$PACKAGES_DIR" ]]; then
        log_info "Creating packages directory: $PACKAGES_DIR"
        mkdir -p "$PACKAGES_DIR"
    else
        log_info "Cleaning existing packages directory"
        rm -rf "$PACKAGES_DIR"/*.deb
    fi
}

# Download file with retry mechanism
download_file() {
    local url="$1"
    local filename="$2"
    local filepath="$PACKAGES_DIR/$filename"
    
    log_info "Downloading: $filename"
    log_debug "URL: $url"
    
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_debug "Attempt $attempt/$MAX_RETRIES"
        
        if curl -fL -o "$filepath" "$url"; then
            if [[ -f "$filepath" ]] && [[ -s "$filepath" ]]; then
                local size=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo "0")
                log_info "✅ Successfully downloaded: $filename (${size} bytes)"
                return 0
            else
                log_warn "Downloaded file is empty: $filename"
                rm -f "$filepath"
            fi
        else
            log_warn "Download failed for: $filename (attempt $attempt/$MAX_RETRIES)"
        fi
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
        
        ((attempt++))
    done
    
    log_error "❌ Failed to download: $filename after $MAX_RETRIES attempts"
    return 1
}

# Fetch release info and download .deb packages
fetch_and_download() {
    log_info "Fetching release information from: $API_URL"
    
    # Fetch API response
    local response
    response=$(curl -sSf "$API_URL")
    
    # Validate JSON
    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "Invalid JSON received from API"
        exit 1
    fi
    
    # Extract version
    local version
    version=$(echo "$response" | jq -r '.version')
    log_info "Found Caido version: $version"
    
    # Extract .deb packages for Linux desktop
    local deb_packages
    deb_packages=$(echo "$response" | jq -r '.links[] | select(.format == "deb" and .os == "linux" and .kind == "desktop") | @base64')
    
    if [[ -z "$deb_packages" ]]; then
        log_error "No .deb packages found for Linux desktop"
        exit 1
    fi
    
    log_info "Found .deb packages for download"
    
    local success_count=0
    local total_count=0
    
    # Process each package
    while IFS= read -r package_encoded; do
        [[ -z "$package_encoded" ]] && continue
        
        local package_json
        package_json=$(echo "$package_encoded" | base64 -d)
        
        local url
        local filename
        local arch
        
        url=$(echo "$package_json" | jq -r '.link')
        filename=$(basename "$url")
        arch=$(echo "$package_json" | jq -r '.arch')
        
        if [[ -z "$url" ]] || [[ "$url" == "null" ]]; then
            log_warn "Skipping invalid package entry"
            continue
        fi
        
        log_info "Processing: $filename ($arch)"
        
        ((total_count++))
        if download_file "$url" "$filename"; then
            ((success_count++))
        fi
    done <<< "$deb_packages"
    
    log_info "========================================"
    log_info "Download Summary:"
    log_info "Total packages: $total_count"
    log_info "Successful: $success_count"
    log_info "Failed: $((total_count - success_count))"
    log_info "========================================"
    
    if [[ $success_count -eq 0 ]]; then
        log_error "All downloads failed"
        exit 1
    fi
    
    log_info "✅ Download completed successfully"
    
    # List downloaded packages
    if ls "$PACKAGES_DIR"/*.deb 1> /dev/null 2>&1; then
        log_info "Downloaded packages:"
        ls -la "$PACKAGES_DIR"/*.deb
    fi
}

# Update aptify.yml with downloaded packages
update_aptify_config() {
    log_info "Updating aptify.yml configuration..."
    
    if [[ ! -f "aptify.yml" ]]; then
        log_error "aptify.yml not found"
        exit 1
    fi
    
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq not found. Please install yq for YAML processing"
        exit 1
    fi
    
    # Get list of downloaded .deb files
    local deb_files
    deb_files=$(find "$PACKAGES_DIR" -name "*.deb" -type f -exec basename {} \; | sort)
    
    if [[ -z "$deb_files" ]]; then
        log_warn "No .deb files found to update aptify.yml"
        return 0
    fi
    
    # Update aptify.yml packages array
    local packages_json
    packages_json=$(echo "$deb_files" | jq -R -s -c 'split("\n") | map(select(. != "")) | map("packages/" + .)')
    
    yq eval ".releases[0].components[0].packages = $packages_json" -i aptify.yml
    
    log_info "Updated aptify.yml with packages:"
    echo "$deb_files" | sed 's/^/  - /'
    
    # Show updated config
    log_debug "Updated aptify.yml:"
    yq eval '.releases[0].components[0].packages' aptify.yml
}

# Main function
main() {
    log_info "Starting Caido .deb package download process..."
    
    check_dependencies
    setup_directories
    fetch_and_download
    
    # Only update aptify.yml if requested
    if [[ "${UPDATE_CONFIG:-false}" == "true" ]]; then
        update_aptify_config
    fi
    
    log_info "✅ Process completed successfully"
}

# Handle script arguments
case "${1:-}" in
    --update-config)
        UPDATE_CONFIG=true
        main
        ;;
    --help|-h)
        echo "Usage: $0 [--update-config]"
        echo "  --update-config: Update aptify.yml with downloaded packages"
        echo "  --help: Show this help message"
        exit 0
        ;;
    *)
        main
        ;;
esac