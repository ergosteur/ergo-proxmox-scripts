#!/bin/bash
# 6-in-1 Proxmox cloud-init template builder.
#
# Usage:
#   ./build-cloudinit-template.sh <VMID> <alpine|ubuntu|debian|fedora|almalinux|arch> [--docker]
#
# Optional overrides (env vars):
#   STORAGE          Proxmox storage pool for disks   (default: local-btrfs)
#   SNIPPET_STORAGE  Storage holding cloud-init snippets, must have the
#                    "Snippets" content type enabled  (default: local)
#   BRIDGE           Network bridge                   (default: vmbr0)
#   MEMORY           RAM in MB                        (default: 1024)
#   CORES            CPU cores                        (default: 1)
#   DISK_SIZE        Disk size, e.g. 32G              (default: per-distro)
#   SSH_KEY_FILE     Public keys to inject            (default: /root/.ssh/authorized_keys)
#   CI_PASSWORD      Cloud-init password              (default: prompted securely)
#   CACHE_DIR        Cloud image download cache       (default: /var/tmp/pve-cloudinit-images)
#
# Example:
#   STORAGE=local-lvm MEMORY=2048 ./build-cloudinit-template.sh 8000 arch --docker

set -euo pipefail

# Print the header comment block: everything from line 2 up to the first blank line.
usage() {
    sed -n '2,/^$/p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# --- Distribution version pins (update these over time) ---
ALPINE_MAJOR="v3.24"
ALPINE_PATCH="3.24.1"
UBUNTU_CODENAME="resolute"   # 26.04 LTS
UBUNTU_VER="2604"
DEBIAN_CODENAME="trixie"
DEBIAN_VER="13"
FEDORA_VER="44"
FEDORA_RELEASE="1.7"   # minor release can change throughout the cycle
ALMA_VER="10"
# Arch is rolling, so it pulls the "latest" build natively.

# --- Overridable configuration ---
STORAGE=${STORAGE:-local-btrfs}
SNIPPET_STORAGE=${SNIPPET_STORAGE:-local}
BRIDGE=${BRIDGE:-vmbr0}
MEMORY=${MEMORY:-1024}
CORES=${CORES:-1}
SSH_KEY_FILE=${SSH_KEY_FILE:-/root/.ssh/authorized_keys}
CACHE_DIR=${CACHE_DIR:-/var/tmp/pve-cloudinit-images}

# --- 1. Validation and input parsing ---
SUPPORTED_DISTROS="alpine|ubuntu|debian|fedora|almalinux|arch"

if [[ $EUID -ne 0 ]]; then
    printf "Please run as root:\nsudo %s\n" "$0" >&2
    exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage >&2
    exit 1
fi

for bin in wget qm pvesm openssl qemu-img; do
    if ! command -v "$bin" >/dev/null; then
        echo "Required command '$bin' not found. Is this running on a Proxmox host?" >&2
        exit 1
    fi
done

VMID=$1
if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "Error: a numeric VM ID is required." >&2
    exit 1
fi

DISTRO_CHOICE=$(echo "$2" | tr '[:upper:]' '[:lower:]')
if [[ ! "$DISTRO_CHOICE" =~ ^($SUPPORTED_DISTROS)$ ]]; then
    echo "Error: unsupported OS distribution '$2'." >&2
    echo "Please choose one of: ${SUPPORTED_DISTROS//|/, }" >&2
    exit 1
fi

CI_USER="$DISTRO_CHOICE"
INSTALL_DOCKER=false
if [[ "${3:-}" == "--docker" ]]; then
    INSTALL_DOCKER=true
elif [[ -n "${3:-}" ]]; then
    echo "Error: unknown option '$3' (expected --docker)." >&2
    exit 1
fi

if qm status "$VMID" &>/dev/null; then
    echo "Error: VM ID $VMID already exists." >&2
    exit 1
fi

if ! pvesm status -storage "$STORAGE" &>/dev/null; then
    echo "Error: storage pool '$STORAGE' not found (check STORAGE env var)." >&2
    exit 1
fi

if ! pvesm status -storage "$SNIPPET_STORAGE" &>/dev/null; then
    echo "Error: snippet storage '$SNIPPET_STORAGE' not found (check SNIPPET_STORAGE env var)." >&2
    exit 1
fi

# Snippets are a per-storage content type and are off by default — a missing one
# produces a confusing failure much later, so check it up front.
if ! pvesm status -storage "$SNIPPET_STORAGE" -content snippets &>/dev/null; then
    echo "Error: storage '$SNIPPET_STORAGE' does not have the 'Snippets' content type enabled." >&2
    echo "Enable it under Datacenter > Storage > $SNIPPET_STORAGE > Content, or set SNIPPET_STORAGE." >&2
    exit 1
fi

# --- 2. Set distribution-specific variables ---
case $DISTRO_CHOICE in
    alpine)
        VM_NAME="alpine-${ALPINE_MAJOR//v/}-cloudinit"
        # Upstream renamed the cloud image prefix from nocloud_ to generic_ in 3.24;
        # 3.23 and older only have nocloud_, so this URL is not backward-compatible.
        IMAGE_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_MAJOR}/releases/cloud/generic_alpine-${ALPINE_PATCH}-x86_64-uefi-cloudinit-r0.qcow2"
        DEFAULT_DISK_SIZE="8G"
        PKG_MGR="apk"
        ;;
    ubuntu)
        VM_NAME="ubuntu-${UBUNTU_VER}-cloudinit"
        IMAGE_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
        DEFAULT_DISK_SIZE="32G"
        PKG_MGR="apt"
        ;;
    debian)
        VM_NAME="debian-${DEBIAN_VER}-cloudinit"
        IMAGE_URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VER}-genericcloud-amd64.qcow2"
        DEFAULT_DISK_SIZE="32G"
        PKG_MGR="apt"
        ;;
    fedora)
        VM_NAME="fedora-${FEDORA_VER}-cloudinit"
        IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VER}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${FEDORA_VER}-${FEDORA_RELEASE}.x86_64.qcow2"
        DEFAULT_DISK_SIZE="32G"
        PKG_MGR="dnf"
        ;;
    almalinux)
        VM_NAME="almalinux-${ALMA_VER}-cloudinit"
        IMAGE_URL="https://repo.almalinux.org/almalinux/${ALMA_VER}/cloud/x86_64/images/AlmaLinux-${ALMA_VER}-GenericCloud-latest.x86_64.qcow2"
        DEFAULT_DISK_SIZE="32G"
        PKG_MGR="dnf"
        ;;
    arch)
        VM_NAME="archlinux-cloudinit"
        IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
        DEFAULT_DISK_SIZE="32G"
        PKG_MGR="pacman"
        ;;
