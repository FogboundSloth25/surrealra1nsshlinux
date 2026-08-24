#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAMDISK_DIR="$SCRIPT_DIR/sshramdisk"
BIN_DIR="$SCRIPT_DIR/Linux"
DEFAULT_REPO="FogboundSloth25/surrealra1nsshlinux"
WORKFLOW_FILE=".github/workflows/build-sshlinux.yml"
BRANCH="development"
TSSCHECKER_DIR="$SCRIPT_DIR/.cache/tsschecker"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[!] sshlinux.sh is intended to run on Linux."
    exit 1
fi

install_fedora_dependencies() {
    source /etc/os-release
    [[ "${ID:-}" == "fedora" ]] || { echo "[!] Fedora Linux is required."; exit 1; }
    [[ "${VERSION_ID:-}" == "44" ]] || echo "[!] Tested on Fedora 44; detected Fedora ${VERSION_ID:-unknown}."

    local packages=(gh git curl jq ca-certificates tar gzip unzip xz file usbutils libusb1 libusbmuxd libusbmuxd-utils usbmuxd libimobiledevice libimobiledevice-utils libirecovery libirecovery-utils python3 python3-pip openssl procps-ng)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        echo "[*] Installing Fedora dependencies: ${missing[*]}"
        sudo -v
        sudo dnf -y install "${missing[@]}"
    else
        echo "[*] Fedora dependencies are already installed."
    fi
    sudo udevadm control --reload-rules >/dev/null 2>&1 || true
    sudo udevadm trigger >/dev/null 2>&1 || true
}

install_fedora_dependencies

if [[ -x "$BIN_DIR/irecovery" ]]; then
    IRECOVERY="$BIN_DIR/irecovery"
elif command -v irecovery >/dev/null 2>&1; then
    IRECOVERY="$(command -v irecovery)"
else
    echo "[!] irecovery is unavailable even after installing libirecovery-utils."; exit 1
fi

ensure_gaster() {
    if [[ -x "$BIN_DIR/gaster" ]]; then GASTER="$BIN_DIR/gaster"; return; fi
    [[ "$(uname -m)" == "x86_64" ]] || { echo "[!] Automatic gaster install supports x86_64 only."; exit 1; }
    mkdir -p "$BIN_DIR"
    local archive="$SCRIPT_DIR/.gaster-linux-x86_64.zip"
    echo "[*] gaster is missing; downloading upstream Linux x86_64 build..."
    curl -fL --retry 3 --retry-all-errors "https://nightly.link/verygenericname/gaster/workflows/makefile/main/gaster-Linux-x86_64.zip" -o "$archive"
    rm -rf "$BIN_DIR/.gaster-extract"
    unzip -o "$archive" -d "$BIN_DIR/.gaster-extract" >/dev/null
    if [[ -f "$BIN_DIR/.gaster-extract/gaster" ]]; then mv "$BIN_DIR/.gaster-extract/gaster" "$BIN_DIR/gaster"; elif [[ -f "$BIN_DIR/.gaster-extract/gaster-Linux-x86_64" ]]; then mv "$BIN_DIR/.gaster-extract/gaster-Linux-x86_64" "$BIN_DIR/gaster"; else echo "[!] gaster was not found in the archive."; exit 1; fi
    rm -rf "$BIN_DIR/.gaster-extract" "$archive"; chmod 0755 "$BIN_DIR/gaster"; GASTER="$BIN_DIR/gaster"
}
ensure_gaster

ramdisk_ready() {
    local f
    for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 version.txt; do [[ -s "$RAMDISK_DIR/$f" ]] || return 1; done
}

get_device_info() {
    local info
    info="$($IRECOVERY -q 2>/dev/null || true)"
    CPID="$(awk -F': ' '$1=="CPID"{print $2; exit}' <<<"$info")"
    MODEL="$(awk -F': ' '$1=="MODEL"{print $2; exit}' <<<"$info")"
    PRODUCT="$(awk -F': ' '$1=="PRODUCT"{print $2; exit}' <<<"$info")"
    ECID="$(awk -F': ' '$1=="ECID"{print $2; exit}' <<<"$info")"
    [[ -n "$CPID" && -n "$MODEL" && -n "$PRODUCT" ]] || { echo "[!] Could not read CPID/MODEL/PRODUCT from irecovery."; echo "[!] Put the device in DFU mode and try: $IRECOVERY -q"; exit 1; }
    [[ -n "$ECID" ]] || { echo "[!] ECID was not reported by irecovery; automatic SHSH lookup is unavailable."; exit 1; }
}

