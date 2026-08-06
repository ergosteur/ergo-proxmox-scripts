#!/usr/bin/env python3
#
# RETIRED. Kept for reference only.
#
# Proxmox imports OVA/OVF natively now, via a storage with the "import" content
# type: upload the .ova there and use Create VM > Import, or `qm importovf`.
# The built-in path handles disk format conversion per storage type, which this
# script did not.
#
# Two known bugs, left unfixed since the script is retired:
#   * every VMDK is imported in the loop, but only vm-<vmid>-disk-0 is ever
#     attached, so multi-disk appliances leave the rest orphaned
#   * the disk name is assumed to be vm-<vmid>-disk-N, which does not hold on
#     every storage type

import os
import sys
import tarfile
import tempfile
import subprocess
import xml.etree.ElementTree as ET
import argparse
import shutil

# Proxmox OVF/OVA Importer v1.3 with UEFI support

def parse_ovf(ovf_path):
    ns = {
        'ovf': "http://schemas.dmtf.org/ovf/envelope/1",
        'rasd': "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData",
        'vssd': "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
    }
    tree = ET.parse(ovf_path)

    cpu = 0
    mem = 0
    disks = []
    uefi = False
    for item in tree.findall(".//ovf:VirtualHardwareSection/ovf:Item", ns):
        rtype = item.find("rasd:ResourceType", ns)
        quantity = item.find("rasd:VirtualQuantity", ns)
        if rtype is None or quantity is None:
            continue
        rtype_val = rtype.text.strip()
        quantity_val = quantity.text.strip()
        if rtype_val == "3":
            cpu = int(quantity_val)
        elif rtype_val == "4":
            mem = int(quantity_val)
        elif rtype_val == "17":
            host_res = item.find("rasd:HostResource", ns)
            if host_res is not None:
                disks.append(host_res.text.split('/')[-1])

    for disk in tree.findall(".//ovf:DiskSection/ovf:Disk", ns):
        if 'capacity' in disk.attrib:
            size_bytes = int(disk.attrib['capacity'])
            size_gb = round(size_bytes / (1024**3), 1)
        else:
            size_gb = 0

    vsys_type = tree.find(".//ovf:VirtualHardwareSection/ovf:System/vssd:VirtualSystemType", ns)
    if vsys_type is not None and "efi" in vsys_type.text.lower():
        uefi = True

    return cpu, mem, disks, size_gb, uefi

def run(cmd):
    print(f"$ {' '.join(cmd)}")
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        print(result.stdout)
        sys.exit(1)
    return result.stdout

def check_storage(storage):
    status = run(["pvesm", "status"])
    for line in status.splitlines():
        if line.startswith(storage):
            parts = line.split()
            avail_bytes = int(parts[5])
            return avail_bytes
    print(f"❌ Storage {storage} not found!")
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ova_path")
    parser.add_argument("vmid")
    parser.add_argument("storage")
    parser.add_argument("--name", default=None)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--uefi", action="store_true", help="Force UEFI/OVMF BIOS")
    args = parser.parse_args()

    ova_path = os.path.abspath(args.ova_path)
    vmid = str(args.vmid)
    storage = args.storage
    vmname = args.name or os.path.splitext(os.path.basename(ova_path))[0].replace(".", "-").replace("_", "-")

    print(f"✅ VM ID {vmid} is available")
    avail_bytes = check_storage(storage)
    print(f"🧮 Storage free space: {round(avail_bytes / (1024**3), 1)}G")

    with tempfile.TemporaryDirectory() as tmpdir:
        print("==> Detected OVA bundle. Extracting...")
        with tarfile.open(ova_path, 'r') as tar:
            tar.extractall(path=tmpdir)

        ovf_file = next(f for f in os.listdir(tmpdir) if f.endswith(".ovf"))
        ovf_path = os.path.join(tmpdir, ovf_file)
        cpu, mem, disks, declared_gb, uefi_detected = parse_ovf(ovf_path)

        print(f"📦 Total VMDK declared size: {declared_gb}G")
        if declared_gb * 1024**3 > avail_bytes:
            print("❌ Not enough space to import.")
            sys.exit(1)
        else:
            print("✅ Storage has enough capacity")

        print(f"🧠 Parsed RAM from OVF: {mem} MB")
        print(f"🧮 Parsed CPU count from OVF: {cpu}")

        if mem < 16:
            print("⚠️ OVF RAM too low. Defaulting to 512 MB.")
            mem = 512
        if cpu < 1:
            print("⚠️ OVF CPU count too low. Defaulting to 1 core.")
            cpu = 1

        use_uefi = args.uefi or uefi_detected
        create_cmd = ["qm", "create", vmid,
                      "--name", vmname,
                      "--memory", str(mem),
                      "--cores", str(cpu),
                      "--net0", "virtio,bridge=vmbr0"]
        if use_uefi:
            print("🧬 Enabling UEFI BIOS (OVMF)...")
            if not os.path.exists("/usr/share/OVMF/OVMF_CODE.fd"):
                print("⚠️ Warning: UEFI firmware (OVMF) not found. You may need to install the 'ovmf' package.")
            create_cmd += ["--bios", "ovmf"]

        print(f"==> Creating VM {vmid}...")
        run(create_cmd)

        for idx, vmdk in enumerate(f for f in os.listdir(tmpdir) if f.endswith(".vmdk")):
            disk_path = os.path.join(tmpdir, vmdk)
            print(f"==> Importing disk {vmdk} to {storage}...")
            run(["qm", "importdisk", vmid, disk_path, storage])

        print(f"==> Attaching disks to VM {vmid}...")
        run(["qm", "set", vmid, "--scsihw", "virtio-scsi-pci", "--scsi0", f"{storage}:vm-{vmid}-disk-0"])

        print(f"==> Setting boot order to scsi0 (disabling net0 boot)...")
        run(["qm", "set", vmid, "--boot", "order=scsi0"])

        print("✅ Import complete!")

if __name__ == "__main__":
    main()
