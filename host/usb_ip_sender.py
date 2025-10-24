#!/usr/bin/env python3
"""
USB IP Display Sender Script - Improved Version
Features:
- Responds to refresh requests from Pico
- Continuously monitors for device requests
- Sends data when requested or on initial connection
"""

import serial
import subprocess
import time
import sys
import os
import threading
from datetime import datetime

# Configuration
SERIAL_PORT = "/dev/ttyACM0"  # Default Pico serial port
BAUD_RATE = 115200
INITIAL_SEND_COUNT = 3  # Send data this many times on startup
MONITOR_MODE = False  # Set to True to keep running and respond to requests

def get_ip_address():
    """Get the primary IP address of the host"""
    try:
        # Method 1: Using hostname -I
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        ips = result.stdout.strip().split()
        
        if ips:
            # Filter out IPv6 addresses, keep only IPv4
            ipv4_ips = [ip for ip in ips if ':' not in ip and '.' in ip]
            
            # Prioritize non-local addresses
            for ip in ipv4_ips:
                if not ip.startswith('127.'):
                    return ip
            
            # Fall back to first available IP
            return ipv4_ips[0] if ipv4_ips else ips[0]
        
        # Method 2: Using ip command as fallback
        result = subprocess.run(['ip', 'route', 'get', '1'], capture_output=True, text=True)
        if result.returncode == 0:
            parts = result.stdout.split()
            if 'src' in parts:
                src_index = parts.index('src')
                if src_index + 1 < len(parts):
                    return parts[src_index + 1]
        
        return "No IP found"
        
    except Exception as e:
        return f"Error: {str(e)[:10]}"

def get_interface_ip(interface):
    """Get IP address for a specific network interface"""
    try:
        result = subprocess.run(
            ['ip', 'addr', 'show', interface], 
            capture_output=True, 
            text=True
        )
        
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if 'inet ' in line and not 'inet6' in line:
                    ip = line.split()[1].split('/')[0]
                    return ip
    except:
        pass
    
    return None

def get_ssh_status():
    """Check if SSH service is running"""
    try:
        # Try systemctl first
        for service_name in ['ssh', 'sshd']:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name], 
                capture_output=True, 
                text=True
            )
            if result.returncode == 0 and result.stdout.strip() == 'active':
                return "SSH: ON"
        
        # Check if SSH process is running
        result = subprocess.run(['pgrep', '-x', 'sshd'], capture_output=True, text=True)
        if result.stdout.strip():
            return "SSH: ON"
        
        return "SSH: OFF"
        
    except:
        return "SSH: ???"

def get_hostname():
    """Get the system hostname"""
    try:
        result = subprocess.run(['hostname'], capture_output=True, text=True)
        return result.stdout.strip()[:16]
    except:
        return "Unknown"

def format_display_data():
    """Format data for LCD display"""
    ip = get_ip_address()[:16]
    ssh = get_ssh_status()[:16]
    return f"{ip}|{ssh}"

def send_to_display(ser, data):
    """Send data to the Pico display via serial"""
    try:
        ser.write(f"{data}\n".encode())
        ser.flush()
        return True
    except Exception as e:
        print(f"Error sending data: {e}", file=sys.stderr)
        return False

def find_pico_port():
    """Find the Pico's serial port"""
    possible_ports = [
        "/dev/ttyACM0",
        "/dev/ttyACM1",
        "/dev/ttyUSB0",
        "/dev/ttyUSB1",
        "/dev/pico_display",
    ]
    
    for port in possible_ports:
        if os.path.exists(port):
            return port
    
    # Try to find any ACM device
    try:
        result = subprocess.run(['ls', '/dev/ttyACM*'], shell=True, capture_output=True, text=True)
        if result.stdout:
            ports = result.stdout.strip().split('\n')
            if ports:
                return ports[0]
    except:
        pass
    
    return None

