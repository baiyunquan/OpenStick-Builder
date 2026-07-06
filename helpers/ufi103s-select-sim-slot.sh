#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run as root" >&2
	exit 1
fi

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 physical|esim1|esim2" >&2
	exit 1
fi

slot=$1
base=/boot
variant_dir=/boot/dtbs/variants
active_dtb=$base/msm8916-thwc-ufi001c.dtb

case "$slot" in
	physical) variant=$variant_dir/msm8916-thwc-ufi001c-physical.dtb ;;
	esim1) variant=$variant_dir/msm8916-thwc-ufi001c-esim1.dtb ;;
	esim2) variant=$variant_dir/msm8916-thwc-ufi001c-esim2.dtb ;;
	*)
		echo "Unknown slot: $slot" >&2
		exit 1
		;;
esac

if [ ! -f "$variant" ]; then
	echo "Variant DTB not found: $variant" >&2
	echo "Install DTB variants to /boot/dtbs/variants first." >&2
	exit 1
fi

if [ -f /sys/class/remoteproc/remoteproc0/state ]; then
	state=$(cat /sys/class/remoteproc/remoteproc0/state || true)
	if [ "$state" = "running" ]; then
		echo stop > /sys/class/remoteproc/remoteproc0/state || true
	fi
fi

cp "$active_dtb" "$active_dtb.bak"
cp "$variant" "$active_dtb"
sync

echo "Active SIM DTB switched to: $slot"
echo "Reboot the device to apply the new modem routing."
