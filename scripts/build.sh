#!/usr/bin/env bash
# Build one Raspberry Pi OS kernel flavour with Landlock enabled.
#
# Usage: scripts/build.sh <flavour> <resolved.json> [workdir]
#   flavour        2712 (Raspberry Pi 5) or v8 (Raspberry Pi 4)
#   resolved.json  output of scripts/resolve.sh
#   workdir        scratch directory (default: ./work/<flavour>)
#
# Produces in <workdir>:
#   src/                      the exact source of the published package
#   stock.config              /boot/config-<stock release> from the stock deb
#   src/.config               final config
#   modules-staging/lib/modules/<kernel_release>/   installed modules
#   kernel_release            the kernel release string
#   config.diff               config difference to stock
#
# Must run natively on arm64 with the Debian trixie toolchain, the same one
# Raspberry Pi OS builds with (see README and .github/workflows/build.yml).
set -euo pipefail

FLAVOUR="${1:?usage: build.sh <flavour> <resolved.json> [workdir]}"
RESOLVED="$(realpath "${2:?usage: build.sh <flavour> <resolved.json> [workdir]}")"
WORK="$(mkdir -p "${3:-work/$FLAVOUR}" && realpath "${3:-work/$FLAVOUR}")"
SUFFIX="-landlock"
LSM="landlock,lockdown,yama,integrity,apparmor"
JOBS="${JOBS:-$(nproc)}"

log() { printf '\n==> %s\n' "$*" >&2; }
die() { echo "build: $*" >&2; exit 1; }

jq -e --arg f "$FLAVOUR" '.flavours[$f]' "$RESOLVED" >/dev/null || die "unknown flavour $FLAVOUR"
ARCHIVE="$(jq -r .archive "$RESOLVED")"
PACKAGE_VERSION="$(jq -r .package_version "$RESOLVED")"
STOCK_RELEASE="$(jq -r --arg f "$FLAVOUR" '.flavours[$f].stock_release' "$RESOLVED")"
KERNEL_RELEASE="$STOCK_RELEASE$SUFFIX"

# Same toolchain as the Raspberry Pi OS build (debian/rules.gen: C_COMPILER=gcc-14,
# COMPAT_GNU_TYPE=arm-linux-gnueabihf for the 32-bit compat vDSO).
CC_BIN="${CC_BIN:-aarch64-linux-gnu-gcc-14}"
COMPAT_PREFIX="${COMPAT_PREFIX:-arm-linux-gnueabihf-}"
MAKE_ARGS=(ARCH=arm64 "CC=$CC_BIN" "CROSS_COMPILE_COMPAT=$COMPAT_PREFIX" LOCALVERSION=)
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-rpi-landlock-kernel}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"
KBUILD_BUILD_VERSION_TIMESTAMP="Debian $PACKAGE_VERSION landlock ($(date -u +%Y-%m-%d))"
export KBUILD_BUILD_VERSION_TIMESTAMP

kmake() { make -C "$WORK/src" "${MAKE_ARGS[@]}" "$@"; }

download() { # url dest sha256
  if [ -f "$2" ] && echo "$3  $2" | sha256sum -c --status; then return; fi
  curl -fsSL --retry 3 -o "$2.part" "$1"
  echo "$3  $2.part" | sha256sum -c --quiet || die "checksum mismatch for $1"
  mv "$2.part" "$2"
}

log "Stock kernel package for $FLAVOUR ($STOCK_RELEASE, $PACKAGE_VERSION)"
mkdir -p "$WORK/dl"
deb_path="$(jq -r --arg f "$FLAVOUR" '.flavours[$f].deb.path' "$RESOLVED")"
deb_sha="$(jq -r --arg f "$FLAVOUR" '.flavours[$f].deb.sha256' "$RESOLVED")"
deb="$WORK/dl/$(basename "$deb_path")"
download "$ARCHIVE/$deb_path" "$deb" "$deb_sha"
dpkg-deb --fsys-tarfile "$deb" | tar -xO "./boot/config-$STOCK_RELEASE" >"$WORK/stock.config"
[ -s "$WORK/stock.config" ] || die "no /boot/config-$STOCK_RELEASE in $deb"

log "Source package $(jq -r '.source.package' "$RESOLVED") $PACKAGE_VERSION"
dsc=""
while IFS=$'\t' read -r name url sha; do
  download "$url" "$WORK/dl/$name" "$sha"
  case "$name" in *.dsc) dsc="$WORK/dl/$name" ;; esac
done < <(jq -r '.source.files[] | [.name, .url, .sha256] | @tsv' "$RESOLVED")
[ -n "$dsc" ] || die "no .dsc downloaded"
# The orig tarball is vanilla upstream; dpkg-source applies debian/patches/series,
# which includes the Raspberry Pi tree (rpi/rpi.patch). Checksums were verified
# against the archive's Sources index above, and dpkg-source re-checks them
# against the .dsc.
rm -rf "$WORK/src"
dpkg-source --no-check -x "$dsc" "$WORK/src" >"$WORK/dpkg-source.log"
grep -q 'applying rpi/rpi.patch' "$WORK/dpkg-source.log" || die "Raspberry Pi patch was not applied"

KERNEL_VERSION="$(kmake -s kernelversion)"
case "$STOCK_RELEASE" in
  "$KERNEL_VERSION"*) ;;
  *) die "stock release $STOCK_RELEASE does not start with source kernel version $KERNEL_VERSION" ;;
esac
LOCALVERSION_VALUE="${STOCK_RELEASE#"$KERNEL_VERSION"}$SUFFIX"

log "Config: stock + Landlock (CONFIG_LOCALVERSION=$LOCALVERSION_VALUE)"
cp "$WORK/stock.config" "$WORK/src/.config"
"$WORK/src/scripts/config" --file "$WORK/src/.config" \
  --enable SECURITY_LANDLOCK \
  --set-str LSM "$LSM" \
  --set-str LOCALVERSION "$LOCALVERSION_VALUE" \
  --disable LOCALVERSION_AUTO
kmake olddefconfig
kmake -s syncconfig
"$(dirname "$0")/check-config.sh" "$WORK/stock.config" "$WORK/src/.config" | tee "$WORK/config.diff"

actual_release="$(kmake -s kernelrelease)"
[ "$actual_release" = "$KERNEL_RELEASE" ] ||
  die "kernelrelease is '$actual_release', expected '$KERNEL_RELEASE'"
echo "$KERNEL_RELEASE" >"$WORK/kernel_release"

log "Building Image and modules with $JOBS jobs"
kmake -j"$JOBS" Image modules
built_release="$(cat "$WORK/src/include/config/kernel.release")"
[ "$built_release" = "$KERNEL_RELEASE" ] || die "built kernel.release is '$built_release'"

log "Installing modules"
rm -rf "$WORK/modules-staging"
kmake modules_install INSTALL_MOD_PATH="$WORK/modules-staging" INSTALL_MOD_STRIP=1
rm -f "$WORK/modules-staging/lib/modules/$KERNEL_RELEASE/build" \
  "$WORK/modules-staging/lib/modules/$KERNEL_RELEASE/source"
[ -f "$WORK/modules-staging/lib/modules/$KERNEL_RELEASE/modules.dep" ] || die "modules.dep missing (is depmod installed?)"

log "Built $KERNEL_RELEASE"
