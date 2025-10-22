#!/bin/bash

# USB IP Display Device - GitHub Installer Script
# This script downloads and configures the Linux host to automatically send IP info to the USB display
# 
# Installation:
#   curl -sSL https://raw.githubusercontent.com/yufengliu15/lcdipaddress/main/install.sh | sudo bash
#   OR
#   wget -qO- https://raw.githubusercontent.com/yufengliu15/lcdipaddress/main/install.sh | sudo bash

set -e  # Exit on error

# ================== CONFIGURATION ==================
# Update this to your GitHub repository
GITHUB_USER="yufengliu15"
GITHUB_REPO="lcdipaddress"
GITHUB_BRANCH="main"  # or "master"
VERSION="1.0.0"

# GitHub URLs
REPO_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
REPO_API="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}"

# Installation paths
INSTALL_DIR="/opt/usb-ip-display"
SCRIPT_NAME="usb_ip_sender.py"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
UDEV_RULE_NAME="99-pico-ip-display.rules"
UDEV_RULE_PATH="/etc/udev/rules.d/${UDEV_RULE_NAME}"
UNINSTALLER_PATH="/usr/local/bin/usb-ip-display-uninstall"
VERSION_FILE="/opt/usb-ip-display/.version"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ================== FUNCTIONS ==================

# Function to print colored messages
print_msg() {
    echo -e "${2}${1}${NC}"
}

# Function to print banner
print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║     USB IP Display Device Installer      ║"
    echo "║          GitHub Edition v${VERSION}           ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_msg "This script must be run as root (use sudo)" "$RED"
        echo
        print_msg "Try: curl -sSL ${REPO_BASE}/install.sh | sudo bash" "$YELLOW"
        exit 1
    fi
}

# Check for required commands
check_requirements() {
    local missing_tools=()
    
    for tool in curl python3 pip3 udevadm; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_msg "Missing required tools: ${missing_tools[*]}" "$RED"
        print_msg "Installing missing dependencies..." "$YELLOW"
        
        apt-get update
        
        for tool in "${missing_tools[@]}"; do
            case $tool in
                python3)
                    apt-get install -y python3
                    ;;
                pip3)
                    apt-get install -y python3-pip
                    ;;
                curl)
                    apt-get install -y curl
                    ;;
                udevadm)
                    apt-get install -y udev
                    ;;
            esac
        done
    fi
}

# Check internet connectivity
check_internet() {
    print_msg "Checking internet connection..." "$YELLOW"
    
    if ! curl -sSf "https://raw.githubusercontent.com" > /dev/null 2>&1; then
        print_msg "No internet connection. Please check your network." "$RED"
        exit 1
    fi
    
    print_msg "✓ Internet connection OK" "$GREEN"
}

# Check if repository exists
check_repository() {
    print_msg "Checking GitHub repository..." "$YELLOW"
    
    if ! curl -sSf "${REPO_API}" > /dev/null 2>&1; then
        print_msg "Repository not found: ${GITHUB_USER}/${GITHUB_REPO}" "$RED"
        print_msg "Please update the GITHUB_USER and GITHUB_REPO variables in this script" "$YELLOW"
        exit 1
    fi
    
    print_msg "✓ Repository found" "$GREEN"
}

