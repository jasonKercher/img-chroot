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
		eprintln "$*"
		return 0
	fi
	msg=$1
	panic "$msg: Failure"
}

usage() {
	echo "$0 <image or block device> <mount point>"
	abort
}

CLEAN_UP() {
	if [ -n "$term_store" ]; then
		export TERM=$term_store
	fi

	if [ ! -d "$mount_point" ]; then
		return 0
	fi

	if [ -f "${mount_point}/etc/resolv.conf.BAK" ]; then
		mv -v "${mount_point}/etc/resolv.conf.BAK" \
		      "${mount_point}/etc/resolv.conf"
	else
		rm "${mount_point}/etc/resolv.conf" 2>> /dev/null
	fi
	umount "${mount_point}/dev/pts/" 2>> /dev/null
	umount "${mount_point}/dev/" 2>> /dev/null
	umount "${mount_point}/sys/" 2>> /dev/null
	umount "${mount_point}/proc/" 2>> /dev/null

	# If this is the case, the root file system is mounted FROM the
	# boot partition, so we must umount root FIRST!
	local boot_mount_point
	boot_mount_point=$(readlink "${mount_point}/boot/bootfiles")
	if [ $? -eq 0 ]; then
		rm "${mount_point}/boot/bootfiles"

		umount "${mount_point}" 2>> /dev/null
		umount "$boot_mount_point"
		rmdir -v "$boot_mount_point"
	else
		umount "${mount_point}/boot"
		umount "${mount_point}"
	fi
}

umount=false
mount_only=false
while getopts ':-:p:h' opt; do
	if [ "$opt" = "-" ]; then
		opt="${OPTARG%%=*}"
		OPTARG="${OPTARG#$opt}"
		OPTARG="${OPTARG#=}"
	fi

	case "$opt" in
	m | mount-only)  mount_only=true;;
	u | umount)      umount=true;;
	h | help)        echo 'lol no'; return;;
	\?)              exit 2;;
	*)               eprintln "$OPTARG: invalid init argument";;
	esac
done
shift $((OPTIND-1))

if [ $EUID -ne 0 ]; then
	panic "must be superuser to use $0"
fi

if $umount; then
	mount_point="$1"
	CLEAN_UP
	exit
fi

if [ $# -lt 2 ]; then
	eprintln 'Missing argument(s)'
	usage
fi

if ! command -v kpartx >> /dev/null; then
	panic "$0 depends on kpartx"
fi

mount_point=$2
if [ ! -d "$mount_point" ]; then
	panic "mount point '$mount_point' does not exist"
fi

term_store=$TERM

image_or_block=$1
part_info=$(kpartx "$image_or_block")
catch_error kpartx

# TODO: Not this.
part_count=$(wc -l <<< "$part_info")
if [ $part_count -gt 2 ]; then
	panicf 'Found %d partitions. Expected 1 or 2.\n' $part_count
fi

boot_part=$(head -1 <<< "$part_info")
linux_part=$(tail -1 <<< "$part_info")

boot_mount_point="${mount_point}/boot"
if [ $part_count -eq 1 ]; then
	boot_mount_point=$(mktemp -d)
	echo "Boot mount point: '$boot_mount_point'"
fi

if [ -b "$image_or_block" ]; then
	if [ $part_count -eq 2 ]; then
		linux_dev=$(cut -d' ' -f1 <<< "$linux_part")
		mount "/dev/${linux_dev}" "$mount_point"
		catch_error 'mount linux partition'
	fi

	boot_dev=$(cut -d' ' -f1 <<< "$boot_part")
	mount "/dev/${boot_dev}" "$boot_mount_point"
	catch_error 'mount boot partition'
elif [ -f "$image_or_block" ]; then
	if [ $part_count -eq 2 ]; then
		linux_off=$(cut -d' ' -f6 <<< "$linux_part")
		((linux_off *= 512))
		linux_sz=$(cut -d' ' -f4 <<< "$linux_part")
		((linux_sz *= 512))

		mount -o loop,offset=$linux_off,sizelimit=$linux_sz "$image_or_block" "$mount_point"
		catch_error 'mount linux partition'
	fi

	boot_off=$(cut -d' ' -f6 <<< "$boot_part")
	((boot_off *= 512))
	boot_sz=$(cut -d' ' -f4 <<< "$boot_part")
	((boot_sz *= 512))

	mount -o loop,offset=$boot_off,sizelimit=$boot_sz "$image_or_block" "$boot_mount_point"
	catch_error 'mount boot partition'
else
	panic "'$image_or_block' is not a block device or file"
fi

# If there is only 1 partition, then we are going to assume, there is a
# filesystem "file" in the boot partition that must be mounted.
if [ $part_count -eq 1 ]; then
	mount "${boot_mount_point}/"*.ext* "$mount_point"
	catch_error 'failed to mount filesystem file'

	ln -s "$boot_mount_point" "${mount_point}/boot/bootfiles"
fi

if $mount_only; then
	exit 0
fi

mount --bind /dev "${mount_point}/dev/"
catch_error 'bind mount /dev/'

mount --bind /dev/pts "${mount_point}/dev/pts/"
catch_error 'bind mount /dev/pts/'

mount --bind /sys "${mount_point}/sys/"
catch_error 'bind mount /sys/'

mount --bind /proc "${mount_point}/proc/"
catch_error 'bind mount /proc/'

if [ -f "${mount_point}/etc/resolv.conf" ] || readlink "${mount_point}/etc/resolv.conf" >> /dev/null; then
	mv -v "${mount_point}/etc/resolv.conf" \
	      "${mount_point}/etc/resolv.conf.BAK"
fi
cp /etc/resolv.conf "${mount_point}/etc/"

# chroot to raspbian
export TERM=xterm-256color

chroot "${mount_point}" /bin/bash
catch_error chroot

CLEAN_UP

