#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAMDISK_DIR="$SCRIPT_DIR/sshramdisk"
BIN_DIR="$SCRIPT_DIR/Linux"
DEFAULT_REPO="FogboundSloth25/surrealra1nsshlinux"
WORKFLOW_FILE=".github/workflows/build-sshlinux.yml"
BRANCH="development"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[!] sshlinux.sh is intended to run on Linux."
    exit 1
fi

install_fedora_dependencies() {
    if [[ ! -r /etc/os-release ]]; then
        echo "[!] /etc/os-release is missing; cannot detect Fedora."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "fedora" ]]; then
        echo "[!] This build of sshlinux.sh is configured for Fedora Linux."
        echo "[!] Detected: ${PRETTY_NAME:-unknown}"
        exit 1
    fi

    if [[ "${VERSION_ID:-}" != "44" ]]; then
        echo "[!] This build is tested/configured for Fedora 44."
        echo "[!] Detected Fedora ${VERSION_ID:-unknown}; continuing may still work."
    fi

    local packages=(
        gh
        git
        curl
        jq
        ca-certificates
        tar
        gzip
        unzip
        xz
        file
        usbutils
        libusb1
        libusbmuxd
        libusbmuxd-utils
        usbmuxd
        libimobiledevice
        libimobiledevice-utils
        libirecovery
        libirecovery-utils
        python3
        python3-pip
        openssl
        procps-ng
    )

    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]} > 0)); then
        echo "[*] Installing Fedora dependencies: ${missing[*]}"
        sudo -v
        sudo dnf -y install "${missing[@]}"
    else
        echo "[*] Fedora dependencies are already installed."
    fi

    # libirecovery installs udev rules. Reload them after installation so a
    # device entering DFU is recognized without requiring a reboot.
    sudo udevadm control --reload-rules >/dev/null 2>&1 || true
    sudo udevadm trigger >/dev/null 2>&1 || true
}

install_fedora_dependencies

# Prefer the repository-provided tool when present, otherwise use Fedora's
# packaged libirecovery utility.
if [[ -x "$BIN_DIR/irecovery" ]]; then
    IRECOVERY="$BIN_DIR/irecovery"
elif command -v irecovery >/dev/null 2>&1; then
    IRECOVERY="$(command -v irecovery)"
else
    echo "[!] irecovery is unavailable even after installing libirecovery-utils."
    exit 1
fi

# gaster is not a Fedora package. Keep the binary local to the project and
# fetch the upstream Linux build automatically when it is missing.
ensure_gaster() {
    if [[ -x "$BIN_DIR/gaster" ]]; then
        GASTER="$BIN_DIR/gaster"
        return 0
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        echo "[!] No automatic gaster binary is configured for $(uname -m)."
        echo "[!] Put a compatible gaster binary at $BIN_DIR/gaster."
        exit 1
    fi

    mkdir -p "$BIN_DIR"
    local archive="$SCRIPT_DIR/.gaster-linux-x86_64.zip"
    echo "[*] gaster is missing; downloading upstream Linux x86_64 build..."
    curl -fL --retry 3 --retry-all-errors \
        "https://nightly.link/verygenericname/gaster/workflows/makefile/main/gaster-Linux-x86_64.zip" \
        -o "$archive"
    unzip -o "$archive" -d "$BIN_DIR/.gaster-extract" >/dev/null
    if [[ -f "$BIN_DIR/.gaster-extract/gaster" ]]; then
        mv "$BIN_DIR/.gaster-extract/gaster" "$BIN_DIR/gaster"
    elif [[ -f "$BIN_DIR/.gaster-extract/gaster-Linux-x86_64" ]]; then
        mv "$BIN_DIR/.gaster-extract/gaster-Linux-x86_64" "$BIN_DIR/gaster"
    else
        echo "[!] Could not locate gaster in the downloaded archive."
        rm -rf "$BIN_DIR/.gaster-extract" "$archive"
        exit 1
    fi
    rm -rf "$BIN_DIR/.gaster-extract" "$archive"
    chmod 0755 "$BIN_DIR/gaster"
    GASTER="$BIN_DIR/gaster"
}

ensure_gaster

ramdisk_ready() {
    local f
    for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 version.txt; do
        [[ -s "$RAMDISK_DIR/$f" ]] || return 1
    done
    return 0
}

get_device_info() {
    local info
    info="$($IRECOVERY -q 2>/dev/null || true)"
    CPID="$(awk -F': ' '$1=="CPID"{print $2; exit}' <<<"$info")"
    MODEL="$(awk -F': ' '$1=="MODEL"{print $2; exit}' <<<"$info")"
    PRODUCT="$(awk -F': ' '$1=="PRODUCT"{print $2; exit}' <<<"$info")"
    [[ -n "$CPID" && -n "$MODEL" && -n "$PRODUCT" ]] || {
        echo "[!] Could not read CPID/MODEL/PRODUCT from irecovery."
        echo "[!] Put the device in DFU mode and try again."
        echo "[!] Try: $IRECOVERY -q"
        exit 1
    }
}