esac

DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_SIZE}

if [[ "$INSTALL_DOCKER" == true ]]; then
    VM_NAME="${VM_NAME}-docker"
fi

# Secure password prompt
CLEARTEXT_PASSWORD=${CI_PASSWORD:-}
if [[ -z "$CLEARTEXT_PASSWORD" ]]; then
    while true; do
        read -rs -p "Enter cloud-init password for user '$CI_USER': " PASSWORD_INPUT
        echo
        read -rs -p "Confirm password: " PASSWORD_CONFIRM
        echo
        if [[ "$PASSWORD_INPUT" != "$PASSWORD_CONFIRM" ]]; then
            echo "Passwords do not match. Please try again."
        elif [[ -z "$PASSWORD_INPUT" ]]; then
            echo "Password cannot be empty. Please try again."
        else
            CLEARTEXT_PASSWORD="$PASSWORD_INPUT"
            break
        fi
    done
fi

# From here on a failure can leave a half-built VM behind, so say how to clean up.
trap 'echo "Failed while building VM $VMID. It may be left in a partial state — check with: qm config $VMID  (clean up with: qm destroy $VMID)" >&2' ERR

# --- 3. Generate cloud-init vendor snippet ---
SNIPPET_NAME="${DISTRO_CHOICE}-vendor.yaml"

# Resolve the snippet directory from the storage rather than assuming /var/lib/vz,
# so SNIPPET_STORAGE and the on-disk path can never disagree. Fall back to parsing
# storage.cfg if pvesm won't resolve a path for a volume that does not exist yet.
SNIPPET_FILE=$(pvesm path "$SNIPPET_STORAGE:snippets/$SNIPPET_NAME" 2>/dev/null || true)
if [[ -z "$SNIPPET_FILE" ]]; then
    STORAGE_PATH=$(awk -v s="$SNIPPET_STORAGE" '
        $1 == "dir:" && $2 == s { found = 1; next }
        /^[a-z]+:/ { found = 0 }
        found && $1 == "path" { print $2; exit }
    ' /etc/pve/storage.cfg 2>/dev/null || true)
    if [[ -n "$STORAGE_PATH" ]]; then
        SNIPPET_FILE="$STORAGE_PATH/snippets/$SNIPPET_NAME"
    fi
fi
if [[ -z "$SNIPPET_FILE" ]]; then
    echo "Error: could not resolve the snippets path for storage '$SNIPPET_STORAGE'." >&2
    echo "Is it a directory-backed storage? Override with SNIPPET_STORAGE." >&2
    exit 1
fi

echo "Generating cloud-init vendor snippet for $DISTRO_CHOICE..."
mkdir -p "$(dirname "$SNIPPET_FILE")"

{
    echo "#cloud-config"
    echo "runcmd:"
} > "$SNIPPET_FILE"

case $PKG_MGR in
    apt)
        cat >> "$SNIPPET_FILE" <<EOF
  - apt-get update
  - apt-get install -y qemu-guest-agent curl
  - systemctl enable --now qemu-guest-agent
EOF
        ;;
    dnf)
        cat >> "$SNIPPET_FILE" <<EOF
  - dnf update -y
  - dnf install -y qemu-guest-agent curl
  - systemctl enable --now qemu-guest-agent
