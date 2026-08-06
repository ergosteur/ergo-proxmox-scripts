#!/bin/bash
# Build a Proxmox cloud-init template VM from a Debian cloud image.
#
# Usage:
#   ./make-debian-cloudinit-template.sh <VMID> [CODENAME]
#
# CODENAME is a Debian release codename (default: trixie). Known:
#   bullseye (11), bookworm (12), trixie (13), forky (14)
#
# Optional overrides (env vars):
#   IMAGE_URL Full image URL, overrides CODENAME lookup entirely
#   STORAGE   Proxmox storage pool for disks   (default: local-zfs)
#   BRIDGE    Network bridge                   (default: vmbr0)
#   MEMORY    RAM in MB                        (default: 2048)
#   CORES     CPU cores                        (default: 4)
#   NAME      Template name in Proxmox         (default: debian-<CODENAME>-cloudinit-<VMID>)
#
# Example:
#   STORAGE=local-lvm BRIDGE=vmbr1 ./make-debian-cloudinit-template.sh 9000 bookworm

set -euo pipefail

usage() {
    grep '^#' "$0" | sed -e 's/^#//' -e 's/^ //' | head -n 20
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    printf "Please run as root:\nsudo %s\n" "$0"
    exit 1
fi

for bin in wget qm pvesm; do
    if ! command -v "$bin" >/dev/null; then
        echo "Required command '$bin' not found. Is this running on a Proxmox host?" >&2
        exit 1
    fi
done

ID=${1:-}
if [[ -z "$ID" || ! "$ID" =~ ^[0-9]+$ ]]; then
    echo "Error: a numeric VM ID is required." >&2
    usage
    exit 1
fi

if qm status "$ID" &>/dev/null; then
    echo "Error: VM ID $ID already exists." >&2
    exit 1
fi

declare -A DEBIAN_VERSIONS=(
    [bullseye]=11
    [bookworm]=12
    [trixie]=13
    [forky]=14
)

CODENAME=${2:-trixie}
STORAGE=${STORAGE:-local-zfs}
BRIDGE=${BRIDGE:-vmbr0}
MEMORY=${MEMORY:-2048}
CORES=${CORES:-4}
NAME=${NAME:-"debian-$CODENAME-cloudinit-$ID"}

if [[ -n "${IMAGE_URL:-}" ]]; then
    URL="$IMAGE_URL"
else
    VERSION=${DEBIAN_VERSIONS[$CODENAME]:-}
    if [[ -z "$VERSION" ]]; then
        echo "Error: unknown Debian codename '$CODENAME'. Known: ${!DEBIAN_VERSIONS[*]}" >&2
        exit 1
    fi
    URL="https://cloud.debian.org/images/cloud/$CODENAME/latest/debian-$VERSION-genericcloud-amd64.qcow2"
fi

if ! pvesm status -storage "$STORAGE" &>/dev/null; then
    echo "Error: storage pool '$STORAGE' not found (check STORAGE env var)." >&2
    exit 1
fi

trap 'echo "Failed while building VM $ID. It may be left in a partial state — check with: qm config $ID  (clean up with: qm destroy $ID)" >&2' ERR

CACHE_DIR=/var/tmp/pve-cloudinit-images
mkdir -p "$CACHE_DIR"
IMAGE_FILE="$CACHE_DIR/$(basename "$URL")"

echo "Fetching cloud image (cached under $CACHE_DIR, re-used if unchanged)..."
wget -N -P "$CACHE_DIR" "$URL"

qm create "$ID" --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-pci --memory "$MEMORY" --cores "$CORES" --machine q35

if command -v virt-customize >/dev/null; then
    echo "Installing qemu-guest-agent into guest image..."
    virt-customize -a "$IMAGE_FILE" --install qemu-guest-agent
    qm set "$ID" --agent 1
else
    echo "virt-customize not found (install libguestfs-tools for this); skipping in-guest qemu-guest-agent install."
fi

qm importdisk "$ID" "$IMAGE_FILE" "$STORAGE"
DISK=$(qm config "$ID" | awk -F': ' '/^unused0:/ {print $2}')
if [[ -z "$DISK" ]]; then
    echo "Error: could not find imported disk on VM $ID." >&2
    exit 1
fi

qm set "$ID" --scsi0 "$DISK"
qm set "$ID" --scsi1 "$STORAGE:cloudinit"
qm set "$ID" --name "$NAME" --boot order=scsi0 --serial0 socket --vga serial0
qm template "$ID"

echo "Template $ID ($NAME) created from $URL using storage '$STORAGE'."
