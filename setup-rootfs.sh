#!/bin/bash
set -euo pipefail

ROOTFS="/var/lib/k8s-from-scratch/rootfs"

if [[ -v CONTAINER_ROOTFS ]]; then
    if [[ -n "$CONTAINER_ROOTFS" ]]; then
        ROOTFS="$CONTAINER_ROOTFS"
    fi
fi

ARCH="$(dpkg --print-architecture)"
ARCHIVE="ubuntu-base-24.04.3-base-${ARCH}.tar.gz"
BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script as root inside the development container."
    exit 1
fi

if [[ "$ROOTFS" != /* ]]; then
    echo "ROOTFS must be an absolute path: $ROOTFS" >&2
    exit 1
fi

if [[ -e "$ROOTFS" || -L "$ROOTFS"  ]]; then
    echo "Directory already exists: $ROOTFS"
    echo "Stopping to avoid overwriting it."
    exit 1
fi

echo "Downloading Ubuntu Base for $ARCH..."
curl --fail --location \
    "$BASE_URL/$ARCHIVE" \
    --output "/tmp/$ARCHIVE"

echo "Extracting filesystem into ${ROOTFS}..."
mkdir -p "$ROOTFS"
tar --extract --gzip \
    --file="/tmp/$ARCHIVE" \
    --directory="$ROOTFS"

rm -f -- "/tmp/$ARCHIVE"

echo "Root filesystem ready:"
ls "$ROOTFS"

echo "Entering the new filesystem. Type exit to return."
chroot "$ROOTFS" /bin/bash
