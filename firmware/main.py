"""
USB IP Display Device - Improved Pico Firmware
Features:
- Displays IP address forever (no timeout to "waiting")
- Auto-refreshes every 15 seconds
- Shows countdown timer when no recent data
- Keeps last known IP displayed
"""

import board
import busio
import time
import usb_cdc
import supervisor

# Try to import LCD libraries
try:
    from lcd_api import LcdApi
    from i2c_lcd import I2cLcd
    LCD_AVAILABLE = True
except ImportError:
    LCD_AVAILABLE = False
    print("LCD libraries not found - running in simple mode")

# Configuration
I2C_ADDR = 0x27  # Common I2C address for LCD (try 0x3F if this doesn't work)
I2C_NUM_ROWS = 2
I2C_NUM_COLS = 16
I2C_SDA = board.GP4
I2C_SCL = board.GP5

# Timing configuration
REFRESH_INTERVAL = 15  # Request new data every 15 seconds
DISPLAY_UPDATE_INTERVAL = 1  # Update countdown every 1 second

class USBIPDisplay:
    def __init__(self):
        """Initialize the display and serial connection"""
        self.lcd = None
        self.serial = None
        self.last_ip = "No IP yet"
        self.last_ssh = "SSH: ???"
        self.last_data_time = time.monotonic()
        self.last_refresh_request = time.monotonic()
        self.startup_time = time.monotonic()
        self.has_received_data = False
        
        # Initialize components
        if LCD_AVAILABLE:
            self.init_lcd()
        self.init_serial()
        
    def init_lcd(self):
        """Initialize the I2C LCD display"""
        try:
            # Create I2C bus
            i2c = busio.I2C(I2C_SCL, I2C_SDA, frequency=100000)
            
            # Wait for I2C to be ready
            while not i2c.try_lock():
                pass
            
            # Scan for I2C devices
            devices = i2c.scan()
            i2c.unlock()
            
            if devices:
                print(f"I2C devices found: {[hex(d) for d in devices]}")
                if I2C_ADDR not in devices and devices:
                    actual_addr = devices[0]
                    print(f"Using detected I2C address: {hex(actual_addr)}")
                else:
                    actual_addr = I2C_ADDR
            else:
                print("No I2C devices found!")
                actual_addr = I2C_ADDR
            
            # Initialize LCD
            self.lcd = I2cLcd(i2c, actual_addr, I2C_NUM_ROWS, I2C_NUM_COLS)
            self.lcd.clear()
            
            # Show startup message
            self.lcd.putstr("USB IP Display")
            self.lcd.move_to(0, 1)
            self.lcd.putstr("Starting...")
            
            print("LCD initialized successfully")
            
        except Exception as e:
            print(f"LCD initialization error: {e}")
            self.lcd = None
    
    def init_serial(self):
        """Initialize USB serial connection"""
        try:
            self.serial = usb_cdc.console
            
            if self.serial:
                self.serial.timeout = 0.1
                print("Serial initialized successfully")
            else:
                print("No serial connection available")
                
        except Exception as e:
            print(f"Serial initialization error: {e}")
            self.serial = None
    
    def send_refresh_request(self):
        """Send a request to the host for fresh data"""
        if self.serial:
            try:
                # Send special command to request refresh
                self.serial.write(b"REFRESH\n")
                self.serial.flush()
                print("Sent refresh request")
            except Exception as e:
                print(f"Error sending refresh request: {e}")
    
    def display_data(self, line1, line2):
        """Display data on LCD"""
        if not self.lcd:
            return False
            
        try:
            self.lcd.clear()
            
            # Display line 1
            self.lcd.putstr(line1[:16])
            
            # Display line 2
            if line2:
                self.lcd.move_to(0, 1)
                self.lcd.putstr(line2[:16])
            
            return True
            
        except Exception as e:
            print(f"Display error: {e}")
            return False
    
    def display_with_countdown(self):
        """Display last known data with countdown to next refresh"""
        if not self.lcd or not self.has_received_data:
            return
            
        try:
            current_time = time.monotonic()
            time_until_refresh = REFRESH_INTERVAL - (current_time - self.last_refresh_request)
            
            if time_until_refresh < 0:
                time_until_refresh = 0
            
            # Update display with countdown
            self.lcd.clear()
            
            # Line 1: IP address (persistent)
            self.lcd.putstr(self.last_ip[:16])
            
            # Line 2: SSH status + countdown
            if time_until_refresh > 0:
                # Show SSH status with countdown
                ssh_part = self.last_ssh[:8]  # Shortened to fit countdown
                countdown_str = f" R:{int(time_until_refresh)}s"
                line2 = (ssh_part + countdown_str)[:16]
            else:
                # Just show SSH status when refreshing
                line2 = self.last_ssh[:16]
            
            self.lcd.move_to(0, 1)
            self.lcd.putstr(line2)
            
        except Exception as e:
            print(f"Display update error: {e}")
    
    def show_waiting_with_countdown(self):
        """Show waiting message with countdown to next attempt"""
        if not self.lcd:
            return
            
        try:
            current_time = time.monotonic()
            time_until_refresh = REFRESH_INTERVAL - (current_time - self.last_refresh_request)
            
            if time_until_refresh < 0:
                time_until_refresh = 0
            
            self.lcd.clear()
            self.lcd.putstr("Waiting for host")
            self.lcd.move_to(0, 1)
            self.lcd.putstr(f"Refresh in {int(time_until_refresh)}s")
            
        except Exception as e:
            print(f"Waiting display error: {e}")
    
    def parse_data(self, data):
        """Parse incoming data format: 'line1|line2'"""
        try:
            data = data.strip()
            
            # Ignore refresh acknowledgments
            if data.upper() == "REFRESH_ACK":
                return None, None
            
            if '|' in data:
                parts = data.split('|', 1)
                return parts[0], parts[1] if len(parts) > 1 else ""
            else:
                return data, ""
                
        except Exception as e:
            print(f"Parse error: {e}")
            return None, None
    
    def run(self):
        """Main loop"""
        print("Starting USB IP Display (Improved)...")
        
        last_display_update = time.monotonic()
        
        while True:
            try:
                current_time = time.monotonic()
                
                # Check if it's time to request a refresh
                if current_time - self.last_refresh_request >= REFRESH_INTERVAL:
                    self.send_refresh_request()
                    self.last_refresh_request = current_time
                
                # Check for serial data
                if self.serial and self.serial.in_waiting > 0:
                    raw_data = self.serial.read(self.serial.in_waiting)
                    
                    if raw_data:
                        try:
                            data_str = raw_data.decode('utf-8')
                            
                            # Handle multiple messages
                            for line in data_str.split('\n'):
                                if line.strip():
                                    line1, line2 = self.parse_data(line)
                                    
                                    if line1:
                                        print(f"Received: {line1} | {line2}")
                                        
                                        # Update stored data
                                        self.last_ip = line1
                                        self.last_ssh = line2
                                        self.last_data_time = current_time
                                        self.has_received_data = True
                                        
                                        # Immediately display new data
                                        if self.lcd:
                                            self.display_data(line1, line2)
                                        
                                        # Reset refresh timer on new data
                                        self.last_refresh_request = current_time
                                        
                        except UnicodeDecodeError:
                            print("Decode error - invalid UTF-8")
                
                # Update display with countdown every second
                if self.lcd and current_time - last_display_update >= DISPLAY_UPDATE_INTERVAL:
                    if self.has_received_data:
                        # We have data - keep showing it with countdown
                        self.display_with_countdown()
                    else:
                        # No data yet - show waiting with countdown
                        self.show_waiting_with_countdown()
                    
                    last_display_update = current_time
                
                # Small delay to prevent CPU spinning
                time.sleep(0.01)
                
            except KeyboardInterrupt:
                print("\nShutting down...")
                if self.lcd:
                    self.lcd.clear()
                    self.lcd.putstr("Shutting down...")
                break
                
            except Exception as e:
                print(f"Main loop error: {e}")
                time.sleep(0.5)

