#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys
mount -t efivarfs efivarfs -o nosuid,nodev,noexec /sys/firmware/efi/efivars

find /sys -name modalias | while read m; do
    modalias=$(cat "$m")
    modprobe -v "$modalias" 2> /dev/null
done

modprobe -v nvme

rootdev=""
opt="rw"
wait=""
fstype="auto"

[ ! -f /etc/platform-preboot ] || . /etc/platform-preboot

if [ -z "$rootdev" ]; then
    for bootarg in `cat /proc/cmdline`; do
        case "$bootarg" in
            root=*) rootdev="${bootarg##root=}" ;;
            ro) opt="ro" ;;
            rootwait) wait="yes" ;;
            rootfstype=*) fstype="${bootarg##rootfstype=}" ;;
        esac
    done
fi

if [ -n "$wait" -a ! -b "${rootdev}" ]; then
    echo "Waiting for ${rootdev}..."
    while true; do
        test -b "${rootdev}" && break
        sleep 0.1
    done
fi

# OTIV
if [ "@@USE_OVERLAY@@" = "true" ]; then
	echo "Forcing RO on rootfs"
	opt="ro"
fi

echo "Mounting ${rootdev}..."
[ -d /mnt ] || mkdir -p /mnt
count=0
while [ $count -lt 5 ]; do
    if mount -t "${fstype}" -o "${opt}" "${rootdev}" /mnt; then
        break
    fi
    sleep 1.0
    count=`expr $count + 1`
done
[ $count -lt 5 ] || exec sh

[ ! -f /etc/platform-pre-switchroot ] || . /etc/platform-pre-switchroot

root="/mnt"

# OTIV
# There are several advantages to have the root filesystem loaded as Read-Only.
# First, there is the guarantee that the filesystem doesn't get corrupted by software.
# Second, one can just reboot the machine to fall back the original state after boot.
# Third, there is no risk of messing up any cryptographic signatures that are stored in the uefi partitions. This is necessary to perform secure-boot.

# These changes will, in the initramfs, mount the partition in RO mode as an ext4 filesystem,
# provide some directories in tmpfs and map those on top of the filesystem, creating an overlay,
# where all modifications take place in volatile (tmpfs) memory. The overlay is then used as the root filesystem.
if [ "@@USE_OVERLAY@@" = "true" ]; then
	echo "Applying overlay to rootfs"
	[ -d /otiv-overlay ] || mkdir -p /otiv-overlay
	# First execute the overlay
	mount -t tmpfs otiv-overlay-tmp /otiv-overlay
	mkdir -p /otiv-overlay/lower
	mkdir -p /otiv-overlay/upper
	mkdir -p /otiv-overlay/work
	mkdir -p /otiv-overlay/root
	mount -t overlay otiv-overlay -o lowerdir=${root},upperdir=/otiv-overlay/upper,workdir=/otiv-overlay/work /otiv-overlay/root
	root="/otiv-overlay/root"
	# Allow access to upper an work, but not to lower
	mkdir -p ${root}/overlay/lower
	mkdir -p ${root}/overlay/upper
	mkdir -p ${root}/overlay/work
	mount /mnt ${root}/overlay/lower
	mount /otiv-overlay/upper ${root}/overlay/upper
	mount /otiv-overlay/work ${root}/overlay/work
fi

echo "Switching to rootfs on ${rootdev}..."

mount --move /sys  ${root}/sys
mount --move /proc ${root}/proc
mount --move /dev  ${root}/dev

exec switch_root ${root} /sbin/init
