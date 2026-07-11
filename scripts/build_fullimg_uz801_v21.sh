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
LAST_USABLE_LBA=$((TOTAL_SECTORS - 2))
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
ROOTFS_SIZE=6909918
ROOTFS_END=$((ROOTFS_START + ROOTFS_SIZE - 1))

ROOTFS_PARTUUID=A7AB80E8-E9D1-E8CD-F157-93F69B1D141E
CMDLINE="earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e no_framebuffer=true rw"
IMAGE_BASENAME=${IMAGE_BASENAME:-uz801_v2.1_debian13_trixie}

BOOT_RAW="$TMPDIR/boot.img"
ROOTFS_RAW="$TMPDIR/rootfs.img"
FULL_IMG="files/${IMAGE_BASENAME}.img"
FULL_XZ="files/${IMAGE_BASENAME}.img.xz"
GPT_TXT="files/${IMAGE_BASENAME}_gpt.txt"

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

# Create a valid GPT full image using the known-good FY_UZ801_V2.1 layout.
truncate -s "$DISK_BYTES" "$FULL_IMG"

cat <<EOF | sfdisk "$FULL_IMG" >/dev/null
label: gpt
label-id: DB708ACF-2E04-8DE2-BAFE-30C9B26444C5
unit: sectors
first-lba: 34
last-lba: $LAST_USABLE_LBA
sector-size: 512

${FULL_IMG}1  : start=$CDT_START,      size=$CDT_SIZE,      type=A19F205F-CCD8-4B6D-8F1E-2D9BC24CFFB1, uuid=18285060-B8C8-7CF7-2823-FD5DD2956B88, name="cdt"
${FULL_IMG}2  : start=$SBL1_START,     size=$SBL1_SIZE,     type=DEA0BA2C-CBDD-4805-B4F9-F428251C3E98, uuid=534641AB-51F1-F296-CF79-26E9C92E9002, name="sbl1"
${FULL_IMG}3  : start=$RPM_START,      size=$RPM_SIZE,      type=098DF793-D712-413D-9D4E-89D711772228, uuid=4CD3470F-02EF-5E92-C4F4-14BB5251E8F1, name="rpm"
${FULL_IMG}4  : start=$TZ_START,       size=$TZ_SIZE,       type=A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4, uuid=0929EF2F-5CBE-B222-9AFF-64578C4E1FEB, name="tz"
${FULL_IMG}5  : start=$HYP_START,      size=$HYP_SIZE,      type=E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A, uuid=BF2EA2B6-9F32-B528-99BB-C856CD988976, name="hyp"
${FULL_IMG}6  : start=$SEC_START,      size=$SEC_SIZE,      type=303E6AC3-AF15-4C54-9E9B-D9A8FBECF401, uuid=DB68EEC7-4C13-BC28-F720-2241BB41D057, name="sec"
${FULL_IMG}7  : start=$MODEMST1_START, size=$MODEMST1_SIZE, type=EBBEADAF-22C9-E33B-8F5D-0E81686A68CB, uuid=F4C8387D-6628-200B-82CC-16025907D272, name="modemst1"
${FULL_IMG}8  : start=$MODEMST2_START, size=$MODEMST2_SIZE, type=0A288B1F-22C9-E33B-8F5D-0E81686A68CB, uuid=45BA3E2A-D277-68A3-4A11-748D8EF623AF, name="modemst2"
${FULL_IMG}9  : start=$FSC_START,      size=$FSC_SIZE,      type=57B90A16-22C9-E33B-8F5D-0E81686A68CB, uuid=28FA1C81-5B9F-3A57-290B-E8CA46EB0055, name="fsc"
${FULL_IMG}10 : start=$FSG_START,      size=$FSG_SIZE,      type=638FF8E2-22C9-E33B-8F5D-0E81686A68CB, uuid=0D6C74B1-89BD-841E-4B2E-B7B23246967B, name="fsg"
${FULL_IMG}11 : start=$ABOOT_START,    size=$ABOOT_SIZE,    type=400FFDCD-22E0-47E7-9A23-F16ED9382388, uuid=2432CE91-198E-589B-5D6C-1E2953615A38, name="aboot"
${FULL_IMG}12 : start=$BOOT_START,     size=$BOOT_SIZE,     type=20117F86-E985-4357-B9EE-374BC1D8487D, uuid=80780B1D-0FE1-27D3-23E4-9244E62F8C46, name="boot"
${FULL_IMG}13 : start=$DEVINFO_START,  size=$DEVINFO_SIZE,  type=1B81E7E6-F50D-419B-A739-2AEEF8DA3335, uuid=8B46880A-3DE7-53E5-1E74-4602F82E1993, name="devinfo"
${FULL_IMG}14 : start=$ROOTFS_START,   size=$ROOTFS_SIZE,   type=97D7B011-54DA-4835-B3C4-917AD6E73D74, uuid=$ROOTFS_PARTUUID, name="rootfs"
EOF

# Write each partition payload into the matching full-image slot.
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$CDT_START count=$CDT_SIZE conv=notrunc status=none
dd if=files/sbl1.mbn of="$FULL_IMG" bs=512 seek=$SBL1_START conv=notrunc status=none
dd if=files/rpm.mbn of="$FULL_IMG" bs=512 seek=$RPM_START conv=notrunc status=none
dd if=files/tz.mbn of="$FULL_IMG" bs=512 seek=$TZ_START conv=notrunc status=none
dd if=files/hyp.mbn of="$FULL_IMG" bs=512 seek=$HYP_START conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$SEC_START count=$SEC_SIZE conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$MODEMST1_START count=$MODEMST1_SIZE conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$MODEMST2_START count=$MODEMST2_SIZE conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$FSC_START count=$FSC_SIZE conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$FSG_START count=$FSG_SIZE conv=notrunc status=none
dd if=files/aboot.mbn of="$FULL_IMG" bs=512 seek=$ABOOT_START conv=notrunc status=none
dd if="$BOOT_RAW" of="$FULL_IMG" bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=/dev/zero of="$FULL_IMG" bs=512 seek=$DEVINFO_START count=$DEVINFO_SIZE conv=notrunc status=none
dd if="$ROOTFS_RAW" of="$FULL_IMG" bs=512 seek=$ROOTFS_START conv=notrunc status=none

cp "$BOOT_RAW" "files/${IMAGE_BASENAME}_boot.img"
cp "$ROOTFS_RAW" "files/${IMAGE_BASENAME}_rootfs.img"
sgdisk -p "$FULL_IMG" > "$GPT_TXT"
xz -T0 -f -k "$FULL_IMG"

(
	cd files
	sha256sum \
		"${IMAGE_BASENAME}_boot.img" \
		"${IMAGE_BASENAME}_rootfs.img" \
		"${IMAGE_BASENAME}.img" \
		"${IMAGE_BASENAME}.img.xz" \
		"${IMAGE_BASENAME}_gpt.txt" > "${IMAGE_BASENAME}_SHA256SUMS"
)

echo "Built $FULL_IMG and $FULL_XZ"
