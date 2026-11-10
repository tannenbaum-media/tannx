/* net.c - TannX OS Ring-3 TCP/IP + HTTP client. The kernel only moves raw
 * Ethernet frames (SYS_NET_TX/RX/MAC); DHCP, ARP, IPv4, ICMP, DNS and a
 * minimal TCP live here in userspace. QEMU slirp defaults remain the fallback
 * when no DHCP lease is available.
 *
 * main(): print our MAC, obtain a lease, ARP-resolve the gateway, ping it,
 * then open a TCP connection to the slirp host (10.0.2.2) and do an HTTP GET,
 * printing the response. Each stage prints a marker so a failure is easy to
 * localise. */
#include "libc.h"

/* ---- config: filled by DHCP, with slirp defaults as the fallback --- */
static uint8_t my_ip[4]  = {10, 0, 2, 15};
static uint8_t gw_ip[4]  = {10, 0, 2, 2};
static uint8_t dns_ip[4] = {10, 0, 2, 3};
static uint8_t srv_ip[4] = {10, 0, 2, 2};   /* HTTP server (set per request) */
static uint16_t srv_port = 8080;

static uint8_t my_mac[6];
static uint8_t gw_mac[6];
static uint8_t srv_mac[6];   /* L2 dst for the proxy: gw on slirp, the dev box
                                directly on a real LAN (filled by discovery) */

static uint8_t txb[1600];
static uint8_t rxb[1600];

/* ---- small helpers ----------------------------------------------- */
static void mac_bcast(uint8_t *m) { for (int i = 0; i < 6; i++) m[i] = 0xff; }
static int  mac_eq(const uint8_t *a, const uint8_t *b) {
    for (int i = 0; i < 6; i++) if (a[i] != b[i]) return 0; return 1; }
static int  ip_eq(const uint8_t *a, const uint8_t *b) {
    for (int i = 0; i < 4; i++) if (a[i] != b[i]) return 0; return 1; }

/* ones-complement Internet checksum over len bytes, plus an initial sum
 * (the TCP/UDP pseudo-header). Bytes are summed big-endian. */
static uint16_t cksum(const uint8_t *p, int len, uint32_t s) {
    while (len > 1) { s += (p[0] << 8) | p[1]; p += 2; len -= 2; }
    if (len) s += p[0] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (~s) & 0xffff;
}

/* build a 14-byte Ethernet header into txb; return the payload offset (14) */
static int eth_build(const uint8_t *dst, uint16_t ethertype) {
    memcpy(txb, dst, 6);
    memcpy(txb + 6, my_mac, 6);
    txb[12] = ethertype >> 8; txb[13] = ethertype & 0xff;
    return 14;
}

/* nonblocking: return a frame addressed to us (or broadcast), else 0 */
static int rx_for_us(void) {
    int n = sys_net_rx(rxb, sizeof rxb);
    if (n <= 0) return 0;
    if (rxb[0] == 0xff || mac_eq(rxb, my_mac)) return n;
    return 0;   /* promiscuous NIC: drop frames not for us */
}

/* ---- ARP --------------------------------------------------------- */
static int arp_resolve(const uint8_t *ip, uint8_t *mac_out) {
    uint8_t bc[6]; mac_bcast(bc);
    int o = eth_build(bc, 0x0806);
    uint8_t *a = txb + o;
    a[0]=0;a[1]=1; a[2]=0x08;a[3]=0; a[4]=6;a[5]=4; a[6]=0;a[7]=1; /* req */
    memcpy(a+8,  my_mac, 6); memcpy(a+14, my_ip, 4);
    memset(a+18, 0, 6);      memcpy(a+24, ip, 4);
    sys_net_tx(txb, o + 28);

    uint32_t start = sys_uptime();
    while (sys_uptime() - start < 54) {            /* ~3 s */
        int n = rx_for_us();
        if (n >= 42 && rxb[12] == 0x08 && rxb[13] == 0x06) {
            uint8_t *r = rxb + 14;
            if (r[6] == 0 && r[7] == 2 && ip_eq(r + 14, ip)) {  /* reply */
                memcpy(mac_out, r + 8, 6);
                return 1;
            }
        }
        if (n == 0) sys_yield();
    }
    return 0;
}

/* ---- IPv4 build (proto, payload already at txb+14+20) ------------- */
static int ip_build(const uint8_t *dst_mac, const uint8_t *dst_ip,
                    int proto, int payload_len) {
    int o = eth_build(dst_mac, 0x0800);
    uint8_t *ip = txb + o;
    int tot = 20 + payload_len;
    ip[0]=0x45; ip[1]=0; ip[2]=tot>>8; ip[3]=tot&0xff;
    ip[4]=0;ip[5]=0; ip[6]=0;ip[7]=0; ip[8]=64; ip[9]=proto;
    ip[10]=0;ip[11]=0;
    memcpy(ip+12, my_ip, 4); memcpy(ip+16, dst_ip, 4);
    uint16_t c = cksum(ip, 20, 0); ip[10]=c>>8; ip[11]=c&0xff;
    return o + 20;   /* offset of the L4 payload */
}

/* ---- ICMP echo (ping the gateway) -------------------------------- */
static int ping(const uint8_t *ip) {
    int l4 = ip_build(gw_mac, ip, 1, 12);   /* 8 ICMP hdr + 4 data */
    uint8_t *ic = txb + l4;
    ic[0]=8; ic[1]=0; ic[2]=0; ic[3]=0;     /* echo request */
    ic[4]=0x13;ic[5]=0x37; ic[6]=0;ic[7]=1; /* id, seq */
    ic[8]='p';ic[9]='i';ic[10]='n';ic[11]='g';
    uint16_t c = cksum(ic, 12, 0); ic[2]=c>>8; ic[3]=c&0xff;
    sys_net_tx(txb, l4 + 12);

    uint32_t start = sys_uptime();
    while (sys_uptime() - start < 54) {
        int n = rx_for_us();
        if (n >= 34 && rxb[12]==0x08 && rxb[13]==0x00 && rxb[23]==1) {
            uint8_t *r = rxb + 14; int ihl = (r[0]&0xf)*4;
            if (r[ihl] == 0 && ip_eq(r+12, ip)) return 1;   /* echo reply */
        }
        if (n == 0) sys_yield();
    }
    return 0;
}

/* ---- minimal TCP client ------------------------------------------ */
#define F_FIN 0x01
#define F_SYN 0x02
#define F_RST 0x04
#define F_PSH 0x08
#define F_ACK 0x10

static uint16_t src_port;
static uint32_t snd_nxt, rcv_nxt;

static void send_tcp(int flags, const uint8_t *data, int dlen) {
    int l4 = ip_build(srv_mac, srv_ip, 6, 20 + dlen);
    uint8_t *t = txb + l4;
    t[0]=src_port>>8; t[1]=src_port&0xff;
    t[2]=srv_port>>8; t[3]=srv_port&0xff;
    t[4]=snd_nxt>>24; t[5]=snd_nxt>>16; t[6]=snd_nxt>>8; t[7]=snd_nxt;
    t[8]=rcv_nxt>>24; t[9]=rcv_nxt>>16; t[10]=rcv_nxt>>8; t[11]=rcv_nxt;
    t[12]=(5<<4); t[13]=flags; t[14]=0x20; t[15]=0; /* window 8192 */
    t[16]=0;t[17]=0; t[18]=0;t[19]=0;
    if (dlen) memcpy(t+20, data, dlen);
    uint32_t ps = 0;     /* pseudo-header sum */
    ps += (my_ip[0]<<8)|my_ip[1];   ps += (my_ip[2]<<8)|my_ip[3];
    ps += (srv_ip[0]<<8)|srv_ip[1]; ps += (srv_ip[2]<<8)|srv_ip[3];
    ps += 6; ps += 20 + dlen;
    uint16_t c = cksum(t, 20 + dlen, ps);
    t[16]=c>>8; t[17]=c&0xff;
    sys_net_tx(txb, l4 + 20 + dlen);
}