require_gh() {
    command -v gh >/dev/null 2>&1 || { echo "[!] GitHub CLI is required."; exit 1; }
    if ! gh auth status >/dev/null 2>&1; then
        echo "[*] GitHub CLI is not authenticated."
        gh auth login --web --git-protocol https
    fi
    gh auth status >/dev/null 2>&1 || { echo "[!] GitHub authentication failed."; exit 1; }
}

find_local_shsh() {
    local candidates=(
        "$SCRIPT_DIR/other/shsh/${CPID}.shsh" "$SCRIPT_DIR/other/shsh/${CPID}.shsh2"
        "$SCRIPT_DIR/shsh/${CPID}.shsh" "$SCRIPT_DIR/shsh/${CPID}.shsh2"
        "$HOME/.cache/sshlinux/${CPID}.shsh" "$HOME/.cache/sshlinux/${CPID}.shsh2"
    )
    local path
    for path in "${candidates[@]}"; do if [[ -s "$path" ]]; then SHSH_PATH="$path"; return 0; fi; done
    return 1
}

ensure_tsschecker() {
    [[ "$(uname -m)" == "x86_64" ]] || { echo "[!] Automatic tsschecker install currently supports x86_64 only."; return 1; }
    if [[ -x "$TSSCHECKER_DIR/tsschecker" ]]; then TSSCHECKER="$TSSCHECKER_DIR/tsschecker"; return 0; fi
    require_gh
    mkdir -p "$TSSCHECKER_DIR"
    local run_id artifact_tmp
    echo "[*] Downloading current Linux x86_64 tsschecker build..."
    while read -r run_id; do
        [[ -n "$run_id" ]] || continue
        artifact_tmp="$TSSCHECKER_DIR/download-$run_id"
        rm -rf "$artifact_tmp"; mkdir -p "$artifact_tmp"
        if gh run download "$run_id" --repo 1Conan/tsschecker -n tsschecker_linux_x86_64 -D "$artifact_tmp" >/dev/null 2>&1; then
            local candidate
            candidate="$(find "$artifact_tmp" -type f -name 'tsschecker*' -perm -u+x -print -quit)"
            [[ -n "$candidate" ]] || candidate="$(find "$artifact_tmp" -type f -name 'tsschecker*' -print -quit)"
            if [[ -n "$candidate" ]]; then cp "$candidate" "$TSSCHECKER_DIR/tsschecker"; chmod 0755 "$TSSCHECKER_DIR/tsschecker"; rm -rf "$artifact_tmp"; TSSCHECKER="$TSSCHECKER_DIR/tsschecker"; return 0; fi
        fi
        rm -rf "$artifact_tmp"
    done < <(gh run list --repo 1Conan/tsschecker --limit 20 --json databaseId,status,conclusion --jq '.[] | select(.status=="completed" and .conclusion=="success") | .databaseId')
    return 1
}

hex_to_dec() {
    python3 - "$1" <<'PY'
import sys
s=sys.argv[1].strip()
try:
    print(int(s, 0))
except ValueError:
    print(int(s, 16))
PY
}

fetch_shshhost_blob() {
    local ios_version="$1" ecid_value api_json url
    ecid_value="$(hex_to_dec "$ECID")"
    echo "[*] Checking shsh.host for a previously saved blob for ECID $ecid_value..."
    api_json="$(curl -fsSL --retry 3 --retry-all-errors "https://api.arx8x.net/shsh3/list.php?ecid=$ecid_value" 2>/dev/null || true)"
    [[ -n "$api_json" ]] || return 1
    url="$(jq -r --arg dev "$PRODUCT" --arg board "$MODEL" --arg ver "$ios_version" '.\n        .. | objects | select(.url? and .version? and .device? and .boardconfig?)\n        | select(.device==$dev and (.boardconfig|ascii_downcase)==($board|ascii_downcase) and .version==$ver)\n        | .url' <<<"$api_json" 2>/dev/null | head -n1)"
    [[ -n "$url" && "$url" != "null" ]] || return 1
    mkdir -p "$HOME/.cache/sshlinux"
    SHSH_PATH="$HOME/.cache/sshlinux/${CPID}.shsh2"
    echo "[*] Downloading saved SHSH2 from shsh.host..."
    curl -fL --retry 3 --retry-all-errors "$url" -o "$SHSH_PATH"
    [[ -s "$SHSH_PATH" ]]
}

