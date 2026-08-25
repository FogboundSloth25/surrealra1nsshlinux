#!/usr/bin/env bash
set -euo pipefail

: "${IOS_VERSION:?IOS_VERSION is required}"
: "${DEVICE_ID:?DEVICE_ID is required}"
: "${DEVICE_MODEL:?DEVICE_MODEL is required}"
: "${DEVICE_CPID:?DEVICE_CPID is required}"
: "${LOCAL_SHSH:?LOCAL_SHSH is required}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/ci/work-sshrd"
UPSTREAM_DIR="$WORK_DIR/SSHRD_Script"
PATCHER_DIR="$WORK_DIR/Cryptiiiic-iBoot64Patcher"
SHSH_DIR="$UPSTREAM_DIR/other/shsh"
OUTPUT_DIR="$ROOT_DIR/sshramdisk"

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

test -s "$LOCAL_SHSH" || {
    echo "[!] SHSH ticket is missing or empty: $LOCAL_SHSH"
    exit 1
}

build_cryptiiiic_ibootpatcher() {
    local arch dep_url dep_archive dep_root patch_header patcher_bin
    arch="$(uname -m)"
    case "$arch" in
        x86_64|arm64) ;;
        *) echo "[!] Unsupported macOS runner architecture: $arch"; exit 1 ;;
    esac

    echo "[*] Building Cryptiiiic/iBoot64Patcher for macOS $arch"
    git clone --depth=1 https://github.com/Cryptiiiic/iBoot64Patcher.git "$PATCHER_DIR"
    cd "$PATCHER_DIR"

    dep_url="https://cdn.cryptiiiic.com/deps/static/macOS/${arch}/macOS_${arch}_Release_Latest.tar.zst"
    dep_archive="$WORK_DIR/macOS_${arch}_Release_Latest.tar.zst"
    dep_root="$PATCHER_DIR/dep_root"

    echo "[*] Downloading Cryptiiiic static macOS dependencies"
    if ! curl -fL --retry 3 --retry-all-errors "$dep_url" -o "$dep_archive"; then
        echo "[!] Normal TLS verification failed for cdn.cryptiiiic.com; retrying only this known archive without certificate verification."
        curl -kfL --retry 3 --retry-all-errors "$dep_url" -o "$dep_archive"
    fi

    if ! command -v unzstd >/dev/null 2>&1; then
        brew install zstd >/dev/null
    fi

    mkdir -p "$dep_root"
    tar --use-compress-program=unzstd -xf "$dep_archive" -C "$dep_root"
    test -d "$dep_root/include" || { echo "[!] Missing dep_root/include after extraction"; exit 1; }
    test -d "$dep_root/lib" || { echo "[!] Missing dep_root/lib after extraction"; exit 1; }

    PATCHER_MAIN="$PATCHER_DIR/src/main.cpp"
    python3 - "$PATCHER_MAIN" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
s = s.replace("p2._patchSize", "p2.getPatchSize()")
s = s.replace("p2._patch", "p2.getPatch()")
p.write_text(s)
PY

    if grep -nE 'p2\._patch(Size)?\b|p2\._patch\b' "$PATCHER_MAIN" >/dev/null; then
        echo "[!] Failed to adapt iBoot64Patcher to the current libpatchfinder API"
        exit 1
    fi

    patch_header="$dep_root/include/libpatchfinder/patch.hpp"
    test -f "$patch_header" || { echo "[!] Missing libpatchfinder patch.hpp"; exit 1; }
    python3 - "$patch_header" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
