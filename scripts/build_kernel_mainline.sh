#!/bin/sh -e

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHROOT=${CHROOT=${ROOT_DIR}/rootfs}
KERNEL_REPO=${KERNEL_REPO=https://github.com/msm8916-mainline/linux.git}
KERNEL_BRANCH=${KERNEL_BRANCH=msm8916/6.12}
KERNEL_DEFCONFIG=${KERNEL_DEFCONFIG=defconfig}
KERNEL_DIR=${KERNEL_DIR=$(mktemp -d)}
KERNEL_OUT=${KERNEL_OUT=${KERNEL_DIR}/out}
MAKE_JOBS=${MAKE_JOBS=$(nproc)}
DTB_PATH=${DTB_PATH=arch/arm64/boot/dts/qcom/msm8916-yiming-uz801v3.dtb}

cleanup() {
	if [ -n "${KERNEL_DIR:-}" ] && [ -d "${KERNEL_DIR}" ] && [ "${KERNEL_DIR#${ROOT_DIR}/}" = "${KERNEL_DIR}" ]; then
		rm -rf "${KERNEL_DIR}"
	fi
}
trap cleanup EXIT

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

for c in git make rsync chroot sed; do
	need_cmd "$c"
done

[ -d "${CHROOT}" ] || {
	echo "Missing rootfs at ${CHROOT}" >&2
	exit 1
}

git clone --depth 1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" "${KERNEL_DIR}"
mkdir -p "${KERNEL_OUT}"

make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DEFCONFIG}"

"${KERNEL_DIR}/scripts/config" --file "${KERNEL_OUT}/.config" \
	-e CONFIG_ARCH_QCOM \
	-e CONFIG_QCOM_SMEM \
	-e CONFIG_QCOM_SMD_RPM \
	-e CONFIG_QCOM_SMEM_STATE \
	-e CONFIG_SERIAL_MSM \
	-e CONFIG_SERIAL_MSM_CONSOLE \
	-e CONFIG_PINCTRL_MSM8916 \
	-e CONFIG_MMC_SDHCI_MSM \
	-e CONFIG_MMC_CQHCI \
	-e CONFIG_QCOM_WCNSS_CTRL \
	-e CONFIG_WCN36XX \
	-e CONFIG_RFKILL \
	-e CONFIG_RPMSG_CTRL \
	-e CONFIG_RPMSG_CHAR \
	-e CONFIG_QRTR \
	-e CONFIG_QRTR_SMD \
	-e CONFIG_QCOM_QMI_HELPERS \
	-e CONFIG_QCOM_APR \
	-e CONFIG_QCOM_GLINK_SSR \
	-e CONFIG_QCOM_GSBI \
	-e CONFIG_QCOM_RMTFS_MEM \
	-e CONFIG_USB_NET_DRIVERS \
	-e CONFIG_USB_USBNET \
	-e CONFIG_USB_NET_QMI_WWAN \
	-e CONFIG_INPUT_EVDEV \
	-e CONFIG_TMPFS_POSIX_ACL \
	-e CONFIG_DEVTMPFS \
	-e CONFIG_DEVTMPFS_MOUNT \
	-e CONFIG_FHANDLE \
	-e CONFIG_BLK_DEV_LOOP \
	-e CONFIG_BLK_DEV_RAM \
	-e CONFIG_EXT4_FS \
	-e CONFIG_EXT4_FS_POSIX_ACL \
	-e CONFIG_F2FS_FS \
	-e CONFIG_SQUASHFS \
	-e CONFIG_OVERLAY_FS \
	-e CONFIG_IP_NF_IPTABLES \
	-e CONFIG_NF_TABLES \
	-e CONFIG_BRIDGE \
	-e CONFIG_VETH \
	-e CONFIG_CFG80211 \
	-e CONFIG_MAC80211 \
	-e CONFIG_FW_LOADER \
	-e CONFIG_FW_LOADER_USER_HELPER \
	-e CONFIG_FW_LOADER_COMPRESS \
	-e CONFIG_REMOTEPROC \
	-e CONFIG_QCOM_SYSMON \
	-e CONFIG_QCOM_PIL_INFO \
	-e CONFIG_QCOM_Q6V5_COMMON \
	-e CONFIG_QCOM_Q6V5_MSS \
	-e CONFIG_QCOM_Q6V5_WCNSS \
	-e CONFIG_QCOM_RPROC_COMMON \
	-e CONFIG_USB_CONFIGFS \
	-e CONFIG_USB_CONFIGFS_ECM \
	-e CONFIG_USB_CONFIGFS_RNDIS \
	-e CONFIG_USB_CONFIGFS_ACM \
	-e CONFIG_USB_CONFIGFS_MASS_STORAGE \
	-e CONFIG_USB_GADGET \
	-e CONFIG_USB_DWC3 \
	-e CONFIG_USB_DWC3_QCOM || true

yes "" | make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${MAKE_JOBS}" Image.gz modules dtbs

KERNEL_RELEASE=$(make -s -C "${KERNEL_DIR}" O="${KERNEL_OUT}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)
BOOT_DIR="${CHROOT}/boot"
DTB_DIR="${BOOT_DIR}/dtbs/qcom"

make -C "${KERNEL_DIR}" O="${KERNEL_OUT}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="${CHROOT}" modules_install

mkdir -p "${DTB_DIR}"
install -m 0644 "${KERNEL_OUT}/arch/arm64/boot/Image.gz" "${BOOT_DIR}/vmlinuz-${KERNEL_RELEASE}"
install -m 0644 "${KERNEL_OUT}/${DTB_PATH}" "${DTB_DIR}/$(basename "${DTB_PATH}")"

ln -sf "boot/vmlinuz-${KERNEL_RELEASE}" "${CHROOT}/vmlinuz"
ln -sfn "boot/dtbs" "${CHROOT}/dtbs"

chroot "${CHROOT}" /bin/sh -ec "
	depmod '${KERNEL_RELEASE}'
	update-initramfs -c -k '${KERNEL_RELEASE}'
	ln -sf 'boot/initrd.img-${KERNEL_RELEASE}' /initramfs
"

# Keep the short names expected by the builder and extlinux.
ln -sf "vmlinuz-${KERNEL_RELEASE}" "${BOOT_DIR}/vmlinuz"
ln -sf "initrd.img-${KERNEL_RELEASE}" "${BOOT_DIR}/initramfs"

echo "${KERNEL_RELEASE}" > "${ROOT_DIR}/files/kernel-release.txt"