require_gh() {
    command -v gh >/dev/null 2>&1 || {
        echo "[!] GitHub CLI (gh) is required and should have been installed automatically."
        exit 1
    }

    if ! gh auth status >/dev/null 2>&1; then
        echo "[*] GitHub CLI is not authenticated."
        echo "[*] Starting GitHub device/browser login..."
        gh auth login --web --git-protocol https
    fi

    gh auth status >/dev/null 2>&1 || {
        echo "[!] GitHub authentication failed."
        exit 1
    }
}

find_shsh() {
    local candidates=(
        "$SCRIPT_DIR/other/shsh/${CPID}.shsh"
        "$SCRIPT_DIR/other/shsh/${CPID}.shsh2"
        "$SCRIPT_DIR/shsh/${CPID}.shsh"
        "$SCRIPT_DIR/shsh/${CPID}.shsh2"
        "$HOME/.cache/sshlinux/${CPID}.shsh"
        "$HOME/.cache/sshlinux/${CPID}.shsh2"
    )

    for path in "${candidates[@]}"; do
        if [[ -s "$path" ]]; then
            SHSH_PATH="$path"
            return 0
        fi
    done

    echo "[!] No SHSH/SHSH2 ticket was found automatically for $CPID."
    echo "[!] A personalized IM4M is required by the SSHRD build."
    echo "[*] Expected locations include:"
    printf '    %s\n' "${candidates[@]}"
    echo
    read -r -e -p "Path to matching SHSH/SHSH2 (or Ctrl+C): " SHSH_PATH
    [[ -s "$SHSH_PATH" ]] || {
        echo "[!] SHSH file not found or empty: $SHSH_PATH"
        exit 1
    }
}

choose_repo() {
    local requested="${2:-}"
    if [[ -n "$requested" ]]; then
        REPO="$requested"
    else
        read -r -e -p "GitHub repository [$DEFAULT_REPO]: " REPO
        REPO="${REPO:-$DEFAULT_REPO}"
    fi

    gh repo view "$REPO" >/dev/null 2>&1 || {
        echo "[!] Cannot access repository: $REPO"
        exit 1
    }
}

run_build() {
    local requested_repo="${2:-}"
    local ios_version="${IOS_VERSION:-}"
    local request_id="sshlinux-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    local shsh_b64
    local run_id=""
    local download_dir="$SCRIPT_DIR/.sshlinux-download-$request_id"

    require_gh
    get_device_info
    choose_repo build "$requested_repo"

    echo "[*] Device: $PRODUCT"
    echo "[*] Model:  $MODEL"
    echo "[*] CPID:   $CPID"

    if [[ -z "$ios_version" ]]; then
        read -r -e -p "iOS version to build (for example 15.6.1): " ios_version
    fi
    [[ -n "$ios_version" ]] || { echo "[!] iOS version is required."; exit 1; }

    find_shsh
    shsh_b64="$(base64 -w0 "$SHSH_PATH" 2>/dev/null || base64 "$SHSH_PATH" | tr -d '\n')"

    echo "[*] Dispatching macOS GitHub Actions workflow..."
    gh workflow run "$WORKFLOW_FILE" \
        --repo "$REPO" \
        --ref "$BRANCH" \
        -f request_id="$request_id" \
        -f ios_version="$ios_version" \
        -f product="$PRODUCT" \
        -f model="$MODEL" \
        -f cpid="$CPID" \
        -f shsh_base64="$shsh_b64"

    echo "[*] Waiting for workflow run..."
    for _ in {1..30}; do
        run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" --limit 20 \
            --json databaseId,displayTitle,createdAt \
            --jq 'map(select(.displayTitle | contains("'"$request_id"'"))) | sort_by(.createdAt) | last | .databaseId' 2>/dev/null || true)"
        if [[ "$run_id" =~ ^[0-9]+$ ]]; then
            break
        fi
        sleep 2
    done

    [[ "$run_id" =~ ^[0-9]+$ ]] || {
        echo "[!] Could not locate the dispatched workflow run."
        exit 1
    }

    echo "[*] Workflow run: $run_id"
    echo "[*] Streaming macOS build logs:"
    echo
    gh run watch "$run_id" --repo "$REPO" --interval 3 --log

    local conclusion
    conclusion="$(gh run view "$run_id" --repo "$REPO" --json conclusion --jq '.conclusion')"
    [[ "$conclusion" == "success" ]] || {
        echo "[!] Workflow failed: $conclusion"
        exit 1
    }

    echo "[*] Downloading ramdisk artifact..."
    rm -rf "$download_dir"
    mkdir -p "$download_dir"
    gh run download "$run_id" --repo "$REPO" -n "sshramdisk-${PRODUCT}" -D "$download_dir"

    local archive
    archive="$(find "$download_dir" -maxdepth 2 -type f -name 'sshramdisk-*.tar.gz' -print -quit)"
    [[ -n "$archive" ]] || {
        echo "[!] Ramdisk artifact was not found in the workflow output."
        exit 1
    }

    rm -rf "$RAMDISK_DIR"
    mkdir -p "$RAMDISK_DIR"
    tar -xzf "$archive" -C "$SCRIPT_DIR"
    rm -rf "$download_dir"

    ramdisk_ready || {
        echo "[!] Downloaded ramdisk is incomplete."
        exit 1
    }

    echo "[*] Ramdisk downloaded to: $RAMDISK_DIR"
    ls -lh "$RAMDISK_DIR"
    echo "[*] Build complete. Run: ./sshlinux.sh boot"
}

