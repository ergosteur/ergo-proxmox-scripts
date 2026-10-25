#!/bin/bash
# Start a VM with PCIe passthrough only after checking that its devices are where
# its PCI resource mappings say they are.
#
# Usage:
#   ./start-passthrough-vm.sh [--check]
#
# Run at boot by passthrough-vm-start.service, after Proxmox's own guest
# autostart; give the VM onboot: 0 so that only this starts it. The VM and its
# devices are set in conf/passthrough-vm.conf.
#
# Adding a PCIe card can renumber the buses behind it, so a hostpci entry that
# names a PCI address can end up passing through the wrong device. Here each
# device is found by what it is instead: by vendor/device/subsystem ID when that
# is unique, or, for one port of a multi-port NIC, by its MAC-pinned interface.
# If a device has moved, its resource mapping is repointed at the new address
# before starting. If a device is missing, ambiguous, bound to a host driver or
# sharing its IOMMU group, the VM is left stopped and the script exits non-zero,
# so the unit shows as failed and dependents-start.service does not run.
#
# Nothing is started while prox-maintenance-mode.sh has autostart disabled.
#
# Options:
#   --check   Verify only: report what would be done, change and start nothing
#
# Exit status is 0 when the VM was started, was already running, or maintenance
# mode is on, and 1 when a check or the start failed.
#
# The config is looked for relative to this script, so this works both in a
# checkout and deployed at /opt/ergosteur. Override with PASSTHROUGH_VM_CONFIG.

set -uo pipefail

# Print the header comment block: everything from line 2 up to the first blank line.
usage() {
    sed -n '2,/^$/p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${PASSTHROUGH_VM_CONFIG:-$SCRIPT_DIR/conf/passthrough-vm.conf}
MAINT_STATE=/var/tmp/proxmox-autostart-backup.txt  # written by prox-maintenance-mode.sh --enable
NODE=$(hostname)
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --check)   CHECK_ONLY=true; shift ;;
        *) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

