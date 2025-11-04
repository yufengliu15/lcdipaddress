#!/bin/bash
# USB IP Display 

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

print_msg "USB IP Display - Self-Contained Installer" "$BLUE"
print_msg "==========================================" "$BLUE"
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

# 4. Create the sender script directly (embedded)
print_msg "Installing sender script..." "$YELLOW"

cat > /usr/local/bin/usb_ip_sender.py << 'PYTHON_SCRIPT_EOF'
#!/usr/bin/env python3
"""
USB IP Display Sender - Robust Version
Features:
- Sends data immediately on connection
- Resends every 15 seconds automatically
- Handles disconnections gracefully
- No need for Pico to request refreshes
"""

import serial
import serial.tools.list_ports
import subprocess
import time
import sys
import os
import signal
from datetime import datetime

# Configuration
BAUD_RATE = 115200
SEND_INTERVAL = 15  # Send data every 15 seconds
INITIAL_DELAY = 2   # Wait this long after connection before first send
RETRY_DELAY = 1     # Wait between connection attempts

# Global flag for clean shutdown
running = True

def signal_handler(sig, frame):
    global running
    running = False
    print("\nShutting down...")
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def get_ip_address():
    """Get the primary IP address"""
    try:
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=2)
        ips = result.stdout.strip().split()
        
        if ips:
            # Get IPv4 addresses only
            ipv4_ips = [ip for ip in ips if ':' not in ip and '.' in ip]
            
            # Prioritize non-localhost addresses
            for ip in ipv4_ips:
                if not ip.startswith('127.') and not ip.startswith('169.254.'):
                    return ip
            
            # Fall back to any IPv4
            if ipv4_ips:
                return ipv4_ips[0]
            
            # Last resort - any IP
            if ips:
                return ips[0]
        
        return "No IP found"
        
    except Exception as e:
        return "IP Error"

def get_ssh_status():
    """Check if SSH service is running"""
    try:
        # Check systemd services
        for service in ['ssh', 'sshd', 'openssh-server']:
            try:
                result = subprocess.run(
                    ['systemctl', 'is-active', service], 
                    capture_output=True, 
                    text=True,
                    timeout=1
                )
                if result.returncode == 0 and result.stdout.strip() == 'active':
                    return "SSH: ON"
            except:
                continue
        
        # Check process
        try:
            result = subprocess.run(['pgrep', 'sshd'], capture_output=True, text=True, timeout=1)
            if result.stdout.strip():
                return "SSH: ON"
        except:
            pass
        
        return "SSH: OFF"
        
    except Exception:
        return "SSH: ???"

def find_pico_port():
    """Find the Pico's serial port"""
    # First, try common ports
    common_ports = ['/dev/ttyACM0', '/dev/ttyACM1', '/dev/ttyUSB0']
    for port in common_ports:
        if os.path.exists(port):
            return port
    
    # Try to find using serial.tools
    try:
        ports = serial.tools.list_ports.comports()
        for port in ports:
            # Check for Raspberry Pi vendor ID
            if port.vid == 0x2e8a:
                return port.device
            # Check for common CDC ACM devices
            if 'ACM' in port.device or 'USB' in port.device:
                return port.device
    except:
        pass
    
    # Last resort - find any ttyACM device
    import glob
    acm_devices = glob.glob('/dev/ttyACM*')
    if acm_devices:
        return acm_devices[0]
    
    return None

def wait_for_device():
    """Wait for Pico device to appear"""
    print("Waiting for Pico device...")
    os.system('logger -t usb-ip-display "Waiting for device..."')
    
    while running:
        port = find_pico_port()
        if port:
            print(f"Found device at {port}")
            os.system(f'logger -t usb-ip-display "Device found at {port}"')
            return port
        time.sleep(RETRY_DELAY)
    
    return None

def send_data_to_pico(ser):
    """Send IP and SSH data to Pico"""
    try:
        ip = get_ip_address()[:16]
        ssh = get_ssh_status()[:16]
        data = f"{ip}|{ssh}"
        
        # Send multiple times to ensure delivery
        for _ in range(2):
            ser.write(f"{data}\n".encode())
            ser.flush()
            time.sleep(0.1)
        
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"[{timestamp}] Sent: {data}")
        os.system(f'logger -t usb-ip-display "Sent: {data}"')
        
        return True
        
    except Exception as e:
        print(f"Send error: {e}")
        os.system(f'logger -t usb-ip-display "Send error: {e}"')
        return False

def handle_device_connection(port):
    """Handle connection to a specific device"""
    print(f"Connecting to {port}...")
    os.system(f'logger -t usb-ip-display "Connecting to {port}"')
    
    try:
        # Open serial connection
        ser = serial.Serial(port, BAUD_RATE, timeout=1)
        
        # Wait for device to be ready
        time.sleep(INITIAL_DELAY)
        
        # Clear any pending data
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        
        print(f"Connected to {port}")
        os.system(f'logger -t usb-ip-display "Connected successfully"')
        
        # Send initial data immediately
        send_data_to_pico(ser)
        
        last_send_time = time.time()
        
        # Main loop - send data periodically
        while running:
            try:
                current_time = time.time()
                
                # Send data every interval
                if current_time - last_send_time >= SEND_INTERVAL:
                    if send_data_to_pico(ser):
                        last_send_time = current_time
                    else:
                        # Send failed, device might be disconnected
                        break
                
                # Small sleep to prevent CPU spinning
                time.sleep(0.5)
                
                # Check if port still exists
                if not os.path.exists(port):
                    print(f"Device disconnected from {port}")
                    break
                    
            except serial.SerialException as e:
                print(f"Serial error: {e}")
                break
            except Exception as e:
                print(f"Loop error: {e}")
                time.sleep(1)
        
        # Close connection
        try:
            ser.close()
        except:
            pass
            
    except serial.SerialException as e:
        print(f"Failed to connect to {port}: {e}")
        os.system(f'logger -t usb-ip-display "Connection failed: {e}"')
    except Exception as e:
        print(f"Unexpected error: {e}")
        os.system(f'logger -t usb-ip-display "Unexpected error: {e}"')

def main():
    """Main function - handles device connections and reconnections"""
    print("USB IP Display Sender - Robust Version")
    print("Press Ctrl+C to stop")
    print("-" * 40)
    
    os.system('logger -t usb-ip-display "Starting robust sender"')
    
    while running:
        try:
            # Wait for device
            port = wait_for_device()
            if not port:
                break
            
            # Handle the connection
            handle_device_connection(port)
            
            if running:
                print("Device disconnected, waiting for reconnection...")
                os.system('logger -t usb-ip-display "Device disconnected, waiting..."')
                time.sleep(RETRY_DELAY)
            
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Main loop error: {e}")
            os.system(f'logger -t usb-ip-display "Main error: {e}"')
            time.sleep(RETRY_DELAY)
    
    print("Shutdown complete")
    os.system('logger -t usb-ip-display "Shutdown complete"')

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        print("Test Mode:")
        print(f"  IP: {get_ip_address()}")
        print(f"  SSH: {get_ssh_status()}")
        print(f"  Port: {find_pico_port()}")
    else:
        main()
PYTHON_SCRIPT_EOF

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
${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --test
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
    ${PYTHON_PATH} /usr/local/bin/usb_ip_sender.py --test
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
