#!/usr/bin/env bash
# Render GitHub release notes.
#
# Usage: scripts/release-notes.sh <resolved.json> <dist-dir>
# <dist-dir> holds the tarballs, SHA256SUMS and config-<flavour>.diff files.
set -euo pipefail

RESOLVED="${1:?usage: release-notes.sh <resolved.json> <dist-dir>}"
DIST="${2:?usage: release-notes.sh <resolved.json> <dist-dir>}"
REPO="${GITHUB_REPOSITORY:-VincentSchmid/rpi-landlock-kernel}"
COMMIT="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

pv="$(jq -r .package_version "$RESOLVED")"

cat <<EOF
Raspberry Pi OS kernel \`$pv\` rebuilt with **Landlock** enabled, so NVIDIA OpenShell sandboxes (Landlock ABI >= 3) can run on Raspberry Pi 4 and 5.

| Flavour | Board | Stock release | Kernel release | Bundle |
|---|---|---|---|---|
EOF
for f in $(jq -r '.flavours | keys_unsorted[]' "$RESOLVED"); do
  board="$(jq -r --arg f "$f" '.flavours[$f].board' "$RESOLVED")"
  stock="$(jq -r --arg f "$f" '.flavours[$f].stock_release' "$RESOLVED")"
  echo "| \`$f\` | $board | \`$stock\` | \`$stock-landlock\` | \`landlock-kernel-$f.tar.gz\` |"
done

cat <<'EOF'

## Change against the stock kernel

The build starts from the stock `/boot/config-<stock release>` taken from the published `linux-image-<stock release>` package and only applies:

```sh
scripts/config --enable SECURITY_LANDLOCK \
  --set-str LSM "landlock,lockdown,yama,integrity,apparmor" \
  --set-str LOCALVERSION "<stock suffix>-landlock" \
  --disable LOCALVERSION_AUTO
make olddefconfig
```

Resulting difference between the stock config and the shipped `config` (toolchain detection lines such as `CONFIG_RUSTC_*` may also differ):

EOF
for d in "$DIST"/config-*.diff; do
  [ -e "$d" ] || continue
  f="$(basename "$d" .diff)"
  f="${f#config-}"
  # shellcheck disable=SC2016 # literal Markdown backticks
  printf '<details><summary><code>%s</code></summary>\n\n```diff\n%s\n```\n\n</details>\n\n' "$f" "$(cat "$d")"
done

cat <<EOF
## Install

Install with the Ansible playbook in [VincentSchmid/onprem-infra](https://github.com/VincentSchmid/onprem-infra):

\`\`\`sh
just configure-kernel <node>
\`\`\`

It installs \`kernel.img\` under a custom file name next to the stock kernel, installs \`modules/<kernel_release>\` to \`/usr/lib/modules/<kernel_release>/\`, keeps Raspberry Pi's own device trees and tests the new kernel with \`tryboot\` before making it the default.

## Source (GPL-2.0)

The kernel binaries are licensed under GPL-2.0. They were built from exactly the source of the Raspberry Pi OS package \`linux $pv\` (the orig tarball plus the Debian/Raspberry Pi patch series applied by \`dpkg-source -x\`):

EOF
jq -r '.source.files[] | "- <\(.url)> (sha256 `\(.sha256)`)"' "$RESOLVED"
cat <<EOF

Packaging repository: $(jq -r .source.vcs "$RESOLVED"). Build scripts: https://github.com/$REPO/tree/$COMMIT.
If any of these URLs stops working, open an issue in this repository and the corresponding source will be provided.

## Checksums

\`\`\`
$(cat "$DIST/SHA256SUMS")
\`\`\`
EOF
