#!/bin/bash

# USB IP Display Device - Minimal GitHub Installer
# Downloads and installs everything from GitHub repository
# 
# Installation:
#   curl -sSL https://raw.githubusercontent.com/yufengliu15/lcdipaddress/main/install.sh | sudo bash

set -e  # Exit on error

# ================== CONFIGURATION ==================
GITHUB_USER="yufengliu15"
GITHUB_REPO="lcdipaddress"
GITHUB_BRANCH="main"
VERSION="1.0.0"

# GitHub URLs
REPO_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Installation paths
SCRIPT_PATH="/usr/local/bin/usb_ip_sender.py"
UDEV_RULE_PATH="/etc/udev/rules.d/99-pico-ip-display.rules"
UNINSTALLER_PATH="/usr/local/bin/usb-ip-display-uninstall"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ================== FUNCTIONS ==================

print_msg() {
    echo -e "${2}${1}${NC}"
}

print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     USB IP Display Device Installer      ║"
    echo "║           GitHub Edition v${VERSION}          ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_msg "This script must be run as root (use sudo)" "$RED"
        exit 1
    fi
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_msg "Installing $1..." "$YELLOW"
        apt-get update && apt-get install -y $1
    fi
}

download_file() {
    local url=$1
    local dest=$2
    local desc=$3
    
    print_msg "Downloading ${desc}..." "$YELLOW"
    
    if curl -sSL "${url}" -o "${dest}"; then
        print_msg "✓ ${desc} installed" "$GREEN"
        return 0
    else
        print_msg "✗ Failed to download ${desc}" "$RED"
        print_msg "  URL: ${url}" "$RED"
        return 1
    fi
}

# ================== MAIN INSTALLATION ==================

main() {
    print_banner
    
    # Checks
    check_root
    check_command curl
    check_command python3
    check_command pip3
    
    print_msg "\n🚀 Starting installation from GitHub..." "$BLUE"
    echo
    
    # Install Python dependencies
    print_msg "Installing Python dependencies..." "$YELLOW"
    pip3 install pyserial
    print_msg "✓ Dependencies installed" "$GREEN"
    
    # Download and install files from GitHub
    download_file \
        "${REPO_BASE}/host/usb_ip_sender.py" \
        "${SCRIPT_PATH}" \
        "IP sender script"
    chmod +x "${SCRIPT_PATH}"
    
    download_file \
        "${REPO_BASE}/host/99-pico-ip-display.rules" \
        "${UDEV_RULE_PATH}" \
        "Udev rules"
    
    # Create uninstaller
    print_msg "Creating uninstaller..." "$YELLOW"
    cat > "${UNINSTALLER_PATH}" << EOF
#!/bin/bash
echo "Uninstalling USB IP Display Device..."
rm -f "${SCRIPT_PATH}" && echo "✓ Removed sender script"
rm -f "${UDEV_RULE_PATH}" && echo "✓ Removed udev rule"
udevadm control --reload-rules 2>/dev/null && echo "✓ Reloaded udev rules"
rm -f "${UNINSTALLER_PATH}"
echo "✓ Uninstallation complete"
EOF
    chmod +x "${UNINSTALLER_PATH}"
    print_msg "✓ Uninstaller created" "$GREEN"
    
    # Reload udev
    print_msg "Reloading udev rules..." "$YELLOW"
    udevadm control --reload-rules
    udevadm trigger
    print_msg "✓ Udev rules activated" "$GREEN"
    
    # Download Pico files (optional)
    echo
    print_msg "Downloading Pico firmware..." "$YELLOW"
    PICO_DIR="/tmp/pico-firmware-$$"
    mkdir -p "${PICO_DIR}"
    
    for file in main.py lcd_api.py i2c_lcd.py; do
        download_file \
            "${REPO_BASE}/pico/${file}" \
            "${PICO_DIR}/${file}" \
            "Pico ${file}"
    done
    
    # Success
    echo
    print_msg "========================================" "$GREEN"
    print_msg "     Installation Successful! ✓        " "$GREEN"
    print_msg "========================================" "$GREEN"
    echo
    print_msg "📋 Next steps:" "$YELLOW"
    print_msg "1. Copy Pico files from ${PICO_DIR} to your Pico" "$NC"
    print_msg "2. Connect your Pico to see IP address" "$NC"
    echo
    print_msg "📦 Commands:" "$YELLOW"
    print_msg "  Test:      sudo ${SCRIPT_PATH}" "$NC"
    print_msg "  Uninstall: sudo usb-ip-display-uninstall" "$NC"
    echo
}

# Run
main