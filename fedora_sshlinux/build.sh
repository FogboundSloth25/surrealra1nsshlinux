#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/fedora-sshlinux"
ROOTFS="$OUT_DIR/rootfs"
RAMDISK_DIR="$ROOT_DIR/sshramdisk"

FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
ARCH="${ARCH:-aarch64}"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

rm -rf "$OUT_DIR"
mkdir -p "$ROOTFS" "$RAMDISK_DIR"

for tool in dnf cpio gzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "[!] Missing required tool: $tool"
        exit 1
    }
done

echo "[*] Building Fedora ${FEDORA_RELEASE} ${ARCH} SSHLinux userspace"

$SUDO dnf -y \
    --releasever="$FEDORA_RELEASE" \
    --forcearch="$ARCH" \
    --installroot="$ROOTFS" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --setopt=tsflags=nodocs \
    install \
        bash coreutils util-linux iproute iputils procps-ng kmod \
        openssh-clients openssh-server dropbear ca-certificates \
        curl wget busybox findutils grep sed gawk tar gzip xz nano

mkdir -p "$ROOTFS/etc/dropbear" "$ROOTFS/root" "$ROOTFS/run" "$ROOTFS/tmp" \
         "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/mnt" \
         "$ROOTFS/usr/local/bin"

cat > "$ROOTFS/etc/os-release" <<EOF
NAME="SSHLinux Fedora"
ID=fedora
VERSION="${FEDORA_RELEASE}"
VERSION_ID="${FEDORA_RELEASE}"
PRETTY_NAME="SSHLinux Fedora ${FEDORA_RELEASE}"
EOF

cat > "$ROOTFS/usr/local/bin/linux-init" <<'EOF'
#!/bin/sh
set -eu

mountpoint -q /proc || mount -t proc proc /proc || true
mountpoint -q /sys  || mount -t sysfs sysfs /sys || true
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev || true
mountpoint -q /run  || mount -t tmpfs tmpfs /run || true

mkdir -p /run/sshlinux /tmp /root
chmod 1777 /tmp

if command -v dropbear >/dev/null 2>&1; then
    mkdir -p /etc/dropbear
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1 || true
    dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1 || true
    exec dropbear -R -E -F -p 22
fi

exec /bin/sh
EOF
chmod 0755 "$ROOTFS/usr/local/bin/linux-init"

printf '%s\n' "$FEDORA_RELEASE" > "$OUT_DIR/version.txt"
printf '%s\n' "$ARCH" > "$OUT_DIR/arch.txt"

(
    cd "$ROOTFS"
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT_DIR/payload.cpio.gz"
)

cp "$OUT_DIR/payload.cpio.gz" "$RAMDISK_DIR/fedora-payload.cpio.gz"
cat > "$RAMDISK_DIR/README" <<EOF
Fedora SSHLinux userspace payload.
Fedora: ${FEDORA_RELEASE}
Architecture: ${ARCH}

This payload is not the device-specific Apple boot chain.
The Apple iBSS/iBEC/ramdisk.img4/devicetree/kernelcache/trustcache files
must be generated separately for the selected device and iOS build.
EOF

echo "[*] Created $OUT_DIR/payload.cpio.gz"
echo "[*] Installed $RAMDISK_DIR/fedora-payload.cpio.gz"
