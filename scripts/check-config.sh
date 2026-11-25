#!/usr/bin/env bash
# Verify a final kernel .config against the stock config it was derived from.
#
# Usage: scripts/check-config.sh <stock.config> <final.config>
#
# Fails unless Landlock is built in and listed in CONFIG_LSM, and unless
# options that must match the stock kernel (page size, compat vDSO, module
# format, existing LSMs) are unchanged. Prints the full difference to stock.
set -euo pipefail

STOCK="${1:?usage: check-config.sh <stock.config> <final.config>}"
FINAL="${2:?usage: check-config.sh <stock.config> <final.config>}"

fail=0
err() { echo "check-config: $*" >&2; fail=1; }

value() { # file option -> value, or "n" if unset/absent
  local v
  v="$(sed -n "s/^CONFIG_$2=//p" "$1" | head -n1)"
  printf '%s\n' "${v:-n}"
}

[ "$(value "$FINAL" SECURITY_LANDLOCK)" = y ] || err "CONFIG_SECURITY_LANDLOCK is not y"
lsm="$(value "$FINAL" LSM)"
case ",${lsm//\"/}," in
  *,landlock,*) ;;
  *) err "landlock missing from CONFIG_LSM=$lsm" ;;
esac
[ "$(value "$FINAL" LOCALVERSION_AUTO)" = n ] || err "CONFIG_LOCALVERSION_AUTO must be disabled"

# Options that must not differ from the stock kernel.
preserve=(
  PAGE_SIZE_4KB PAGE_SIZE_16KB PAGE_SIZE_64KB ARM64_VA_BITS
  COMPAT COMPAT_VDSO KUSER_HELPERS
  MODVERSIONS MODULE_COMPRESS_XZ MODULE_COMPRESS_ALL MODULE_SIG
  SECURITY SECURITY_APPARMOR DEFAULT_SECURITY_APPARMOR SECCOMP SECCOMP_FILTER
  CROSS_MEMORY_ATTACH INTEGRITY PREEMPT HZ
)
for opt in "${preserve[@]}"; do
  s="$(value "$STOCK" "$opt")"
  f="$(value "$FINAL" "$opt")"
  [ "$s" = "$f" ] || err "CONFIG_$opt changed from stock: $s -> $f"
done

echo "Config difference to stock:"
changes="$(diff <(grep -E '^(CONFIG_|# CONFIG_.* is not set)' "$STOCK" | sort) \
                <(grep -E '^(CONFIG_|# CONFIG_.* is not set)' "$FINAL" | sort) |
           sed -n 's/^< /- /p; s/^> /+ /p' || true)"
echo "${changes:-  (none)}"

exit "$fail"
