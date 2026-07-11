#!/bin/sh -e

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
MNT=$(mktemp -d)

cleanup() {
	umount "${MNT}" 2>/dev/null || true
	rm -rf "${TMPDIR}" "${MNT}"
}
trap cleanup EXIT

mkdir -p files

need_file() {
	[ -f "$1" ] || {
		echo "Missing required file: $1" >&2
		exit 1
	}
}

for f in \
	files/aboot.mbn \
	files/hyp.mbn \
	files/rpm.mbn \
	files/sbl1.mbn \
	files/tz.mbn \
	rootfs.tgz
do
	need_file "$f"
done

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

for c in dd find mkbootimg mkfs.ext4 sfdisk sha256sum sgdisk tar truncate; do
	need_cmd "$c"
done

TOTAL_SECTORS=7569375
DISK_BYTES=$((TOTAL_SECTORS * 512))
LAST_USABLE_LBA=$((TOTAL_SECTORS - 34))
CDT_START=131072
CDT_SIZE=4
SBL1_START=262144
SBL1_SIZE=1024
RPM_START=263168
RPM_SIZE=1024
TZ_START=264192
TZ_SIZE=2048
HYP_START=266240
HYP_SIZE=1024
SEC_START=267264
SEC_SIZE=32
MODEMST1_START=267296
MODEMST1_SIZE=4096
MODEMST2_START=271392
MODEMST2_SIZE=4096
FSC_START=275488
FSC_SIZE=2
FSG_START=393216
FSG_SIZE=4096
ABOOT_START=524288
ABOOT_SIZE=2048
BOOT_START=526336
BOOT_SIZE=131072
DEVINFO_START=657408
DEVINFO_SIZE=2048
ROOTFS_START=659456
ROOTFS_SIZE=6909886
ROOTFS_END=$((ROOTFS_START + ROOTFS_SIZE - 1))

ROOTFS_PARTUUID=A7AB80E8-E9D1-E8CD-F157-93F69B1D141E
CMDLINE="earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e no_framebuffer=true rw"
IMAGE_BASENAME=${IMAGE_BASENAME:-uz801_v2.1_debian13_trixie}

BOOT_RAW="$TMPDIR/boot.img"
ROOTFS_RAW="$TMPDIR/rootfs.img"
FULL_IMG="files/${IMAGE_BASENAME}.img"
FULL_XZ="files/${IMAGE_BASENAME}.img.xz"
GPT_TXT="files/${IMAGE_BASENAME}_gpt.txt"
MERGE_SCRIPT="files/merge_uz801_v21_fullimg.sh"

# Stage the rootfs so we can both pack it into ext4 and extract boot assets.
mkdir -p "$TMPDIR/rootfs"
tar xpf rootfs.tgz -C "$TMPDIR/rootfs"

# Create Android boot.img using the kernel and initramfs shipped in the rootfs.
KERNEL=$(find -L "$TMPDIR/rootfs/boot" -maxdepth 1 -type f \( -name 'vmlinuz*' -o -name 'Image*' \) | sort | head -n 1)
INITRAMFS=$(find -L "$TMPDIR/rootfs/boot" -maxdepth 1 -type f \( -name 'initramfs*' -o -name 'initrd*' \) | sort | head -n 1)

[ -n "$KERNEL" ] || {
	echo "Unable to find kernel under rootfs /boot" >&2
	exit 1
}
[ -n "$INITRAMFS" ] || {
	echo "Unable to find initramfs under rootfs /boot" >&2
	exit 1
}

[ "$ROOTFS_END" -le "$LAST_USABLE_LBA" ] || {
	echo "Rootfs partition ends at LBA $ROOTFS_END, beyond last usable LBA $LAST_USABLE_LBA" >&2
	exit 1
}

# Ubuntu Noble's mkbootimg imports GKI certificate helpers even when unused.
PYTHONPATH="${PYTHONPATH:+${PYTHONPATH}:}${ROOT_DIR}/tools/mkbootimg_compat" mkbootimg \
	--kernel "$KERNEL" \
	--ramdisk "$INITRAMFS" \
	--base 0x80000000 \
	--kernel_offset 0x00080000 \
	--ramdisk_offset 0x02000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x01e00000 \
	--pagesize 2048 \
	--cmdline "$CMDLINE" \
	--output "$BOOT_RAW"

truncate -s $((BOOT_SIZE * 512)) "$BOOT_RAW"

# Create rootfs partition image with the same partition capacity as the known-good image.
truncate -s $((ROOTFS_SIZE * 512)) "$ROOTFS_RAW"
mkfs.ext4 -q -F -U "${ROOTFS_PARTUUID}" -L rootfs "$ROOTFS_RAW"
mount "$ROOTFS_RAW" "$MNT"
tar xpf rootfs.tgz -C "$MNT"
cp -a dist/* "$MNT"
sync
umount "$MNT"

cp "$BOOT_RAW" "files/${IMAGE_BASENAME}_boot.img"
cp "$ROOTFS_RAW" "files/${IMAGE_BASENAME}_rootfs.img"
cp "scripts/merge_uz801_v21_fullimg.sh" "$MERGE_SCRIPT"
chmod 0755 "$MERGE_SCRIPT"

FILES_DIR=files IMAGE_BASENAME="$IMAGE_BASENAME" sh -e scripts/merge_uz801_v21_fullimg.sh

(
	cd files
	sha256sum \
		"merge_uz801_v21_fullimg.sh" \
		"${IMAGE_BASENAME}_boot.img" \
		"${IMAGE_BASENAME}_rootfs.img" \
		"${IMAGE_BASENAME}.img" \
		"${IMAGE_BASENAME}.img.xz" \
		"${IMAGE_BASENAME}_gpt.txt" > "${IMAGE_BASENAME}_SHA256SUMS"
)

echo "Built $FULL_IMG and $FULL_XZ"
