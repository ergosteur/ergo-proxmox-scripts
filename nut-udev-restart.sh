#!/bin/bash
# nut-udev-restart.sh - safely restart NUT UPS driver on USB event
# Location: /opt/ergosteur/nut-udev-restart.sh

(
    # small delay so the USB device is fully settled before restarting driver
    sleep 2

    # stop and start the driver
    /sbin/upsdrvctl stop
    /sbin/upsdrvctl start
) &

exit 0
