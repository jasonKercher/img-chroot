#!/bin/bash

abort() {
	if declare -F CLEAN_UP >> /dev/null; then
		CLEAN_UP "$@"
	fi
	exit 2
}

eprintf() {
	1>&2 printf "$@"
}

eprintln() {
	1>&2 echo "$*"
}

panicf() {
	local fmt=$1
	shift
	eprintf "PANIC: $fmt\\n" "$@"
	abort
}

panic() {
	eprintln "PANIC: $*"
	abort
}

catch_error() {
	res=$?
	if [ $res -eq 0 ]; then
		return 0
	fi

	if [ "$1" = '--warn' ]; then
		shift
	fi
	msg=$1
	panic "$msg: Failure"
}

usage() {
	echo "$0 <image or block device> <mount point>"
	abort
}

CLEAN_UP() {
	if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
		return 0
	fi
	umount "${mount_point}/dev/pts/" 2>> /dev/null
	umount "${mount_point}/dev/" 2>> /dev/null
	umount "${mount_point}/sys/" 2>> /dev/null
	umount "${mount_point}/proc/" 2>> /dev/null
	umount "${mount_point}/boot/" 2>> /dev/null
	umount "${mount_point}" 2>> /dev/null
}

if [ $# -lt 2 ]; then
	eprintln 'Missing argument(s)'
	usage
fi

if ! command -v kpartx >> /dev/null; then
	panic "$0 depends on kpartx"
fi

if [ $EUID -ne 0 ]; then
	panic "must be superuser to use $0"
fi

mount_point=$2
if [ ! -d "$mount_point" ]; then
	panic "mount point '$mount_point' does not exist"
fi

image_or_block=$1
part_info=$(kpartx "$image_or_block")
catch_error kpartx

# NOTE: logic assumes 2 partitions = boot,linux.
# TODO: Not this.
part_count=$(wc -l <<< "$part_info")
if [ $part_count -ne 2 ]; then
	panicf 'Found %d partitions. Expected 2.\n' $part_count
fi

boot_part=$(head -1 <<< "$part_info")
linux_part=$(tail -1 <<< "$part_info")

if [ -b "$image_or_block" ]; then
	linux_dev=$(cut -d' ' -f1 <<< "$linux_part")
	boot_dev=$(cut -d' ' -f1 <<< "$boot_part")

	mount "/dev/${linux_dev}" "$mount_point"
	catch_error 'mount linux partition'

	mount "/dev/${boot_dev}" "${mount_point}/boot/"
	catch_error 'mount boot partition'
elif [ -f "$1" ]; then
	linux_off=$(cut -d' ' -f6 <<< "$linux_part")
	((linux_off *= 512))
	linux_sz=$(cut -d' ' -f4 <<< "$linux_part")
	((linux_sz *= 512))

	boot_off=$(cut -d' ' -f6 <<< "$boot_part")
	((boot_off *= 512))
	boot_sz=$(cut -d' ' -f4 <<< "$boot_part")
	((boot_sz *= 512))

	mount -o loop,offset=$linux_off,sizelimit=$linux_sz "$image_or_block" "${mount_point}"
	catch_error 'mount linux partition'

	mount -o loop,offset=$boot_off,sizelimit=$boot_sz "$image_or_block" "${mount_point}/boot/"
	catch_error 'mount boot partition'
else
	panic "'$image_or_block' is not a block device or file"
fi

mount --bind /dev "${mount_point}/dev/"
catch_error 'bind mount /dev/'

mount --bind /dev/pts "${mount_point}/dev/pts/"
catch_error 'bind mount /dev/pts/'

mount --bind /sys "${mount_point}/sys/"
catch_error 'bind mount /sys/'

mount --bind /proc "${mount_point}/proc/"
catch_error 'bind mount /proc/'

# chroot to raspbian
chroot "${mount_point}" /bin/bash
catch_error chroot

CLEAN_UP

