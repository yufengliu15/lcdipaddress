#!/bin/bash

# USB IP Display - Alternative Setup using systemd
# This approach uses systemd device units instead of udev rules
# More reliable on modern Linux systems

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_msg() {
    echo -e "${2}${1}${NC}"
}

if [[ $EUID -ne 0 ]]; then
    print_msg "This script must be run as root (use sudo)" "$RED"
    exit 1
fi

print_msg "USB IP Display - Systemd Installer" "$BLUE"
print_msg "===================================" "$BLUE"
echo
print_msg "This installer uses systemd instead of udev (more reliable)" "$YELLOW"
echo

# 1. Install dependencies
print_msg "Installing dependencies..." "$YELLOW"
apt-get update -qq
apt-get install -y python3-serial || pip3 install --break-system-packages pyserial || pip3 install pyserial
print_msg "✓ Dependencies installed" "$GREEN"

# 2. Install the Python script
print_msg "Installing Python script..." "$YELLOW"

SCRIPT_PATH="/usr/local/bin/usb_ip_sender.py"

if [ -f "/mnt/project/usb_ip_sender.py" ]; then
    cp "/mnt/project/usb_ip_sender.py" "$SCRIPT_PATH"
else
    cat > "$SCRIPT_PATH" << 'EOF'
#!/usr/bin/env python3
"""USB IP Display Sender"""
import serial, subprocess, time, sys, os

def get_ip():
    try:
        r = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ips = r.stdout.strip().split()
        return ips[0] if ips else "No IP"
    except: return "Error"

def get_ssh():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'ssh'], capture_output=True, text=True)
        return "SSH: ON" if r.returncode == 0 else "SSH: OFF"
    except: return "SSH: ???"

def main():
    port = "/dev/ttyACM0"
    if len(sys.argv) > 1: port = sys.argv[1]
    
    os.system(f'logger -t usb-ip-display "Starting for {port}"')
    
    data = f"{get_ip()[:16]}|{get_ssh()[:16]}"
    
    for attempt in range(5):
        try:
            if attempt > 0: time.sleep(0.5)
            with serial.Serial(port, 115200, timeout=1) as ser:
                time.sleep(0.5)
                for _ in range(3):
                    ser.write(f"{data}\n".encode())
                    ser.flush()
                    time.sleep(0.1)
                os.system(f'logger -t usb-ip-display "Sent: {data}"')
                print(f"Sent: {data}")
                break
        except Exception as e:
            if attempt == 4:
                os.system(f'logger -t usb-ip-display "Failed: {e}"')
                sys.exit(1)

if __name__ == "__main__": main()
EOF
fi

chmod +x "$SCRIPT_PATH"
print_msg "✓ Script installed" "$GREEN"

# 3. Create systemd service template
print_msg "Creating systemd service..." "$YELLOW"

cat > /etc/systemd/system/pico-ip-display@.service << 'EOF'
[Unit]
Description=USB IP Display for %I
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/usb_ip_sender.py /dev/%I
RemainAfterExit=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

print_msg "✓ Systemd service created" "$GREEN"

# 4. Create device-activated service  
print_msg "Creating device trigger..." "$YELLOW"

cat > /etc/systemd/system/pico-ip-display-ttyACM0.service << 'EOF'
[Unit]
Description=USB IP Display Trigger for ttyACM0
BindsTo=dev-ttyACM0.device
After=dev-ttyACM0.device

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb_ip_sender.py /dev/ttyACM0
RemainAfterExit=yes

[Install]
WantedBy=dev-ttyACM0.device
EOF

print_msg "✓ Device trigger created" "$GREEN"

# 5. Create udev rule (belt and suspenders approach)
print_msg "Creating udev rule..." "$YELLOW"

cat > /etc/udev/rules.d/99-pico-systemd.rules << 'EOF'
# Trigger systemd service when Pico connects
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", TAG+="systemd", ENV{SYSTEMD_WANTS}="pico-ip-display@%k.service"
EOF

print_msg "✓ Udev rule created" "$GREEN"

