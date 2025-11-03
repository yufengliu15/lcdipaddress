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