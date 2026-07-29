# shellcheck shell=bash
# Runtime facts about this host. The Zimbra version is not pinned anywhere in
# this program; it is observed once per session and cached.
[ -n "${ZRO_LIB_CAPABILITY_LOADED:-}" ] && return 0
ZRO_LIB_CAPABILITY_LOADED=1

ZRO_CAP_VERSION_CACHE=""

zro_cap_reset() {
  ZRO_CAP_VERSION_CACHE=""
}

zro_cap_version() {
  if [ -n "${ZRO_CAP_FORCE:-}" ]; then
    printf '%s' "$ZRO_CAP_FORCE"
    return 0
  fi
  if [ -z "$ZRO_CAP_VERSION_CACHE" ]; then
    ZRO_CAP_VERSION_CACHE=$(zro_exec zmcontrol -v 2>/dev/null | head -n 1)
  fi
  printf '%s' "$ZRO_CAP_VERSION_CACHE"
}

# An operation is offered only when the allowlist names it AND the binary is
# actually installed here. Menus grey out what this rejects, instead of letting
# the operator select something that will fail once selected.
#
# There is no recursion risk: availability is a filesystem test, and only the
# version lookup goes back through zro_exec.
zro_cap_op_available() {
  local bin=${1-} token=${2-}
  zro_allowed "$bin" "$token" || return 1
  zro_bin_available "$bin" || return 1
  return 0
}
