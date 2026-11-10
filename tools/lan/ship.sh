#!/usr/bin/env bash
# ============================================================
#  TannX OS ship - the one-command deploy loop for the bare-metal
#  test PC. Build the current source, push it to the PXE server,
#  remote-reboot the test PC, and CONFIRM the new build is live via
#  the STATUS return channel. This is the hand loop (make pxe ->
#  pxe-server deploy -> net-reboot -> net-status) as one step.
#
#    ./ship.sh                        # build, deploy, reboot, confirm
#    AGENTOS_BCAST=192.0.2.255 ./ship.sh
#
#  Needs a kernel built with REMOTE_CTL=1 and a trusted LAN
#  (see tools/lan/README.md).
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
lan_need_bcast
BCAST="$AGENTOS_BCAST"

echo "[ship] building pxe.img ..."
make -C "$REPO_ROOT" $AGENTOS_MAKE_FLAGS pxe >/dev/null 2>&1 || { echo "[ship] build FAILED"; exit 1; }
VER="$(grep '^nh_rep_pfx:' "$REPO_ROOT/agentos32.S" | grep -oE 'v[0-9]+\.[0-9]+')"  # what STATUS reports
echo "[ship] built $VER; deploying to PXE ..."
"$HERE/pxe-server.sh" deploy >/dev/null 2>&1 || {
  echo "[ship] deploy FAILED - is the server up?  sudo $HERE/pxe-server.sh start"; exit 1; }

echo "[ship] remote-rebooting the test PC ..."
"$HERE/net-reboot.sh" AGENTOS-REBOOT "$BCAST" >/dev/null 2>&1

echo "[ship] waiting for $VER to PXE-boot and report back ..."
for i in $(seq 1 20); do
  out="$(timeout 6 "$HERE/net-status.sh" "$BCAST" 2>/dev/null | grep '<-')"
  if echo "$out" | grep -q "$VER"; then
    echo "[ship] LIVE: ${out#*<- }"
    exit 0
  fi
  sleep 1
done
echo "[ship] no confirmation - the test PC never reported $VER (power/PXE/LAN?)"
exit 1
