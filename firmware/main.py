"""
USB IP Display Device - Pico Firmware
This runs on the Raspberry Pi Pico with an I2C LCD display
Receives IP information via USB serial and displays it
"""

import board
import busio
import time
import usb_cdc
import supervisor
from lcd_api import LcdApi
from i2c_lcd import I2cLcd

# Configuration
I2C_ADDR = 0x27  # Common I2C address for LCD (try 0x3F if this doesn't work)
I2C_NUM_ROWS = 2
I2C_NUM_COLS = 16

# Pin definitions for I2C
I2C_SDA = board.GP0
I2C_SCL = board.GP1

class USBIPDisplay:
    def __init__(self):
        """Initialize the display and serial connection"""
        self.lcd = None
        self.serial = None
        self.last_data = None
        self.error_count = 0
        self.startup_time = time.monotonic()
        
        # Initialize components
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
            
            # Scan for I2C devices (for debugging)
            devices = i2c.scan()
            i2c.unlock()
            
            if devices:
                print(f"I2C devices found: {[hex(d) for d in devices]}")
                # Use first device if our configured address isn't found
                if I2C_ADDR not in devices and devices:
                    actual_addr = devices[0]
                    print(f"Using detected I2C address: {hex(actual_addr)}")
                else:
                    actual_addr = I2C_ADDR
            else:
                print("No I2C devices found!")
                actual_addr = I2C_ADDR  # Try anyway
            
            # Initialize LCD
            self.lcd = I2cLcd(i2c, actual_addr, I2C_NUM_ROWS, I2C_NUM_COLS)
            self.lcd.clear()
            
            # Show startup message
            self.lcd.putstr("USB IP Display")
            self.lcd.move_to(0, 1)
            self.lcd.putstr("Waiting...")
            
            print("LCD initialized successfully")
            
        except Exception as e:
            print(f"LCD initialization error: {e}")
            self.lcd = None
    
    def init_serial(self):
        """Initialize USB serial connection"""
        try:
            # Use the default USB CDC serial connection
            self.serial = usb_cdc.console
            
            if self.serial:
                # Set timeout for non-blocking reads
                self.serial.timeout = 0.1
                print("Serial initialized successfully")
            else:
                print("No serial connection available")
                
        except Exception as e:
            print(f"Serial initialization error: {e}")
            self.serial = None
    
    def display_data(self, line1, line2):
        """Display data on LCD"""
        if not self.lcd:
            return False
            
        try:
            self.lcd.clear()
            
            # Display line 1 (IP address)
            self.lcd.putstr(line1[:16])  # Truncate to 16 chars
            
            # Display line 2 (SSH status or other info)
            if line2:
                self.lcd.move_to(0, 1)
                self.lcd.putstr(line2[:16])
            
            return True
            
        except Exception as e:
            print(f"Display error: {e}")
            self.error_count += 1
            return False
    
    def parse_data(self, data):
        """Parse incoming data format: 'line1|line2'"""
        try:
            # Remove any whitespace and newlines
            data = data.strip()
            
            if '|' in data:
                # Split by pipe character
                parts = data.split('|', 1)
                return parts[0], parts[1] if len(parts) > 1 else ""
            else:
                # Single line of data
                return data, ""
                
        except Exception as e:
            print(f"Parse error: {e}")
            return None, None
    
    def show_status(self):
        """Show current status when no data received"""
        if not self.lcd:
            return
            
        try:
            uptime = int(time.monotonic() - self.startup_time)
            
            self.lcd.clear()
            self.lcd.putstr("Waiting for host")
            self.lcd.move_to(0, 1)
            self.lcd.putstr(f"Uptime: {uptime}s")
            
        except Exception:
            pass
    
    def run(self):
        """Main loop"""
        print("Starting USB IP Display...")
        
        last_update = time.monotonic()
        show_status_interval = 5.0  # Update status every 5 seconds
        data_timeout = 30.0  # Show "waiting" after 30 seconds of no data
        
        while True:
            try:
                # Check for serial data
                if self.serial and self.serial.in_waiting > 0:
                    # Read available data
                    raw_data = self.serial.read(self.serial.in_waiting)
                    
                    if raw_data:
                        # Decode and process
                        try:
                            data_str = raw_data.decode('utf-8')
                            # Handle multiple messages
                            for line in data_str.split('\n'):
                                if line.strip():
                                    line1, line2 = self.parse_data(line)
                                    
                                    if line1:
                                        print(f"Received: {line1} | {line2}")
                                        self.display_data(line1, line2)
                                        self.last_data = (line1, line2)
                                        last_update = time.monotonic()
                                        
                        except UnicodeDecodeError:
                            print("Decode error - invalid UTF-8")
                
                # Show status if no recent data
                current_time = time.monotonic()
                if current_time - last_update > data_timeout:
                    if current_time - last_update > show_status_interval:
                        self.show_status()
                        last_update = current_time
                
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
                self.error_count += 1
                
                # Reset if too many errors
                if self.error_count > 10:
                    print("Too many errors, resetting...")
                    time.sleep(1)
                    supervisor.reload()
                
                time.sleep(0.5)

# Alternative simpler version for testing without LCD
class SimpleUSBReceiver:
    """Simple version for testing without LCD connected"""
    
    def __init__(self):
        self.serial = usb_cdc.console
        if self.serial:
            self.serial.timeout = 0.1
    
    def run(self):
        print("Simple USB Receiver Started (no LCD)")
        print("Waiting for data...")
        
        while True:
            try:
                if self.serial and self.serial.in_waiting > 0:
                    raw_data = self.serial.read(self.serial.in_waiting)
                    if raw_data:
                        try:
                            data_str = raw_data.decode('utf-8').strip()
                            print(f"Received: {data_str}")
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
    # Try to initialize with LCD first
    try:
        display = USBIPDisplay()
        display.run()
    except Exception as e:
        print(f"Failed to start with LCD: {e}")
        print("Starting in simple mode (no LCD)...")
        
        # Fall back to simple receiver for testing
        simple = SimpleUSBReceiver()
        simple.run()
