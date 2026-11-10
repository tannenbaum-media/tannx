#!/usr/bin/env python3
# l2tap.py - a host-side L2 endpoint for QEMU's '-netdev dgram'. Lets a
# headless test inject raw Ethernet frames into the guest NIC and read the
# frames the guest transmits - so TannX OS's broadcast UDP return channel
# (STATUS/RESULTS/EXEC-OUT on :4711, control on :4713) can be driven and
# observed WITHOUT a real LAN. QEMU delivers whatever we send to its
# `local` port to the guest's RX ring, and forwards the guest's TX to our
# `remote` port. Pure stdlib; we build/parse Ethernet+IPv4+UDP by hand
# (the same wire the bare-metal test PC speaks).
#
# QEMU side:
#   -netdev dgram,id=n0,local.type=inet,local.host=127.0.0.1,local.port=L,\
#                       remote.type=inet,remote.host=127.0.0.1,remote.port=H
#   -device rtl8139,netdev=n0
# Host: bind H (read guest TX), send framed UDP to L (guest RX).
import socket, struct

HOST_MAC = bytes.fromhex("52540012ff99")   # arbitrary host MAC
BCAST    = b"\xff" * 6


def _ip_cksum(hdr: bytes) -> int:
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff


def build_udp_bcast(payload: bytes, dport: int, sport: int = 40000,
                    src_ip: str = "10.0.0.9") -> bytes:
    """A broadcast Ethernet frame carrying a UDP datagram - what the dev
    host sends the test PC (dst 255.255.255.255, the guest's RCR accepts it)."""
    sip = socket.inet_aton(src_ip)
    dip = b"\xff\xff\xff\xff"
    udp_len = 8 + len(payload)
    udp = struct.pack(">HHHH", sport, dport, udp_len, 0) + payload
    total = 20 + udp_len
    ip = bytearray(struct.pack(">BBHHHBBH4s4s",
                   0x45, 0, total, 0, 0, 64, 17, 0, sip, dip))
    c = _ip_cksum(bytes(ip))
    ip[10], ip[11] = c >> 8, c & 0xff
    eth = BCAST + HOST_MAC + b"\x08\x00"
    return eth + bytes(ip) + udp


def parse_udp(frame: bytes):
    """-> (sport, dport, payload) for an IPv4/UDP frame, else None."""
    if len(frame) < 14 + 20 + 8 or frame[12:14] != b"\x08\x00":
        return None
    ihl = (frame[14] & 0x0f) * 4
    if frame[14 + 9] != 17:                       # proto UDP
        return None
    u = 14 + ihl
    sport, dport, ulen = struct.unpack(">HHH", frame[u:u + 6])
    return sport, dport, frame[u + 8: u + ulen]


class L2:
    """Host endpoint: send to QEMU's local port, recv on our (= QEMU's
    remote) port. Bind BEFORE launching QEMU to avoid the startup race."""
    def __init__(self, host_port: int, guest_port: int, addr: str = "127.0.0.1"):
        self.guest = (addr, guest_port)
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind((addr, host_port))
        self.s.settimeout(0.5)

    def inject(self, frame: bytes):
        self.s.sendto(frame, self.guest)

    def send_udp(self, payload: bytes, dport: int):
        self.inject(build_udp_bcast(payload, dport))

    def recv_frame(self):
        try:
            d, _ = self.s.recvfrom(4096)
            return d
        except socket.timeout:
            return None

    def close(self):
        self.s.close()