def monitor_for_requests(ser):
    """Monitor serial port for refresh requests from Pico"""
    os.system('logger -t usb-ip-display "Starting monitor mode"')
    print("Monitor mode: Listening for refresh requests...")
    
    last_sent_time = 0
    send_interval = 1  # Minimum seconds between sends
    
    while True:
        try:
            # Check for incoming data
            if ser.in_waiting > 0:
                try:
                    incoming = ser.read(ser.in_waiting).decode('utf-8').strip()
                    
                    # Check for refresh request
                    if "REFRESH" in incoming:
                        current_time = time.time()
                        
                        # Rate limit sends
                        if current_time - last_sent_time >= send_interval:
                            print(f"Received refresh request at {datetime.now()}")
                            
                            # Get fresh data and send
                            display_data = format_display_data()
                            if send_to_display(ser, display_data):
                                print(f"Sent: {display_data}")
                                os.system(f'logger -t usb-ip-display "Sent on request: {display_data}"')
                            
                            # Send acknowledgment
                            ser.write(b"REFRESH_ACK\n")
                            
                            last_sent_time = current_time
                        
                except UnicodeDecodeError:
                    pass
            
            time.sleep(0.1)
            
        except KeyboardInterrupt:
            print("\nMonitor mode stopped")
            break
        except Exception as e:
            print(f"Monitor error: {e}", file=sys.stderr)
            time.sleep(1)

def main():
    """Main function"""
    global MONITOR_MODE
    
    # Check for command line arguments
    if len(sys.argv) > 1:
        if sys.argv[1] == '--monitor':
            MONITOR_MODE = True
        elif sys.argv[1] == '--test':
            # Test mode
            print("System Information:")
            print(f"  IP Address: {get_ip_address()}")
            print(f"  SSH Status: {get_ssh_status()}")
            print(f"  Hostname: {get_hostname()}")
            print(f"  Display output: {format_display_data()}")
            sys.exit(0)
    
    # Log to syslog
    os.system(f'logger -t usb-ip-display "Starting IP sender script (monitor={MONITOR_MODE})"')
    
    # Find serial port
    serial_port = find_pico_port()
    if not serial_port:
        serial_port = SERIAL_PORT
    
    # Get initial data
    display_data = format_display_data()
    
    # Log what we're sending
    os.system(f'logger -t usb-ip-display "Initial data: {display_data}"')
    
    # Try to open serial port
    max_retries = 5
    for attempt in range(max_retries):
        try:
            if attempt > 0:
                time.sleep(0.5)
            
            # Open serial connection
            with serial.Serial(serial_port, BAUD_RATE, timeout=1) as ser:
                # Wait for port to be ready
                time.sleep(1)
                
                # Send initial data multiple times
                print(f"Sending initial data {INITIAL_SEND_COUNT} times...")
                for i in range(INITIAL_SEND_COUNT):
                    if send_to_display(ser, display_data):
                        print(f"  [{i+1}/{INITIAL_SEND_COUNT}] Sent: {display_data}")
                        os.system(f'logger -t usb-ip-display "Initial send {i+1}: {display_data}"')
                    time.sleep(0.2)
                
                # Enter monitor mode if requested
                if MONITOR_MODE:
                    monitor_for_requests(ser)
                else:
                    print("Initial send complete. Use --monitor flag to keep listening for requests.")
                
                break
                
        except serial.SerialException as e:
            if attempt == max_retries - 1:
                error_msg = f"Failed to open {serial_port}: {e}"
                print(error_msg, file=sys.stderr)
                os.system(f'logger -t usb-ip-display "{error_msg}"')
                sys.exit(1)
            else:
                os.system(f'logger -t usb-ip-display "Retry {attempt + 1}/{max_retries}: {e}"')
                
        except Exception as e:
            error_msg = f"Unexpected error: {e}"
            print(error_msg, file=sys.stderr)
            os.system(f'logger -t usb-ip-display "{error_msg}"')
            sys.exit(1)

if __name__ == "__main__":
    main()