#!/bin/bash
# USB IP Display - Universal Installer 

set -e

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

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SOURCE_SCRIPT="$SCRIPT_DIR/usb_ip_sender.py"

# Check if usb_ip_sender.py exists in same directory
if [ ! -f "$SOURCE_SCRIPT" ]; then
    print_msg "Error: usb_ip_sender.py not found at $SOURCE_SCRIPT" "$RED"
    print_msg "Please ensure both files are in the same directory" "$YELLOW"
    exit 1
fi

print_msg "USB IP Display - Universal Installer" "$BLUE"
print_msg "=====================================" "$BLUE"
echo

# Detect OS
OS_NAME="Unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$NAME"
    print_msg "Detected OS: $OS_NAME" "$YELLOW"
fi

# 1. Ubuntu-specific fixes
if [[ "$ID" == "ubuntu" ]] || [[ "$ID_LIKE" == *"ubuntu"* ]]; then
    print_msg "Ubuntu-based OS detected - applying fixes..." "$YELLOW"
    
    # Disable ModemManager
    systemctl stop ModemManager 2>/dev/null || true
    systemctl disable ModemManager 2>/dev/null || true
    
    # Remove brltty if present
    apt-get remove -y brltty 2>/dev/null || true
    
    # Add user to dialout group
    CURRENT_USER="${SUDO_USER:-$USER}"
    usermod -a -G dialout $CURRENT_USER 2>/dev/null || true
    
    print_msg "✓ Ubuntu fixes applied" "$GREEN"
fi

# 2. Install dependencies
print_msg "Installing Python dependencies..." "$YELLOW"

# Try multiple methods to install pyserial
if ! python3 -c "import serial" 2>/dev/null; then
    # Try apt first (most reliable)
    apt-get update -qq
    apt-get install -y python3-serial 2>/dev/null || \
    pip3 install pyserial --break-system-packages 2>/dev/null || \
    pip3 install pyserial 2>/dev/null || \
    { print_msg "Warning: Could not install pyserial automatically" "$YELLOW"; }
fi

print_msg "✓ Dependencies installed" "$GREEN"

# 3. Find Python3 location (for systemd)
PYTHON_PATH=$(which python3)
print_msg "Python3 location: $PYTHON_PATH" "$NC"

# 4. Copy and prepare the sender script
print_msg "Installing sender script..." "$YELLOW"

# Ensure script starts with proper shebang
cp "$SOURCE_SCRIPT" /usr/local/bin/usb_ip_sender.py

# Make sure it has shebang
if ! head -1 /usr/local/bin/usb_ip_sender.py | grep -q "^#!"; then
    echo '#!/usr/bin/env python3' > /tmp/usb_ip_sender_temp.py
    cat /usr/local/bin/usb_ip_sender.py >> /tmp/usb_ip_sender_temp.py
    mv /tmp/usb_ip_sender_temp.py /usr/local/bin/usb_ip_sender.py
fi

chmod +x /usr/local/bin/usb_ip_sender.py
print_msg "✓ Script installed to /usr/local/bin/usb_ip_sender.py" "$GREEN"

# 5. Create systemd service with full paths
print_msg "Creating systemd service..." "$YELLOW"

cat > /etc/systemd/system/pico-monitor.service << EOF
[Unit]
Description=USB IP Display Monitor Service
After=multi-user.target

