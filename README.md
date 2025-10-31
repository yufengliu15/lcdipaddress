# lcdipaddress
Code to display the IP of any Linux device onto a 16x2 LCD screen with some setup. The host computer is set up with a systemd service that constantly looks for a ttyACM0 device. If found, it will try to send IP data to the connected device, which in this case is a RPi Pico. 

# Installation
Run the following script below on host device.

`curl -sSL https://raw.githubusercontent.com/yufengliu15/lcdipaddress/main/host/install.sh | sudo bash`

Connect the host device to the pico with a USB cable. 

## Testing
Test by running `sudo python3 /usr/local/bin/usb_ip_sender.py` in your host machine

You should be able to see the IP address of the host machine on the LCD.

# Uninstall
`sudo usb-ip-display-uninstall`
