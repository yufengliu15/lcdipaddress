#!/bin/bash

# USB IP Display - Complete Fix for Reconnection Issues
# This script fixes the problem where display gets stuck on "Waiting for host"

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

print_msg "USB IP Display - Reconnection Fix" "$BLUE"
print_msg "==================================" "$BLUE"
echo
print_msg "This fixes the 'stuck on waiting' issue" "$YELLOW"
echo

# 1. Stop any existing services
print_msg "Stopping existing services..." "$YELLOW"
systemctl stop pico-ip-display@*.service 2>/dev/null || true
systemctl stop pico-ip-display-ttyACM0.service 2>/dev/null || true
systemctl stop pico-watcher.service 2>/dev/null || true
pkill -f usb_ip_sender.py 2>/dev/null || true
print_msg "✓ Services stopped" "$GREEN"

# 2. Install the robust Python script
print_msg "Installing robust sender script..." "$YELLOW"

cat > /usr/local/bin/usb_ip_sender.py << 'SCRIPT_EOF'
#!/usr/bin/env python3
"""USB IP Display - Auto-sending version (no refresh needed)"""

import serial
import subprocess
import time
import sys
import os
from datetime import datetime

BAUD_RATE = 115200
SEND_INTERVAL = 15  # Send every 15 seconds
RECONNECT_DELAY = 2

def log(msg):
    """Log to syslog and console"""
    os.system(f'logger -t usb-ip-display "{msg}"')
    print(msg)

def get_ip():
    """Get primary IP address"""
    try:
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=2)
        ips = result.stdout.strip().split()
        if ips:
            # Get first non-local IPv4
            for ip in ips:
                if '.' in ip and not ip.startswith('127.') and not ip.startswith('169.'):
                    return ip
            # Fallback to first IP
            return ips[0] if ips else "No IP"
        return "No IP"
    except:
        return "IP Error"

def get_ssh():
    """Check SSH status"""
    try:
        for svc in ['ssh', 'sshd']:
            r = subprocess.run(['systemctl', 'is-active', svc], capture_output=True, text=True, timeout=1)
            if r.returncode == 0:
                return "SSH: ON"
        return "SSH: OFF"
    except:
        return "SSH: ???"

def find_pico():
    """Find Pico serial port"""
    import glob
    # Check common ports
    for port in ['/dev/ttyACM0', '/dev/ttyACM1', '/dev/pico_display']:
        if os.path.exists(port):
            return port
    # Find any ACM device
    acm = glob.glob('/dev/ttyACM*')
    return acm[0] if acm else None

def send_data(ser):
    """Send IP data to Pico"""
    try:
        data = f"{get_ip()[:16]}|{get_ssh()[:16]}"
        # Send twice for reliability
        for _ in range(2):
            ser.write(f"{data}\n".encode())
            ser.flush()
            time.sleep(0.05)
        log(f"Sent: {data}")
        return True
    except Exception as e:
        log(f"Send failed: {e}")
        return False

def monitor_device():
    """Main monitoring loop"""
    log("Starting monitor mode")
    
    while True:
        try:
            # Find device
            port = find_pico()
            if not port:
                log("No device found, waiting...")
                time.sleep(RECONNECT_DELAY)
                continue
            
            log(f"Connecting to {port}")
            
            # Open connection
            try:
                ser = serial.Serial(port, BAUD_RATE, timeout=1)
                time.sleep(2)  # Let device initialize
                
                # Clear buffers
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                
                log(f"Connected to {port}")
                
                # Send initial data
                send_data(ser)
                
                # Keep sending periodically
                last_send = time.time()
                while True:
                    # Check if device still exists
                    if not os.path.exists(port):
                        log("Device disconnected")
                        break
                    
                    # Send data every interval
                    if time.time() - last_send >= SEND_INTERVAL:
                        if not send_data(ser):
                            break
                        last_send = time.time()
                    
                    time.sleep(1)
                
                ser.close()
                
            except Exception as e:
                log(f"Connection error: {e}")
            
            log("Disconnected, waiting for reconnection...")
            time.sleep(RECONNECT_DELAY)
            
        except KeyboardInterrupt:
            log("Stopped by user")
            break
        except Exception as e:
            log(f"Monitor error: {e}")
            time.sleep(RECONNECT_DELAY)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == '--once':
        # One-shot mode for udev
        port = find_pico()
        if port:
            try:
                ser = serial.Serial(port, BAUD_RATE, timeout=1)
                time.sleep(1)
                send_data(ser)
                ser.close()
            except Exception as e:
                log(f"One-shot error: {e}")
    else:
        # Monitor mode
        monitor_device()
SCRIPT_EOF

chmod +x /usr/local/bin/usb_ip_sender.py
print_msg "✓ Script installed" "$GREEN"

# 3. Create improved systemd service
print_msg "Creating improved systemd service..." "$YELLOW"

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

# 4. Create udev rule for immediate response
print_msg "Creating udev rule..." "$YELLOW"

cat > /etc/udev/rules.d/99-pico-display.rules << 'EOF'
# Immediate one-shot send when Pico connects
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", RUN+="/usr/local/bin/usb_ip_sender.py --once"

# Also log the connection
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", RUN+="/bin/sh -c 'echo Pico connected at $(date) >> /var/log/pico.log'"
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
echo "Recent logs:"
journalctl -u pico-monitor -n 10 --no-pager
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

# 6. Reload everything
print_msg "Activating services..." "$YELLOW"

# Reload systemd and udev
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger

# Enable and start the monitor service
systemctl enable pico-monitor.service
systemctl restart pico-monitor.service

print_msg "✓ Services activated" "$GREEN"

# 7. Test if device is currently connected
if [ -e /dev/ttyACM0 ]; then
    print_msg "Device detected, sending test data..." "$YELLOW"
    /usr/local/bin/usb_ip_sender.py --once
    print_msg "✓ Test data sent" "$GREEN"
fi

# Done!
echo
print_msg "=====================================" "$GREEN"
print_msg "   LCD IP Address displayer     " "$GREEN"
print_msg "=====================================" "$GREEN"
echo
print_msg "HOW IT WORKS:" "$YELLOW"
print_msg "1. Monitor service runs continuously" "$NC"
print_msg "2. Detects when Pico connects/disconnects" "$NC"
print_msg "3. Sends data immediately on connection" "$NC"
print_msg "4. Keeps sending every 15 seconds" "$NC"
echo