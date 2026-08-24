# surrealra1n / SSHLinux

A tethered downgrade / boot project for supported checkm8 devices.

## SSHLinux ramdisk workflow

The Apple SSH ramdisk is built on a **macOS GitHub Actions runner** because the SSHRD build uses Apple's `hdiutil` and HFS+ image handling. The builder follows the upstream `verygenericname/SSHRD_Script` flow and produces:

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

### Build from Fedora/Linux

Use one command:

```bash
./sshlinux.sh build owner/repository
```

Or omit the repository and let the script ask:

```bash
./sshlinux.sh build
```

The script:

1. Reads `CPID`, `MODEL` and `PRODUCT` from `irecovery -q`.
2. Authenticates through the GitHub CLI (`gh`) when necessary.
3. Asks for the target iOS version.
4. Finds a matching local SHSH/SHSH2 ticket, or asks for its local path.
5. Dispatches `.github/workflows/build-sshlinux.yml` on a macOS runner.
6. Streams the GitHub Actions log back into the same terminal.
7. Downloads the successful `sshramdisk-<PRODUCT>` artifact.
8. Extracts the ramdisk into `./sshramdisk/`.

The macOS runner never needs the physical iPhone/iPad. The local device identifiers are supplied to the workflow, while the workflow performs the IPSW/BuildManifest/ramdisk assembly on macOS.

### Boot

After a successful build:

```bash
./sshlinux.sh boot
```

The launcher uses the local `./sshramdisk/`. When it is missing, it can look for a previous successful matching artifact in the configured GitHub repository and download it automatically.

The personalized SHSH/SHSH2 ticket is not uploaded anywhere except as a workflow-dispatch input needed for the build; the macOS builder removes the temporary ticket from its workspace after creating the ramdisk. For a public repository, workflow inputs may be visible to users who can view workflow runs, so using a private repository is preferable when the ticket should not be exposed.

## Existing surrealra1n usage

The original surrealra1n workflow and restore functionality remain in `surrealra1n.sh`.

# Thanks to:

libimobiledevice team, tihmstar, LukeeGD/LukeZGD, xerub, plooshi, etc.

Mineek - iPhone X restored patcher, openra1n, and seprmvr64

Nathan (verygenericname) - SSHRD_Script
