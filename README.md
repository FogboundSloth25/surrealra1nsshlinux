# surrealra1n / SSHLinux

A tethered downgrade / boot project for supported checkm8 devices.

## SSHLinux ramdisk workflow

The Apple SSH ramdisk is built on a **macOS GitHub Actions runner** because the SSHRD build uses Apple's `hdiutil` and HFS+ image handling. The build follows the upstream `verygenericname/SSHRD_Script` flow and produces:

```text
sshramdisk/
├── iBSS.img4
├── iBEC.img4
├── logo.img4
├── ramdisk.img4
├── devicetree.img4
├── kernelcache.img4
├── trustcache.img4   # when required by the target build
└── version.txt
```

Run **Actions → Build SSHLinux ramdisk (macOS) → Run workflow** and provide:

- `ios_version` — target iOS version.
- `product` — `PRODUCT` from `irecovery -q`, for example `iPhone10,6`.
- `model` — `MODEL` from `irecovery -q`.
- `cpid` — `CPID` from `irecovery -q`.
- `shsh_url` — URL to the matching SHSH/SHSH2 ticket used to create the IM4M.

The workflow publishes the resulting ramdisk as the device-specific release tag:

```text
ramdisk-<PRODUCT>
```

The Linux launcher `./sshlinux.sh boot` first checks the local `./sshramdisk/`. When it is missing/incomplete, it reads `PRODUCT` with `irecovery` and automatically downloads the latest macOS-built ramdisk for that device from the corresponding GitHub Release.

You can override the download URL with:

```bash
SSHLINUX_RAMDISK_URL="https://example.invalid/sshramdisk.tar.gz" ./sshlinux.sh boot
```

## Existing surrealra1n usage

The original surrealra1n workflow and restore functionality remain in `surrealra1n.sh`.

# Thanks to:

libimobiledevice team, tihmstar, LukeeGD/LukeZGD, xerub, plooshi, etc.

Mineek - iPhone X restored patcher, openra1n, and seprmvr64

Nathan (verygenericname) - SSHRD_Script