/* wait for a TCP segment from the server on our port. Returns the data
 * offset within rxb (>0) and fills *flags/*seg_seq/*dlen, or 0 on timeout. */
static int recv_tcp(int *flags, uint32_t *seq, int *dlen, int timeout) {
    uint32_t start = sys_uptime();
    while (sys_uptime() - start < (uint32_t)timeout) {
        int n = rx_for_us();
        if (n >= 54 && rxb[12]==0x08 && rxb[13]==0x00 && rxb[23]==6) {
            uint8_t *ip = rxb + 14; int ihl = (ip[0]&0xf)*4;
            uint8_t *t = ip + ihl;
            uint16_t sp = (t[0]<<8)|t[1], dp = (t[2]<<8)|t[3];
            if (sp == srv_port && dp == src_port && ip_eq(ip+12, srv_ip)) {
                int thl = (t[12]>>4)*4;
                int iptot = (ip[2]<<8)|ip[3];
                /* a malformed header (iptot < ihl+thl, or claiming
                 * more than we received) would make dlen negative or run the
                 * payload past the frame - reject it instead. */
                if (iptot < ihl + thl || 14 + iptot > n) continue;
                *flags = t[13];
                *seq = ((uint32_t)t[4]<<24)|(t[5]<<16)|(t[6]<<8)|t[7];
                *dlen = iptot - ihl - thl;
                return (int)((t + thl) - rxb);
            }
        }
        if (n == 0) { sys_progress(50); sys_yield(); }
        /* progress doubles as the watchdog HEARTBEAT: the ask agent waits
         * minutes on the LLM while claimed-busy; without it the kernel
         * watchdog would shoot it after ~30 s of "running" */
    }
    return 0;
}

/* Optional capture: when cap_buf != 0, http_xfer collects the POST
 * response body there (cap_len written) instead of printing it - so
 * llmscript can persist the answer instead of just showing it. */
static char *cap_buf;
static int   cap_max, cap_len;

/* http_xfer: one HTTP/1.0 request/response over a fresh connection.
 * body == 0 -> GET (response printed verbatim, http_get behaviour);
 * body != 0 -> POST (headers are SKIPPED, only the response body is
 * printed - that's the LLM answer, headers would just be noise).
 * timeout is the per-segment receive patience in ticks (~18/s): an LLM
 * answer takes many seconds of think time before the first byte. */
static const uint8_t *xfer_bin;             /* see below http_xfer */
static int xfer_bin_len;
static uint16_t conn_seq;      /* two connections in the same tick must not reuse
                                * a source port: slirp drops a SYN that matches the
                                * 4-tuple of the connection it just closed */
static int http_xfer(const char *host, const char *path,
                     const char *body, int timeout) {
    src_port = 40000 + ((sys_uptime() + conn_seq++) & 0x1fff);
    snd_nxt  = 0x52000000;
    rcv_nxt  = 0;

    send_tcp(F_SYN, 0, 0);                         /* SYN */
    int fl, dl; uint32_t sq;
    int off = recv_tcp(&fl, &sq, &dl, 54);         /* expect SYN-ACK */
    if (!off || !(fl & F_SYN) || !(fl & F_ACK)) { print("  TCP: no SYN-ACK\r\n"); return 0; }
    snd_nxt += 1;                                  /* SYN consumes a seq */
    rcv_nxt  = sq + 1;
    send_tcp(F_ACK, 0, 0);                         /* complete handshake */

    /* build + send the request (req fits headers + a 512-byte body -
     * slot-sized prompts from the ask agent are the largest case) */
    static char req[704];
    char *p = req; const char *s;
    s = body ? "POST " : "GET ";               while (*s) *p++ = *s++;
    s = path;                                  while (*s) *p++ = *s++;
    s = " HTTP/1.0\r\nHost: ";                 while (*s) *p++ = *s++;
    s = host;                                  while (*s) *p++ = *s++;
    if (body) {
        int blen = 0;
        if (xfer_bin) blen = xfer_bin_len;     /* binary body streamed after the header */
        else { while (body[blen]) blen++; if (blen > 512) blen = 512; }   /* bound to the buffer */
        s = xfer_bin ? "\r\nContent-Type: application/octet-stream\r\nContent-Length: "
                     : "\r\nContent-Type: text/plain\r\nContent-Length: ";
        while (*s) *p++ = *s++;
        /* decimal length, no printf into a buffer in this libc */
        char num[8]; int nl = 0, v = blen;
        do { num[nl++] = (char)('0' + v % 10); v /= 10; } while (v);
        while (nl) *p++ = num[--nl];
        s = "\r\nConnection: close\r\n\r\n";    while (*s) *p++ = *s++;
        if (!xfer_bin) { int k; for (k = 0; k < blen; k++) *p++ = body[k]; }
    } else {
        s = "\r\nConnection: close\r\n\r\n";    while (*s) *p++ = *s++;
    }
    int rlen = (int)(p - req);
    send_tcp(F_PSH | F_ACK, (uint8_t *)req, rlen);
    snd_nxt += rlen;
    if (xfer_bin) {
        /* stream the binary body (a WAV for /stt) in MSS-sized segments.
         * Bursts of 8 (the NIC send is synchronous), then drain the ACKs for
         * a moment: slirp delays lone ACKs ~200 ms, so waiting per segment
         * would turn a 128 KB upload into 20 s. No retransmit logic: slirp
         * sits on the same host, nothing is lost on the way. */
        int sent = 0, burst = 0;
        while (sent < xfer_bin_len) {
            int n = xfer_bin_len - sent; if (n > 1400) n = 1400;
            send_tcp(F_PSH | F_ACK, xfer_bin + sent, n);
            snd_nxt += (uint32_t)n; sent += n;
            if (++burst == 8 && sent < xfer_bin_len) {
                burst = 0; sys_progress(sent / (xfer_bin_len / 100 + 1));
                recv_tcp(&fl, &sq, &dl, 2);              /* an ACK, or 2 ticks */
            }   /* never after the last burst: the drain would swallow a fast
                 * response segment (it did, through a guestfwd) */
        }
    }

    if (!body) print("  --- HTTP response ---\r\n");
    int got = 0, idle = 0, hdr_skip = body ? 1 : 0, seen = 0;
    for (;;) {
        /* once the answer has started, be brief. A forwarder between us and
         * the proxy (slirp guestfwd -> nc, as the gate uses with a private
         * proxy port) may never send a FIN, and the LLM-grade patience
         * (4 x 15 s) is for the think time BEFORE the first byte, not after
         * it: the proxy writes its whole answer at once. Binary uploads get
         * the tighter 9 ticks, text answers ~1 s per idle round. */
        off = recv_tcp(&fl, &sq, &dl, got ? (xfer_bin ? 9 : 18) : timeout);
        if (!off) { if (++idle > 3) break; continue; }
        idle = 0;
        if (sq == rcv_nxt && dl > 0) {
            const char *d = (const char *)(rxb + off);
            int i = 0;
            if (hdr_skip) {                  /* swallow the status+headers */
                for (; i < dl; i++) {
                    seen = (d[i] == "\r\n\r\n"[seen]) ? seen + 1
                         : (d[i] == '\r' ? 1 : 0);
                    if (seen == 4) { i++; hdr_skip = 0; break; }
                }
            }
            if (!hdr_skip && i < dl) {
                if (cap_buf) {
                    int n = dl - i;
                    if (n > cap_max - cap_len) n = cap_max - cap_len;
                    memcpy(cap_buf + cap_len, d + i, n);
                    cap_len += n;
                } else {
                    sys_write(d + i, dl - i);
                }
            }
            rcv_nxt += dl;
            got += dl;
            send_tcp(F_ACK, 0, 0);                       /* ack the data */
        }
        if (fl & F_FIN) {                                /* server closed */
            rcv_nxt += 1;
            send_tcp(F_ACK, 0, 0);
            send_tcp(F_FIN | F_ACK, 0, 0);
            break;
        }
    }
    if (!body) {
        print("\r\n  --- end (");
        printf("%d bytes) ---\r\n", got);
    }
    return got;
}

