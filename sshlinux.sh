#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAMDISK_DIR="$SCRIPT_DIR/sshramdisk"
BIN_DIR="$SCRIPT_DIR/Linux"
REPO="FogboundSloth25/surrealra1nsshlinux"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[!] sshlinux.sh is intended to run on Linux."
    exit 1
fi

IRECOVERY="$BIN_DIR/irecovery"
GASTER="$BIN_DIR/gaster"

[[ -x "$IRECOVERY" ]] || { echo "[!] Missing $IRECOVERY"; exit 1; }
[[ -x "$GASTER" ]] || { echo "[!] Missing $GASTER"; exit 1; }

ramdisk_ready() {
    local f
    for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 version.txt; do
        [[ -s "$RAMDISK_DIR/$f" ]] || return 1
    done
    return 0
}

get_product() {
    "$IRECOVERY" -q 2>/dev/null | awk -F': ' '$1 == "PRODUCT" {print $2; exit}'
}

get_model() {
    "$IRECOVERY" -q 2>/dev/null | awk -F': ' '$1 == "MODEL" {print $2; exit}'
}

download_ramdisk() {
    local product="$1"
    local url="${SSHLINUX_RAMDISK_URL:-https://github.com/${REPO}/releases/download/ramdisk-${product}/sshramdisk-${product}.tar.gz}"
    local archive="$SCRIPT_DIR/.sshramdisk-${product}.tar.gz"

    echo "[*] No usable local SSH ramdisk found."
    echo "[*] Device product: $product"
    echo "[*] Downloading macOS-built ramdisk: $url"

    mkdir -p "$RAMDISK_DIR"
    curl -fL --retry 3 --retry-all-errors "$url" -o "$archive"
    rm -rf "$RAMDISK_DIR"
    mkdir -p "$RAMDISK_DIR"
    tar -xzf "$archive" -C "$SCRIPT_DIR"
    rm -f "$archive"

    ramdisk_ready || {
        echo "[!] Downloaded ramdisk is incomplete."
        exit 1
    }
}

ensure_ramdisk() {
    if ramdisk_ready; then
        echo "[*] Using local SSH ramdisk: $RAMDISK_DIR"
        return 0
    fi

    local product
    product="$(get_product || true)"
    if [[ -z "$product" ]]; then
        echo "[!] Could not determine PRODUCT from irecovery."
        echo "[!] Put a compatible ramdisk in ./sshramdisk or connect the device in DFU."
        exit 1
    fi

    download_ramdisk "$product"
}

need_file() {
    [[ -s "$RAMDISK_DIR/$1" ]] || {
        echo "[!] Missing ramdisk component: $RAMDISK_DIR/$1"
        exit 1
    }
}

usage() {
    cat <<EOF
Usage: ./sshlinux.sh boot

The launcher first checks ./sshramdisk. If no complete ramdisk is present,
it reads PRODUCT from irecovery and automatically downloads the latest
macOS-built ramdisk published for that device from GitHub Releases.

Environment:
  SSHLINUX_RAMDISK_URL  Override the release URL used for downloading.

Required files:
  iBSS.img4
  iBEC.img4
  logo.img4
  ramdisk.img4
  devicetree.img4
  kernelcache.img4
  version.txt
Optional:
  trustcache.img4
EOF
}

case "${1:-}" in
    boot)
        ensure_ramdisk

        for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
            need_file "$f"
        done

        echo "[*] Device model: $(get_model || true)"
        echo "[*] Device product: $(get_product || true)"
        echo "[*] Ramdisk iOS version: $(cat "$RAMDISK_DIR/version.txt")"

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
