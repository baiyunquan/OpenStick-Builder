#!/bin/sh -e

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHROOT=${CHROOT=${ROOT_DIR}/rootfs}
ARTIFACTS_DIR=${ARTIFACTS_DIR=${ROOT_DIR}/kernel-artifacts}
DTB_BASENAME=${DTB_BASENAME=msm8916-yiming-uz801v3.dtb}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

for c in chroot find install rsync tar zstd; do
	need_cmd "$c"
done

[ -d "${CHROOT}" ] || {
	echo "Missing rootfs at ${CHROOT}" >&2
	exit 1
}

[ -d "${ARTIFACTS_DIR}" ] || {
	echo "Missing artifact directory at ${ARTIFACTS_DIR}" >&2
	exit 1
}

KERNEL_IMAGE=$(find "${ARTIFACTS_DIR}" -type f \( -name 'Image.gz' -o -name 'Image' -o -name 'vmlinuz*' \) | head -n 1)
[ -n "${KERNEL_IMAGE}" ] || {
	echo "Unable to find a kernel image under ${ARTIFACTS_DIR}" >&2
	exit 1
}

DTB_FILE=$(find "${ARTIFACTS_DIR}" -type f -name "${DTB_BASENAME}" | head -n 1)
[ -n "${DTB_FILE}" ] || {
	echo "Unable to find ${DTB_BASENAME} under ${ARTIFACTS_DIR}" >&2
	exit 1
}

MODULES_DIR=
if find "${ARTIFACTS_DIR}" -type d -path '*/lib/modules/*' | grep -q .; then
	MODULES_DIR=$(find "${ARTIFACTS_DIR}" -type d -path '*/lib/modules/*' | head -n 1)
	mkdir -p "${CHROOT}/lib/modules"
	rsync -a "${MODULES_DIR}/" "${CHROOT}/lib/modules/$(basename "${MODULES_DIR}")/"
fi

if [ -z "${MODULES_DIR}" ]; then
	MODULES_ARCHIVE=$(find "${ARTIFACTS_DIR}" -type f \( -name '*modules*.tar.zst' -o -name '*modules*.tar.gz' -o -name '*modules*.tar.xz' -o -name '*modules*.tar' \) | head -n 1)
	[ -n "${MODULES_ARCHIVE}" ] || {
		echo "Unable to find kernel modules in ${ARTIFACTS_DIR}" >&2
		exit 1
	}

	case "${MODULES_ARCHIVE}" in
		*.tar.zst) tar --zstd -xf "${MODULES_ARCHIVE}" -C "${CHROOT}" ;;
		*.tar.gz) tar -xzf "${MODULES_ARCHIVE}" -C "${CHROOT}" ;;
		*.tar.xz) tar -xJf "${MODULES_ARCHIVE}" -C "${CHROOT}" ;;
		*.tar) tar -xf "${MODULES_ARCHIVE}" -C "${CHROOT}" ;;
	esac

	MODULES_DIR=$(find "${CHROOT}/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
fi

[ -n "${MODULES_DIR}" ] || {
	echo "Unable to determine installed module directory" >&2
	exit 1
}

KERNEL_RELEASE=$(basename "${MODULES_DIR}")
BOOT_DIR="${CHROOT}/boot"
DTB_DIR="${BOOT_DIR}/dtbs/qcom"

mkdir -p "${DTB_DIR}"
install -m 0644 "${KERNEL_IMAGE}" "${BOOT_DIR}/vmlinuz-${KERNEL_RELEASE}"
install -m 0644 "${DTB_FILE}" "${DTB_DIR}/${DTB_BASENAME}"

ln -sf "boot/vmlinuz-${KERNEL_RELEASE}" "${CHROOT}/vmlinuz"
ln -sfn "boot/dtbs" "${CHROOT}/dtbs"

chroot "${CHROOT}" /bin/sh -ec "
	depmod '${KERNEL_RELEASE}'
	update-initramfs -c -k '${KERNEL_RELEASE}'
	ln -sf 'boot/initrd.img-${KERNEL_RELEASE}' /initramfs
"

ln -sf "vmlinuz-${KERNEL_RELEASE}" "${BOOT_DIR}/vmlinuz"
ln -sf "initrd.img-${KERNEL_RELEASE}" "${BOOT_DIR}/initramfs"

mkdir -p "${ROOT_DIR}/files"
echo "${KERNEL_RELEASE}" > "${ROOT_DIR}/files/kernel-release.txt"
