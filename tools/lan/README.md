# tools/lan - scripts for a bare-metal TannX OS box on your LAN

Everything in this directory talks to a **real PC** running TannX OS over
Ethernet (PXE boot, UDP remote control, hardware-in-the-loop tests). None
of it is needed to build or run TannX OS in QEMU, and none of it is part of
`make test-all`.

**Requirements and warnings**

- A kernel built with `REMOTE_CTL=1`. The default build does not listen on
  the UDP control port, so these scripts get no answer from it.
- **Trusted LAN only.** The remote channel has no authentication: anyone on
  the broadcast domain can run commands on the box or reboot it. Use it on
  an isolated lab network you control, never on a shared or public one.
- `python3`, `iproute2` (`ip`), and for PXE `dnsmasq`.

## Configuration (environment variables)

There are no built-in site defaults; `lan-env.sh` (sourced by every script)
resolves these and fails with a clear message when it cannot:

| Variable           | Meaning                                                    | Default                                      |
|--------------------|------------------------------------------------------------|----------------------------------------------|
| `AGENTOS_IFACE`    | host interface facing the test PC                          | interface of the host's default route        |
| `AGENTOS_BCAST`    | directed broadcast of that LAN, e.g. `192.0.2.255`         | derived from `AGENTOS_IFACE` (`ip addr` brd) |
| `AGENTOS_TFTP_DIR` | TFTP root the PXE server serves `pxe.img` from             | none (required by `pxe-server.sh`)           |
| `AGENTOS_MAKE_FLAGS` | make flags for the builds `ship.sh`/`pxe-server.sh` run      | `REMOTE_CTL=1`                               |
| `AGENTOS_PIDFILE`  | pid file of the dnsmasq started by `pxe-server.sh`         | `/tmp/agentos-dnsmasq.pid`                   |
| `AGENTOS_PORT`     | UDP port `wishd.sh` listens on                             | `4711`                                       |
| `AGENTOS_WISH_QUEUE` | wish queue file (`wishd.sh`, `wish-loop.sh`)             | `wish-queue.txt` in the current directory / repo root |

Most scripts also accept the broadcast address as a positional argument.
Wire ports: the OS listens on UDP `:4713` and broadcasts replies to `:4711`.
The host runs `llm-proxy.py --bind 0.0.0.0` (see its header) for the LLM
features; the proxy's UDP discovery responder answers on `:4080`.

## Scripts

| Script                 | What it does                                                                                  | Needs                                   |
|------------------------|-----------------------------------------------------------------------------------------------|-----------------------------------------|
| `pxe-server.sh`        | `start/stop/status/deploy`: dnsmasq in proxy-DHCP + TFTP mode so the PC netboots `pxe.img`. Only ever stops the dnsmasq it started (pid file). | root, `AGENTOS_IFACE`, `AGENTOS_TFTP_DIR` |
| `ship.sh`              | build -> `pxe-server.sh deploy` -> remote reboot -> wait until STATUS reports the new version | PXE server running, `AGENTOS_BCAST`     |
| `test-hw.sh`           | hardware-in-the-loop test of the RTL8168 RX/TX + return channel (`--no-ship` to skip shipping) | `AGENTOS_BCAST`                         |
| `net-status.sh`        | ask for the STATUS telemetry line                                                             | `AGENTOS_BCAST`                         |
| `net-dmesg.sh`         | pull the tail of the kernel log                                                               | `AGENTOS_BCAST`                         |
| `net-result.sh`        | pull finished agent task results                                                              | `AGENTOS_BCAST`                         |
| `net-exec.sh`          | run a shell command line on the box and print its console output                              | `AGENTOS_BCAST` (optional)              |
| `net-reboot.sh`        | broadcast `AGENTOS-REBOOT` (or any text into the box's inbox)                                 | `AGENTOS_BCAST`                         |
| `net-abort.sh`         | broadcast `AGENTOS-ABORT`: stop a wedged chain/autopilot without a reboot                     | `AGENTOS_BCAST`                         |
| `net-mission.sh`       | set the autopilot mission text and confirm it via STATUS                                      | `AGENTOS_BCAST`                         |
| `net-run.sh`           | start the ring-3 user program remotely (`RUNPROG`)                                            | `AGENTOS_BCAST`                         |
| `net-selftest.sh`      | trigger the CPU/RAM self-test and read the results from dmesg                                 | `AGENTOS_BCAST`                         |
| `net-ehcitest.sh`      | trigger EHCI/USB enumeration on a controller/port and print the diagnostics                   | `AGENTOS_BCAST`                         |
| `net-kbdtest.sh`       | arm the USB keyboard diagnostics and print key reports while you type at the box              | `AGENTOS_BCAST`                         |
| `wishd.sh`             | listen for `netwish` broadcasts, ack them, append to the wish queue                           | optional `AGENTOS_BCAST` for the acks   |
| `wish-loop.sh`         | watch the wish queue; on a new wish build (hook or by hand) and `ship.sh`                     | everything above                        |
| `autopilot-monitor.sh` | live terminal dashboard: STATUS telemetry + the autopilot rounds from the proxy log; `a` abort, `r` reboot | `AGENTOS_BCAST`, proxy log |
| `lan-env.sh`           | shared helper (sourced, not run): resolves the variables above and `REPO_ROOT`                | -                                       |

Example session:

```sh
export AGENTOS_IFACE=eth1 AGENTOS_TFTP_DIR=/srv/tftp     # your lab NIC + TFTP root
sudo -E tools/lan/pxe-server.sh start                    # PC: boot menu -> PXE
tools/lan/ship.sh                                        # build (REMOTE_CTL=1), deploy, reboot, confirm
tools/lan/net-status.sh                                  # AgentOS/32 vX.Y STAT up=...
tools/lan/net-exec.sh "spawn prime; task prime 100; sleep 45; tasks" 12
```
