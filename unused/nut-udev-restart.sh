#!/bin/bash
# RETIRED. Kept for reference only.
#
# Intended to be called from a udev RUN+= when the UPS re-enumerates on USB, to
# restart the NUT driver so it reattaches to the new device node. It was never
# wired up: /etc/udev/rules.d/50-nut-ups.rules only sets MODE and GROUP.
#
# Superseded by systemd. nut-driver@ups.service is Restart=always with
# RestartUSec=15s, so the driver is already retried indefinitely and picks up a
# new device node on its own. This script would only save about 13 seconds.
#
# It would also not work reliably as written:
#
#   - systemd-udevd runs RUN+= handlers in a cgroup and kills whatever is still
#     alive when the event completes, so the backgrounded subshell can be killed
#     mid-sleep and the restart never happens. Long-running work belongs in
#     ENV{SYSTEMD_WANTS}= or RUN+="systemctl --no-block ...".
#   - upsdrvctl starts the driver outside nut-driver@ups.service's supervision,
#     while stopping it makes systemd spawn a competing replacement.
#
# If faster recovery is ever wanted, drop the script and put the trigger in the
# rule instead:
#
#   SUBSYSTEM=="usb", ATTR{idVendor}=="0764", ATTR{idProduct}=="0601", \
#     ACTION=="add", RUN+="/usr/bin/systemctl --no-block restart nut-driver@ups.service"

(
    # small delay so the USB device is fully settled before restarting driver
    sleep 2

    # stop and start the driver
    /sbin/upsdrvctl stop
    /sbin/upsdrvctl start
) &

exit 0