# 6. Reload everything
print_msg "Activating services..." "$YELLOW"

systemctl daemon-reload
systemctl enable pico-ip-display-ttyACM0.service 2>/dev/null || true
udevadm control --reload-rules
udevadm trigger

print_msg "✓ Services activated" "$GREEN"

# 7. Create watcher script
cat > /usr/local/bin/pico-watcher << 'EOF'
#!/bin/bash
# Monitors Pico connections and manually triggers if needed

while true; do
    if [ -e /dev/ttyACM0 ]; then
        # Check if we already sent data recently
        if [ ! -f /tmp/pico-sent ] || [ $(find /tmp/pico-sent -mmin +1 2>/dev/null | wc -l) -gt 0 ]; then
            echo "Pico detected, sending IP..."
            /usr/local/bin/usb_ip_sender.py && touch /tmp/pico-sent
        fi
    else
        rm -f /tmp/pico-sent 2>/dev/null
    fi
    sleep 2
done
EOF
chmod +x /usr/local/bin/pico-watcher

# 8. Create watcher service (ultimate fallback)
cat > /etc/systemd/system/pico-watcher.service << 'EOF'
[Unit]
Description=Pico IP Display Watcher
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/pico-watcher
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

print_msg "✓ Watcher service created" "$GREEN"

# 9. Create test command
cat > /usr/local/bin/test-pico << 'EOF'
#!/bin/bash
echo "Testing Pico IP Display..."
echo ""
echo "1. Checking if Pico is connected:"
if [ -e /dev/ttyACM0 ]; then
    echo "   ✓ Found /dev/ttyACM0"
    echo ""
    echo "2. Testing manual execution:"
    /usr/local/bin/usb_ip_sender.py
    echo ""
    echo "3. Checking systemd service status:"
    systemctl status pico-ip-display@ttyACM0.service --no-pager || true
    echo ""
    echo "4. Recent logs:"
    journalctl -u pico-ip-display@ttyACM0 -n 5 --no-pager
else
    echo "   ✗ No Pico found at /dev/ttyACM0"
    echo "   Please connect your Pico and try again"
fi
EOF
chmod +x /usr/local/bin/test-pico

# 10. Create uninstaller
cat > /usr/local/bin/uninstall-pico-display << 'EOF'
#!/bin/bash
echo "Uninstalling Pico IP Display..."
systemctl stop pico-watcher.service 2>/dev/null
systemctl disable pico-watcher.service 2>/dev/null
systemctl disable pico-ip-display-ttyACM0.service 2>/dev/null
rm -f /etc/systemd/system/pico-ip-display*.service
rm -f /etc/systemd/system/pico-watcher.service
rm -f /etc/udev/rules.d/99-pico*.rules
rm -f /usr/local/bin/usb_ip_sender.py
rm -f /usr/local/bin/pico-watcher
rm -f /usr/local/bin/test-pico
systemctl daemon-reload
udevadm control --reload-rules
echo "✓ Uninstalled"
rm -f /usr/local/bin/uninstall-pico-display
EOF
chmod +x /usr/local/bin/uninstall-pico-display

# Done!
echo
print_msg "=====================================" "$GREEN"
print_msg "   Installation Complete! ✓         " "$GREEN"
print_msg "=====================================" "$GREEN"
echo
print_msg "THREE ways this will work now:" "$BLUE"
print_msg "1. Systemd device trigger (fastest)" "$NC"
print_msg "2. Udev rule with systemd (backup)" "$NC"  
print_msg "3. Watcher service (guaranteed)" "$NC"
echo
print_msg "To enable the watcher (100% reliable):" "$YELLOW"
print_msg "  sudo systemctl enable --now pico-watcher.service" "$NC"
echo
print_msg "To test:" "$YELLOW"
print_msg "  sudo test-pico" "$NC"
echo
print_msg "To check logs:" "$YELLOW"
print_msg "  journalctl -f | grep pico" "$NC"
echo
print_msg "To uninstall:" "$YELLOW"
print_msg "  sudo uninstall-pico-display" "$NC"
echo