[Service]
Type=simple
ExecStart=${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PATH=/usr/bin:/bin:/usr/local/bin"

[Install]
WantedBy=multi-user.target
EOF

print_msg "✓ Service created with full Python path" "$GREEN"

# 6. Create udev rule
print_msg "Creating udev rule..." "$YELLOW"

cat > /etc/udev/rules.d/99-pico-display.rules << EOF
# Trigger send when Pico connects
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", RUN+="${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --once"

# Also try without vendor check (some Ubuntu systems)
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", RUN+="${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --once"
EOF

print_msg "✓ Udev rule created" "$GREEN"

# 7. Create helper commands
print_msg "Creating helper commands..." "$YELLOW"

# Status command
cat > /usr/local/bin/pico-status << 'EOF'
#!/bin/bash
echo "=== Pico IP Display Status ==="
echo ""
if [ -e /dev/ttyACM0 ]; then
    echo "✓ Device connected: /dev/ttyACM0"
    ls -la /dev/ttyACM0
else
    echo "✗ No device found"
fi
echo ""
echo "Service status:"
systemctl status pico-monitor --no-pager | head -15
echo ""
echo "Recent logs:"
journalctl -u pico-monitor -n 10 --no-pager
echo ""
echo "Commands:"
echo "  Watch logs:  sudo journalctl -f -u pico-monitor"
echo "  Restart:     sudo systemctl restart pico-monitor"
echo "  Test once:   sudo pico-send"
EOF
chmod +x /usr/local/bin/pico-status

# Manual send command with full path
cat > /usr/local/bin/pico-send << EOF
#!/bin/bash
${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --once
EOF
chmod +x /usr/local/bin/pico-send

print_msg "✓ Helper commands created" "$GREEN"

# 8. Create uninstaller
cat > /usr/local/bin/pico-uninstall << 'EOF'
#!/bin/bash
echo "Uninstalling USB IP Display..."

# Stop and disable service
systemctl stop pico-monitor.service 2>/dev/null || true
systemctl disable pico-monitor.service 2>/dev/null || true
rm -f /etc/systemd/system/pico-monitor.service

# Remove files
rm -f /usr/local/bin/usb_ip_sender.py
rm -f /usr/local/bin/pico-status
rm -f /usr/local/bin/pico-send
rm -f /etc/udev/rules.d/99-pico-display.rules

# Reload systemd and udev
systemctl daemon-reload
udevadm control --reload-rules

echo "✓ USB IP Display uninstalled"
rm -f /usr/local/bin/pico-uninstall
EOF
chmod +x /usr/local/bin/pico-uninstall

print_msg "✓ Uninstaller created" "$GREEN"

# 9. Reload and activate
print_msg "Activating services..." "$YELLOW"

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger

systemctl enable pico-monitor.service
systemctl restart pico-monitor.service

# Give service time to start
sleep 2

# Check if service started successfully
if systemctl is-active --quiet pico-monitor.service; then
    print_msg "✓ Monitor service running successfully" "$GREEN"
else
    print_msg "⚠ Monitor service failed to start" "$YELLOW"
    print_msg "  Check: sudo journalctl -u pico-monitor -n 20" "$NC"
    print_msg "  Manual test: sudo pico-send" "$NC"
fi

print_msg "✓ Services activated" "$GREEN"

# 10. Test if device is currently connected
if [ -e /dev/ttyACM0 ]; then
    print_msg "Device detected, sending test data..." "$YELLOW"
    ${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --once
    print_msg "✓ Test data sent" "$GREEN"
fi

# Done!
echo
print_msg "=====================================" "$GREEN"
print_msg "      Installation Complete!         " "$GREEN"
print_msg "=====================================" "$GREEN"
echo
print_msg "The device will now:" "$NC"
print_msg "  • Detect when Pico connects" "$NC"
print_msg "  • Send IP info immediately" "$NC"
print_msg "  • Keep updating every 15 seconds" "$NC"
echo

if [[ "$ID" == "ubuntu" ]] || [[ "$ID_LIKE" == *"ubuntu"* ]]; then
    print_msg "IMPORTANT FOR UBUNTU:" "$RED"
    print_msg "  You must LOGOUT and LOGIN for dialout group to take effect!" "$YELLOW"
    print_msg "  (or just run: sudo pico-send after plugging in)" "$NC"
    echo
fi

print_msg "Useful commands:" "$YELLOW"
print_msg "  pico-status    - Check device status" "$NC"
print_msg "  pico-send      - Manually send data once" "$NC"
print_msg "  pico-uninstall - Remove everything" "$NC"
echo
print_msg "To watch live logs:" "$YELLOW"
print_msg "  sudo journalctl -f -u pico-monitor" "$NC"
echo

# Final service check
print_msg "Checking service status..." "$NC"
systemctl status pico-monitor --no-pager | head -5
echo
