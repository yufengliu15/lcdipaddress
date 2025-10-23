#!/usr/bin/env python3
"""
USB IP Display Sender Script
Sends host IP address and SSH status to Pico display device

This script is triggered by udev when a Raspberry Pi Pico is connected.
It collects the system's IP address and SSH status, then sends this
information via USB serial to the Pico for display on an LCD.

Author: Your Name
License: MIT
"""

import serial
import subprocess
import time
import sys
import os
from datetime import datetime

# Configuration
SERIAL_PORT = "/dev/ttyACM0"  # Default Pico serial port
BAUD_RATE = 115200
RETRY_ATTEMPTS = 5
RETRY_DELAY = 0.5

def get_ip_address():
    """
    Get the primary IP address of the host.
    
    Returns:
        str: IP address or error message
    """
    try:
        # Method 1: Using hostname -I (most reliable for Linux)
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
            # Parse output like: "1.0.0.0 via 192.168.1.1 dev eth0 src 192.168.1.100"
            parts = result.stdout.split()
            if 'src' in parts:
                src_index = parts.index('src')
                if src_index + 1 < len(parts):
                    return parts[src_index + 1]
        
        return "No IP found"
        
    except Exception as e:
        return f"Error: {str(e)[:10]}"

def get_interface_ip(interface):
    """
    Get IP address for a specific network interface.
    
    Args:
        interface (str): Network interface name (e.g., 'eth0', 'wlan0')
    
    Returns:
        str: IP address or None if not found
    """
    try:
        result = subprocess.run(
            ['ip', 'addr', 'show', interface], 
            capture_output=True, 
            text=True
        )
        
        if result.returncode == 0:
            # Look for inet line
            for line in result.stdout.split('\n'):
                if 'inet ' in line and not 'inet6' in line:
                    # Extract IP from line like: "inet 192.168.1.100/24 brd ..."
                    ip = line.split()[1].split('/')[0]
                    return ip
    except:
        pass
    
    return None

def get_ssh_status():
    """
    Check if SSH service is running.
    
    Returns:
        str: SSH status message
    """
    try:
        # Try systemctl first (systemd systems like modern Raspbian)
        for service_name in ['ssh', 'sshd']:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name], 
                capture_output=True, 
                text=True
            )
            if result.returncode == 0 and result.stdout.strip() == 'active':
                return "SSH: ON"
        
        # Check if SSH process is running (fallback method)
        result = subprocess.run(['pgrep', '-x', 'sshd'], capture_output=True, text=True)
        if result.stdout.strip():
            return "SSH: ON"
        
        return "SSH: OFF"
        
    except FileNotFoundError:
        # For non-systemd systems, just check process
        try:
            result = subprocess.run(['pgrep', '-x', 'sshd'], capture_output=True, text=True)
            if result.stdout.strip():
                return "SSH: ON"
            return "SSH: OFF"
        except:
            return "SSH: ???"
    except:
        return "SSH: ???"

def get_hostname():
    """
    Get the system hostname.
    
    Returns:
        str: Hostname (truncated if needed)
    """
    try:
        result = subprocess.run(['hostname'], capture_output=True, text=True)
        return result.stdout.strip()[:16]  # Limit to 16 chars for LCD
    except:
        return "Unknown"

def get_system_info():
    """
    Get additional system information for display.
    
    Returns:
        dict: System information
    """
    info = {
        'ip': get_ip_address(),
        'ssh': get_ssh_status(),
        'hostname': get_hostname(),
        'eth0': get_interface_ip('eth0'),
        'wlan0': get_interface_ip('wlan0'),
    }
    
    # Add current time
    info['time'] = datetime.now().strftime("%H:%M:%S")
    
    return info

