#!/bin/sh -e

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHROOT=${CHROOT=${ROOT_DIR}/rootfs}
KERNEL_DEB=${KERNEL_DEB=}
DTB_BASENAME=${DTB_BASENAME=msm8916-yiming-uz801v3.dtb}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

for c in depmod dpkg-deb find head install ln mkdir sort tail; do
	need_cmd "$c"
done

[ -d "${CHROOT}" ] || {
	echo "Missing rootfs at ${CHROOT}" >&2
	exit 1
}

[ -n "${KERNEL_DEB}" ] || {
	echo "KERNEL_DEB is not set" >&2
	exit 1
}

[ -f "${KERNEL_DEB}" ] || {
	echo "Missing kernel deb: ${KERNEL_DEB}" >&2
	exit 1
}

dpkg-deb -x "${KERNEL_DEB}" "${CHROOT}"

MODULES_DIR=$(find "${CHROOT}/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
[ -n "${MODULES_DIR}" ] || {
	echo "Unable to determine installed module directory after extracting ${KERNEL_DEB}" >&2
	exit 1
}

KERNEL_RELEASE=$(basename "${MODULES_DIR}")
BOOT_DIR="${CHROOT}/boot"
DTB_DIR="${BOOT_DIR}/dtbs/qcom"

mkdir -p "${DTB_DIR}"

# Some kernel .deb packages ship dtbs under /usr/lib/linux-image-*/ or /lib/firmware/.
DTB_SOURCE=$(find "${CHROOT}" -type f -name "${DTB_BASENAME}" | head -n 1 || true)
if [ -n "${DTB_SOURCE}" ]; then
	install -m 0644 "${DTB_SOURCE}" "${DTB_DIR}/${DTB_BASENAME}"
	ln -sfn "boot/dtbs" "${CHROOT}/dtbs"
fi

if [ -f "${BOOT_DIR}/vmlinuz-${KERNEL_RELEASE}" ]; then
	ln -sf "boot/vmlinuz-${KERNEL_RELEASE}" "${CHROOT}/vmlinuz"
	ln -sf "vmlinuz-${KERNEL_RELEASE}" "${BOOT_DIR}/vmlinuz"
fi

# We boot with a prebuilt Android boot.img, so the rootfs only needs the
# extracted modules/userspace bits from the .deb. Avoid chrooted initramfs
# generation here; it is brittle in CI and unnecessary for this flow.
depmod -b "${CHROOT}" "${KERNEL_RELEASE}"

mkdir -p "${ROOT_DIR}/files"
echo "${KERNEL_RELEASE}" > "${ROOT_DIR}/files/kernel-release.txt"
