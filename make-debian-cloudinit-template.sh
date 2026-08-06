#!/bin/bash
# makes a cloud-init template vm from URL
# call like ./make-debian-template.sh 9000

# Check for root priviliges
if [[ $EUID -ne 0 ]]; then
   printf "Please run as root:\nsudo %s\n" "${0}"
   exit 1
fi


ID=$1
URL=${2:-"https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"}
FS=btrfs
# decide between lvm, zfs or btrfs

wget $URL -O cloud-init.qcow2
qm create $ID --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --memory 2048 --cores 4 --machine q35
command -v virt-customize
# install libguestfs-tools to have virt-customize

if [[ $? -eq 0 ]]; then
   echo "installing qemu-guest-agent into guest"
   virt-customize -a cloud-init.qcow2 --install qemu-guest-agent
   qm set $ID --agent 1
else
   echo "will not install qemu-guest-agent into guest"
fi

qm importdisk $ID  ./cloud-init.qcow2 local-$FS
[ "$FS" == "btrfs" ] && qm set $ID --scsi0 local-$FS:$ID/vm-$ID-disk-0.raw
[ "$FS" == "lvm" ] && qm set $ID --scsi0 local-$FS:vm-$ID-disk-0
[ "$FS" == "zfs" ] && qm set $ID --scsi0 local-$FS:vm-$ID-disk-0
qm set $ID --scsi1 local-$FS:cloudinit
qm set $ID --serial0 socket --vga serial0
qm set $ID --name cloud-init-template
qm set $ID --boot order=scsi0
qm template $ID