# Check for updates
check_for_updates() {
    if [ -f "$VERSION_FILE" ]; then
        INSTALLED_VERSION=$(cat "$VERSION_FILE")
        print_msg "Installed version: $INSTALLED_VERSION" "$BLUE"
        
        # Get latest version from GitHub
        LATEST_VERSION=$(curl -s "${REPO_API}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')
        
        if [ ! -z "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "$INSTALLED_VERSION" ]; then
            print_msg "New version available: $LATEST_VERSION" "$YELLOW"
            print_msg "Visit: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases" "$YELLOW"
        fi
    fi
}

# Download file from GitHub
download_file() {
    local source_path=$1
    local dest_path=$2
    local file_desc=$3
    
    print_msg "Downloading ${file_desc}..." "$YELLOW"
    
    if curl -sSL "${REPO_BASE}/${source_path}" -o "${dest_path}"; then
        print_msg "✓ ${file_desc} downloaded" "$GREEN"
        return 0
    else
        print_msg "✗ Failed to download ${file_desc}" "$RED"
        return 1
    fi
}

# Create installation directory
create_install_dir() {
    print_msg "Creating installation directory..." "$YELLOW"
    
    mkdir -p "$INSTALL_DIR"
    echo "$VERSION" > "$VERSION_FILE"
    
    print_msg "✓ Installation directory created" "$GREEN"
}

# Install Python dependencies
install_dependencies() {
    print_msg "Installing Python dependencies..." "$YELLOW"
    
    # Install pyserial
    if pip3 install pyserial; then
        print_msg "✓ Python dependencies installed" "$GREEN"
    else
        print_msg "Warning: Failed to install some Python packages" "$YELLOW"
    fi
}

# Download and install the USB IP sender script
install_sender_script() {
    # First, create the Python script from embedded content for reliability
    print_msg "Installing IP sender script..." "$YELLOW"
    
    cat > "$SCRIPT_PATH" << 'PYTHON_SCRIPT_EOF'
#!/usr/bin/env python3
"""
USB IP Display Sender Script
Sends host IP address and SSH status to Pico display device
"""

import serial
import subprocess
import time
import sys
import os
from datetime import datetime

# Configuration
SERIAL_PORT = "/dev/ttyACM0"
BAUD_RATE = 115200
RETRY_ATTEMPTS = 5
RETRY_DELAY = 0.5

def get_ip_address():
    """Get the primary IP address of the host"""
    try:
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ips = result.stdout.strip().split()
        
        # Return first non-localhost IP, or fallback message
        if ips:
            # Filter out IPv6 addresses if needed (keep only IPv4)
            ipv4_ips = [ip for ip in ips if ':' not in ip]
            return ipv4_ips[0] if ipv4_ips else ips[0]
        else:
            return "No IP found"
    except Exception as e:
        return f"Error: {str(e)[:10]}"

def get_ssh_status():
    """Check if SSH service is running"""
    try:
        # Try systemctl first (systemd systems)
        result = subprocess.run(['systemctl', 'is-active', 'ssh'], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            return "SSH: ON"
        
        # Try sshd as alternative service name
        result = subprocess.run(['systemctl', 'is-active', 'sshd'], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            return "SSH: ON"
            
        # Check if process is running directly
        result = subprocess.run(['pgrep', 'sshd'], 
                              capture_output=True, text=True)
        if result.stdout.strip():
            return "SSH: ON"
        
        return "SSH: OFF"
    except:
        # For non-systemd systems, check if sshd process exists
        try:
            result = subprocess.run(['pgrep', 'sshd'], 
                                  capture_output=True, text=True)
            if result.stdout.strip():
                return "SSH: ON"
            return "SSH: OFF"
        except:
            return "SSH: ???"

def send_to_display(ser, data):
    """Send data to the Pico display"""
    try:
        # Send data with newline terminator
        ser.write(f"{data}\n".encode())
        ser.flush()
        return True
    except Exception as e:
        print(f"Error sending data: {e}", file=sys.stderr)
        return False

def main():
    """Main function"""
    # Log to syslog for debugging
    os.system(f'logger -t usb-ip-display "Starting IP sender script"')
    
    # Get system information
    ip_address = get_ip_address()
    ssh_status = get_ssh_status()
    
    # Format display data (2 lines for 16x2 LCD)
    line1 = ip_address[:16]  # First line: IP address (truncate if needed)
    line2 = ssh_status[:16]   # Second line: SSH status
    
    display_data = f"{line1}|{line2}"  # Use | as line separator
    
    # Try to open serial port with retries
    for attempt in range(RETRY_ATTEMPTS):
        try:
            # Wait a bit for device to be ready
            if attempt > 0:
                time.sleep(RETRY_DELAY)
            
            # Open serial connection
            with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1) as ser:
                # Wait for port to be ready
                time.sleep(0.5)
                
                # Send data multiple times to ensure delivery
                for _ in range(3):
                    if send_to_display(ser, display_data):
                        os.system(f'logger -t usb-ip-display "Successfully sent: {display_data}"')
                    time.sleep(0.1)
                
                print(f"Sent to display: {display_data}")
                break
                
        except serial.SerialException as e:
            if attempt == RETRY_ATTEMPTS - 1:
                error_msg = f"Failed to open {SERIAL_PORT} after {RETRY_ATTEMPTS} attempts"
                print(error_msg, file=sys.stderr)
                os.system(f'logger -t usb-ip-display "{error_msg}"')
                sys.exit(1)
            else:
                os.system(f'logger -t usb-ip-display "Retry {attempt + 1}/{RETRY_ATTEMPTS}: {e}"')
        except Exception as e:
            error_msg = f"Unexpected error: {e}"
            print(error_msg, file=sys.stderr)
            os.system(f'logger -t usb-ip-display "{error_msg}"')
            sys.exit(1)

if __name__ == "__main__":
    main()
PYTHON_SCRIPT_EOF

    chmod +x "$SCRIPT_PATH"
    
    # Optionally try to update from GitHub if available
    if curl -sSf "${REPO_BASE}/host/usb_ip_sender.py" > /dev/null 2>&1; then
        print_msg "Checking for updates from GitHub..." "$YELLOW"
        download_file "host/usb_ip_sender.py" "${INSTALL_DIR}/usb_ip_sender.py" "Latest sender script"
        
        # If download succeeded, use the GitHub version
        if [ -f "${INSTALL_DIR}/usb_ip_sender.py" ]; then
            cp "${INSTALL_DIR}/usb_ip_sender.py" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
        fi
    fi
    
    print_msg "✓ IP sender script installed at $SCRIPT_PATH" "$GREEN"
}

# Install udev rules
install_udev_rules() {
    print_msg "Installing udev rules..." "$YELLOW"
    
    # Create udev rule
    cat > "$UDEV_RULE_PATH" << 'UDEV_RULES_EOF'
# Udev rule for USB IP Display Device (Raspberry Pi Pico)
# This rule triggers the IP sender script when the Pico is connected

# Rule for Raspberry Pi Pico
ACTION=="add", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0005", SYMLINK+="pico_display", RUN+="/usr/local/bin/usb_ip_sender.py"

# Alternative rule using serial subsystem
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0005", RUN+="/usr/local/bin/usb_ip_sender.py"
UDEV_RULES_EOF

    # Try to download latest rules from GitHub
    if curl -sSf "${REPO_BASE}/host/99-pico-ip-display.rules" > /dev/null 2>&1; then
        download_file "host/99-pico-ip-display.rules" "${INSTALL_DIR}/99-pico-ip-display.rules" "Latest udev rules"
        
        if [ -f "${INSTALL_DIR}/99-pico-ip-display.rules" ]; then
            cp "${INSTALL_DIR}/99-pico-ip-display.rules" "$UDEV_RULE_PATH"
        fi
    fi
    
    print_msg "✓ Udev rules installed" "$GREEN"
}

# Reload udev rules
reload_udev() {
    print_msg "Reloading udev rules..." "$YELLOW"
    
    udevadm control --reload-rules
    udevadm trigger
    
    print_msg "✓ Udev rules reloaded" "$GREEN"
}

# Create uninstaller
create_uninstaller() {
    print_msg "Creating uninstaller..." "$YELLOW"
    
    cat > "$UNINSTALLER_PATH" << UNINSTALLER_EOF
#!/bin/bash
# USB IP Display Device Uninstaller
# This script removes all components installed by the installer

echo -e "${RED}========================================${NC}"
echo -e "${RED}   USB IP Display Device Uninstaller    ${NC}"
echo -e "${RED}========================================${NC}"
echo

# Remove sender script
if [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH"
    echo "✓ Removed sender script"
fi

# Remove udev rule
if [ -f "$UDEV_RULE_PATH" ]; then
    rm -f "$UDEV_RULE_PATH"
    echo "✓ Removed udev rule"
fi

# Remove installation directory
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "✓ Removed installation directory"
fi

# Reload udev rules
udevadm control --reload-rules 2>/dev/null
echo "✓ Reloaded udev rules"

# Remove uninstaller itself
rm -f "$UNINSTALLER_PATH"

echo
echo -e "${GREEN}✓ USB IP Display Device has been completely removed${NC}"
echo "Note: Python package 'pyserial' was not removed as it may be used by other programs"
echo
UNINSTALLER_EOF

    chmod +x "$UNINSTALLER_PATH"
    print_msg "✓ Uninstaller created" "$GREEN"
}

# Download Pico firmware files
download_pico_firmware() {
    print_msg "\nDownloading Pico firmware files..." "$YELLOW"
    
    PICO_DIR="${INSTALL_DIR}/pico"
    mkdir -p "$PICO_DIR"
    
    # List of Pico files to download
    local files_downloaded=0
    
    for file in "main.py" "lcd_api.py" "i2c_lcd.py"; do
        if curl -sSf "${REPO_BASE}/pico/${file}" > /dev/null 2>&1; then
            if download_file "pico/${file}" "${PICO_DIR}/${file}" "Pico ${file}"; then
                ((files_downloaded++))
            fi
        fi
    done
    
    if [ $files_downloaded -gt 0 ]; then
        print_msg "✓ Pico firmware files saved to ${PICO_DIR}" "$GREEN"
        print_msg "  Copy these files to your Pico running CircuitPython" "$YELLOW"
    else
        print_msg "ℹ Pico firmware files not found in repository" "$YELLOW"
        print_msg "  You'll need to create them manually or download separately" "$YELLOW"
    fi
}

# Main installation function
main() {
    print_banner
    
    # Pre-installation checks
    check_root
    check_requirements
    check_internet
    
    # Repository check (optional - comment out if repo doesn't exist yet)
    # check_repository
    
    print_msg "\n🚀 Starting installation..." "$BLUE"
    echo
    
    # Check for existing installation
    if [ -f "$VERSION_FILE" ]; then
        print_msg "Existing installation found. Upgrading..." "$YELLOW"
        check_for_updates
    fi
    
    # Perform installation
    create_install_dir
    install_dependencies
    install_sender_script
    install_udev_rules
    reload_udev
    create_uninstaller
    download_pico_firmware
    
    # Success message
    echo
    print_msg "========================================" "$GREEN"
    print_msg "     Installation Successful! ✓        " "$GREEN"
    print_msg "========================================" "$GREEN"
    echo
    print_msg "The host is now configured for USB IP Display" "$GREEN"
    echo
    print_msg "📋 Next steps:" "$YELLOW"
    print_msg "1. Copy Pico firmware files from ${PICO_DIR} to your Pico" "$NC"
    print_msg "2. Connect your Pico with the display" "$NC"
    print_msg "3. IP address will appear automatically!" "$NC"
    echo
    print_msg "📦 Useful commands:" "$YELLOW"
    print_msg "  Test manually:  sudo ${SCRIPT_PATH}" "$NC"
    print_msg "  Uninstall:      sudo usb-ip-display-uninstall" "$NC"
    print_msg "  Check logs:     journalctl -xe | grep usb-ip-display" "$NC"
    echo
    print_msg "📖 Documentation: https://github.com/${GITHUB_USER}/${GITHUB_REPO}" "$BLUE"
    echo
}

# Run main function
main