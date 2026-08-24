# SSHLinux ramdisk output

The GitHub Actions Fedora build places the Linux userspace payload here as:

```text
fedora-payload.cpio.gz
```

This file is the Fedora aarch64 userspace payload. It is not, by itself, a bootable Apple IMG4 ramdisk.

The Apple boot-chain files are device- and iOS-version-specific and must be produced by the corresponding SSHRD/ramdisk builder:

```text
iBSS.img4
iBEC.img4
logo.img4
ramdisk.img4
devicetree.img4
trustcache.img4
kernelcache.img4
```

Keep those files out of git unless there is a specific reason to vendor them.