def format_display_data(info, mode='default'):
    """
    Format data for LCD display (2 lines, 16 chars each).
    
    Args:
        info (dict): System information
        mode (str): Display mode
    
    Returns:
        str: Formatted display string with | separator
    """
    if mode == 'default':
        # Line 1: IP address, Line 2: SSH status
        line1 = info['ip'][:16]
        line2 = info['ssh'][:16]
        
    elif mode == 'hostname':
        # Line 1: Hostname, Line 2: IP
        line1 = info['hostname'][:16]
        line2 = info['ip'][:16]
        
    elif mode == 'interfaces':
        # Show ethernet and wifi IPs
        eth_ip = info['eth0'] or "No ethernet"
        wlan_ip = info['wlan0'] or "No wifi"
        line1 = f"E:{eth_ip}"[:16]
        line2 = f"W:{wlan_ip}"[:16]
        
    elif mode == 'time':
        # Line 1: IP, Line 2: Current time
        line1 = info['ip'][:16]
        line2 = f"Time: {info['time']}"[:16]
        
    else:
        line1 = info['ip'][:16]
        line2 = info['ssh'][:16]
    
    return f"{line1}|{line2}"

def send_to_display(ser, data):
    """
    Send data to the Pico display via serial.
    
    Args:
        ser: Serial connection object
        data (str): Data to send
    
    Returns:
        bool: True if successful
    """
    try:
        # Send data with newline terminator
        ser.write(f"{data}\n".encode())
        ser.flush()
        return True
    except Exception as e:
        print(f"Error sending data: {e}", file=sys.stderr)
        return False

def find_pico_port():
    """
    Find the Pico's serial port if not at default location.
    
    Returns:
        str: Serial port path or None
    """
    possible_ports = [
        "/dev/ttyACM0",
        "/dev/ttyACM1",
        "/dev/ttyUSB0",
        "/dev/ttyUSB1",
        "/dev/pico_display",  # Custom symlink from udev
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

def main():
    """Main function."""
    # Log to syslog for debugging
    os.system(f'logger -t usb-ip-display "Starting IP sender script"')
    
    # Find serial port
    serial_port = find_pico_port()
    if not serial_port:
        serial_port = SERIAL_PORT  # Fall back to default
    
    # Get system information
    info = get_system_info()
    
    # Format display data
    display_data = format_display_data(info, mode='default')
    
    # Log what we're sending
    os.system(f'logger -t usb-ip-display "Sending: {display_data}"')
    
    # Try to open serial port with retries
    for attempt in range(RETRY_ATTEMPTS):
        try:
            # Wait a bit for device to be ready
            if attempt > 0:
                time.sleep(RETRY_DELAY)
            
            # Open serial connection
            with serial.Serial(serial_port, BAUD_RATE, timeout=1) as ser:
                # Wait for port to be ready
                time.sleep(0.5)
                
                # Send data multiple times to ensure delivery
                success_count = 0
                for _ in range(3):
                    if send_to_display(ser, display_data):
                        success_count += 1
                        os.system(f'logger -t usb-ip-display "Successfully sent: {display_data}"')
                    time.sleep(0.1)
                
                if success_count > 0:
                    print(f"Sent to display: {display_data}")
                    break
                
        except serial.SerialException as e:
            if attempt == RETRY_ATTEMPTS - 1:
                error_msg = f"Failed to open {serial_port} after {RETRY_ATTEMPTS} attempts: {e}"
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
    # Allow command-line testing with different modes
    if len(sys.argv) > 1:
        mode = sys.argv[1]
        info = get_system_info()
        
        if mode == '--test':
            # Test mode: print info without sending
            print("System Information:")
            print(f"  IP Address: {info['ip']}")
            print(f"  SSH Status: {info['ssh']}")
            print(f"  Hostname: {info['hostname']}")
            print(f"  Ethernet: {info.get('eth0', 'None')}")
            print(f"  WiFi: {info.get('wlan0', 'None')}")
            print(f"\nDisplay output: {format_display_data(info)}")
        else:
            # Send with specified mode
            print(f"Mode: {mode}")
            print(format_display_data(info, mode))
    else:
        # Normal operation
        main()