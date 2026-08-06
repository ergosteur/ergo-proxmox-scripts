#!/bin/bash
set -euo pipefail

# === OVF/OVA Importer for Proxmox ===
# Supports: --force, OVF parsing, accurate storage check, multi-disk VMDK, CPU/RAM

FORCE=0
POSITIONAL=()

# === Parse args manually to allow --force anywhere ===
for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

set -- "${POSITIONAL[@]}"
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <ova|ovf-file> <vmid> <storage> [vm-name] [--force]"
  exit 1
fi

INPUT="$1"
VMID="$2"
STORAGE="$3"
VMNAME="${4:-}"

# === Auto-suggest VM name from filename if not given ===
if [[ -z "$VMNAME" || "$VMNAME" == "--force" ]]; then
  BASENAME=$(basename "$INPUT")
  BASENAME="${BASENAME%.*}"
  VMNAME=$(echo "$BASENAME" | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
  echo "==> No VM name provided."
  echo "==> Suggested VM Name: $VMNAME"
  echo "==> Continuing in 5 seconds... (Ctrl-C to cancel)"
  sleep 5
fi

# === Validate VM ID ===
if qm status "$VMID" &>/dev/null; then
  echo "❌ ERROR: VM ID $VMID already exists"
  exit 1
else
  echo "✅ VM ID $VMID is available"
fi

# === Validate storage ===
if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
  echo "❌ ERROR: Storage '$STORAGE' not found!"
  echo "👉 Available storages:"
  pvesm status | awk 'NR>1 {print $1}'
  exit 1
else
  echo "✅ Storage '$STORAGE' exists"
fi

# === Get free space in bytes from pvesm (field 6 × 1024) ===
STORAGE_FREE_KB=$(pvesm status | awk -v storage="$STORAGE" '$1 == storage {print $6}')
if [[ -z "$STORAGE_FREE_KB" || "$STORAGE_FREE_KB" -eq 0 ]]; then
  echo "❌ ERROR: Could not determine available space for '$STORAGE'"
  exit 1
fi
STORAGE_FREE=$((STORAGE_FREE_KB * 1024))

# === Temp workspace ===
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Preparing to import VM $VMID from $INPUT (name: $VMNAME)"

# === Extract OVA or OVF ===
if [[ "$INPUT" == *.ova ]]; then
  echo "==> Detected OVA bundle. Extracting..."
  tar -xvf "$INPUT" -C "$TMPDIR"
elif [[ "$INPUT" == *.ovf ]]; then
  echo "==> Detected OVF file. Copying OVF and VMDKs..."
  cp "$INPUT" "$TMPDIR"
  for vmdk in "${INPUT%.ovf}"*.vmdk; do cp "$vmdk" "$TMPDIR"; done
else
  echo "❌ ERROR: Input must be .ova or .ovf"
  exit 1
fi

cd "$TMPDIR"
OVF=$(find . -name "*.ovf" | head -n 1)
[[ -f "$OVF" ]] || { echo "❌ ERROR: OVF file not found!"; exit 1; }

# === Get total declared capacity from OVF ===
REQUIRED_CAPACITY=$(grep -oP 'ovf:capacity="\K[0-9]+' "$OVF" | awk '{sum+=$1} END{print sum}')
REQUIRED_FMT=$(numfmt --to=iec "$REQUIRED_CAPACITY" 2>/dev/null || echo "$REQUIRED_CAPACITY B")
STORAGE_FMT=$(numfmt --to=iec "$STORAGE_FREE" 2>/dev/null || echo "$STORAGE_FREE B")

echo "🧮 Storage free space: $STORAGE_FMT"
echo "📦 Total VMDK declared size: $REQUIRED_FMT"

if [[ "$FORCE" -eq 1 ]]; then
  echo "⚠️  --force enabled, skipping free space check"
elif [[ -z "$REQUIRED_CAPACITY" || -z "$STORAGE_FREE" ]]; then
  echo "❌ ERROR: Capacity values missing"
  exit 1
elif ! [[ "$REQUIRED_CAPACITY" =~ ^[0-9]+$ && "$STORAGE_FREE" =~ ^[0-9]+$ ]]; then
  echo "❌ ERROR: Capacity values not integers"
  exit 1
elif (( STORAGE_FREE < REQUIRED_CAPACITY )); then
  echo "❌ Not enough free space on storage '$STORAGE'"
  exit 1
else
  echo "✅ Storage has enough capacity"
fi

# === Parse RAM and CPU ===
OVF_RAM=$(xmllint --xpath 'string(//*[local-name()="Item"][.//*[local-name()="ResourceType"]="4"]/*[local-name()="VirtualQuantity"])' "$OVF" 2>/dev/null || echo "2048")
OVF_CPU=$(xmllint --xpath 'string(//*[local-name()="Item"][.//*[local-name()="ResourceType"]="3"]/*[local-name()="VirtualQuantity"])' "$OVF" 2>/dev/null || echo "2")

[[ "$OVF_RAM" =~ ^[0-9]+$ ]] || OVF_RAM=2048
[[ "$OVF_CPU" =~ ^[0-9]+$ ]] || OVF_CPU=2

echo "🧠 Parsed RAM from OVF: ${OVF_RAM} MB"
echo "🧮 Parsed CPU count from OVF: $OVF_CPU"

# === Create VM ===
echo "==> Creating VM $VMID..."
qm create "$VMID" --name "$VMNAME" --memory "$OVF_RAM" --cores "$OVF_CPU" --net0 virtio,bridge=vmbr0 --ostype l26

# === Parse VMDK files reliably ===
mapfile -t VMDK_FILES < <(xmllint --xpath "//*[local-name()='File']/@*" "$OVF" 2>/dev/null \
  | grep -oE 'href="[^"]+\.vmdk"' | sed -E 's/^href="|"$//g')

if [[ ${#VMDK_FILES[@]} -eq 0 ]]; then
  echo "❌ ERROR: No VMDK files found in OVF"
  exit 1
fi

echo "📄 VMDK files to import:"
for f in "${VMDK_FILES[@]}"; do echo "   - $f"; done

i=0
for VMDK in "${VMDK_FILES[@]}"; do
  VMDK_FILE=$(basename "$VMDK")
  [[ -f "$VMDK_FILE" ]] || { echo "❌ Missing VMDK file: $VMDK_FILE"; exit 1; }

  echo "💾 Importing $VMDK_FILE to $STORAGE..."
  qm importdisk "$VMID" "$VMDK_FILE" "$STORAGE" --format qcow2

  echo "🔗 Attaching disk as scsi$i..."
  qm set "$VMID" --scsi$i "$STORAGE:vm-$VMID-disk-$i"
  ((i++))
done

# === Finalize configuration ===
qm set "$VMID" --scsihw virtio-scsi-pci --boot c --bootdisk scsi0
qm set "$VMID" --vga std

echo "✅ VM $VMID ('$VMNAME') successfully imported and ready to start!"
