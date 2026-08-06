#!/bin/sh
# run from root's crontab
/usr/sbin/ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off
/usr/sbin/ethtool -K enp4s1f12np12 rx-udp-gro-forwarding on rx-gro-list off
