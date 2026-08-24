#!/usr/bin/env bash
set -euo pipefail

: "${IOS_VERSION:?IOS_VERSION is required}"
: "${DEVICE_ID:?DEVICE_ID is required}"
: "${DEVICE_MODEL:?DEVICE_MODEL is required}"
: "${DEVICE_CPID:?DEVICE_CPID is required}"
: "${SHSH_URL:?SHSH_URL is required}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/ci/work-sshrd"
UPSTREAM_DIR="$WORK_DIR/SSHRD_Script"
SHSH_DIR="$UPSTREAM_DIR/other/shsh"
OUTPUT_DIR="$ROOT_DIR/sshramdisk"

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

echo "[*] Cloning upstream SSHRD_Script"
git clone --depth=1 https://github.com/verygenericname/SSHRD_Script.git "$UPSTREAM_DIR"
cd "$UPSTREAM_DIR"
git submodule update --init --recursive

mkdir -p "$SHSH_DIR"

case "$SHSH_URL" in
  http://*|https://*)
    curl -fL --retry 3 --retry-all-errors "$SHSH_URL" -o "$SHSH_DIR/${DEVICE_CPID}.shsh"
    ;;
  *)
    echo "[!] SHSH_URL must be an http(s) URL"
    exit 1
    ;;
esac

[[ -s "$SHSH_DIR/${DEVICE_CPID}.shsh" ]] || {
  echo "[!] Downloaded SHSH ticket is empty"
  exit 1
}

python3 - <<'PY'
from pathlib import Path

p = Path("sshrd.sh")
s = p.read_text()

old = '''elif [ "$oscheck" = 'Darwin' ]; then
    if ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); then
        echo "[*] Waiting for device in DFU mode"
    fi
    
    while ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
else
    if ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); then
        echo "[*] Waiting for device in DFU mode"
    fi
    
    while ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
fi

echo "[*] Getting device info and pwning... this may take a second"
check=$("$oscheck"/irecovery -q | grep CPID | sed 's/CPID: //')
replace=$("$oscheck"/irecovery -q | grep MODEL | sed 's/MODEL: //')
deviceid=$("$oscheck"/irecovery -q | grep PRODUCT | sed 's/PRODUCT: //')
ipswurl=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$1'")' | "$oscheck"/jq -s '.[0] | .url' --raw-output)
'''

new = '''echo "[*] Building without a physical DFU device"
check="$DEVICE_CPID"
replace="$DEVICE_MODEL"
deviceid="$DEVICE_ID"
ipswurl=$(curl -fsSL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$oscheck"/jq '.firmwares | .[] | select(.version=="'$IOS_VERSION'")' | "$oscheck"/jq -s '.[0] | .url' --raw-output)

if [ -z "$ipswurl" ] || [ "$ipswurl" = "null" ]; then
    echo "[!] No IPSW found for $deviceid $IOS_VERSION"
    exit 1
fi
'''

if old not in s:
    raise SystemExit("Could not find the SSHRD device-detection block")
s = s.replace(old, new, 1)
p.write_text(s)
PY

# Run the upstream build path. hdiutil/hfsplus handling is intentionally left to
# the upstream script, because the SSH ramdisk is built from an HFS+ image on macOS.
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

echo "[*] SSH ramdisk built successfully"
echo "[*] Output: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
