"""
USB IP Display Device - Simple Robust Firmware
This version:
- Displays whatever IP data it receives
- Shows countdown until expected next update (every 15s)
- Never times out to "Waiting" - keeps showing last IP
- Simpler and more reliable
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
    print("LCD libraries not found - running in console mode")

# Configuration
I2C_ADDR = 0x27  # Common I2C address (try 0x3F if this doesn't work)
I2C_NUM_ROWS = 2
I2C_NUM_COLS = 16
I2C_SDA = board.GP4
I2C_SCL = board.GP5

EXPECTED_REFRESH_INTERVAL = 15  # Host sends data every 15 seconds

class USBIPDisplay:
    def __init__(self):
        """Initialize the display and serial connection"""
        self.lcd = None
        self.serial = None
        self.last_ip = None
        self.last_ssh = None
        self.last_receive_time = None
        self.startup_time = time.monotonic()
        
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
                # Use first device found if our address isn't there
                actual_addr = I2C_ADDR if I2C_ADDR in devices else devices[0]
            else:
                print("No I2C devices found, using default")
                actual_addr = I2C_ADDR
            
            # Initialize LCD
            self.lcd = I2cLcd(i2c, actual_addr, I2C_NUM_ROWS, I2C_NUM_COLS)
            self.lcd.clear()
            
            # Show startup message
            self.show_startup()
            
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
                print("Serial initialized")
            else:
                print("No serial connection available")
        except Exception as e:
            print(f"Serial initialization error: {e}")
            self.serial = None
    
    def show_startup(self):
        """Show startup message"""
        if self.lcd:
            self.lcd.clear()
            self.lcd.putstr("USB IP Display")
            self.lcd.move_to(0, 1)
            self.lcd.putstr("Connecting...")
    
    def update_display(self):
        """Update the display with current data and countdown"""
        if not self.lcd:
            return
        
        try:
            self.lcd.clear()
            
            # If we have never received data
            if self.last_ip is None:
                self.lcd.putstr("Waiting for host")
                self.lcd.move_to(0, 1)
                uptime = int(time.monotonic() - self.startup_time)
                self.lcd.putstr(f"Uptime: {uptime}s")
                return
            
            # Display IP on line 1
            self.lcd.putstr(self.last_ip[:16])
            
            # Calculate countdown for line 2
            if self.last_receive_time:
                elapsed = time.monotonic() - self.last_receive_time
                time_until_refresh = max(0, EXPECTED_REFRESH_INTERVAL - elapsed)
                
                # Format line 2 with SSH status and countdown
                if time_until_refresh > 0:
                    ssh_display = self.last_ssh[:8] if self.last_ssh else "SSH: ???"
                    countdown = f" R:{int(time_until_refresh)}s"
                    line2 = (ssh_display + countdown)[:16]
                else:
                    # Show just SSH status when refresh is imminent
                    line2 = (self.last_ssh or "SSH: ???")[:16]
            else:
                # No timing info yet
                line2 = (self.last_ssh or "SSH: ???")[:16]
            
            self.lcd.move_to(0, 1)
            self.lcd.putstr(line2)
            
        except Exception as e:
            print(f"Display error: {e}")
    
    def parse_data(self, data):
        """Parse incoming data"""
        try:
            data = data.strip()
            
            if '|' in data:
                parts = data.split('|', 1)
                return parts[0], parts[1] if len(parts) > 1 else ""
            else:
                # Assume it's just an IP
                return data, "SSH: ???"
                
        except Exception as e:
            print(f"Parse error: {e}")
            return None, None
    
    def run(self):
        """Main loop"""
        print("Starting USB IP Display (Simple Robust Version)...")
        
        last_display_update = time.monotonic()
        display_update_interval = 0.5  # Update display every 0.5 seconds
        
        while True:
            try:
                current_time = time.monotonic()
                
                # Check for serial data
                if self.serial and self.serial.in_waiting > 0:
                    try:
                        raw_data = self.serial.read(self.serial.in_waiting)
                        
                        if raw_data:
                            data_str = raw_data.decode('utf-8')
                            
                            # Process each line
                            for line in data_str.split('\n'):
                                line = line.strip()
                                if line:
                                    ip, ssh = self.parse_data(line)
                                    
                                    if ip:
                                        print(f"Received: IP={ip}, SSH={ssh}")
                                        
                                        # Update stored data
                                        self.last_ip = ip
                                        self.last_ssh = ssh
                                        self.last_receive_time = current_time
                                        
                                        # Immediately update display
                                        self.update_display()
                                        last_display_update = current_time
                                        
                    except UnicodeDecodeError:
                        print("Decode error")
                    except Exception as e:
                        print(f"Data processing error: {e}")
                
                # Update display periodically (for countdown)
                if current_time - last_display_update >= display_update_interval:
                    self.update_display()
                    last_display_update = current_time
                
                # Small delay
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

class SimpleConsoleReceiver:
    """Console-only version for testing"""
    
    def __init__(self):
        self.serial = usb_cdc.console
        if self.serial:
            self.serial.timeout = 0.1
        self.last_ip = None
        self.last_ssh = None
        self.last_receive_time = None
    
    def run(self):
        print("Simple Console Receiver (No LCD)")
        print("Waiting for data from host...")
        print("-" * 40)
        
        while True:
            try:
                current_time = time.monotonic()
                
                if self.serial and self.serial.in_waiting > 0:
                    raw_data = self.serial.read(self.serial.in_waiting)
                    if raw_data:
                        try:
                            data_str = raw_data.decode('utf-8').strip()
                            if data_str:
                                if '|' in data_str:
                                    parts = data_str.split('|')
                                    self.last_ip = parts[0]
                                    self.last_ssh = parts[1] if len(parts) > 1 else ""
                                else:
                                    self.last_ip = data_str
                                    self.last_ssh = "???"
                                
                                self.last_receive_time = current_time
                                
                                # Calculate time until next expected update
                                countdown = EXPECTED_REFRESH_INTERVAL
                                
                                print(f"\n[{int(current_time)}s] Received:")
                                print(f"  IP:  {self.last_ip}")
                                print(f"  SSH: {self.last_ssh}")
                                print(f"  Next refresh expected in {countdown}s")
                                print("-" * 40)
                                
                        except UnicodeDecodeError:
                            print("Decode error")
                
                # Print countdown periodically
                if self.last_receive_time and int(current_time) % 5 == 0:
                    elapsed = current_time - self.last_receive_time
                    remaining = max(0, EXPECTED_REFRESH_INTERVAL - elapsed)
                    if remaining > 0:
                        print(f"Next refresh in {int(remaining)}s...", end='\r')
                
                time.sleep(0.1)
                
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
            print("Starting console mode...")
            receiver = SimpleConsoleReceiver()
            receiver.run()
    else:
        print("No LCD libraries - starting console mode")
        receiver = SimpleConsoleReceiver()
        receiver.run()