class SimpleUSBReceiver:
    """Simple version for testing without LCD connected"""
    
    def __init__(self):
        self.serial = usb_cdc.console
        if self.serial:
            self.serial.timeout = 0.1
        self.last_refresh = time.monotonic()
        self.last_ip = "No IP"
        self.last_ssh = "SSH: ???"
    
    def run(self):
        print("Simple USB Receiver (no LCD) - With Auto-Refresh")
        print("Waiting for data...")
        
        while True:
            try:
                current_time = time.monotonic()
                
                # Send refresh request every 15 seconds
                if current_time - self.last_refresh >= REFRESH_INTERVAL:
                    if self.serial:
                        self.serial.write(b"REFRESH\n")
                        self.serial.flush()
                        print(f"[{int(current_time)}s] Sent refresh request")
                    self.last_refresh = current_time
                
                # Check for incoming data
                if self.serial and self.serial.in_waiting > 0:
                    raw_data = self.serial.read(self.serial.in_waiting)
                    if raw_data:
                        try:
                            data_str = raw_data.decode('utf-8').strip()
                            if data_str and data_str != "REFRESH_ACK":
                                print(f"[{int(current_time)}s] Received: {data_str}")
                                if '|' in data_str:
                                    parts = data_str.split('|')
                                    self.last_ip = parts[0]
                                    self.last_ssh = parts[1] if len(parts) > 1 else ""
                                    print(f"  IP: {self.last_ip}")
                                    print(f"  SSH: {self.last_ssh}")
                        except UnicodeDecodeError:
                            print("Decode error")
                
                time.sleep(0.01)
                
            except KeyboardInterrupt:
                print("\nShutting down...")
                break
            except Exception as e:
                print(f"Error: {e}")
                time.sleep(0.5)

# Main execution
if __name__ == "__main__":
    if LCD_AVAILABLE:
        try:
            display = USBIPDisplay()
            display.run()
        except Exception as e:
            print(f"Failed to start with LCD: {e}")
            print("Starting in simple mode...")
            simple = SimpleUSBReceiver()
            simple.run()
    else:
        print("Starting in simple mode (no LCD libraries)")
        simple = SimpleUSBReceiver()
        simple.run()