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

if [[ -e "$ROOTFS" ]]; then
    # If both tools are already present, nothing to do.
    if [[ -x "$ROOTFS/bin/ping" && ( -x "$ROOTFS/bin/nc" || -x "$ROOTFS/usr/bin/nc" ) ]]; then
        echo "Rootfs already prepared: $ROOTFS"
        exit 0
    fi
    if [[ ! -x "$ROOTFS/bin/bash" ]]; then
        echo "Rootfs at $ROOTFS exists but appears incomplete (no /bin/bash). Remove it and re-run." >&2
        exit 1
    fi
    echo "Rootfs exists; installing missing networking tools..."
else
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
    echo "Extraction complete."
fi

echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"

echo "Installing iputils-ping and netcat-openbsd into rootfs..."
chroot "$ROOTFS" apt-get update -q --allow-insecure-repositories
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    --allow-unauthenticated \
    gpgv iputils-ping netcat-openbsd
chroot "$ROOTFS" apt-get clean

echo "Root filesystem ready: $ROOTFS"