EOF
        ;;
    pacman)
        cat >> "$SNIPPET_FILE" <<EOF
  - pacman -Syu --noconfirm
  - pacman -S --noconfirm qemu-guest-agent bash-completion curl
  - systemctl enable --now qemu-guest-agent
EOF
        ;;
    apk)
        cat >> "$SNIPPET_FILE" <<EOF
  - apk update
  - apk add qemu-guest-agent bash bash-completion curl
  - rc-update add qemu-guest-agent default
  - service qemu-guest-agent start
  - sed -i 's|/bin/ash|/bin/bash|g' /etc/passwd
EOF
        ;;
esac

if [[ "$INSTALL_DOCKER" == true ]]; then
    echo "Injecting Docker runtime installation into cloud-init..."
    case $DISTRO_CHOICE in
        alpine)
            cat >> "$SNIPPET_FILE" <<EOF
  - apk add docker docker-cli-compose
  - rc-update add docker default
  - service docker start
  - addgroup $CI_USER docker
EOF
            ;;
        arch)
            cat >> "$SNIPPET_FILE" <<EOF
  - pacman -S --noconfirm docker docker-compose
  - systemctl enable --now docker
  - usermod -aG docker $CI_USER
EOF
            ;;
        *)
            cat >> "$SNIPPET_FILE" <<EOF
  - curl -fsSL https://get.docker.com -o get-docker.sh
  - sh get-docker.sh
  - systemctl enable --now docker
  - usermod -aG docker $CI_USER
EOF
            ;;
    esac
fi

# Always reboot at the end.
echo "  - reboot" >> "$SNIPPET_FILE"

# /etc/timezone is Debian-specific; fall back to timedatectl elsewhere.
if [[ -r /etc/timezone ]]; then
    echo "timezone: $(cat /etc/timezone)" >> "$SNIPPET_FILE"
elif command -v timedatectl >/dev/null; then
    echo "timezone: $(timedatectl show -p Timezone --value)" >> "$SNIPPET_FILE"
fi

# --- 4. Download the cloud image (cached) ---
mkdir -p "$CACHE_DIR"
IMAGE_FILE="$CACHE_DIR/$(basename "$IMAGE_URL")"

echo "Fetching cloud image (cached under $CACHE_DIR, re-used if unchanged)..."
wget -N -P "$CACHE_DIR" "$IMAGE_URL"

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: expected image at $IMAGE_FILE after download." >&2
    exit 1
fi

# --- 5. Create the base VM ---
echo "Creating the base VM ($VMID)..."
qm create "$VMID" --name "$VM_NAME" --ostype l26 \
    --memory "$MEMORY" \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 "$STORAGE:0,pre-enrolled-keys=0" \
    --cpu host --sockets 1 --cores "$CORES" \
    --vga serial0 --serial0 socket \
    --net0 "virtio,bridge=$BRIDGE"

# --- 6. Import disk and configure hardware ---
echo "Importing disk and configuring hardware..."
# import-from handles any storage type (BTRFS, ZFS, LVM) and attaches as scsi0.
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$STORAGE:0,import-from=$IMAGE_FILE,discard=on"

# Grow the imported disk in place, so the cached image stays pristine for reuse.
echo "Resizing disk to $DISK_SIZE..."
qm disk resize "$VMID" scsi0 "$DISK_SIZE"

qm set "$VMID" --boot order=scsi0
qm set "$VMID" --ide2 "$STORAGE:cloudinit"

# --- 7. Configure cloud-init settings ---
echo "Applying cloud-init settings..."

VM_TAGS="$DISTRO_CHOICE-template,cloudinit,linux,template"
if [[ "$INSTALL_DOCKER" == true ]]; then
    VM_TAGS="$VM_TAGS,docker"
fi

# Quoted: the SHA-512 crypt hash contains $ and / and must not be word-split.
CIPASSWORD=$(openssl passwd -6 "$CLEARTEXT_PASSWORD")

qm set "$VMID" --cicustom "vendor=$SNIPPET_STORAGE:snippets/$SNIPPET_NAME"
qm set "$VMID" --tags "$VM_TAGS"
qm set "$VMID" --ciuser "$CI_USER"
qm set "$VMID" --cipassword "$CIPASSWORD"
qm set "$VMID" --ipconfig0 ip=dhcp,ip6=dhcp

# Only inject SSH keys if the file actually exists.
if [[ -f "$SSH_KEY_FILE" ]]; then
    qm set "$VMID" --sshkeys "$SSH_KEY_FILE"
else
    echo "Warning: SSH key file not found at $SSH_KEY_FILE. Skipping injection." >&2
fi

# --- 8. Finalize template ---
qm template "$VMID"

trap - ERR

echo "Done! $DISTRO_CHOICE template $VMID ($VM_NAME) is ready for cloning."
echo "User '$CI_USER', disk $DISK_SIZE on storage '$STORAGE'. Cached image kept at $IMAGE_FILE."
