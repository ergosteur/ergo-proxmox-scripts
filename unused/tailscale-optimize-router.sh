#!/bin/sh
# RETIRED. Kept for reference only.
#
# Tailscale's UDP GRO forwarding tuning belongs on the machine running
# tailscaled. Here that is VM 100 (ts-subnet-rtr), a KVM guest with its own
# kernel and its own netdevs, so setting it on the Proxmox host cannot affect
# it. Apply it inside that VM instead, on its default-route interface:
#
#   NETDEV=$(ip -o route get 8.8.8.8 | cut -f 5 -d " ")
#   ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
#
# Host-side tuning would have been the right lever only if tailscaled ran in an
# LXC container, which shares the host kernel.
#
# The interfaces below were wrong regardless. VM 100 sits on vmbr7, backed by
# enp4s0f7np7; vmbr0 is backed by enp4s0f0np0 and carries different guests,
# and enp4s1f12np12 is the host's own routing NIC, not a bridge port.
#
# It was also never in service: the header said "run from root's crontab", but
# root has no crontab.

# run from root's crontab
/usr/sbin/ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off
/usr/sbin/ethtool -K enp4s1f12np12 rx-udp-gro-forwarding on rx-gro-list off