static int http_get(const char *host, const char *path) {
    return http_xfer(host, path, 0, 36);
}

/* ---- DHCP (DISCOVER/OFFER/REQUEST/ACK) over UDP 68<->67 ----------- */
static uint32_t dh_xid = 0x41474E54;   /* "AGNT" */

static int dhcp_build(uint8_t mtype, const uint8_t *reqip, const uint8_t *srvid) {
    uint8_t bc[6]; mac_bcast(bc);
    int o = eth_build(bc, 0x0800);
    uint8_t *ip = txb + o, *udp = ip + 20, *bp = udp + 8;
    memset(bp, 0, 240);
    bp[0]=1; bp[1]=1; bp[2]=6;
    bp[4]=dh_xid>>24; bp[5]=dh_xid>>16; bp[6]=dh_xid>>8; bp[7]=dh_xid;
    bp[10]=0x80;                              /* broadcast flag */
    memcpy(bp+28, my_mac, 6);                 /* chaddr */
    bp[236]=0x63; bp[237]=0x82; bp[238]=0x53; bp[239]=0x63;   /* magic cookie */
    uint8_t *op = bp + 240;
    *op++=53; *op++=1; *op++=mtype;
    *op++=55; *op++=3; *op++=1; *op++=3; *op++=6;             /* req: mask,router,dns */
    if (reqip) { *op++=50; *op++=4; memcpy(op, reqip, 4); op+=4; }
    if (srvid) { *op++=54; *op++=4; memcpy(op, srvid, 4); op+=4; }
    *op++=255;
    int dhlen = (int)(op - bp), udplen = 8 + dhlen, iptot = 20 + udplen;
    udp[0]=0; udp[1]=68; udp[2]=0; udp[3]=67;
    udp[4]=udplen>>8; udp[5]=udplen&0xff; udp[6]=0; udp[7]=0;
    ip[0]=0x45; ip[1]=0; ip[2]=iptot>>8; ip[3]=iptot&0xff;
    ip[4]=0;ip[5]=0; ip[6]=0;ip[7]=0; ip[8]=64; ip[9]=17; ip[10]=0;ip[11]=0;
    memset(ip+12, 0, 4); memset(ip+16, 0xff, 4);
    uint16_t c = cksum(ip, 20, 0); ip[10]=c>>8; ip[11]=c&0xff;
    return o + iptot;
}

static int dhcp_parse(int n, uint8_t *yi, uint8_t *rt, uint8_t *dn, uint8_t *sid) {
    if (n < 42 + 240) return 0;
    uint8_t *ip = rxb + 14; int ihl = (ip[0]&0xf)*4;
    if (ip[9] != 17) return 0;
    uint8_t *udp = ip + ihl;
    if (!(udp[0]==0 && udp[1]==67 && udp[2]==0 && udp[3]==68)) return 0;
    uint8_t *bp = udp + 8;
    if (bp[0] != 2) return 0;
    memcpy(yi, bp+16, 4);
    uint8_t *o = bp + 240, *end = rxb + n; int mt = 0;
    while (o < end && *o != 255) {
        int t = *o++; if (t == 0) continue;
        if (o >= end) break;               /* the length byte itself is OOB */
        int l = *o++;
        if (l > end - o) break;            /* option value truncated by the frame */
        if      (t==53 && l==1) mt = o[0];
        else if (t==54 && l==4) memcpy(sid, o, 4);
        else if (t==3  && l>=4) memcpy(rt, o, 4);
        else if (t==6  && l>=4) memcpy(dn, o, 4);
        o += l;
    }
    return mt;
}

static int dhcp(void) {
    uint8_t yi[4]={0}, rt[4]={0}, dn[4]={0}, sid[4]={0};
    sys_net_tx(txb, dhcp_build(1, 0, 0));         /* DISCOVER */
    uint32_t s = sys_uptime();
    while (sys_uptime() - s < 90) {               /* wait OFFER ~5s */
        int n = sys_net_rx(rxb, sizeof rxb);
        if (n > 0 && dhcp_parse(n, yi, rt, dn, sid) == 2) goto offered;
        if (n <= 0) sys_yield();
    }
    return 0;
offered:
    sys_net_tx(txb, dhcp_build(3, yi, sid));      /* REQUEST */
    s = sys_uptime();
    while (sys_uptime() - s < 90) {               /* wait ACK */
        int n = sys_net_rx(rxb, sizeof rxb);
        if (n > 0 && dhcp_parse(n, yi, rt, dn, sid) == 5) {
            memcpy(my_ip, yi, 4);
            if (rt[0]) memcpy(gw_ip, rt, 4);
            if (dn[0]) memcpy(dns_ip, dn, 4);
            return 1;
        }
        if (n <= 0) sys_yield();
    }
    return 0;
}

/* ---- DNS (resolve an A record via the leased DNS server, UDP :53) - */
/* skip a DNS name, BOUNDED by end (the packet tail) - the reply is untrusted
 * network input, so a name with no terminator / a bad length must not walk off
 * the receive buffer. Returns the position after the name, or 0 on overrun. */
static uint8_t *dns_skipname(uint8_t *a, uint8_t *end) {
    while (a < end && *a) {
        if ((*a & 0xc0) == 0xc0) { a += 2; return a <= end ? a : 0; }  /* compression ptr */
        a += *a + 1;
    }
    if (a >= end) return 0;                 /* ran off without a 0 label */
    return a + 1;                           /* past the 0 label */
}
static uint16_t dns_id = 0x1234;

