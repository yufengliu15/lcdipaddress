#!/bin/bash
# USB IP Display - Simplified Installer

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
SOURCE_SCRIPT="$SCRIPT_DIR/host/usb_ip_sender.py"

# Check if usb_ip_sender.py exists in host directory
if [ ! -f "$SOURCE_SCRIPT" ]; then
    print_msg "Error: usb_ip_sender.py not found at $SOURCE_SCRIPT" "$RED"
    print_msg "Please ensure usb_ip_sender.py is in the host/ subdirectory" "$YELLOW"
    print_msg "Expected structure:" "$YELLOW"
    print_msg "  ./" "$NC"
    print_msg "  ├── install.sh" "$NC"
    print_msg "  └── host/" "$NC"
    print_msg "      └── usb_ip_sender.py" "$NC"
    exit 1
fi

print_msg "USB IP Display - Simplified Installer" "$BLUE"
print_msg "=====================================" "$BLUE"
echo

# 1. Install dependencies
print_msg "Installing Python dependencies..." "$YELLOW"
pip3 install pyserial --break-system-packages 2>/dev/null || pip3 install pyserial
print_msg "✓ Dependencies installed" "$GREEN"

# 2. Copy the sender script
print_msg "Installing sender script..." "$YELLOW"
cp "$SOURCE_SCRIPT" /usr/local/bin/usb_ip_sender.py
chmod +x /usr/local/bin/usb_ip_sender.py
print_msg "✓ Script installed to /usr/local/bin/usb_ip_sender.py" "$GREEN"

# 3. Create systemd service
print_msg "Creating systemd service..." "$YELLOW"

cat > /etc/systemd/system/pico-monitor.service << 'EOF'
[Unit]
Description=USB IP Display Monitor Service
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/usb_ip_sender.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

print_msg "✓ Service created" "$GREEN"

# 4. Create udev rule
print_msg "Creating udev rule..." "$YELLOW"

cat > /etc/udev/rules.d/99-pico-display.rules << 'EOF'
# Trigger one-shot send when Pico connects
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", RUN+="/usr/local/bin/usb_ip_sender.py --once"
EOF

print_msg "✓ Udev rule created" "$GREEN"

# 5. Create helper commands
print_msg "Creating helper commands..." "$YELLOW"

# Status command
cat > /usr/local/bin/pico-status << 'EOF'
#!/bin/bash
echo "=== Pico IP Display Status ==="
echo ""
if [ -e /dev/ttyACM0 ]; then
    echo "✓ Device connected: /dev/ttyACM0"
else
    echo "✗ No device found"
fi
echo ""
echo "Service status:"
systemctl status pico-monitor --no-pager | head -15
echo ""
echo "Commands:"
echo "  Watch logs:  sudo journalctl -f -u pico-monitor"
echo "  Restart:     sudo systemctl restart pico-monitor"
echo "  Test once:   sudo /usr/local/bin/usb_ip_sender.py --once"
EOF
chmod +x /usr/local/bin/pico-status

# Manual send command
cat > /usr/local/bin/pico-send << 'EOF'
#!/bin/bash
/usr/local/bin/usb_ip_sender.py --once
EOF
chmod +x /usr/local/bin/pico-send

print_msg "✓ Helper commands created" "$GREEN"

# 6. Create uninstaller
print_msg "Creating uninstaller..." "$YELLOW"

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

# Remove self
rm -f /usr/local/bin/pico-uninstall

echo "✓ USB IP Display uninstalled"
EOF
chmod +x /usr/local/bin/pico-uninstall

print_msg "✓ Uninstaller created" "$GREEN"

# 7. Reload and activate
print_msg "Activating services..." "$YELLOW"

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger

systemctl enable pico-monitor.service
systemctl restart pico-monitor.service

print_msg "✓ Services activated" "$GREEN"

# 8. Test if device is currently connected
if [ -e /dev/ttyACM0 ]; then
    print_msg "Device detected, sending test data..." "$YELLOW"
    /usr/local/bin/usb_ip_sender.py --once
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
print_msg "Useful commands:" "$YELLOW"
print_msg "  pico-status    - Check device status" "$NC"
print_msg "  pico-send      - Manually send data once" "$NC"
print_msg "  pico-uninstall - Remove everything" "$NC"
echo
print_msg "To watch live logs:" "$YELLOW"
print_msg "  sudo journalctl -f -u pico-monitor" "$NC"
echo
