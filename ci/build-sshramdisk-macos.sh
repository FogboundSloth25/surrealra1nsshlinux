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
SHSH_DIR="$UPSTREAM_DIR/other/shsh"
OUTPUT_DIR="$ROOT_DIR/sshramdisk"

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

test -s "$LOCAL_SHSH" || {
    echo "[!] SHSH ticket is missing or empty: $LOCAL_SHSH"
    exit 1
}

echo "[*] Cloning upstream SSHRD_Script"
git clone --depth=1 https://github.com/verygenericname/SSHRD_Script.git "$UPSTREAM_DIR"
cd "$UPSTREAM_DIR"
git submodule update --init --recursive

mkdir -p "$SHSH_DIR"
cp "$LOCAL_SHSH" "$SHSH_DIR/${DEVICE_CPID}.shsh"
chmod 600 "$SHSH_DIR/${DEVICE_CPID}.shsh"

python3 - <<'PY'
from pathlib import Path

p = Path("sshrd.sh")
s = p.read_text()

# Preserve the upstream if/elif chain. We only replace the DFU wait commands
# inside the existing Darwin/Linux branches, so the surrounding shell syntax
# and the final outer `{ ... } | tee ...` remain intact.
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

# Replace only the device-info assignments. Keep the rest of upstream build
# logic unchanged, including IPSW discovery and ramdisk assembly.
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

# Syntax-check the patched script before the actual build runs.
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
platform=macOS
EOF

# Remove ticket/build material before the job finishes.
rm -rf "$UPSTREAM_DIR/other/shsh/"*
rm -rf "$WORK_DIR"

echo "[*] SSH ramdisk built successfully"
echo "[*] Output: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