s = s.replace("inline const void *getPatch(){return _patch;}", "inline const void *getPatch() const {return _patch;}")
s = s.replace("inline size_t getPatchSize(){return  _patchSize;}", "inline size_t getPatchSize() const {return _patchSize;}")
p.write_text(s)
PY

    grep -F 'getPatch() const' "$patch_header" >/dev/null
    grep -F 'getPatchSize() const' "$patch_header" >/dev/null

    cmake -S . -B cmake-build-release \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MAKE_PROGRAM="$(command -v make)" \
        -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
        -DCMAKE_MESSAGE_LOG_LEVEL=WARNING \
        -DARCH="$arch" \
        -DNO_PKGCFG=1

    cmake --build cmake-build-release --parallel "$(sysctl -n hw.ncpu)"

    if [ -x "$PATCHER_DIR/cmake-build-release/iBoot64Patcher" ]; then
        patcher_bin="$PATCHER_DIR/cmake-build-release/iBoot64Patcher"
    elif [ -x "$PATCHER_DIR/cmake-build-release/src/iBoot64Patcher" ]; then
        patcher_bin="$PATCHER_DIR/cmake-build-release/src/iBoot64Patcher"
    else
        patcher_bin="$(find "$PATCHER_DIR/cmake-build-release" -type f -name iBoot64Patcher -perm -111 -print -quit)"
    fi

    test -n "$patcher_bin" && test -x "$patcher_bin" || {
        echo "[!] Cryptiiiic iBoot64Patcher build did not produce a binary"
        echo "[!] CMake build tree: $PATCHER_DIR/cmake-build-release"
        find "$PATCHER_DIR/cmake-build-release" -maxdepth 3 -type f -name '*iBoot*' -print || true
        exit 1
    }

    cp "$patcher_bin" "$UPSTREAM_DIR/Darwin/iBoot64Patcher"
    chmod 0755 "$UPSTREAM_DIR/Darwin/iBoot64Patcher"
    echo "[*] Using freshly built Cryptiiiic iBoot64Patcher: $patcher_bin"
}

echo "[*] Cloning upstream SSHRD_Script"
git clone --depth=1 https://github.com/verygenericname/SSHRD_Script.git "$UPSTREAM_DIR"
cd "$UPSTREAM_DIR"
git submodule update --init --recursive

build_cryptiiiic_ibootpatcher

# build_cryptiiiic_ibootpatcher changes cwd; explicitly return to SSHRD root.
cd "$UPSTREAM_DIR"
test -f "$UPSTREAM_DIR/sshrd.sh" || {
    echo "[!] Upstream SSHRD script not found: $UPSTREAM_DIR/sshrd.sh"
    exit 1
}

mkdir -p "$SHSH_DIR"
cp "$LOCAL_SHSH" "$SHSH_DIR/${DEVICE_CPID}.shsh"
chmod 600 "$SHSH_DIR/${DEVICE_CPID}.shsh"

python3 - <<'PY'
from pathlib import Path

p = Path("sshrd.sh")
s = p.read_text()

darwin_old = '''elif [ "$oscheck" = 'Darwin' ]; then
    if ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); then
        echo "[*] Waiting for device in DFU mode"
    fi
    
    while ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
'''
darwin_new = '''elif [ "$oscheck" = 'Darwin' ]; then
    echo "[*] Building without a physical DFU device"
'''
linux_old = '''else
    if ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); then
        echo "[*] Waiting for device in DFU mode"
    fi
    
    while ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
fi
'''
linux_new = '''else
    echo "[*] Building without a physical DFU device"
fi
'''

if darwin_old not in s:
    raise SystemExit("Could not find upstream Darwin DFU block")
if linux_old not in s:
    raise SystemExit("Could not find upstream Linux DFU block")
s = s.replace(darwin_old, darwin_new, 1)
s = s.replace(linux_old, linux_new, 1)

info_old = '''check=$("$oscheck"/irecovery -q | grep CPID | sed 's/CPID: //')
replace=$("$oscheck"/irecovery -q | grep MODEL | sed 's/MODEL: //')
deviceid=$("$oscheck"/irecovery -q | grep PRODUCT | sed 's/PRODUCT: //')
ipswurl=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$1'")' | "$oscheck"/jq -s '.[0] | .url' --raw-output)
'''
info_new = '''check="$DEVICE_CPID"
replace="$DEVICE_MODEL"
deviceid="$DEVICE_ID"
ipswurl=$(curl -fsSL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$IOS_VERSION'")' | "$oscheck"/jq -s '.[0] | .url' --raw-output)
if [ -z "$ipswurl" ] || [ "$ipswurl" = "null" ]; then
    echo "[!] No IPSW found for $deviceid $IOS_VERSION"
    exit 1
fi
'''
if info_old not in s:
    raise SystemExit("Could not find upstream device-info block")
