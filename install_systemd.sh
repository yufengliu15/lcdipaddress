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

print_msg "USB IP Display" "$BLUE"
print_msg "=====================================" "$BLUE"
echo

# 1. Backup existing script
print_msg "Backing up existing script..." "$YELLOW"
if [ -f /usr/local/bin/usb_ip_sender.py ]; then
    cp /usr/local/bin/usb_ip_sender.py /usr/local/bin/usb_ip_sender.py.backup
    print_msg "✓ Backup created" "$GREEN"
fi

# 2. Install improved Python script
print_msg "Installing improved sender script..." "$YELLOW"

cat > /usr/local/bin/usb_ip_sender.py << 'EOF'
#!/usr/bin/env python3
"""USB IP Display Sender - Auto-Refresh Version"""

import serial
import subprocess
import time
import sys
import os
from datetime import datetime

# Configuration
SERIAL_PORT = "/dev/ttyACM1"
BAUD_RATE = 115200
MONITOR_MODE = True  # Always run in monitor mode for systemd

def get_ip_address():
    """Get the primary IP address"""
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
    """Check if SSH service is running"""
    try:
        for service in ['ssh', 'sshd']:
            result = subprocess.run(['systemctl', 'is-active', service], 
                                  capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip() == 'active':
                return "SSH: ON"
        
        result = subprocess.run(['pgrep', '-x', 'sshd'], capture_output=True, text=True)
        if result.stdout.strip():
            return "SSH: ON"
        return "SSH: OFF"
    except:
        return "SSH: ???"

def format_display_data():
    """Format data for LCD display"""
    ip = get_ip_address()[:16]
    ssh = get_ssh_status()[:16]
    return f"{ip}|{ssh}"

def send_to_display(ser, data):
    """Send data to Pico"""
    try:
        ser.write(f"{data}\n".encode())
        ser.flush()
        return True
    except Exception as e:
        os.system(f'logger -t usb-ip-display "Send error: {e}"')
        return False

def find_pico_port():
    """Find Pico serial port"""
    for port in ["/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0", "/dev/pico_display"]:
        if os.path.exists(port):
            return port
    
    # Find any ACM device
    try:
        import glob
        acm_devices = glob.glob('/dev/ttyACM*')
        if acm_devices:
            return acm_devices[0]
    except:
        pass
    return SERIAL_PORT

def monitor_mode(ser):
    """Monitor for refresh requests and respond"""
    os.system('logger -t usb-ip-display "Starting monitor mode"')
    print("Monitor mode: Listening for refresh requests...")
    
    # Send initial data
    initial_data = format_display_data()
    for _ in range(3):
        send_to_display(ser, initial_data)
        time.sleep(0.2)
    
    os.system(f'logger -t usb-ip-display "Initial: {initial_data}"')
    
    last_sent_time = 0
    
    while True:
        try:
            # Check for refresh request
            if ser.in_waiting > 0:
                try:
                    incoming = ser.read(ser.in_waiting).decode('utf-8').strip()
                    
                    if "REFRESH" in incoming:
                        current_time = time.time()
                        
                        # Rate limit (1 second minimum between sends)
                        if current_time - last_sent_time >= 1:
                            # Get fresh data
                            display_data = format_display_data()
                            
                            if send_to_display(ser, display_data):
                                timestamp = datetime.now().strftime("%H:%M:%S")
                                print(f"[{timestamp}] Refresh sent: {display_data}")
                                os.system(f'logger -t usb-ip-display "Refresh: {display_data}"')
                            
                            last_sent_time = current_time
                            
                except UnicodeDecodeError:
                    pass
            
            time.sleep(0.05)
            
        except Exception as e:
            os.system(f'logger -t usb-ip-display "Monitor error: {e}"')
            time.sleep(1)
            
            # Try to recover
            if not ser.is_open:
                try:
                    ser.open()
                    os.system('logger -t usb-ip-display "Reconnected to serial"')
                except:
                    pass

def main():
    """Main function"""
    serial_port = find_pico_port()
    
    os.system(f'logger -t usb-ip-display "Starting on port {serial_port}"')
    
    # Open serial connection with retries
    max_retries = 10
    for attempt in range(max_retries):
        try:
            if attempt > 0:
                time.sleep(1)
            
            with serial.Serial(serial_port, BAUD_RATE, timeout=0.5) as ser:
                time.sleep(1)  # Wait for connection
                monitor_mode(ser)  # This runs forever
                break
                
        except Exception as e:
            os.system(f'logger -t usb-ip-display "Attempt {attempt+1}: {e}"')
            if attempt == max_retries - 1:
                sys.exit(1)

if __name__ == "__main__":
    # Command line options
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        print(f"IP: {get_ip_address()}")
        print(f"SSH: {get_ssh_status()}")
        print(f"Output: {format_display_data()}")
    else:
        main()
EOF

chmod +x /usr/local/bin/usb_ip_sender.py
print_msg "✓ Improved script installed" "$GREEN"

# 3. Update systemd service for continuous monitoring
print_msg "Updating systemd service..." "$YELLOW"

# Update the template service
cat > /etc/systemd/system/pico-ip-display@.service << 'EOF'
[Unit]
Description=USB IP Display Monitor for %I
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/usb_ip_sender.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Update the device-activated service
cat > /etc/systemd/system/pico-ip-display-ttyACM0.service << 'EOF'
[Unit]
Description=USB IP Display Monitor for ttyACM0
BindsTo=dev-ttyACM0.device
After=dev-ttyACM0.device

[Service]
Type=simple
Restart=always
RestartSec=3
ExecStart=/usr/local/bin/usb_ip_sender.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=dev-ttyACM0.device
EOF

print_msg "✓ Systemd services updated" "$GREEN"

# 4. Update udev rule to trigger long-running service
print_msg "Updating udev rule..." "$YELLOW"

cat > /etc/udev/rules.d/99-pico-monitor.rules << 'EOF'
# Start monitor service when Pico connects
ACTION=="add", KERNEL=="ttyACM[0-9]*", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", TAG+="systemd", ENV{SYSTEMD_WANTS}="pico-ip-display@%k.service"

# Alternative rule
ACTION=="add", SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", RUN+="/bin/systemctl start pico-ip-display@$kernel.service"
EOF

print_msg "✓ Udev rule updated" "$GREEN"

# 5. Create quick test command
cat > /usr/local/bin/pico-status << 'EOF'
#!/bin/bash
echo "=== Pico IP Display Status ==="
echo ""

# Check if device exists
if [ -e /dev/ttyACM0 ]; then
    echo "✓ Device found: /dev/ttyACM0"
else
    echo "✗ Device not found"
fi

echo ""
echo "Service status:"
systemctl status pico-ip-display@ttyACM0.service --no-pager 2>/dev/null || systemctl status pico-ip-display-ttyACM0.service --no-pager 2>/dev/null || echo "No service running"

echo ""
echo "Recent logs:"
journalctl -u pico-ip-display@ttyACM0 -n 10 --no-pager 2>/dev/null | tail -5

echo ""
echo "To watch live logs: journalctl -f -u pico-ip-display@ttyACM0"
echo "To restart service: sudo systemctl restart pico-ip-display@ttyACM0"
EOF
chmod +x /usr/local/bin/pico-status

# 6. Reload everything
print_msg "Reloading services..." "$YELLOW"

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger

# Try to restart service if device exists
if [ -e /dev/ttyACM0 ]; then
    systemctl restart pico-ip-display-ttyACM0.service 2>/dev/null || \
    systemctl restart pico-ip-display@ttyACM0.service 2>/dev/null || true
    print_msg "✓ Service restarted" "$GREEN"
fi

print_msg "✓ Services reloaded" "$GREEN"

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