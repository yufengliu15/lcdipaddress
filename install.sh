#!/bin/bash

# USB IP Display Device - Fixed Installer for Modern Linux
# Handles "externally-managed-environment" error

set -e

# Configuration
GITHUB_USER="yufengliu15"
GITHUB_REPO="lcdipaddress"
GITHUB_BRANCH="main"
REPO_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Installation paths
SCRIPT_PATH="/usr/local/bin/usb_ip_sender.py"
UDEV_RULE_PATH="/etc/udev/rules.d/99-pico-ip-display.rules"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_msg() {
    echo -e "${2}${1}${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_msg "This script must be run as root (use sudo)" "$RED"
    exit 1
fi

print_msg "USB IP Display Installer" "$BLUE"
print_msg "========================" "$BLUE"
echo

# Function to install Python packages properly
install_python_deps() {
    print_msg "Installing Python dependencies..." "$YELLOW"
    
    # Method 1: Try using apt package (preferred for system-wide)
    if apt-get install -y python3-serial 2>/dev/null; then
        print_msg "✓ Installed python3-serial via apt" "$GREEN"
        return 0
    fi
    
    # Method 2: Try pip with break-system-packages flag (PEP 668)
    if pip3 install --break-system-packages pyserial 2>/dev/null; then
        print_msg "✓ Installed pyserial via pip (break-system-packages)" "$GREEN"
        return 0
    fi
    
    # Method 3: Try pip3 without flag (older systems)
    if pip3 install pyserial 2>/dev/null; then
        print_msg "✓ Installed pyserial via pip" "$GREEN"
        return 0
    fi
    
    # Method 4: Use pipx for isolated environment
    if command -v pipx &> /dev/null; then
        pipx install pyserial 2>/dev/null || true
        print_msg "✓ Installed via pipx" "$GREEN"
        return 0
    fi
    
    # Method 5: Manual installation with virtual environment
    print_msg "Installing in virtual environment..." "$YELLOW"
    
    # Create a virtual environment for our script
    python3 -m venv /opt/usb-ip-display-venv
    /opt/usb-ip-display-venv/bin/pip install pyserial
    
    # Create a wrapper script that uses the venv
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Wrapper to run Python script with virtual environment
/opt/usb-ip-display-venv/bin/python /opt/usb-ip-display/usb_ip_sender.py "$@"
EOF
    chmod +x "$SCRIPT_PATH"
    
    # Download the actual Python script to a different location
    mkdir -p /opt/usb-ip-display
    curl -sSL "${REPO_BASE}/host/usb_ip_sender.py" -o /opt/usb-ip-display/usb_ip_sender.py
    
    print_msg "✓ Installed in virtual environment" "$GREEN"
    return 0
}

# Install system dependencies
print_msg "Installing system dependencies..." "$YELLOW"
apt-get update
apt-get install -y python3 python3-pip python3-venv curl

# Install Python dependencies (handles externally-managed-environment)
install_python_deps

# Download main Python script (if not using venv method)
if [ ! -f /opt/usb-ip-display/usb_ip_sender.py ]; then
    print_msg "Downloading IP sender script..." "$YELLOW"
    curl -sSL "${REPO_BASE}/host/usb_ip_sender.py" -o "$SCRIPT_PATH" || {
        # If GitHub fails, use embedded version
        print_msg "GitHub unavailable, using embedded version..." "$YELLOW"
        cat > "$SCRIPT_PATH" << 'EMBEDDED_SCRIPT'
#!/usr/bin/env python3
"""USB IP Display Sender Script"""

import subprocess
import time
import sys
import os

try:
    import serial
except ImportError:
    print("Error: pyserial not installed", file=sys.stderr)
    print("Try: sudo apt-get install python3-serial", file=sys.stderr)
    sys.exit(1)

SERIAL_PORT = "/dev/ttyACM0"
BAUD_RATE = 115200

def get_ip_address():
    try:
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ips = result.stdout.strip().split()
        if ips:
            ipv4_ips = [ip for ip in ips if ':' not in ip and '.' in ip]
            for ip in ipv4_ips:
                if not ip.startswith('127.'):
                    return ip
            return ipv4_ips[0] if ipv4_ips else "No IP"
        return "No IP found"
    except Exception as e:
        return f"Error: {str(e)[:10]}"

def get_ssh_status():
    try:
        for service in ['ssh', 'sshd']:
            result = subprocess.run(['systemctl', 'is-active', service], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                return "SSH: ON"
        result = subprocess.run(['pgrep', 'sshd'], capture_output=True, text=True)
        if result.stdout.strip():
            return "SSH: ON"
        return "SSH: OFF"
    except:
        return "SSH: ???"

def main():
    os.system('logger -t usb-ip-display "Starting IP sender"')
    
    ip_address = get_ip_address()
    ssh_status = get_ssh_status()
    
    display_data = f"{ip_address[:16]}|{ssh_status[:16]}"
    
    for attempt in range(5):
        try:
            if attempt > 0:
                time.sleep(0.5)
            
            with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1) as ser:
                time.sleep(0.5)
                for _ in range(3):
                    ser.write(f"{display_data}\n".encode())
                    ser.flush()
                    time.sleep(0.1)
                
                print(f"Sent: {display_data}")
                os.system(f'logger -t usb-ip-display "Sent: {display_data}"')
                break
                
        except Exception as e:
            if attempt == 4:
                print(f"Failed: {e}", file=sys.stderr)
                sys.exit(1)

if __name__ == "__main__":
    main()
EMBEDDED_SCRIPT
    }
    chmod +x "$SCRIPT_PATH"
fi

print_msg "✓ IP sender script installed" "$GREEN"

# Download and install udev rules
print_msg "Installing udev rules..." "$YELLOW"
cat > "$UDEV_RULE_PATH" << 'EOF'
# Udev rule for USB IP Display Device (Raspberry Pi Pico)
ACTION=="add", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0005", SYMLINK+="pico_display", RUN+="/usr/local/bin/usb_ip_sender.py"
EOF

print_msg "✓ Udev rules installed" "$GREEN"

# Reload udev rules
print_msg "Reloading udev rules..." "$YELLOW"
udevadm control --reload-rules
udevadm trigger
print_msg "✓ Udev rules activated" "$GREEN"

# Create uninstaller
cat > /usr/local/bin/usb-ip-display-uninstall << 'EOF'
#!/bin/bash
echo "Uninstalling USB IP Display..."
rm -f /usr/local/bin/usb_ip_sender.py
rm -f /etc/udev/rules.d/99-pico-ip-display.rules
rm -rf /opt/usb-ip-display
rm -rf /opt/usb-ip-display-venv
udevadm control --reload-rules
echo "✓ Uninstalled successfully"
rm -f /usr/local/bin/usb-ip-display-uninstall
EOF
chmod +x /usr/local/bin/usb-ip-display-uninstall

# Success message
echo
print_msg "========================================" "$GREEN"
print_msg "     Installation Successful! ✓        " "$GREEN"
print_msg "========================================" "$GREEN"
echo
print_msg "The system is now configured for USB IP Display" "$GREEN"
echo
print_msg "Test with: sudo python3 $SCRIPT_PATH" "$YELLOW"
print_msg "Uninstall: sudo usb-ip-display-uninstall" "$YELLOW"
echo