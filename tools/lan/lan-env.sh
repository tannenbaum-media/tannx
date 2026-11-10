# lan-env.sh - shared settings for the tools/lan scripts. Source it, do not run it.
#
#   . "$(dirname "$0")/lan-env.sh"
#
# Resolves (environment wins, nothing here is site-specific):
#   REPO_ROOT      the repository root (two levels up from this file)
#   AGENTOS_IFACE  LAN interface facing the TannX OS test PC
#                  (default: the interface of the host's default route)
#   AGENTOS_BCAST  directed broadcast address of that LAN, e.g. 192.0.2.255
#                  (default: derived from AGENTOS_IFACE; empty if that fails)
#   AGENTOS_MAKE_FLAGS  extra make flags for the builds ship.sh/pxe-server.sh
#                  run (default REMOTE_CTL=1 - the remote channel these
#                  scripts rely on is off in a default build)
#
# lan_need_bcast exits with a clear message when AGENTOS_BCAST could not be
# determined - the scripts never fall back to a built-in address.

LAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAN_DIR/../.." && pwd)"

lan_default_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

lan_default_bcast() {
  local ifc="${AGENTOS_IFACE:-}"
  [ -n "$ifc" ] || return 1
  ip -4 -o addr show dev "$ifc" 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "brd") {print $(i+1); exit}}'
}

: "${AGENTOS_MAKE_FLAGS:=REMOTE_CTL=1}"
: "${AGENTOS_IFACE:=$(lan_default_iface)}"
: "${AGENTOS_BCAST:=$(lan_default_bcast)}"

lan_need_bcast() {
  [ -n "${AGENTOS_BCAST:-}" ] && return 0
  echo "error: cannot determine the LAN broadcast address." >&2
  echo "       set AGENTOS_BCAST (directed broadcast of the test PC's LAN, e.g. 192.0.2.255)" >&2
  echo "       or AGENTOS_IFACE (the interface facing the test PC), or pass it as an argument." >&2
  exit 2
}

lan_need_iface() {
  [ -n "${AGENTOS_IFACE:-}" ] && return 0
  echo "error: cannot determine the LAN interface - set AGENTOS_IFACE (e.g. AGENTOS_IFACE=eth0)." >&2
  exit 2
}
