# rpi-landlock-kernel

Raspberry Pi OS kernels rebuilt with [Landlock](https://docs.kernel.org/userspace-api/landlock.html) enabled, so [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandboxes can run on the Raspberry Pi 4 and 5 nodes of a k3s cluster.

## Why

OpenShell needs Landlock ABI >= 3 (Linux >= 6.2), enabled at boot. The Raspberry Pi OS (trixie) kernel is new enough, but it is built with

```
# CONFIG_SECURITY_LANDLOCK is not set
CONFIG_LSM=""
```

so Landlock is missing completely. AppArmor, seccomp and `CROSS_MEMORY_ATTACH` are already built in. Yama is not.

## What is changed

Nothing except the Landlock/LSM options and the kernel release suffix. Each build:

1. Reads the current version of the `linux-image-rpi-2712` (Pi 5) and `linux-image-rpi-v8` (Pi 4) metapackages from `https://archive.raspberrypi.com/debian/dists/trixie/main/binary-arm64/Packages.gz`. If the two versions differ, the build fails.
2. Downloads the matching stock `linux-image-<stock release>` package and uses its `/boot/config-<stock release>` as the base config. The page size (16K on 2712) and all other options come from this config.
3. Downloads the source package `linux` for exactly that version (`.dsc`, `.orig.tar.xz` and `.debian.tar.xz` from `pool/main/l/linux`, with checksums verified against `Sources.gz`) and unpacks it with `dpkg-source -x`. The orig tarball is plain upstream Linux. The Raspberry Pi tree comes from `debian/patches/rpi/rpi.patch`, which `dpkg-source` applies together with the rest of `debian/patches/series`, the same way the official package build does.
4. Applies:
   ```sh
   scripts/config --enable SECURITY_LANDLOCK \
     --set-str LSM "landlock,lockdown,yama,integrity,apparmor" \
     --set-str LOCALVERSION "<stock suffix>-landlock" \
     --disable LOCALVERSION_AUTO
   make olddefconfig
   ```
   The kernel release becomes `<stock release>-landlock`, for example `6.18.60+rpt-rpi-2712-landlock`. `lockdown` and `yama` in `CONFIG_LSM` do nothing as long as those LSMs are not built (as in stock). They are listed so the order stays the upstream default if they ever are.
5. Checks the result: `CONFIG_SECURITY_LANDLOCK=y`, `landlock` in `CONFIG_LSM`, `make -s kernelrelease` = `<stock release>-landlock`, and key options (page size, compat vDSO, module format, AppArmor, seccomp, …) unchanged from stock. See `scripts/check-config.sh`.
6. Builds `Image` and `modules` natively on arm64 (`ubuntu-24.04-arm` runner, `debian:trixie` container, `gcc-14` and `arm-linux-gnueabihf-gcc` for the compat vDSO, the same toolchain as Raspberry Pi OS). No device trees are built: nodes keep Raspberry Pi's own DTBs and overlays.

## Bundle layout (contract)

Each release has `landlock-kernel-2712.tar.gz`, `landlock-kernel-v8.tar.gz` and `SHA256SUMS` (`sha256sum` format, covering both tarballs). A tarball contains exactly:

```
kernel.img                         # arch/arm64/boot/Image (uncompressed)
config                             # final .config
metadata.json                      # see below
modules/<kernel_release>/...       # installs to /usr/lib/modules/<kernel_release>/
```

Modules are stripped (`INSTALL_MOD_STRIP=1`) and xz-compressed like the stock ones (`CONFIG_MODULE_COMPRESS_XZ`). They include `modules.dep` etc. The `build`/`source` symlinks are removed.

`metadata.json`:

```json
{
  "flavour": "2712",
  "board": "Raspberry Pi 5",
  "package_version": "1:6.18.60-1+rpt1",
  "stock_release": "6.18.60+rpt-rpi-2712",
  "kernel_release": "6.18.60+rpt-rpi-2712-landlock",
  "source": "<space-separated URLs of the .dsc, .orig.tar.xz and .debian.tar.xz used>",
  "built_at": "2026-11-25T10:00:00Z",
  "commit": "<sha of this repository>"
}
```

`board` is `Raspberry Pi 4` for `v8`.

## Releases

The release tag is the package version with the epoch removed and `+` replaced by `-`. For example, `1:6.18.60-1+rpt1` becomes `6.18.60-1-rpt1`.

The `build` workflow runs every Monday at 05:00 UTC and can also be started by hand:

```sh
gh workflow run build.yml                 # build if there is no release for the current kernel yet
gh workflow run build.yml -f force=true   # rebuild and replace the assets of an existing release
```

If a release for the current version already exists and `force` is not set, the build jobs are skipped and the run summary says "already built". New Raspberry Pi kernels are picked up by the weekly run.

**Rebuild whenever Raspberry Pi releases a new kernel.** The modules in a bundle only match their own kernel. A node that installs a new stock kernel package keeps booting the custom kernel until it is reconfigured with the matching bundle. The weekly schedule produces that bundle.

## Install

Installation is handled by the Ansible playbook in [VincentSchmid/onprem-infra](https://github.com/VincentSchmid/onprem-infra):

```sh
just configure-kernel <node>
```

It downloads the bundle for the node's board, verifies it against `SHA256SUMS`, copies `kernel.img` under a custom file name next to the stock kernel in the boot partition, installs `modules/<kernel_release>` to `/usr/lib/modules/<kernel_release>/`, and boots it once via `tryboot` before making it the default. The stock kernel and Raspberry Pi device trees are left alone, so going back is a `config.txt` change.

After booting, check with:

```sh
uname -r                          # ...-landlock
cat /sys/kernel/security/lsm      # contains landlock
```

## Running locally

The scripts need `curl`, `jq`, `dpkg-deb`/`dpkg-source` and, for `build.sh`, a native arm64 Debian trixie environment with the packages installed in `.github/workflows/build.yml`:

```sh
scripts/resolve.sh resolved.json
scripts/build.sh 2712 resolved.json work/2712
scripts/package.sh 2712 resolved.json work/2712 dist
```

## License

The scripts and workflow in this repository are MIT licensed (see `LICENSE`). The kernel binaries in the releases are built from the Linux kernel and are licensed under GPL-2.0. Each release lists the exact source URLs.
