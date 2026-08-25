#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"Could not find upstream {label} block")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} /path/to/sshrd.sh", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")

    darwin_old = """elif [ \"$oscheck\" = 'Darwin' ]; then
    if ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); then
        echo \"[*] Waiting for device in DFU mode\"
    fi
    
    while ! (system_profiler SPUSBDataType SPUSBHostDataType 2> /dev/null | grep ' Apple Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
"""
    darwin_new = """elif [ \"$oscheck\" = 'Darwin' ]; then
    echo \"[*] Building without a physical DFU device\"
"""
    text = replace_once(text, darwin_old, darwin_new, "Darwin DFU")

    linux_old = """else
    if ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); then
        echo \"[*] Waiting for device in DFU mode\"
    fi
    
    while ! (lsusb 2> /dev/null | grep ' Apple, Inc. Mobile Device (DFU Mode)' >> /dev/null); do
        sleep 1
    done
fi
"""
    linux_new = """else
    echo \"[*] Building without a physical DFU device\"
fi
"""
    text = replace_once(text, linux_old, linux_new, "Linux DFU")

    info_old = """check=$(\"$oscheck\"/irecovery -q | grep CPID | sed 's/CPID: //')
replace=$(\"$oscheck\"/irecovery -q | grep MODEL | sed 's/MODEL: //')
deviceid=$(\"$oscheck\"/irecovery -q | grep PRODUCT | sed 's/PRODUCT: //')
ipswurl=$(curl -sL \"https://api.ipsw.me/v4/device/$deviceid?type=ipsw\" | \"$oscheck\"/jq '.firmwares | .[] | select(.version==\"'$1'\")' | \"$oscheck\"/jq -s '.[0] | .url' --raw-output)
"""
    info_new = """check=\"$DEVICE_CPID\"
replace=\"$DEVICE_MODEL\"
deviceid=\"$DEVICE_ID\"
ipswurl=$(curl -fsSL \"https://api.ipsw.me/v4/device/$deviceid?type=ipsw\" | \"$oscheck\"/jq '.firmwares | .[] | select(.version==\"'$IOS_VERSION'\")' | \"$oscheck\"/jq -s '.[0] | .url' --raw-output)
if [ -z \"$ipswurl\" ] || [ \"$ipswurl\" = \"null\" ]; then
    echo \"[!] No IPSW found for $deviceid $IOS_VERSION\"
    exit 1
fi
"""
    text = replace_once(text, info_old, info_new, "device info")

    build_old = """
\"$oscheck\"/gaster pwn > /dev/null
# A10X / T2 workaround
\"$oscheck\"/gaster decrypt_kbag 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 > /dev/null || true
\"$oscheck\"/img4tool -e -s other/shsh/\"${check}\".shsh -m work/IM4M
"""
    build_new = """
# CI has no attached DFU device. Modern Darwin (>=24) uses img4 directly
# for iBSS/iBEC, so the build path must not call gaster pwn/decrypt here.
\"$oscheck\"/img4tool -e -s other/shsh/\"${check}\".shsh -m work/IM4M
"""
    text = replace_once(text, build_old, build_new, "build-time gaster")

    ibec_old = '''"$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "rd=md0 debug=0x2014e -v wdt=-1 `if [ -z "$2" ]; then :; else echo "$2=$3"; fi` `if [ "$check" = '0x8960' ] || [ "$check" = '0x7000' ] || [ "$check" = '0x7001' ]; then echo "nand-enable-reformat=1 -restore"; fi`" -n
'''
    ibec_new = '''IBOOT_BOOTARGS="rd=md0 debug=0x2014e -v wdt=-1 `if [ -z "$2" ]; then :; else echo "$2=$3"; fi` `if [ "$check" = '0x8960' ] || [ "$check" = '0x7000' ] || [ "$check" = '0x7001' ]; then echo "nand-enable-reformat=1 -restore"; fi`"
if ! "$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "$IBOOT_BOOTARGS" -n; then
    echo "[!] NVRAM-unlock patch unavailable; retrying iBEC without -n."
    "$oscheck"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b "$IBOOT_BOOTARGS"
fi
'''
    text = replace_once(text, ibec_old, ibec_new, "iBEC patch invocation")

    anchor = '../"$oscheck"/pzb -g BuildManifest.plist "$ipswurl"\n'
    robust = '''../"$oscheck"/pzb -g BuildManifest.plist "$ipswurl"
test -s BuildManifest.plist || { echo "[!] BuildManifest.plist was not downloaded"; exit 1; }
echo "[*] BuildManifest downloaded; using model=$replace product=$deviceid"

KERNELCACHE_PATH=$(python3 - "$replace" "$deviceid" BuildManifest.plist <<'PY'
import plistlib
import sys
from pathlib import Path

model = sys.argv[1].strip().upper()
product = sys.argv[2].strip().upper()
manifest = plistlib.loads(Path(sys.argv[3]).read_bytes())

identities = manifest.get("BuildIdentities", [])
for identity in identities:
    info = identity.get("Info", {})
    candidates = {
        str(info.get("DeviceClass", "")).strip().upper(),
        str(info.get("BoardConfig", "")).strip().upper(),
        str(info.get("ProductType", "")).strip().upper(),
        str(info.get("Variant", "")).strip().upper(),
    }
    if model in candidates or product in candidates:
        kc = identity.get("Manifest", {}).get("KernelCache", {}).get("Info", {}).get("Path")
        if kc:
            print(kc)
            raise SystemExit(0)

for identity in identities:
    info = identity.get("Info", {})
    if str(info.get("ProductType", "")).strip().upper() == product:
        kc = identity.get("Manifest", {}).get("KernelCache", {}).get("Info", {}).get("Path")
        if kc:
            print(kc)
            raise SystemExit(0)

raise SystemExit("No KernelCache path found for model/product")
PY
)

test -n "$KERNELCACHE_PATH" || { echo "[!] KernelCache path resolution failed"; exit 1; }
KERNELCACHE_FILE="${KERNELCACHE_PATH##*/}"
echo "[*] KernelCache path: $KERNELCACHE_PATH"
echo "[*] KernelCache file: $KERNELCACHE_FILE"
../"$oscheck"/pzb -g "$KERNELCACHE_PATH" "$ipswurl"
test -s "$KERNELCACHE_FILE" || {
    echo "[!] KernelCache download failed: $KERNELCACHE_FILE"
    echo "[!] Expected path: $KERNELCACHE_PATH"
    exit 1
}

'''
    text = replace_once(text, anchor, robust, "BuildManifest download")

    text, count = re.subn(
        r'^\.\./"\$oscheck"/pzb -g "\$\(awk .*?kernelcache\.release.*?\)" "\$ipswurl"\n',
        '# KernelCache already downloaded using the structured manifest lookup above.\n',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise RuntimeError("Could not replace upstream kernelcache pzb line")

    text = re.sub(
        r'work/"\$\(awk .*?kernelcache\.release.*?\)"',
        'work/"$KERNELCACHE_FILE"',
        text,
    )

    path.write_text(text, encoding="utf-8")
    print(f"[+] Patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())