static int dns_resolve(const char *host, uint8_t *out) {
    int o = eth_build(gw_mac, 0x0800);
    uint8_t *ip = txb + o, *udp = ip + 20, *dns = udp + 8;
    dns[0]=dns_id>>8; dns[1]=dns_id&0xff; dns[2]=0x01; dns[3]=0x00;  /* RD */
    dns[4]=0;dns[5]=1; dns[6]=0;dns[7]=0; dns[8]=0;dns[9]=0; dns[10]=0;dns[11]=0;
    uint8_t *q = dns + 12; const char *p = host;
    while (*p) {                                  /* QNAME as length-prefixed labels */
        uint8_t *lp = q++; int l = 0;
        while (*p && *p != '.') { *q++ = (uint8_t)*p++; l++; }
        *lp = (uint8_t)l;
        if (*p == '.') p++;
    }
    *q++ = 0; *q++ = 0; *q++ = 1; *q++ = 0; *q++ = 1;   /* root, QTYPE A, QCLASS IN */
    int dnslen = (int)(q - dns), udplen = 8 + dnslen, iptot = 20 + udplen;
    udp[0]=0xc0; udp[1]=0x35; udp[2]=0; udp[3]=53;
    udp[4]=udplen>>8; udp[5]=udplen&0xff; udp[6]=0; udp[7]=0;
    ip[0]=0x45;ip[1]=0;ip[2]=iptot>>8;ip[3]=iptot&0xff;
    ip[4]=0;ip[5]=0;ip[6]=0;ip[7]=0;ip[8]=64;ip[9]=17;ip[10]=0;ip[11]=0;
    memcpy(ip+12,my_ip,4); memcpy(ip+16,dns_ip,4);
    uint16_t c=cksum(ip,20,0); ip[10]=c>>8; ip[11]=c&0xff;
    sys_net_tx(txb, o + iptot);

    uint32_t s = sys_uptime();
    while (sys_uptime() - s < 90) {
        int n = rx_for_us();
        if (n >= 42 && rxb[12]==0x08 && rxb[13]==0x00) {
            uint8_t *rip = rxb+14; int ihl=(rip[0]&0xf)*4; uint8_t *ru = rip + ihl;
            if (rip[9]==17 && ru[0]==0 && ru[1]==53) {        /* UDP from :53 */
                uint8_t *rd = ru + 8;
                uint8_t *end = rxb + n;
                if (rd + 12 <= end && rd[0]==(dns_id>>8) && rd[1]==(dns_id&0xff)) {
                    int anc = (rd[6]<<8)|rd[7];
                    uint8_t *a = dns_skipname(rd + 12, end);    /* skip the question */
                    if (!a || a + 4 > end) return 0;
                    a += 4;                                     /* QTYPE + QCLASS */
                    for (int i = 0; i < anc; i++) {
                        a = dns_skipname(a, end);
                        if (!a || a + 10 > end) return 0;       /* RR fixed header */
                        int type = (a[0]<<8)|a[1], rdl = (a[8]<<8)|a[9];
                        if (rdl > end - (a + 10)) return 0;     /* rdata must fit */
                        if (type == 1 && rdl == 4) { memcpy(out, a+10, 4); return 1; }
                        a += 10 + rdl;
                    }
                    return 0;
                }
            }
        }
        if (n == 0) sys_yield();
    }
    return 0;
}

/* ---- proxy discovery: find llm-proxy.py on the LAN ------------------
 * The OS has no config and the dev box's IP is not the slirp 10.0.2.2 on a
 * real LAN. So broadcast "AGENTOS-PROXY?" to 255.255.255.255:4080; the
 * proxy answers "AGENTOS-PROXY!" and we take ITS source IP + MAC as the
 * server to talk HTTP to. No reply (e.g. QEMU slirp swallows the broadcast
 * return path) -> keep the slirp defaults, so test-llm still works. */
static int discover_proxy(void) {
    uint8_t bc[6]; mac_bcast(bc);
    uint8_t bip[4] = {255, 255, 255, 255};
    int l4 = ip_build(bc, bip, 17, 8 + 14);     /* UDP + "AGENTOS-PROXY?" */
    uint8_t *u = txb + l4;
    u[0]=0x0f; u[1]=0xf0;                        /* src port 4080 */
    u[2]=0x0f; u[3]=0xf0;                        /* dst port 4080 */
    u[4]=0; u[5]=8+14; u[6]=0; u[7]=0;           /* len, cksum 0 */
    memcpy(u+8, "AGENTOS-PROXY?", 14);
    sys_net_tx(txb, l4 + 8 + 14);

    uint32_t start = sys_uptime();
    while (sys_uptime() - start < 27) {          /* ~1.5 s */
        int n = rx_for_us();
        if (n >= 42 && rxb[12]==0x08 && rxb[13]==0x00) {
            uint8_t *ip = rxb + 14; int ihl = (ip[0]&0xf)*4; uint8_t *up = ip + ihl;
            if (ip[9]==17 && up[0]==0x0f && up[1]==0xf0       /* UDP from :4080 */
                && memcmp(up+8, "AGENTOS-PROXY!", 14) == 0) {
                memcpy(srv_ip, ip+12, 4);         /* proxy IP = its src IP */
                memcpy(srv_mac, rxb+6, 6);        /* proxy MAC = frame src MAC */
                return 1;
            }
        }
        if (n == 0) sys_yield();
    }
    return 0;
}

/* ---- quiet bring-up shared by the one-shot clients ----------------- */
static int net_up(void) {
    uint8_t info[7];
    if (sys_net_mac(info) < 0 || !info[6]) { print("llm: no NIC / no link\r\n"); return 0; }
    memcpy(my_mac, info, 6);
    if (!dhcp()) print("llm: no DHCP lease (using slirp defaults)\r\n");
    /* gateway ARP is the slirp fallback path (proxy == gateway there); on a
     * real LAN the proxy is found by discovery, so a missing gw is non-fatal */
    if (arp_resolve(gw_ip, gw_mac)) memcpy(srv_mac, gw_mac, 6);
    if (discover_proxy())
        printf("llm: proxy at %d.%d.%d.%d\r\n", srv_ip[0],srv_ip[1],srv_ip[2],srv_ip[3]);
    return 1;
}

/* ================================================================== *
 *  Server side: a passive TCP open + a tiny HTTP server.
 *  Until now the stack was an outbound client (SYN -> SYN-ACK). This
 *  flips the roles: we LISTEN on a port, answer an inbound SYN with a
 *  SYN-ACK, and serve a request - so a TannX OS box can be QUERIED, not
 *  just query. The send_tcp/recv_tcp helpers are reused as-is: the srv_*
 *  globals just hold the CLIENT now, and src_port is our listen port.
 * ================================================================== */

/* server bring-up: NIC + link + a DHCP lease (so my_ip is right for the
 * replies' checksums); no gateway/proxy lookup - a server needs neither. */
static int net_server_up(void) {
    uint8_t info[7];
    if (sys_net_mac(info) < 0 || !info[6]) { print("httpd: no NIC / no link\r\n"); return 0; }
    memcpy(my_mac, info, 6);
    if (!dhcp()) print("httpd: no DHCP lease (using slirp defaults)\r\n");
    return 1;
}

/* Wait for an inbound SYN to lport (from any client), answer with SYN-ACK,
 * and leave the connection in the srv_ + src_port + seq globals. Returns 1 when
 * established (optimistic: the client's ACK is handled by the read loop), or
 * 0 if the user pressed ESC. */
static int tcp_accept(uint16_t lport) {
    for (;;) {
        if (sys_getkey() == KEY_ESC) return 0;
        int n = rx_for_us();
        /* answer ARP for our IP - a client (or slirp) must resolve us before
         * it can send the SYN; the kernel only moves frames, so we reply here */
        if (n >= 42 && rxb[12] == 0x08 && rxb[13] == 0x06) {
            uint8_t *a = rxb + 14;
            if (a[6] == 0 && a[7] == 1 && ip_eq(a + 24, my_ip)) {   /* request for us */
                int o = eth_build(rxb + 6, 0x0806);
                uint8_t *r = txb + o;
                r[0]=0;r[1]=1; r[2]=0x08;r[3]=0; r[4]=6;r[5]=4; r[6]=0;r[7]=2; /* reply */
                memcpy(r + 8, my_mac, 6); memcpy(r + 14, my_ip, 4);
                memcpy(r + 18, a + 8, 6); memcpy(r + 24, a + 14, 4);
                sys_net_tx(txb, o + 28);
            }
            continue;
        }
        if (n < 54 || rxb[12] != 0x08 || rxb[13] != 0x00 || rxb[23] != 6) {
            if (!n) sys_yield();
            continue;
        }
        uint8_t *ip = rxb + 14; int ihl = (ip[0] & 0xf) * 4;
        uint8_t *t = ip + ihl;
        uint16_t dp = (t[2] << 8) | t[3];
        int flags = t[13];
        if (dp != lport || !(flags & F_SYN) || (flags & F_ACK)) continue;  /* want a fresh SYN */
        memcpy(srv_mac, rxb + 6, 6);                  /* reply to the sender's L2 addr */
        memcpy(srv_ip, ip + 12, 4);
        srv_port = (uint16_t)((t[0] << 8) | t[1]);
        src_port = lport;
        uint32_t cseq = ((uint32_t)t[4] << 24) | (t[5] << 16) | (t[6] << 8) | t[7];
        snd_nxt = 0x52000000;
        rcv_nxt = cseq + 1;
        send_tcp(F_SYN | F_ACK, 0, 0);                /* our SYN-ACK */
        snd_nxt += 1;                                 /* the SYN consumes a seq */
        return 1;
    }
}