request_signed_blob() {
    local ios_version="$1" out_dir
    ensure_tsschecker || return 1
    out_dir="$HOME/.cache/sshlinux/tss-$PRODUCT-$ios_version"
    rm -rf "$out_dir"; mkdir -p "$out_dir"
    echo "[*] Asking Apple's TSS server whether $PRODUCT $ios_version is still signed..."
    "$TSSCHECKER" --device "$PRODUCT" --boardconfig "$MODEL" --ecid "$ECID" --ios "$ios_version" --no-baseband --save --save-path "$out_dir" --nocache || true
    SHSH_PATH="$(find "$out_dir" -type f \( -name '*.shsh' -o -name '*.shsh2' \) -size +0c -print -quit)"
    [[ -n "$SHSH_PATH" ]]
}

find_or_create_shsh() {
    local ios_version="$1"
    if find_local_shsh; then echo "[*] Using local SHSH: $SHSH_PATH"; return 0; fi
    if fetch_shshhost_blob "$ios_version"; then echo "[*] Found a previously saved SHSH2 on shsh.host: $SHSH_PATH"; return 0; fi
    if request_signed_blob "$ios_version"; then echo "[*] Apple returned a fresh signing ticket: $SHSH_PATH"; return 0; fi
    echo "[!] No usable SHSH blob was found for $PRODUCT $ios_version."
    echo "[!] The target firmware is not currently signed, and no saved blob was found for this ECID."
    echo "[!] A new personalized SHSH cannot be created for an unsigned firmware; you need a saved blob."
    echo "[*] You can place it at: $SCRIPT_DIR/other/shsh/${CPID}.shsh2"
    exit 1
}

choose_repo() {
    if [[ -n "${2:-}" ]]; then REPO="$2"; else read -r -e -p "GitHub repository [$DEFAULT_REPO]: " REPO; REPO="${REPO:-$DEFAULT_REPO}"; fi
    gh repo view "$REPO" >/dev/null 2>&1 || { echo "[!] Cannot access repository: $REPO"; exit 1; }
}

fetch_run_logs() {
    local run_id="$1" repo="$2" job_id job_name log_tmp
    echo "[*] Fetching workflow logs..."
    while read -r job_id job_name; do
        [[ -n "$job_id" ]] || continue
        echo
        echo "===== JOB: $job_name ====="
        log_tmp="$SCRIPT_DIR/.sshlinux-job-$job_id.log"
        if gh api "/repos/$repo/actions/jobs/$job_id/logs" >"$log_tmp" 2>/dev/null; then
            cat "$log_tmp"
            rm -f "$log_tmp"
        else
            echo "[!] Failed to fetch logs for job $job_id"
        fi
    done < <(gh run view "$run_id" --repo "$repo" --json jobs --jq '.jobs[] | [.databaseId, .name] | @tsv')
}

wait_for_run() {
    local run_id="$1" repo="$2" status conclusion
    while true; do
        status="$(gh run view "$run_id" --repo "$repo" --json status --jq '.status')"
        conclusion="$(gh run view "$run_id" --repo "$repo" --json conclusion --jq '.conclusion // empty')"
        case "$status" in
            completed)
                fetch_run_logs "$run_id" "$repo"
                [[ "$conclusion" == "success" ]] && return 0
                echo "[!] Workflow completed with conclusion: ${conclusion:-unknown}" >&2
                return 1
                ;;
            queued|in_progress|pending|requested|waiting)
                echo "[*] macOS workflow status: $status"
                sleep 5
                ;;
            *)
                echo "[!] Unknown workflow status: $status" >&2
                sleep 5
                ;;
        esac
    done
}