s = s.replace(info_old, info_new, 1)

build_block = '''\n\n"$oscheck"/gaster pwn > /dev/null
# A10X / T2 workaround
"$oscheck"/gaster decrypt_kbag 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 > /dev/null || true
"$oscheck"/img4tool -e -s other/shsh/"${check}".shsh -m work/IM4M
'''
build_replacement = '''\n\n# The CI runner has no attached DFU device. For modern firmware the later
# darwin_major >= 24 path uses img4 directly for iBSS/iBEC, so gaster is not
# needed during ramdisk construction.
"$oscheck"/img4tool -e -s other/shsh/"${check}".shsh -m work/IM4M
'''
if build_block not in s:
    raise SystemExit("Could not find upstream build-time gaster block")
s = s.replace(build_block, build_replacement, 1)

# Cryptiiiic iBoot64Patcher can patch iBSS for this firmware, but its
# optional NVRAM-unlock pattern may be unavailable on newer iBEC builds.
# Preserve the normal -n path first, then retry without -n so the build can
# continue with the boot-args/debug/signature patches that are available.
ibec_old = '''"$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "rd=md0 debug=0x2014e -v wdt=-1 `if [ -z "$2" ]; then :; else echo "$2=$3"; fi` `if [ "$check" = '0x8960' ] || [ "$check" = '0x7000' ] || [ "$check" = '0x7001' ]; then echo "nand-enable-reformat=1 -restore"; fi`" -n
'''
ibec_new = '''IBOOT_BOOTARGS="rd=md0 debug=0x2014e -v wdt=-1 `if [ -z "$2" ]; then :; else echo "$2=$3"; fi` `if [ "$check" = '0x8960' ] || [ "$check" = '0x7000' ] || [ "$check" = '0x7001' ]; then echo "nand-enable-reformat=1 -restore"; fi`"
if ! "$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "$IBOOT_BOOTARGS" -n; then
    echo "[!] NVRAM-unlock patch is unavailable for this iBEC; retrying without -n."
    "$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "$IBOOT_BOOTARGS"
fi
'''
if ibec_old not in s:
    raise SystemExit("Could not find upstream iBEC patch invocation")
s = s.replace(ibec_old, ibec_new, 1)

Path("sshrd-patched.sh").write_text(s)
PY

if ! /bin/sh -n sshrd-patched.sh; then
    echo "[!] Patched SSHRD script failed shell syntax check"
    exit 2
fi
mv sshrd-patched.sh sshrd.sh
chmod +x sshrd.sh
./sshrd.sh "$IOS_VERSION"

for f in iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4; do
    test -s "sshramdisk/$f"
    cp "sshramdisk/$f" "$OUTPUT_DIR/$f"
done

if [[ -s sshramdisk/trustcache.img4 ]]; then
    cp sshramdisk/trustcache.img4 "$OUTPUT_DIR/trustcache.img4"
fi

cp sshramdisk/version.txt "$OUTPUT_DIR/version.txt"
printf '%s\n' "$DEVICE_ID" > "$OUTPUT_DIR/product.txt"
printf '%s\n' "$DEVICE_MODEL" > "$OUTPUT_DIR/model.txt"
printf '%s\n' "$DEVICE_CPID" > "$OUTPUT_DIR/cpid.txt"

cat > "$OUTPUT_DIR/BUILD_INFO.txt" <<EOF
product=$DEVICE_ID
model=$DEVICE_MODEL
cpid=$DEVICE_CPID
ios=$IOS_VERSION
source=verygenericname/SSHRD_Script
iboot_patcher=Cryptiiiic/iBoot64Patcher
platform=macOS
EOF

rm -rf "$UPSTREAM_DIR/other/shsh/"*
rm -rf "$WORK_DIR"

echo "[*] SSH ramdisk built successfully"
echo "[*] Output: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
