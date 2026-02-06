#!/bin/bash
# Script outline to install and build kernel.
# Author: Siddhant Jajoo.

set -e
set -u
set -x

OUTDIR=/tmp/aeld
KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
KERNEL_VERSION=v5.15.163
BUSYBOX_VERSION=1_33_1
FINDER_APP_DIR=$(realpath $(dirname $0))
ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-

if [ $# -lt 1 ]
then
	echo "Using default directory ${OUTDIR} for output"
else
	OUTDIR=$1
	echo "Using passed directory ${OUTDIR} for output"
fi

OUTDIR=$(realpath -m "${OUTDIR}")
mkdir -p "${OUTDIR}"
if [ ! -d "${OUTDIR}" ]; then
	echo "Failed to create output directory ${OUTDIR}"
	exit 1
fi

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/linux" ]; then
    #Clone only if the repository does not exist.
	echo "CLONING GIT LINUX STABLE VERSION ${KERNEL_VERSION} IN ${OUTDIR}"
	git clone ${KERNEL_REPO} --depth 1 --single-branch --branch ${KERNEL_VERSION}
fi
if [ ! -e ${OUTDIR}/linux/arch/${ARCH}/boot/Image ]; then
    cd linux
    echo "Checking out version ${KERNEL_VERSION}"
    git checkout ${KERNEL_VERSION}

    # Add your kernel build steps here
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} mrproper
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    make -j"$(nproc)" ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} all
    make -j"$(nproc)" ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} modules
    make -j"$(nproc)" ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} dtbs
fi

echo "Adding the Image in outdir"
cp -a ${OUTDIR}/linux/arch/${ARCH}/boot/Image ${OUTDIR}/

echo "Creating the staging directory for the root filesystem"
cd "$OUTDIR"
if [ -d "${OUTDIR}/rootfs" ]
then
	echo "Deleting rootfs directory at ${OUTDIR}/rootfs and starting over"
    sudo rm  -rf ${OUTDIR}/rootfs
fi

# Create necessary base directories
mkdir -p ${OUTDIR}/rootfs
mkdir -p ${OUTDIR}/rootfs/{bin,dev,etc,home,lib,lib64,proc,sbin,sys,tmp,usr,var}
mkdir -p ${OUTDIR}/rootfs/usr/{bin,lib,sbin}
mkdir -p ${OUTDIR}/rootfs/var/log

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/busybox" ]
then
    git clone git://busybox.net/busybox.git
    cd busybox
    git checkout ${BUSYBOX_VERSION}
    # Configure busybox
    make distclean
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    # Disable tc app to avoid build errors with older kernel headers in toolchains.
    sed -i 's/^CONFIG_TC=.*/# CONFIG_TC is not set/' .config
else
    cd busybox
fi

# Ensure tc is disabled even when busybox already exists.
yes "" | make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} oldconfig

# Make and install busybox
make -j"$(nproc)" ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}
make CONFIG_PREFIX=${OUTDIR}/rootfs ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} install

echo "Library dependencies"
${CROSS_COMPILE}readelf -a ${OUTDIR}/busybox/busybox | grep "program interpreter"
${CROSS_COMPILE}readelf -a ${OUTDIR}/busybox/busybox | grep "Shared library"

# Add library dependencies to rootfs
SYSROOT=$(${CROSS_COMPILE}gcc -print-sysroot)
# Some toolchains report "/" as sysroot; derive a real sysroot from libc if so.
if [ -z "${SYSROOT}" ] || [ "${SYSROOT}" = "/" ]; then
    LIBC_PATH=$(${CROSS_COMPILE}gcc -print-file-name=libc.so.6)
    if [ -n "${LIBC_PATH}" ] && [ -e "${LIBC_PATH}" ]; then
        SYSROOT=$(dirname $(dirname $(realpath "${LIBC_PATH}")))
    fi
fi
if [ -z "${SYSROOT}" ] || [ "${SYSROOT}" = "/" ]; then
    echo "Failed to determine a valid sysroot for ${CROSS_COMPILE}gcc"
    exit 1
fi
INTERP=$(${CROSS_COMPILE}readelf -a ${OUTDIR}/busybox/busybox | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
LIBS=$(${CROSS_COMPILE}readelf -a ${OUTDIR}/busybox/busybox | awk -F'[][]' '/Shared library/ {print $2}')
for lib in ${INTERP} ${LIBS}; do
    if [ -e "${SYSROOT}${lib}" ]; then
        dest="${OUTDIR}/rootfs$(dirname ${lib})"
        mkdir -p "${dest}"
        # Dereference symlinks so the actual loader/library is present in initramfs.
        cp -aL "${SYSROOT}${lib}" "${dest}/"
    else
        found=$(find "${SYSROOT}" -name "${lib}" -type f 2>/dev/null | head -n 1)
        if [ -n "${found}" ]; then
            dest="${OUTDIR}/rootfs$(dirname ${found#${SYSROOT}})"
            mkdir -p "${dest}"
            # Dereference symlinks so the actual library file is copied.
            cp -aL "${found}" "${dest}/"
        fi
    fi
done

# Make device nodes
sudo mknod -m 666 ${OUTDIR}/rootfs/dev/null c 1 3
sudo mknod -m 600 ${OUTDIR}/rootfs/dev/console c 5 1

# Clean and build the writer utility
cd "${FINDER_APP_DIR}"
make clean
make CROSS_COMPILE=${CROSS_COMPILE}

# Copy the finder related scripts and executables to the /home directory
# on the target rootfs
mkdir -p ${OUTDIR}/rootfs/home
cp -a ${FINDER_APP_DIR}/finder.sh ${OUTDIR}/rootfs/home/
cp -a ${FINDER_APP_DIR}/finder-test.sh ${OUTDIR}/rootfs/home/
cp -a ${FINDER_APP_DIR}/writer ${OUTDIR}/rootfs/home/
# Ensure /home/conf is a real directory (not a stale symlink) and copy contents.
rm -rf ${OUTDIR}/rootfs/home/conf
mkdir -p ${OUTDIR}/rootfs/home/conf
cp -a ${FINDER_APP_DIR}/conf/. ${OUTDIR}/rootfs/home/conf/
cp -a ${FINDER_APP_DIR}/autorun-qemu.sh ${OUTDIR}/rootfs/home/

# Chown the root directory
sudo chown -R root:root ${OUTDIR}/rootfs

# Create initramfs.cpio.gz
cd ${OUTDIR}/rootfs
find . | cpio -H newc -ov --owner root:root > ${OUTDIR}/initramfs.cpio
cd ${OUTDIR}
gzip -f initramfs.cpio
