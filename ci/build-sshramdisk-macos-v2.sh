#!/usr/bin/env bash
set -Eeuo pipefail

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

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "[!] SSH ramdisk build failed (exit $rc)"
    if [[ -d "$UPSTREAM_DIR/logs" ]]; then
      echo "[!] SSHRD logs: $UPSTREAM_DIR/logs"
      find "$UPSTREAM_DIR/logs" -maxdepth 1 -type f -print || true
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
test -s "$LOCAL_SHSH" || { echo "[!] SHSH ticket missing: $LOCAL_SHSH"; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "[!] Unsupported macOS architecture: $ARCH"; exit 1 ;;
esac

clone_repo() {
  local url="$1" dest="$2"
  git clone --depth=1 "$url" "$dest"
}

echo "[*] Cloning upstream SSHRD_Script"
clone_repo https://github.com/verygenericname/SSHRD_Script.git "$UPSTREAM_DIR"
cd "$UPSTREAM_DIR"
git submodule update --init --recursive

echo "[*] Preparing Cryptiiiic/iBoot64Patcher for macOS $ARCH"
clone_repo https://github.com/Cryptiiiic/iBoot64Patcher.git "$PATCHER_DIR"
cd "$PATCHER_DIR"

DEP_URL="https://cdn.cryptiiiic.com/deps/static/macOS/${ARCH}/macOS_${ARCH}_Release_Latest.tar.zst"
DEP_ARCHIVE="$WORK_DIR/macOS_${ARCH}_Release_Latest.tar.zst"
DEP_ROOT="$PATCHER_DIR/dep_root"

echo "[*] Downloading Cryptiiiic static dependencies"
if ! curl -fL --retry 3 --retry-all-errors "$DEP_URL" -o "$DEP_ARCHIVE"; then
  echo "[!] TLS validation failed for cdn.cryptiiiic.com; retrying only this known dependency with -k"
  curl -kfL --retry 3 --retry-all-errors "$DEP_URL" -o "$DEP_ARCHIVE"
fi

command -v unzstd >/dev/null 2>&1 || brew install zstd >/dev/null
mkdir -p "$DEP_ROOT"
tar --use-compress-program=unzstd -xf "$DEP_ARCHIVE" -C "$DEP_ROOT"
test -d "$DEP_ROOT/include" && test -d "$DEP_ROOT/lib"

PATCHER_MAIN="$PATCHER_DIR/src/main.cpp"
PATCH_HEADER="$DEP_ROOT/include/libpatchfinder/patch.hpp"
python3 - "$PATCHER_MAIN" "$PATCH_HEADER" <<'PY'
from pathlib import Path
import sys
main = Path(sys.argv[1])
header = Path(sys.argv[2])
s = main.read_text()
s = s.replace('p2._patchSize', 'p2.getPatchSize()').replace('p2._patch', 'p2.getPatch()')
main.write_text(s)
h = header.read_text()
h = h.replace('inline const void *getPatch(){return _patch;}', 'inline const void *getPatch() const {return _patch;}')
h = h.replace('inline size_t getPatchSize(){return  _patchSize;}', 'inline size_t getPatchSize() const {return _patchSize;}')
header.write_text(h)
PY

grep -F 'getPatch() const' "$PATCH_HEADER" >/dev/null
grep -F 'getPatchSize() const' "$PATCH_HEADER" >/dev/null

cmake -S . -B cmake-build-release \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DARCH="$ARCH" \
  -DNO_PKGCFG=1
cmake --build cmake-build-release --parallel "$(sysctl -n hw.ncpu)"

PATCHER_BIN=""
for candidate in \
  "$PATCHER_DIR/cmake-build-release/iBoot64Patcher" \
  "$PATCHER_DIR/cmake-build-release/src/iBoot64Patcher"; do
  if [[ -x "$candidate" ]]; then PATCHER_BIN="$candidate"; break; fi
done
if [[ -z "$PATCHER_BIN" ]]; then
  PATCHER_BIN="$(find "$PATCHER_DIR/cmake-build-release" -type f -name iBoot64Patcher -perm -111 -print -quit)"
fi
test -n "$PATCHER_BIN" && test -x "$PATCHER_BIN" || { echo "[!] iBoot64Patcher binary not found"; find "$PATCHER_DIR/cmake-build-release" -maxdepth 3 -type f -print; exit 1; }
cp "$PATCHER_BIN" "$UPSTREAM_DIR/Darwin/iBoot64Patcher"
chmod 0755 "$UPSTREAM_DIR/Darwin/iBoot64Patcher"
cd "$UPSTREAM_DIR"

echo "[*] Using iBoot64Patcher: $PATCHER_BIN"
mkdir -p "$SHSH_DIR"
cp "$LOCAL_SHSH" "$SHSH_DIR/${DEVICE_CPID}.shsh"
chmod 600 "$SHSH_DIR/${DEVICE_CPID}.shsh"

python3 "$ROOT_DIR/ci/patch-sshrd.py" "$UPSTREAM_DIR/sshrd.sh"
/bin/sh -n "$UPSTREAM_DIR/sshrd.sh"
chmod +x "$UPSTREAM_DIR/sshrd.sh"

# Verify that the patched script contains the critical CI substitutions before execution.
grep -F 'Building without a physical DFU device' "$UPSTREAM_DIR/sshrd.sh" >/dev/null
grep -F 'KERNELCACHE_PATH=' "$UPSTREAM_DIR/sshrd.sh" >/dev/null
grep -F 'NVRAM-unlock patch unavailable' "$UPSTREAM_DIR/sshrd.sh" >/dev/null

echo "[*] Starting patched SSHRD build"
cd "$UPSTREAM_DIR"
./sshrd.sh "$IOS_VERSION"

required=(iBSS.img4 iBEC.img4 logo.img4 ramdisk.img4 devicetree.img4 kernelcache.img4 version.txt)
for f in "${required[@]}"; do
  test -s "sshramdisk/$f" || { echo "[!] Missing required output: sshramdisk/$f"; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
cp -a sshramdisk/. "$OUTPUT_DIR/"
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

for f in "${required[@]}"; do test -s "$OUTPUT_DIR/$f"; done

echo "[*] SSH ramdisk build completed successfully"
ls -lh "$OUTPUT_DIR"
