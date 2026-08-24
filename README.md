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

The Fedora 44 launcher automatically installs its required packages and then:

1. Reads `CPID`, `MODEL`, `PRODUCT` and `ECID` from `irecovery -q`.
2. Authenticates through the GitHub CLI (`gh`) when necessary.
3. Asks for the target iOS version.
4. Looks for an existing local `.shsh`/`.shsh2` ticket.
5. If none exists, queries `shsh.host` for a previously saved blob belonging to the device ECID.
6. If no saved blob exists, installs/downloads `tsschecker` and asks Apple's TSS service whether the requested firmware is currently signed; when signed, it saves a fresh ticket automatically.
7. Dispatches `.github/workflows/build-sshlinux.yml` on a macOS runner.
8. Streams the GitHub Actions log back into the same terminal.
9. Downloads the successful `sshramdisk-<PRODUCT>` artifact.
10. Extracts the ramdisk into `./sshramdisk/`.

For an unsigned firmware with no previously saved blob, the script stops and explains that a new personalized SHSH cannot be created retroactively. The blob must have been saved earlier (locally or on a service such as shsh.host).

The macOS runner never needs the physical iPhone/iPad. The local device identifiers and the resolved SHSH ticket are supplied to the workflow, while the workflow performs the IPSW/BuildManifest/ramdisk assembly on macOS.

### Boot

After a successful build:

```bash
./sshlinux.sh boot
```

The launcher uses the local `./sshramdisk/` and never rebuilds it on Fedora.

The SHSH/SHSH2 ticket is transferred to the GitHub Actions run as a workflow input because it is required to construct the personalized IM4M. Use a private repository when the ticket should not be exposed to other people who can inspect workflow runs.

## Existing surrealra1n usage

The original surrealra1n workflow and restore functionality remain in `surrealra1n.sh`.

# Thanks to:

libimobiledevice team, tihmstar, LukeeGD/LukeZGD, xerub, plooshi, etc.

Mineek - iPhone X restored patcher, openra1n, and seprmvr64

Nathan (verygenericname) - SSHRD_Script
