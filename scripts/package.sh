#!/usr/bin/env bash
# Package a finished build into landlock-kernel-<flavour>.tar.gz.
#
# Usage: scripts/package.sh <flavour> <resolved.json> <workdir> [outdir]
#
# Bundle layout:
#   kernel.img                     arch/arm64/boot/Image (uncompressed)
#   config                         final .config
#   metadata.json
#   modules/<kernel_release>/...   installs to /usr/lib/modules/<kernel_release>/
set -euo pipefail

FLAVOUR="${1:?usage: package.sh <flavour> <resolved.json> <workdir> [outdir]}"
RESOLVED="$(realpath "${2:?}")"
WORK="$(realpath "${3:?}")"
OUTDIR="$(mkdir -p "${4:-dist}" && realpath "${4:-dist}")"
COMMIT="${COMMIT:-${GITHUB_SHA:-$(git -C "$(dirname "$0")" rev-parse HEAD 2>/dev/null || echo unknown)}}"

die() { echo "package: $*" >&2; exit 1; }

KERNEL_RELEASE="$(cat "$WORK/kernel_release")"
STOCK_RELEASE="$(jq -r --arg f "$FLAVOUR" '.flavours[$f].stock_release' "$RESOLVED")"
[ "$KERNEL_RELEASE" = "$STOCK_RELEASE-landlock" ] || die "unexpected kernel release $KERNEL_RELEASE"
image="$WORK/src/arch/arm64/boot/Image"
modules="$WORK/modules-staging/lib/modules/$KERNEL_RELEASE"
[ -f "$image" ] || die "missing $image"
[ -d "$modules" ] || die "missing $modules"

stage="$WORK/stage"
rm -rf "$stage"
mkdir -p "$stage/modules"
cp "$image" "$stage/kernel.img"
cp "$WORK/src/.config" "$stage/config"
cp -a "$modules" "$stage/modules/$KERNEL_RELEASE"
find "$stage/modules" -maxdepth 2 -type l \( -name build -o -name source \) -delete

jq -n \
  --arg flavour "$FLAVOUR" \
  --arg board "$(jq -r --arg f "$FLAVOUR" '.flavours[$f].board' "$RESOLVED")" \
  --arg package_version "$(jq -r .package_version "$RESOLVED")" \
  --arg stock_release "$STOCK_RELEASE" \
  --arg kernel_release "$KERNEL_RELEASE" \
  --arg source "$(jq -r '[.source.files[].url] | join(" ")' "$RESOLVED")" \
  --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg commit "$COMMIT" \
  '{flavour: $flavour, board: $board, package_version: $package_version,
    stock_release: $stock_release, kernel_release: $kernel_release,
    source: $source, built_at: $built_at, commit: $commit}' >"$stage/metadata.json"

out="$OUTDIR/landlock-kernel-$FLAVOUR.tar.gz"
tar -C "$stage" --owner=0 --group=0 --numeric-owner --sort=name \
  -czf "$out" kernel.img config metadata.json modules
echo "Wrote $out ($(du -h "$out" | cut -f1))"
cat "$stage/metadata.json"
