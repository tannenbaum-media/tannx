#!/usr/bin/env bash
# ============================================================
#  TannX OS PXE server - the no-stick deploy loop.
#  Runs dnsmasq in PROXY-DHCP + TFTP mode so the test PC can
#  network-boot the latest kernel - WITHOUT colliding with the
#  LAN's existing DHCP server (proxy mode only answers PXE
#  clients, it never hands out IPs). The router still gives the
#  IP; dnsmasq only adds the "boot this file from here" options.
#
#  Configuration (environment):
#    AGENTOS_IFACE     interface facing the test PC (default: default-route
#                      interface; or pass it as the 2nd argument to start)
#    AGENTOS_TFTP_DIR  TFTP root to serve pxe.img from (required)
#    AGENTOS_PIDFILE   dnsmasq pid file (default /tmp/agentos-dnsmasq.pid)
#
#  Usage (run as root):
#    sudo -E ./pxe-server.sh start [interface]
#    sudo -E ./pxe-server.sh stop
#    sudo -E ./pxe-server.sh status
#    sudo -E ./pxe-server.sh deploy             # rebuild + copy pxe.img
#
#  Then on the test PC: BIOS boot menu -> Network/PXE boot.
#  Rebuild on the host (make pxe + deploy) -> reboot the test PC
#  -> the new version runs. No re-flashing. Trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
IFACE="${2:-${AGENTOS_IFACE:-}}"
TFTP="${AGENTOS_TFTP_DIR:-}"
PIDFILE="${AGENTOS_PIDFILE:-/tmp/agentos-dnsmasq.pid}"
LOG=/tmp/agentos-dnsmasq.log

need_tftp() {
  [ -n "$TFTP" ] || { echo "error: set AGENTOS_TFTP_DIR (TFTP root to serve pxe.img from)" >&2; exit 2; }
}

# only ever touch the dnsmasq we started ourselves (by pid file), never
# another dnsmasq instance on the host.
kill_ours() {
  [ -f "$PIDFILE" ] || return 1
  pkill -F "$PIDFILE" 2>/dev/null
  local rc=$?
  rm -f "$PIDFILE"
  return $rc
}

start() {
  command -v dnsmasq >/dev/null || { echo "dnsmasq missing (sudo apt install dnsmasq)"; exit 2; }
  need_tftp
  [ -n "$IFACE" ] || { echo "error: set AGENTOS_IFACE or pass the interface: $0 start <iface>" >&2; exit 2; }
  mkdir -p "$TFTP"
  [ -f "$REPO_ROOT/pxe.img" ] || make -C "$REPO_ROOT" $AGENTOS_MAKE_FLAGS pxe >/dev/null 2>&1
  cp "$REPO_ROOT/pxe.img" "$TFTP/pxe.img"
  kill_ours && sleep 1
  rm -f "$LOG" "$PIDFILE"   # a stale log blocks dnsmasq's reopen (/tmp protection)
  # proxy-DHCP needs the REAL local subnet to match the PXE discover -
  # '0.0.0.0,proxy' makes dnsmasq 2.90 reject every request with "no
  # address range available". Derive it from the interface (/24 LANs).
  SUBNET=$(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1 \
           | awk -F. 'NF==4 {print $1"."$2"."$3".0"}')
  [ -n "$SUBNET" ] || { echo "no IPv4 on $IFACE?"; exit 2; }
  dnsmasq --conf-file=/dev/null --port=0 \
    --interface="$IFACE" --bind-interfaces \
    --dhcp-range="$SUBNET",proxy \
    --dhcp-boot=pxe.img \
    --pxe-service=x86PC,"TannX OS network boot",pxe.img \
    --enable-tftp --tftp-root="$TFTP" \
    --pid-file="$PIDFILE" --log-facility="$LOG"
  sleep 1
  chmod 644 "$LOG" 2>/dev/null   # dnsmasq runs as nobody (0660) - let the
                                 # unprivileged wish-loop session read/watch it
  if pgrep -F "$PIDFILE" >/dev/null 2>&1; then
    echo "PXE server up on $IFACE, serving $TFTP/pxe.img"
    echo "Now set the test PC to Network/PXE boot."
  else
    echo "start failed - see $LOG"; tail -3 "$LOG" 2>/dev/null
  fi
}

stop()   { kill_ours && echo "stopped" || echo "not running (no live pid in $PIDFILE)"; }
status() {
  if pgrep -F "$PIDFILE" >/dev/null 2>&1; then
    echo "running (pid $(cat "$PIDFILE"))"; [ -n "$TFTP" ] && ls -la "$TFTP/pxe.img" 2>/dev/null
  else echo "not running"; fi
}
deploy() { need_tftp; make -C "$REPO_ROOT" $AGENTOS_MAKE_FLAGS pxe >/dev/null 2>&1 && cp "$REPO_ROOT/pxe.img" "$TFTP/pxe.img" \
           && echo "deployed latest pxe.img - reboot the test PC to pick it up"; }

case "${1:-status}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  deploy) deploy ;;
  *) echo "usage: $0 {start [iface]|stop|status|deploy}" ;;
esac