run_build() {
    local requested_repo="${1:-}" ios_version="${IOS_VERSION:-}" request_id run_id="" shsh_b64 download_dir archive
    require_gh; get_device_info; choose_repo build "$requested_repo"
    echo "[*] Device: $PRODUCT"; echo "[*] Model:  $MODEL"; echo "[*] CPID:   $CPID"; echo "[*] ECID:   $ECID"
    [[ -n "$ios_version" ]] || read -r -e -p "iOS version to build (for example 15.6.1): " ios_version
    [[ -n "$ios_version" ]] || { echo "[!] iOS version is required."; exit 1; }
    find_or_create_shsh "$ios_version"
    shsh_b64="$(base64 -w0 "$SHSH_PATH" 2>/dev/null || base64 "$SHSH_PATH" | tr -d '\n')"
    request_id="sshlinux-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    echo "[*] Dispatching macOS GitHub Actions workflow..."
    gh workflow run "$WORKFLOW_FILE" --repo "$REPO" --ref "$BRANCH" -f request_id="$request_id" -f ios_version="$ios_version" -f product="$PRODUCT" -f model="$MODEL" -f cpid="$CPID" -f shsh_base64="$shsh_b64"
    echo "[*] Waiting for workflow run..."
    for _ in {1..30}; do
        run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" --limit 20 --json databaseId,displayTitle,createdAt --jq 'map(select(.displayTitle | contains("'"$request_id"'"))) | sort_by(.createdAt) | last | .databaseId' 2>/dev/null || true)"
        [[ "$run_id" =~ ^[0-9]+$ ]] && break
        sleep 2
    done
    [[ "$run_id" =~ ^[0-9]+$ ]] || { echo "[!] Could not locate the dispatched workflow run."; exit 1; }
    echo "[*] Workflow run: $run_id"
    wait_for_run "$run_id" "$REPO" || exit 1
    echo "[*] Downloading ramdisk artifact..."
    download_dir="$SCRIPT_DIR/.sshlinux-download-$request_id"; rm -rf "$download_dir"; mkdir -p "$download_dir"
    gh run download "$run_id" --repo "$REPO" -n "sshramdisk-${PRODUCT}" -D "$download_dir"
    archive="$(find "$download_dir" -type f -name 'sshramdisk-*.tar.gz' -print -quit)"
    [[ -n "$archive" ]] || { echo "[!] Ramdisk artifact was not found."; exit 1; }
    rm -rf "$RAMDISK_DIR"; mkdir -p "$RAMDISK_DIR"; tar -xzf "$archive" -C "$SCRIPT_DIR"; rm -rf "$download_dir"
    ramdisk_ready || { echo "[!] Downloaded ramdisk is incomplete."; exit 1; }
    echo "[*] Ramdisk downloaded to: $RAMDISK_DIR"; ls -lh "$RAMDISK_DIR"; echo "[*] Build complete. Run: ./sshlinux.sh boot"
}

ensure_ramdisk() { ramdisk_ready && { echo "[*] Using local SSH ramdisk: $RAMDISK_DIR"; return 0; }; echo "[!] No local ramdisk found. Run: ./sshlinux.sh build"; exit 1; }

boot_ramdisk() {
    ensure_ramdisk
    local f
    for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do [[ -s "$RAMDISK_DIR/$f" ]] || { echo "[!] Missing $RAMDISK_DIR/$f"; exit 1; }; done
    get_device_info
    echo "[*] Device: $PRODUCT ($MODEL)"; echo "[*] Ramdisk iOS version: $(cat "$RAMDISK_DIR/version.txt")"
    echo "[*] Entering patched DFU..."; "$GASTER" pwn >/dev/null; "$GASTER" reset >/dev/null
    "$IRECOVERY" -f "$RAMDISK_DIR/iBSS.img4"; sleep 2
    "$IRECOVERY" -f "$RAMDISK_DIR/iBEC.img4"; sleep 2
    "$IRECOVERY" -f "$RAMDISK_DIR/logo.img4"; "$IRECOVERY" -c "setpicture 0x1"
    "$IRECOVERY" -f "$RAMDISK_DIR/ramdisk.img4"; "$IRECOVERY" -c ramdisk
    "$IRECOVERY" -f "$RAMDISK_DIR/devicetree.img4"; "$IRECOVERY" -c devicetree
    if [[ -s "$RAMDISK_DIR/trustcache.img4" ]]; then "$IRECOVERY" -f "$RAMDISK_DIR/trustcache.img4"; "$IRECOVERY" -c firmware; fi
    "$IRECOVERY" -f "$RAMDISK_DIR/kernelcache.img4"; "$IRECOVERY" -c bootx
    echo "[*] Boot command sent."
}

usage() {
    cat <<EOF
Usage:
  ./sshlinux.sh build [owner/repo]
  ./sshlinux.sh boot

build:
  Installs Fedora dependencies automatically, reads device identifiers, finds/requests
  the SHSH blob, dispatches the macOS builder, prints its logs, and downloads the ramdisk.

boot:
  Uses the locally built/downloaded ./sshramdisk.
EOF
}

case "${1:-}" in
    build) run_build "${2:-}" ;;
    boot) boot_ramdisk ;;
    *) usage; exit 2 ;;
esac