ensure_ramdisk() {
    if ramdisk_ready; then
        echo "[*] Using local SSH ramdisk: $RAMDISK_DIR"
        return 0
    fi

    get_device_info
    local repo="${SSHLINUX_REPO:-$DEFAULT_REPO}"
    local artifact_run
    require_gh

    echo "[*] No local ramdisk found for $PRODUCT."
    echo "[*] Looking for the latest matching artifact in $repo..."
    artifact_run="$(gh run list --repo "$repo" --workflow "$WORKFLOW_FILE" --limit 20 --json databaseId,status,conclusion,createdAt,displayTitle \
        --jq 'map(select(.displayTitle | contains("SSHLinux ramdisk")) | select(.status == "completed" and .conclusion == "success")) | sort_by(.createdAt) | reverse | map(.databaseId) | .[0]' 2>/dev/null || true)"

    if [[ "$artifact_run" =~ ^[0-9]+$ ]]; then
        local tmp="$SCRIPT_DIR/.sshlinux-auto-$PRODUCT"
        rm -rf "$tmp"
        mkdir -p "$tmp"
        if gh run download "$artifact_run" --repo "$repo" -n "sshramdisk-${PRODUCT}" -D "$tmp" >/dev/null 2>&1; then
            local archive
            archive="$(find "$tmp" -maxdepth 2 -type f -name 'sshramdisk-*.tar.gz' -print -quit)"
            if [[ -n "$archive" ]]; then
                rm -rf "$RAMDISK_DIR"
                mkdir -p "$RAMDISK_DIR"
                tar -xzf "$archive" -C "$SCRIPT_DIR"
                rm -rf "$tmp"
                ramdisk_ready && return 0
            fi
        fi
        rm -rf "$tmp"
    fi

    echo "[!] No usable downloaded ramdisk was found."
    echo "[!] Run: ./sshlinux.sh build"
    exit 1
}

need_file() {
    [[ -s "$RAMDISK_DIR/$1" ]] || {
        echo "[!] Missing ramdisk component: $RAMDISK_DIR/$1"
        exit 1
    }
}

boot_ramdisk() {
    ensure_ramdisk

    for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
        need_file "$f"
    done

    get_device_info
    echo "[*] Device model: $MODEL"
    echo "[*] Device product: $PRODUCT"
    echo "[*] Ramdisk iOS version: $(cat "$RAMDISK_DIR/version.txt")"

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
}

usage() {
    cat <<EOF
Usage:
  ./sshlinux.sh build [owner/repo]
  ./sshlinux.sh boot

build:
  Installs/updates Fedora dependencies automatically, reads PRODUCT/MODEL/CPID
  from irecovery, authenticates to GitHub with gh, dispatches the macOS builder,
  streams the workflow logs to this terminal, then downloads the generated ramdisk.

boot:
  Uses ./sshramdisk, or downloads the latest successful matching artifact
  from GitHub before booting it.

Fedora 44 dependencies installed automatically:
  gh git curl jq libusb1 libusbmuxd libusbmuxd-utils usbmuxd
  libimobiledevice libimobiledevice-utils libirecovery libirecovery-utils
  usbutils ca-certificates tar gzip unzip xz file python3 python3-pip
  openssl procps-ng

Examples:
  ./sshlinux.sh build
  ./sshlinux.sh build FogboundSloth25/surrealra1nsshlinux
  IOS_VERSION=15.6.1 ./sshlinux.sh build
  SSHLINUX_REPO=owner/repo ./sshlinux.sh boot
EOF
}

case "${1:-}" in
    build)
        run_build "${2:-}"
        ;;
    boot)
        boot_ramdisk
        ;;
    *)
        usage
        exit 2
        ;;
esac
