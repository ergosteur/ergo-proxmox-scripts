#!/bin/sh -e
ip link set dev enp130s0f0 vf 0 mac a0:36:9f:5d:3f:40 trust on promisc on allmulticast on
ip link set dev enp130s0f0 vf 1 mac a0:36:9f:5d:3f:41 trust on promisc on allmulticast on
ip link set dev enp130s0f0 vf 2 mac a0:36:9f:5d:3f:42 trust on promisc on allmulticast on
ip link set dev enp130s0f0 vf 3 mac a0:36:9f:5d:3f:43 trust on promisc on allmulticast on
ip link set dev enp130s0f1 vf 0 mac a0:36:9f:5d:3f:50 trust on promisc on allmulticast on
ip link set dev enp130s0f1 vf 1 mac a0:36:9f:5d:3f:51 trust on promisc on allmulticast on
ip link set dev enp130s0f1 vf 2 mac a0:36:9f:5d:3f:52 trust on promisc on allmulticast on
ip link set dev enp130s0f1 vf 3 mac a0:36:9f:5d:3f:53 trust on promisc on allmulticast on
