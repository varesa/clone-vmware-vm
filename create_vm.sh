#!/bin/bash
# shellcheck disable=SC2002

set -euo pipefail

##
## Requirements:
# - rsync
# - libguestfs-tools-c

##
## Parameters

if [ "$#" != "5" ]; then
	echo "Usage: $0 <target path> <hostname> <ip address with mask> <gateway address> <ssh keys file>"
	echo "For example: $0 /tmp/newvm newvm.example.com 10.0.123.100/24 10.0.123.1 ~/.ssh/id_ed25519.pub"
	exit 1
fi

templatepath="template"
if ! test -d "$templatepath"; then 
    echo "Error: Template path does not exist"
    exit 1
fi

targetpath="$1"
if test -e "$targetpath"; then
    echo "Error: Target path already exists"
    exit 1
fi

hostname="$2"
address="$3"
gateway="$4"

sshkeys="$5"
if ! test -f "$sshkeys"; then
    echo "Error: SSH keys not found at $sshkeys"
    exit 1
fi


##
## Actions

mkdir "$targetpath"

#
# Copy disks

echo "Cloning disks from $templatepath/ to $targetpath/"
echo ""
RSYNC_OPTS="--progress --sparse --inplace"
rsync $RSYNC_OPTS "${templatepath}/debian10-template_0-flat.vmdk" "${targetpath}/${hostname}_boot_flat.vmdk"
rsync $RSYNC_OPTS "${templatepath}/debian10-template_1-flat.vmdk" "${targetpath}/${hostname}_root_flat.vmdk"
rsync $RSYNC_OPTS "${templatepath}/debian10-template_2-flat.vmdk" "${targetpath}/${hostname}_swap_flat.vmdk"
rsync $RSYNC_OPTS "${templatepath}/debian10-template_3-flat.vmdk" "${targetpath}/${hostname}_data_flat.vmdk"
echo ""

#
# Create descriptors

echo "Creating VMDK descriptors"

root_disk="${targetpath}/${hostname}_root.vmdk"
cat "${templatepath}/debian10-template_0.vmdk" | sed "s/debian10-template_0-flat.vmdk/${hostname}_boot_flat.vmdk/" > "${targetpath}/${hostname}_boot.vmdk"
cat "${templatepath}/debian10-template_1.vmdk" | sed "s/debian10-template_1-flat.vmdk/${hostname}_root_flat.vmdk/" > "${targetpath}/${hostname}_root.vmdk"
cat "${templatepath}/debian10-template_2.vmdk" | sed "s/debian10-template_2-flat.vmdk/${hostname}_swap_flat.vmdk/" > "${targetpath}/${hostname}_swap.vmdk"
cat "${templatepath}/debian10-template_3.vmdk" | sed "s/debian10-template_3-flat.vmdk/${hostname}_data_flat.vmdk/" > "${targetpath}/${hostname}_data.vmdk"

echo "Creating VMX file"

cat "${templatepath}/debian10-template.vmx" \
    | sed "s/debian10-template_0.vmdk/${hostname}_boot.vmdk/" \
    | sed "s/debian10-template_1.vmdk/${hostname}_root.vmdk/" \
    | sed "s/debian10-template_2.vmdk/${hostname}_swap.vmdk/" \
    | sed "s/debian10-template_3.vmdk/${hostname}_data.vmdk/" \
    | sed "s/debian10-template/${hostname}/g" \
    > "${targetpath}/${hostname}.vmx"

echo "Copying NVRAM"

cp "${templatepath}/debian10-template.nvram" "${targetpath}/${hostname}.nvram"
echo ""

#
# Mount image for modifications

mountpoint="$(mktemp -d)"
guestmount -i -a "$root_disk" "$mountpoint"

echo "Mounted $root_disk at $mountpoint"
echo ""

echo "- setting hostname"
echo "$hostname" > "${mountpoint}/etc/hostname"

echo "- resetting identity"

rm -f "${mountpoint}/etc/ssh/ssh_host_"*
rm -f "${mountpoint}/etc/machine-id"

echo "- regenerating SSH keys"
ssh-keygen -q -t rsa     -f "${mountpoint}/etc/ssh/ssh_host_rsa_key"     -C '' -N '' #>&/dev/null
ssh-keygen -q -t ecdsa   -f "${mountpoint}/etc/ssh/ssh_host_ecdsa_key"   -C '' -N '' #>&/dev/null
ssh-keygen -q -t ed25519 -f "${mountpoint}/etc/ssh/ssh_host_ed25519_key" -C '' -N '' #>&/dev/null
chmod 600 "${mountpoint}/etc/ssh/ssh_host_"*

echo "- setting network configuration"
cat << EOF > "${mountpoint}/etc/network/interfaces"
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
	address ${address}
	gateway ${gateway}
    post-up /sbin/ethtool -K eth0 lro off
EOF

echo "- setting authorized_keys"
cat "$sshkeys" > "${mountpoint}/root/.ssh/authorized_keys"
chmod 600 "${mountpoint}/root/.ssh/authorized_keys"

echo "- removing passwords (TODO)"

echo "- unmounting"
umount "$mountpoint"
rmdir "$mountpoint"
echo ""
