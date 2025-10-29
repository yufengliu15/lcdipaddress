# lcdipaddress
Code to display the ip of any Linux device onto a 16x2 LCD screen with some setup. Need to run the following script below on host device.

Connect your I2C LCD with your pico as displayed on the provided schematic. 

# Installation
`curl -sSL https://raw.githubusercontent.com/yufengliu15/lcdipaddress/main/host/install.sh | sudo bash`

## Testing
Test by running `sudo python3 /usr/local/bin/usb_ip_sender.py` in your host machine

You should be able to see the IP address of the host machine on the LCD.

# Uninstall
`sudo usb-ip-display-uninstall`