static char *put_s(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *put_u(char *p, uint32_t v) {
    char b[10]; int n = 0;
    do { b[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = b[--n];
    return p;
}

/* {"os":"TannX","up":<ticks>,"agents":<n>,"tasks":<n>,"w":<px>,"h":<px>,
 *  "atp":<round>,"mission":"<text>"} from the live SYS_AGENTS snapshot + the
 * firmware framebuffer geometry (sys_fbinfo) + the autopilot telemetry
 * (sys_atp: round count + current mission) - so the appliance reports its
 * display AND its autonomous-loop liveness over HTTP, not just agent counts. */
static int build_status(char *out) {
    unsigned char ag[192];
    int na = 0, nt = 0;
    if (sys_agents(ag) >= 0) {
        for (int s = 0; s < 8; s++) if (ag[s * 8])       na++;
        for (int tk = 0; tk < 8; tk++) if (ag[64 + tk * 16]) nt++;
    }
    fb_t fb;
    uint32_t w = 0, h = 0;
    if (fb_get(&fb) == 0) { w = fb.w; h = fb.h; }
    uint32_t atp[13];                     /* [0]=round, [1..]=48-byte mission */
    uint32_t round = 0;
    char mission[49];
    mission[0] = 0;
    if (sys_atp(atp) == 0) {
        round = atp[0];
        const unsigned char *ms = (const unsigned char *)&atp[1];
        int mi = 0;
        for (int k = 0; k < 48 && ms[k]; k++) {  /* sanitise: keep JSON valid */
            unsigned char c = ms[k];
            mission[mi++] = (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') ? (char)c : ' ';
        }
        mission[mi] = 0;
    }
    char *p = out;
    p = put_s(p, "{\"os\":\"TannX\",\"up\":");  p = put_u(p, sys_uptime());
    p = put_s(p, ",\"agents\":");                 p = put_u(p, (uint32_t)na);
    p = put_s(p, ",\"tasks\":");                  p = put_u(p, (uint32_t)nt);
    p = put_s(p, ",\"w\":");                       p = put_u(p, w);
    p = put_s(p, ",\"h\":");                       p = put_u(p, h);
    p = put_s(p, ",\"atp\":");                     p = put_u(p, round);
    p = put_s(p, ",\"mission\":\"");               p = put_s(p, mission);
    p = put_s(p, "\"}");
    return (int)(p - out);
}

/* optional disk-backed file reader for GET /file/<name>, registered by appmain
 * (kept a function pointer so net.bin, which has no block drivers, still
 * links). name -> buf (<=cap); returns bytes read, or -1 if not found/no disk. */
int (*httpd_file)(const char *name, uint8_t *buf, int cap) = 0;
/* optional disk-backed file WRITER for POST /file/<name> (upload). data,len ->
 * disk; returns 0 on success, negative on error. Also a function pointer. */
int (*httpd_savefile)(const char *name, const uint8_t *data, int len) = 0;

static int mission_body(const char *src, int len, char *dst, int cap) {
    if (len < 0 || cap <= 0) return -1;
    if (len >= cap) return -1;
    int n = 0;
    while (n < len) {
        unsigned char c = (unsigned char)src[n];
        dst[n] = (c >= 0x20 && c < 0x7f) ? (char)c : ' ';
        n++;
    }
    while (n > 0 && dst[n - 1] == ' ') n--;
    dst[n] = 0;
    return n;
}

/* parse the Content-Length header value out of a request (0 if absent) */
static int hdr_clen(const char *buf) {
    for (const char *p = buf; *p; p++) {
        if ((p[0]=='C'||p[0]=='c') && p[1]=='o' && p[2]=='n' && p[3]=='t' && p[4]=='e'
            && p[5]=='n' && p[6]=='t' && p[7]=='-' && (p[8]=='L'||p[8]=='l')) {
            const char *q = p + 9; while (*q && *q != ':') q++;
            if (*q != ':') return 0;
            q++; while (*q == ' ') q++;
            /* saturating parse: a huge Content-Length must not overflow int into
             * a negative value (which would defeat the too_large/blen checks).
             * Clamp well above reqbuf so the oversized-POST path returns 413. */
            int n = 0; while (*q >= '0' && *q <= '9') {
                if (n > 100000000) { n = 100000000; q++; continue; }
                n = n * 10 + (*q++ - '0');
            }
            return n;
        }
    }
    return 0;
}

/* httpd: serve HTTP/1.0 on :80 forever (ESC stops it). GET /status -> the live
 * agent/task JSON; GET /file/<name> -> a file off a disk (if a reader is
 * registered); anything else -> a banner. One connection at a time. */
int httpd_main(void) {
    print("httpd: TannX OS HTTP server (server-OS track)\r\n");
    if (!net_server_up()) return 0;
    print("httpd: listening on :80 - ESC to stop\r\n");

    static char reqbuf[4096], resp[640], body[400];   /* reqbuf holds headers + a POST upload body */
    static uint8_t filebuf[8192];
    for (;;) {
        if (!tcp_accept(80)) break;                   /* ESC */

        reqbuf[0] = 0;                                 /* reqbuf is static: never
                                                        * let a data-less connection
                                                        * replay the PREVIOUS request
                                                        * (audit finding 6) */
        /* -- read the request: headers (CRLFCRLF), then a POST body of
         * Content-Length bytes (for uploads). One buffer holds both. -------- */
        int rl = 0, idle = 0, done = 0, fl, dl; uint32_t sq;
        int hdr_end = -1, clen = 0, too_large = 0;
        while (!done) {
            int off = recv_tcp(&fl, &sq, &dl, 36);
            if (!off) { if (++idle > 2) break; continue; }
            idle = 0;
            if (sq == rcv_nxt && dl > 0) {
                const char *d = (const char *)(rxb + off);
                for (int i = 0; i < dl && rl < (int)sizeof(reqbuf) - 1; i++) reqbuf[rl++] = d[i];
                rcv_nxt += (uint32_t)dl;
                send_tcp(F_ACK, 0, 0);
                reqbuf[rl] = 0;
                if (hdr_end < 0)
                    for (int i = 3; i < rl; i++)
                        if (reqbuf[i-3]=='\r' && reqbuf[i-2]=='\n' && reqbuf[i-1]=='\r' && reqbuf[i]=='\n') {
                            hdr_end = i + 1; clen = hdr_clen(reqbuf);
                            if (reqbuf[0] == 'P' && clen > (int)sizeof(reqbuf) - hdr_end - 1) too_large = 1;
                            break;
                        }
                /* done when the headers are in AND (not a POST, or the whole body arrived) */
                if (hdr_end >= 0 && (too_large || reqbuf[0] != 'P' || rl >= hdr_end + clen)) done = 1;
            }
            if (fl & F_FIN) { rcv_nxt += 1; send_tcp(F_ACK, 0, 0); break; }
        }
        if (rl == 0) continue;                         /* empty connect (portscan/
                                                        * health-check/preconnect):
                                                        * nothing to parse - drop it
                                                        * before it can replay stale
                                                        * reqbuf (audit finding 6) */
        if (hdr_end < 0) hdr_end = rl;                 /* no body separator seen */

        /* -- parse the path: "GET <path> ..." --------------------------- */
        int i = 0; while (reqbuf[i] && reqbuf[i] != ' ') i++;   /* skip the method */
        while (reqbuf[i] == ' ') i++;
        const char *path = reqbuf + i;
        int is_status = (path[0]=='/'&&path[1]=='s'&&path[2]=='t'&&path[3]=='a'&&path[4]=='t');
        int is_mission = (path[0]=='/'&&path[1]=='m'&&path[2]=='i'&&path[3]=='s'&&path[4]=='s'&&path[5]=='i'&&path[6]=='o'&&path[7]=='n'&&(path[8]==' '||path[8]==0||path[8]=='?'));
        int is_file = (path[0]=='/'&&path[1]=='f'&&path[2]=='i'&&path[3]=='l'&&path[4]=='e'&&path[5]=='/');
        char fname[16]; int fnl = 0;
        if (is_file) { int j = 6; while (path[j] && path[j] != ' ' && fnl < 15) fname[fnl++] = path[j++]; }
        fname[fnl] = 0;

        const char *what = "/";
        if (reqbuf[0] == 'P' && too_large) {
            char *p = resp;
            p = put_s(p, "HTTP/1.0 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
            snd_nxt += (uint32_t)(p - resp);
            printf("httpd: refused oversized POST (%d bytes)\r\n", clen);
        } else if (reqbuf[0] == 'P' && is_mission) {
            int blen = rl - hdr_end; if (blen > clen) blen = clen; if (blen < 0) blen = 0;
            char mission[48];
            int mlen = mission_body(reqbuf + hdr_end, blen, mission, (int)sizeof mission);
            int r = (mlen >= 0) ? sys_setmission(mission, mlen) : -1;
            char *p = resp;
            if (r == 0) p = put_s(p, "HTTP/1.0 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            else        p = put_s(p, "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
            snd_nxt += (uint32_t)(p - resp);
            printf("httpd: %s POST /mission (%d bytes)\r\n", r == 0 ? "accepted" : "refused", blen);
        } else if (reqbuf[0] == 'P' && is_file && !fname[0]) {
            char *p = resp;
            p = put_s(p, "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
            snd_nxt += (uint32_t)(p - resp);
            print("httpd: refused POST with empty filename\r\n");
        } else if (reqbuf[0] == 'P' && is_file && httpd_savefile) {
            /* POST /file/<name>: upload - write the body to the disk (FAT write) */
            int blen = rl - hdr_end; if (blen > clen) blen = clen; if (blen < 0) blen = 0;
            char *p = resp;
            if (blen != clen) {                         /* connection died before the
                                                         * whole body arrived - reject
                                                         * rather than silently save a
                                                         * truncated file (audit finding 6) */
                p = put_s(p, "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
                snd_nxt += (uint32_t)(p - resp);
                printf("httpd: refused truncated POST /file/%s (%d of %d bytes)\r\n", fname, blen, clen);
            } else {
            int r = httpd_savefile(fname, (const uint8_t *)(reqbuf + hdr_end), blen);
            if (r == 0)     p = put_s(p, "HTTP/1.0 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            else if (r == -9) p = put_s(p, "HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            else            p = put_s(p, "HTTP/1.0 500 Write Failed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
            snd_nxt += (uint32_t)(p - resp);
            printf("httpd: %s POST /file/%s (%d bytes)\r\n", r == 0 ? "saved" : "FAILED", fname, blen);
            }
        } else if (is_file && httpd_file) {
            /* serve a file off a disk via the registered reader (headers in one
             * segment, then the body in <=1400-byte chunks) */
            int n = httpd_file(fname, filebuf, (int)sizeof filebuf);
            char *p = resp;
            if (n >= 0) {
                p = put_s(p, "HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ");
                p = put_u(p, (uint32_t)n);
                p = put_s(p, "\r\nConnection: close\r\n\r\n");
                send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
                snd_nxt += (uint32_t)(p - resp);
                int sent = 0;
                while (sent < n) {
                    int chunk = n - sent; if (chunk > 1400) chunk = 1400;
                    send_tcp(F_PSH | F_ACK, filebuf + sent, chunk);
                    snd_nxt += (uint32_t)chunk; sent += chunk;
                }
                printf("httpd: served /file/%s (%d bytes)\r\n", fname, n);
            } else {
                p = put_s(p, "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
                snd_nxt += (uint32_t)(p - resp);
                printf("httpd: 404 /file/%s\r\n", fname);
            }
        } else {
            /* /status -> JSON, anything else -> a plain-text banner */
            int blen; const char *ctype;
            if (is_status) { blen = build_status(body); ctype = "application/json"; what = "/status"; }
            else { /* '/' -> a tiny dashboard page that polls /status via JS, so the
                      appliance is viewable in a browser, not just curl-able */
                   blen = (int)(put_s(body,
                       "<!doctype html><title>TannX OS</title>"
                       "<body style=background:#0a0e1a;color:#7fd7ff>"
                       "<h2>TannX OS appliance</h2><pre id=s>loading...</pre>"
                       "<script>setInterval(async()=>{s.textContent="
                       "await(await fetch('/status')).text()},2000)</script>") - body);
                   ctype = "text/html"; }
            char *p = resp;
            p = put_s(p, "HTTP/1.0 200 OK\r\nContent-Type: ");
            p = put_s(p, ctype);
            p = put_s(p, "\r\nContent-Length: "); p = put_u(p, (uint32_t)blen);
            p = put_s(p, "\r\nConnection: close\r\n\r\n");
            for (int k = 0; k < blen; k++) *p++ = body[k];
            send_tcp(F_PSH | F_ACK, (uint8_t *)resp, (int)(p - resp));
            snd_nxt += (uint32_t)(p - resp);
            printf("httpd: served %s\r\n", what);
        }

        /* -- close: FIN, then briefly drain the client's ACK/FIN -------- */
        send_tcp(F_FIN | F_ACK, 0, 0);
        snd_nxt += 1;
        for (int k = 0; k < 5; k++) {
            int off = recv_tcp(&fl, &sq, &dl, 9);
            if (!off) break;
            if (fl & F_FIN) { rcv_nxt += 1; send_tcp(F_ACK, 0, 0); break; }
        }
    }
    return 0;
}

/* ---- llm <prompt>: the wish loop goes live -------------------------
 * TannX OS speaks plain HTTP to llm-proxy.py on the host (slirp host
 * 10.0.2.2:4080); the proxy talks to the configured LLM backend and
 * returns the answer as plain ASCII. arg is the USER_ARG string "llm <prompt>". */
int llm_main(const char *arg) {
    const char *prompt = arg + 3;
    while (*prompt == ' ') prompt++;
    if (!*prompt) { print("usage: llm <question>\r\n"); return 0; }

    if (!net_up()) return 0;
    /* srv_ip keeps its 10.0.2.2 default = the slirp host = the dev box */
    srv_port = 4080;

    print("llm: asking (the model may think for a while) ...\r\n\r\n");
    int got = http_xfer("10.0.2.2", "/llm", prompt, 270);   /* ~15s/segment */
    if (!got) print("llm: no answer - is llm-proxy.py running on the dev box?\r\n");
    print("\r\n");
    return 0;
}

/* ---- the LLM client API for other ring-3 programs (user/chat.c) -------
 * llm_connect brings the stack up once (NIC, DHCP, proxy discovery; prints
 * its usual lines) and remembers the result; llm_ask POSTs one prompt to the
 * proxy's /llm endpoint and captures the answer into out (NUL-terminated,
 * at most cap-1 bytes). Returns the answer length, 0 = no answer, -1 = no
 * network. The prompt is bounded to 512 bytes by http_xfer. */
static int llm_state;                        /* 0 untried, 1 up, -1 down */
int llm_connect(void) {
    if (!llm_state) { llm_state = net_up() ? 1 : -1; srv_port = 4080; }
    return llm_state > 0;
}
int llm_ask(const char *prompt, char *out, int cap) {
    out[0] = 0;
    if (!llm_connect()) return -1;
    cap_buf = out; cap_max = cap - 1; cap_len = 0;
    http_xfer("10.0.2.2", "/llm", prompt, 270);
    cap_buf = 0;
    out[cap_len] = 0;
    return cap_len;
}

/* ---- offload <job>: compute offload over the proxy -------------------
 * Same TCP path as 'llm', different endpoint: the bare-metal box ships a
 * data-parallel compute job (e.g. a Mandelbrot count) to llm-proxy.py's
 * /compute endpoint and prints the result. The proxy runs it on the dev
 * box (a real deploy could fan it to a GPU host - the proxy model: it
 * abstracts the resources the OS can't run itself). arg = "offload <job>". */
int offload_main(const char *arg) {
    const char *job = arg + 7;                  /* skip "offload" */
    while (*job == ' ') job++;
    if (!*job) {
        print("usage: offload <job>  (e.g. offload mandel 32 | offload sum 100)\r\n");
        return 0;
    }
    if (!net_up()) return 0;
    srv_port = 4080;
    print("offload: sending the compute job to the proxy ...\r\n\r\n");
    int got = http_xfer("10.0.2.2", "/compute", job, 90);
    if (!got) print("offload: no answer - is llm-proxy.py running on the dev box?\r\n");
    print("\r\n");
    return 0;
}

/* ---- llmscript <slot> <task>: the LLM writes software into the OS --
 * The proxy's /script endpoint makes the model answer with NOTHING but TannX OS commands
 * (one per line); the answer is persisted into an AgentFS slot via
 * SYS_WRITE_SLOT (diskon-guarded) and 'script <slot>' executes it.
 * arg is the USER_ARG string "llms <slot> <prompt>". */
int llmscript_main(const char *arg) {
    const char *p = arg + 4;
    while (*p == ' ') p++;
    int slot = *p - '0';
    if (slot < 0 || slot > 7) { print("usage: llmscript <slot 0-7> <task>\r\n"); return 0; }
    p++;
    while (*p == ' ') p++;
    if (!*p) { print("usage: llmscript <slot 0-7> <task>\r\n"); return 0; }

    if (!net_up()) return 0;
    srv_port = 4080;

    static char answer[512];
    cap_buf = answer; cap_max = 480; cap_len = 0;
    print("llmscript: asking the LLM to write the script ...\r\n");
    http_xfer("10.0.2.2", "/script", p, 270);
    cap_buf = 0;
    if (!cap_len) { print("llmscript: no answer - is llm-proxy.py running?\r\n"); return 0; }

    static uint8_t sec[512];                /* AgentFS slot: 'A' 'F' | len | text */
    memset(sec, 0, 512);
    sec[0] = 'A'; sec[1] = 'F';
    int n = 0;
    for (int i = 0; i < cap_len && n < 480; i++)
        if (answer[i] != '\r') sec[3 + n++] = (uint8_t)answer[i];
    sec[2] = (uint8_t)n;

    print("--- the LLM wrote: ---\r\n");
    sys_write((const char *)sec + 3, n);
    print("\r\n----------------------\r\n");
    if (sys_write_slot(slot, sec) != 0) {
        print("llmscript: slot write REFUSED - run 'diskon' first.\r\n");
        return 0;
    }
    printf("llmscript: saved to slot %d - run it:  script %d\r\n", slot, slot);
    return 0;
}

/* ---- spawn ask: the LLM AGENT (typ 5) ------------------------------
 * A persistent ring-3 daemon on the REAL agent ABI: sys_claim matches
 * its typ-5 slot against 'task ask <slot>' work; for each task it reads
 * the prompt text from the AgentFS slot, asks the proxy (/llm, any
 * @backend prefix works), writes the answer back INTO the same slot
 * (sys_write_slot - needs diskon) and finishes with the answer length
 * ('>> Agent [n] ask done = <len>'). 'kill <n>' stops it; the watchdog
 * stays armed but recv_tcp heartbeats progress while the LLM thinks. */
int askd_main(void) {
    print("askd: LLM agent online - queue work: task ask <slot>  (needs diskon)\r\n");
    if (!net_up()) return 0;
    srv_port = 4080;
    static char prompt[520];
    static char ans[512];
    static uint8_t sec[512];
    for (;;) {
        int t = sys_claim();
        if (t < 0) { sys_yield(); continue; }
        int slot = (int)(sys_task_info(t) & 0xffff);
        int len = 0, i;
        if (slot < 8 && sys_read_sectors(257 + slot, 1, sec) == 1
            && sec[0] == 'A' && sec[1] == 'F' && sec[2]) {
            int n = sec[2];
            memcpy(prompt, sec + 3, n);
            prompt[n] = 0;
            cap_buf = ans; cap_max = 480; cap_len = 0;
            http_xfer("10.0.2.2", "/llm", prompt, 270);
            cap_buf = 0;
            if (cap_len) {
                memset(sec, 0, 512);
                sec[0] = 'A'; sec[1] = 'F';
                int m = 0;
                for (i = 0; i < cap_len && m < 480; i++)
                    if (ans[i] != '\r') sec[3 + m++] = (uint8_t)ans[i];
                sec[2] = (uint8_t)m;
                if (sys_write_slot(slot, sec) == 0) len = m;
                else print("askd: slot write REFUSED - run 'diskon' first\r\n");
            } else {
                print("askd: no answer - is llm-proxy.py running?\r\n");
            }
        } else {
            print("askd: empty/bad slot - 'save <slot> <question>' first\r\n");
        }
        sys_finish(len);             /* result = answer length (0 = failed) */
    }
}

int net_main(void) {
    print("net: TannX OS userspace TCP/IP\r\n");
    uint8_t info[7];
    if (sys_net_mac(info) < 0 || !info[6]) { print("net: no NIC / no link\r\n"); return 0; }
    memcpy(my_mac, info, 6);
    printf("  MAC %x:%x:%x:%x:%x:%x\r\n",
           my_mac[0],my_mac[1],my_mac[2],my_mac[3],my_mac[4],my_mac[5]);

    print("  DHCP ... ");
    if (dhcp()) printf("IP %d.%d.%d.%d  gw %d.%d.%d.%d  dns %d.%d.%d.%d\r\n",
                       my_ip[0],my_ip[1],my_ip[2],my_ip[3],
                       gw_ip[0],gw_ip[1],gw_ip[2],gw_ip[3],
                       dns_ip[0],dns_ip[1],dns_ip[2],dns_ip[3]);
    else print("no lease (using slirp defaults)\r\n");

    printf("  ARP who-has %d.%d.%d.%d ... ", gw_ip[0],gw_ip[1],gw_ip[2],gw_ip[3]);
    if (!arp_resolve(gw_ip, gw_mac)) { print("no reply\r\n"); return 0; }
    printf("at %x:%x:%x:%x:%x:%x\r\n",
           gw_mac[0],gw_mac[1],gw_mac[2],gw_mac[3],gw_mac[4],gw_mac[5]);

    printf("  ping %d.%d.%d.%d ... ", gw_ip[0],gw_ip[1],gw_ip[2],gw_ip[3]);
    print(ping(gw_ip) ? "reply\r\n" : "no reply\r\n");

    printf("  GET http://%d.%d.%d.%d:%d/ (local)\r\n",
           srv_ip[0],srv_ip[1],srv_ip[2],srv_ip[3], srv_port);
    http_get("10.0.2.2", "/");

    /* DNS + a real fetch off the internet */
    print("  DNS example.com ... ");
    if (dns_resolve("example.com", srv_ip)) {
        printf("%d.%d.%d.%d\r\n", srv_ip[0],srv_ip[1],srv_ip[2],srv_ip[3]);
        srv_port = 80;
        print("  GET http://example.com/\r\n");
        http_get("example.com", "/");
    } else {
        print("no answer\r\n");
    }
    return 0;
}

/* ---- binary POST for the other programs (user/voice.c) -----------------
 * Bring the client side up (DHCP, gateway/proxy discovery) and POST a
 * binary body to the proxy's `path`; the response body lands in cap
 * (capmax bytes, NUL-terminated). Returns the response length, 0 on no
 * answer, -1 when there is no NIC/link. */
int http_post_bin(const char *path, const uint8_t *data, int len, char *cap, int capmax) {
    if (!net_up()) return -1;
    srv_port = 4080;
    cap_buf = cap; cap_max = capmax - 1; cap_len = 0;
    xfer_bin = data; xfer_bin_len = len;
    http_xfer("10.0.2.2", path, "", 270);
    xfer_bin = 0; cap_buf = 0;
    cap[cap_len] = 0;
    return cap_len;
}

/* ================================================================== *
 *  Proxy helpers for the TannX apps (www, cast, shot). They talk
 *  to llm-proxy.py exactly like 'llm' does - plain HTTP over this stack
 *  to the slirp host / the discovered LAN proxy - but want the response
 *  BODY in a buffer, not on the console.
 * ================================================================== */
static int proxy_ready;
static int proxy_up(void) {
    if (proxy_ready) return 1;
    if (!net_up()) return 0;
    srv_port = 4080;
    proxy_ready = 1;
    return 1;
}
/* one POST to <path> with a short text body (<= 512 bytes); the response
 * body lands NUL-terminated in out (cap bytes). Returns its length, 0 = no
 * answer (no NIC, no proxy). timeout = per-segment patience in ticks - keep
 * it short: the transfer ends on the server's FIN or after 3 idle timeouts,
 * and behind a guestfwd (proxy-port.sh, 'nc' in the middle) the FIN can be
 * late, so every request lingers 3 x timeout before the app gets its data. */
int proxy_post(const char *path, const char *body, char *out, int cap, int timeout) {
    out[0] = 0;
    if (!proxy_up()) return 0;
    cap_buf = out; cap_max = cap - 1; cap_len = 0;
    http_xfer("10.0.2.2", path, body, timeout);
    cap_buf = 0;
    out[cap_len] = 0;
    return cap_len;
}

/* a streaming POST for big bodies (the screenshot BMP): headers first, then
 * the data in 1400-byte segments, a window of 4 in flight, go-back-N on a
 * missing ACK. The response body is captured like proxy_post. Returns the
 * response length, 0 = failed. */
#define UP_SEG 1400
#define UP_WIN 4
static uint32_t last_ack;
static int recv_ack(int timeout) {      /* wait for a segment, note its ACK number */
    int fl, dl; uint32_t sq;
    int off = recv_tcp(&fl, &sq, &dl, timeout);
    if (!off) return 0;
    const uint8_t *ip = rxb + 14; const uint8_t *t = ip + (ip[0] & 0xf) * 4;
    if (fl & F_ACK) last_ack = ((uint32_t)t[8] << 24) | (t[9] << 16) | (t[10] << 8) | t[11];
    if (fl & F_RST) return -1;
    return 1;
}
int proxy_upload(const char *path, const uint8_t *data, uint32_t len, char *out, int cap) {
    out[0] = 0;
    if (!proxy_up()) return 0;
    src_port = 40000 + ((sys_uptime() + conn_seq++) & 0x1fff);
    snd_nxt  = 0x53000000; rcv_nxt = 0;
    send_tcp(F_SYN, 0, 0);
    int fl, dl; uint32_t sq;
    int off = recv_tcp(&fl, &sq, &dl, 54);
    if (!off || !(fl & F_SYN) || !(fl & F_ACK)) { print("  TCP: no SYN-ACK\r\n"); return 0; }
    snd_nxt += 1; rcv_nxt = sq + 1;
    send_tcp(F_ACK, 0, 0);

    static char req[256];
    char *p = req; const char *s;
    s = "POST ";                                   while (*s) *p++ = *s++;
    s = path;                                      while (*s) *p++ = *s++;
    s = " HTTP/1.0\r\nHost: 10.0.2.2\r\nContent-Type: application/octet-stream\r\nContent-Length: ";
    while (*s) *p++ = *s++;
    { char num[12]; int nl = 0; uint32_t v = len;
      do { num[nl++] = (char)('0' + v % 10); v /= 10; } while (v);
      while (nl) *p++ = num[--nl]; }
    s = "\r\nConnection: close\r\n\r\n";            while (*s) *p++ = *s++;
    int rlen = (int)(p - req);
    send_tcp(F_PSH | F_ACK, (uint8_t *)req, rlen);
    snd_nxt += rlen;

    uint32_t base = snd_nxt, sent = 0, acked = 0; int stalls = 0;
    last_ack = 0;
    while (acked < len) {
        /* fill the window */
        while (sent < len && sent - acked < UP_SEG * UP_WIN) {
            uint32_t n = len - sent; if (n > UP_SEG) n = UP_SEG;
            snd_nxt = base + sent;
            send_tcp(F_PSH | F_ACK, data + sent, (int)n);
            sent += n;
        }
        snd_nxt = base + sent;
        int r = recv_ack(18);
        if (r < 0) { print("  TCP: reset by the proxy\r\n"); return 0; }
        if (r == 0) {                                   /* nothing: resend the window */
            if (++stalls > 20) { print("  TCP: upload stalled\r\n"); return 0; }
            sent = acked;
            continue;
        }
        stalls = 0;
        if (last_ack > base && last_ack - base <= len) acked = last_ack - base;
        sys_progress((int)(acked / (len / 100 + 1)));
    }
    /* the body is in; collect the response like http_xfer does */
    int got = 0, idle = 0, hdr_skip = 1, seen = 0;
    cap_buf = out; cap_max = cap - 1; cap_len = 0;
    for (;;) {
        off = recv_tcp(&fl, &sq, &dl, 36);
        if (!off) { if (++idle > 3) break; continue; }
        idle = 0;
        if (sq == rcv_nxt && dl > 0) {
            const char *d = (const char *)(rxb + off); int i = 0;
            if (hdr_skip) {
                for (; i < dl; i++) {
                    seen = (d[i] == "\r\n\r\n"[seen]) ? seen + 1 : (d[i] == '\r' ? 1 : 0);
                    if (seen == 4) { i++; hdr_skip = 0; break; }
                }
            }
            if (!hdr_skip && i < dl) {
                int n = dl - i; if (n > cap_max - cap_len) n = cap_max - cap_len;
                memcpy(cap_buf + cap_len, d + i, n); cap_len += n;
            }
            rcv_nxt += dl; got += dl;
            send_tcp(F_ACK, 0, 0);
        }
        if (fl & F_FIN) { rcv_nxt += 1; send_tcp(F_ACK, 0, 0); send_tcp(F_FIN | F_ACK, 0, 0); break; }
    }
    cap_buf = 0;
    out[cap_len] = 0;
    return cap_len;
}