[[ -r $CONFIG ]] || { echo "Error: cannot read $CONFIG" >&2; exit 1; }
VMID=""
DEVICES=()
# shellcheck source=conf/passthrough-vm.conf.example
source "$CONFIG"
[[ -n $VMID ]] || { echo "Error: VMID is not set in $CONFIG" >&2; exit 1; }
[[ ${#DEVICES[@]} -gt 0 ]] || { echo "Error: no DEVICES listed in $CONFIG" >&2; exit 1; }

fail() {
    echo "ABORT: $* -- VM $VMID not started" >&2
    exit 1
}

# vendor:device:subvendor:subdevice of a PCI function, without the 0x prefixes.
pci_ids() {
    local d=/sys/bus/pci/devices/$1 f ids=()
    for f in vendor device subsystem_vendor subsystem_device; do
        ids+=("$(cut -c3- "$d/$f")")
    done
    (IFS=:; echo "${ids[*]}")
}

driver_of() {
    if [[ -e /sys/bus/pci/devices/$1/driver ]]; then
        basename "$(readlink -f "/sys/bus/pci/devices/$1/driver")"
    else
        echo none
    fi
}

iommu_group() {
    basename "$(readlink -f "/sys/bus/pci/devices/$1/iommu_group")"
}

alone_in_group() {
    [[ $(find "/sys/bus/pci/devices/$1/iommu_group/devices/" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]]
}

find_by_ids() {
    local d
    for d in /sys/bus/pci/devices/*; do
        if [[ $(pci_ids "${d##*/}") == "$1" ]]; then
            echo "${d##*/}"
        fi
    done
}

# Path of a PCI resource mapping on this node, from /etc/pve/mapping/pci.cfg.
mapped_path() {
    awk -v id="$1" -v node="$NODE" '
        $0 == id { inmap = 1; next }
        /^[^ \t]/ { inmap = 0 }
        inmap && $1 == "map" {
            n = split($2, kv, ","); ok = 0; path = ""
            for (i = 1; i <= n; i++) {
                if (kv[i] == "node=" node) ok = 1
                if (kv[i] ~ /^path=/) path = substr(kv[i], 6)
            }
            if (ok) { print path; exit }
        }' /etc/pve/mapping/pci.cfg
}

# Repoint a mapping at the device's current address if it has moved.
# Arguments: mapping id, address, vendor:device:subvendor:subdevice, IOMMU group.
repoint() {
    local id=$1 addr=$2 v d sv sd current
    current=$(mapped_path "$id")
    [[ -n $current ]] || fail "mapping $id has no entry for node $NODE"
    # A path without a function (0000:05:00) passes through every function of
    # the device; keep it in that form.
    [[ $current == *.* ]] || addr=${addr%.*}
    if [[ $current == "$addr" ]]; then
        echo "mapping $id ok ($addr)"
        return
    fi
    echo "mapping $id points at $current but the device is at $addr"
    if $CHECK_ONLY; then
        echo "(check: would repoint $id to $addr)"
        return
    fi
    IFS=: read -r v d sv sd <<<"$3"
    pvesh set "/cluster/mapping/pci/$id" \
        --map "node=$NODE,path=$addr,id=$v:$d,subsystem-id=$sv:$sd,iommugroup=$4" >/dev/null \
        || fail "could not repoint mapping $id"
    echo "repointed mapping $id to $addr"
}

if [[ -e $MAINT_STATE ]]; then
    echo "maintenance mode is on ($MAINT_STATE exists); not starting VM $VMID"
    exit 0
fi

config=$(qm config "$VMID") || fail "cannot read the config of VM $VMID"

for entry in "${DEVICES[@]}"; do
    read -r map lookup arg1 arg2 arg3 <<<"$entry"
    case $lookup in
        by-id)
            want=$arg1
            mapfile -t found < <(find_by_ids "$want")
            [[ ${#found[@]} -eq 1 ]] || fail "$map: expected one device with IDs $want, found ${#found[@]}"
            addr=${found[0]}
            where="by ID"
            # A device with a unique ID is expected to be claimed by vfio-pci at
            # boot. One on a host driver may already be in use by the host (an
            # HBA with its disks mounted, say), so it is not handed over.
            case $(driver_of "$addr") in
                vfio-pci|none) ;;
                *) fail "$map: $addr is bound to $(driver_of "$addr"), expected vfio-pci" ;;
            esac
            ;;
        by-netdev)
            netdev=$arg1 mac=$arg2 want=$arg3
            # At boot the port is on its host driver and visible as its pinned
            # interface. Once the VM has run it is on vfio-pci and the interface is
            # gone; then the mapped address is accepted as long as it is still the
            # right kind of device. Bus numbers only change across a reboot, and
            # after a reboot the interface is always back.
            if [[ -e /sys/class/net/$netdev/device ]]; then
                [[ $(cat "/sys/class/net/$netdev/address") == "$mac" ]] \
                    || fail "$map: $netdev does not have MAC $mac"
                addr=$(basename "$(readlink -f "/sys/class/net/$netdev/device")")
                where="via $netdev"
            else
                addr=$(mapped_path "$map")
                [[ -n $addr && -e /sys/bus/pci/devices/$addr ]] \
                    || fail "$map: $netdev not found and the mapping has no valid path"
                [[ $(driver_of "$addr") == vfio-pci ]] \
                    || fail "$map: $netdev not found and $addr is not on vfio-pci"
                where="already on vfio-pci, using the mapped address"
            fi
            [[ $(pci_ids "$addr") == "$want" ]] || fail "$map: $addr is $(pci_ids "$addr"), expected $want"
            ;;
        *)
            fail "unknown lookup '$lookup' for $map in $CONFIG"
            ;;
    esac
    alone_in_group "$addr" || fail "$map: $addr shares its IOMMU group with other devices"
    echo "$map: $addr ($where, driver $(driver_of "$addr"), IOMMU group $(iommu_group "$addr"))"
    grep -qE "^hostpci[0-9]+: mapping=$map(,|\$)" <<<"$config" \
        || fail "VM $VMID has no hostpci entry using mapping $map"
    repoint "$map" "$addr" "$want" "$(iommu_group "$addr")"
done

if [[ $(qm status "$VMID") == "status: running" ]]; then
    echo "VM $VMID is already running"
    exit 0
fi
if $CHECK_ONLY; then
    echo "all checks passed; would start VM $VMID"
    exit 0
fi
qm start "$VMID" || fail "qm start $VMID failed"
echo "VM $VMID started"
