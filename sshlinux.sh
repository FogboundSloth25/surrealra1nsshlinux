#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAMDISK_DIR="$SCRIPT_DIR/sshramdisk"
BIN_DIR="$SCRIPT_DIR/Linux"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[!] sshlinux.sh is intended to run on Linux."
    exit 1
fi

IRECOVERY="$BIN_DIR/irecovery"
GASTER="$BIN_DIR/gaster"

[[ -x "$IRECOVERY" ]] || { echo "[!] Missing $IRECOVERY"; exit 1; }
[[ -x "$GASTER" ]] || { echo "[!] Missing $GASTER"; exit 1; }

need_file() {
    [[ -s "$RAMDISK_DIR/$1" ]] || {
        echo "[!] Missing ramdisk component: $RAMDISK_DIR/$1"
        exit 1
    }
}

usage() {
    cat <<EOF
Usage: ./sshlinux.sh boot

Boots the Apple SSHLinux ramdisk from ./sshramdisk.

Required files:
  iBSS.img4
  iBEC.img4
  logo.img4
  ramdisk.img4
  devicetree.img4
  kernelcache.img4
Optional:
  trustcache.img4
EOF
}

case "${1:-}" in
    boot)
        for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
            need_file "$f"
        done

        echo "[*] Checking for DFU device..."
        "$IRECOVERY" -q >/dev/null

        echo "[*] Entering patched DFU..."
        "$GASTER" pwn >/dev/null
        "$GASTER" reset >/dev/null

        echo "[*] Sending iBSS"
        "$IRECOVERY" -f "$RAMDISK_DIR/iBSS.img4"
        sleep 2

        echo "[*] Sending iBEC"
        "$IRECOVERY" -f "$RAMDISK_DIR/iBEC.img4"
        sleep 2

        echo "[*] Sending boot logo"
        "$IRECOVERY" -f "$RAMDISK_DIR/logo.img4"
        "$IRECOVERY" -c "setpicture 0x1"

        echo "[*] Sending ramdisk"
        "$IRECOVERY" -f "$RAMDISK_DIR/ramdisk.img4"
        "$IRECOVERY" -c ramdisk

        echo "[*] Sending DeviceTree"
        "$IRECOVERY" -f "$RAMDISK_DIR/devicetree.img4"
        "$IRECOVERY" -c devicetree

        if [[ -s "$RAMDISK_DIR/trustcache.img4" ]]; then
            echo "[*] Sending trustcache"
            "$IRECOVERY" -f "$RAMDISK_DIR/trustcache.img4"
            "$IRECOVERY" -c firmware
        fi

        echo "[*] Sending kernelcache"
        "$IRECOVERY" -f "$RAMDISK_DIR/kernelcache.img4"
        "$IRECOVERY" -c bootx

        echo "[*] Boot command sent."
        ;;
    *)
        usage
        exit 2
        ;;
esac
