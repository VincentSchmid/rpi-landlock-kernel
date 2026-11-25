#!/usr/bin/env bash
# Resolve the current Raspberry Pi OS kernel package version and everything
# needed to rebuild it, from the Raspberry Pi apt archive indexes.
#
# Usage: scripts/resolve.sh [resolved.json]
# Writes JSON to the given file (default: stdout).
#
# Environment:
#   ARCHIVE  apt archive base URL (default https://archive.raspberrypi.com/debian)
#   SUITE    distribution (default trixie)
set -euo pipefail

ARCHIVE="${ARCHIVE:-https://archive.raspberrypi.com/debian}"
SUITE="${SUITE:-trixie}"
OUT="${1:-/dev/stdout}"

declare -A BOARD=([2712]="Raspberry Pi 5" [v8]="Raspberry Pi 4")
FLAVOURS=(2712 v8)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch_index() {
  curl -fsSL --retry 3 "$ARCHIVE/dists/$SUITE/main/$1" | gunzip >"$2"
}
fetch_index binary-arm64/Packages.gz "$work/Packages"
fetch_index source/Sources.gz "$work/Sources"

# Print all stanzas of $1 whose Package field is exactly $2
# (optionally also requiring Version == $3).
stanzas() {
  awk -v pkg="$2" -v ver="${3:-}" '
    BEGIN { RS = ""; ORS = "\n\n" }
    {
      n = split($0, l, "\n"); p = 0; v = (ver == "")
      for (i = 1; i <= n; i++) {
        if (l[i] == "Package: " pkg) p = 1
        if (ver != "" && l[i] == "Version: " ver) v = 1
      }
      if (p && v) print
    }' "$1"
}

# Print the value of single-line field $1 from stanza text on stdin.
field() {
  awk -v f="$1" 'index($0, f ": ") == 1 { print substr($0, length(f) + 3); exit }'
}

# Highest of the versions given on stdin (one per line).
max_version() {
  local best="" v
  while read -r v; do
    [ -n "$v" ] || continue
    if [ -z "$best" ]; then
      best="$v"
    elif command -v dpkg >/dev/null; then
      if dpkg --compare-versions "$v" gt "$best"; then best="$v"; fi
    else
      best="$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -n1)"
    fi
  done
  printf '%s\n' "$best"
}

die() { echo "resolve: $*" >&2; exit 1; }

package_version=""
flavours_json="{}"
for f in "${FLAVOURS[@]}"; do
  meta="linux-image-rpi-$f"
  ver="$(stanzas "$work/Packages" "$meta" | field Version | max_version)"
  [ -n "$ver" ] || die "metapackage $meta not found"
  if [ -z "$package_version" ]; then
    package_version="$ver"
  elif [ "$ver" != "$package_version" ]; then
    die "metapackage versions differ: $meta is $ver, expected $package_version"
  fi

  depends="$(stanzas "$work/Packages" "$meta" "$ver" | field Depends)"
  image_pkg="$(tr ',' '\n' <<<"$depends" | sed -n 's/^ *\(linux-image-[^ ]*\) (= .*/\1/p' | head -n1)"
  [ -n "$image_pkg" ] || die "cannot find versioned image package in Depends of $meta: $depends"
  stock_release="${image_pkg#linux-image-}"

  img="$(stanzas "$work/Packages" "$image_pkg" "$ver")"
  [ -n "$img" ] || die "$image_pkg version $ver not in Packages"
  flavours_json="$(jq -c \
    --arg f "$f" --arg board "${BOARD[$f]}" --arg rel "$stock_release" --arg pkg "$image_pkg" \
    --arg path "$(field Filename <<<"$img")" --arg sha "$(field SHA256 <<<"$img")" \
    --arg size "$(field Size <<<"$img")" \
    '.[$f] = {board: $board, stock_release: $rel, package: $pkg,
              deb: {path: $path, sha256: $sha, size: ($size | tonumber)}}' <<<"$flavours_json")"
done

src_pkg="$(stanzas "$work/Packages" "linux-image-rpi-${FLAVOURS[0]}" "$package_version" | field Source)"
src_pkg="${src_pkg%% *}"
src_pkg="${src_pkg:-linux}"
src="$(stanzas "$work/Sources" "$src_pkg" "$package_version")"
[ -n "$src" ] || die "source package $src_pkg version $package_version not in Sources"
directory="$(field Directory <<<"$src")"
files_json="$(awk '
    /^Checksums-Sha256:/ { on = 1; next }
    on && /^ / { print $1, $2, $3; next }
    on { exit }' <<<"$src" |
  jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")
               | {sha256: .[0], size: (.[1] | tonumber), name: .[2]})')"
[ "$(jq length <<<"$files_json")" -gt 0 ] || die "no source files listed for $src_pkg $package_version"
jq -e 'any(.[]; .name | endswith(".dsc"))' <<<"$files_json" >/dev/null || die "no .dsc in source files"

# Release tag: epoch removed, "+" replaced by "-" (1:6.18.60-1+rpt1 -> 6.18.60-1-rpt1).
tag="${package_version#*:}"
tag="${tag//+/-}"

jq -n \
  --arg archive "$ARCHIVE" --arg suite "$SUITE" --arg pv "$package_version" --arg tag "$tag" \
  --arg src_pkg "$src_pkg" --arg dir "$directory" --arg vcs "$(field Vcs-Git <<<"$src")" \
  --argjson files "$files_json" --argjson flavours "$flavours_json" \
  '{package_version: $pv, tag: $tag, archive: $archive, suite: $suite,
    source: {package: $src_pkg, directory: $dir, vcs: $vcs,
             files: ($files | map(. + {url: ($archive + "/" + $dir + "/" + .name)}))},
    flavours: $flavours}' >"$OUT"
