/* fatfs.c - read-only FAT16/FAT32 over any block device (see fatfs.h).
 * (An independent implementation, unrelated to ChaN's FatFs library.)
 *
 * Extracted from the USB driver so every block driver (USB, virtio-blk, NVMe)
 * can read files off a FAT disk by just registering its block reader. Enough
 * to list the root directory, print a file, and load a script into an AgentFS
 * slot. Handles a bare VBR at LBA 0 or an MBR partition. */
#include "fatfs.h"

typedef unsigned long long uint64_t;

static int (*fat_read)(uint32_t lba, uint8_t *buf);
void fat_use(int (*rb)(uint32_t, uint8_t *)) { fat_read = rb; }

static uint32_t f_fat, f_root, f_data, f_rootsecs, f_spc, f_rootclus;
static uint32_t f_nf, f_fatsz, f_maxcl;          /* FATs, FAT size, cluster bound (write) */
static int f_is32;
static uint8_t *f_sec, *f_fatsec;

static int fat_mount(void) {
    if (!fat_read) return 0;
    if (!f_sec)    f_sec    = zpage(4096);
    if (!f_fatsec) f_fatsec = zpage(4096);
    uint8_t *s = f_sec;
    if (fat_read(0, s)) return 0;
    uint32_t base = 0;
    int f16 = (s[54]=='F' && s[55]=='A' && s[56]=='T');
    int f32 = (s[82]=='F' && s[83]=='A' && s[84]=='T');
    if (!f16 && !f32 && s[510]==0x55 && s[511]==0xAA) {
        if (s[450] == 0xEE) {                                   /* protective MBR -> GPT */
            if (!fat_read(1, s) && s[0]=='E'&&s[1]=='F'&&s[2]=='I'&&s[3]==' '
                && s[4]=='P'&&s[5]=='A'&&s[6]=='R'&&s[7]=='T') {
                uint32_t elba = s[72]|(s[73]<<8)|(s[74]<<16)|((uint32_t)s[75]<<24);
                uint32_t nent = s[80]|(s[81]<<8)|(s[82]<<16)|((uint32_t)s[83]<<24);
                uint32_t esz  = s[84]|(s[85]<<8)|(s[86]<<16)|((uint32_t)s[87]<<24);
                if (esz < 128) esz = 128;
                if (nent > 128) nent = 128;
                for (uint32_t i = 0; i < nent && !base; i++) {
                    uint32_t bo = i * esz;
                    if (fat_read(elba + bo / 512, f_fatsec)) break;
                    uint8_t *e = f_fatsec + (bo & 511);
                    int used = 0; for (int k = 0; k < 16; k++) if (e[k]) { used = 1; break; }
                    uint32_t plba = e[32]|(e[33]<<8)|(e[34]<<16)|((uint32_t)e[35]<<24);
                    if (used && plba && !fat_read(plba, s)) {
                        int g16 = (s[54]=='F'&&s[55]=='A'&&s[56]=='T');
                        int g32 = (s[82]=='F'&&s[83]=='A'&&s[84]=='T');
                        if (g16 || g32) { base = plba; f16 = g16; f32 = g32; }
                    }
                }
            }
        } else {                                                /* classic MBR partition 1 */
            base = s[454] | (s[455]<<8) | (s[456]<<16) | ((uint32_t)s[457]<<24);
            if (base && !fat_read(base, s)) {
                f16 = (s[54]=='F'&&s[55]=='A'&&s[56]=='T');
                f32 = (s[82]=='F'&&s[83]=='A'&&s[84]=='T');
            }
        }
    }
    if (!f16 && !f32) return 0;
    int bps = s[11] | (s[12]<<8);
    if (bps != 512) return 0;
    f_spc = s[13];
    uint32_t rsv = s[14] | (s[15]<<8), nf = s[16];
    uint32_t rec = s[17] | (s[18]<<8);
    uint32_t fatsz = s[22] | (s[23]<<8);
    if (!fatsz) fatsz = s[36]|(s[37]<<8)|(s[38]<<16)|((uint32_t)s[39]<<24);
    /* reject a malformed/malicious BPB: f_spc==0 would divide-by-zero in the
     * cluster math (f_maxcl below, fat_save's need), f_nf/fatsz==0 puts the root
     * and data regions on top of the FAT. A power-of-two sectors/cluster is the
     * only legal shape (1..128). */
    if (f_spc == 0 || (f_spc & (f_spc - 1)) || f_spc > 128) return 0;
    if (nf == 0 || fatsz == 0) return 0;
    f_is32 = (f32 && rec == 0);
    f_fat = base + rsv;
    f_root = f_fat + nf * fatsz;
    f_rootsecs = (rec * 32 + 511) / 512;
    f_data = f_root + f_rootsecs;
    f_rootclus = s[44]|(s[45]<<8)|(s[46]<<16)|((uint32_t)s[47]<<24);
    f_nf = nf; f_fatsz = fatsz;                  /* for write: FAT copies + size */
    { uint32_t tot = s[19] | (s[20]<<8);         /* total sectors (16- or 32-bit) */
      if (!tot) tot = s[32]|(s[33]<<8)|(s[34]<<16)|((uint32_t)s[35]<<24);
      f_maxcl = tot > (f_data - base) ? (tot - (f_data - base)) / f_spc + 2 : 2; }
    return 1;
}

static uint32_t fat_next(uint32_t cl) {
    if (f_is32) {
        uint32_t off = cl * 4;
        if (off / 512 >= f_fatsz) return 0x0ffffff8;   /* entry outside the FAT (an
                                                        * inflated f_maxcl vs f_fatsz) ->
                                                        * end-of-chain, don't read root/data */
        if (fat_read(f_fat + off / 512, f_fatsec)) return 0x0ffffff8;
        uint8_t *e = f_fatsec + (off & 511);
        return (e[0]|(e[1]<<8)|(e[2]<<16)|((uint32_t)e[3]<<24)) & 0x0fffffff;
    }
    uint32_t off = cl * 2;
    if (off / 512 >= f_fatsz) return 0xfff8;            /* entry outside the FAT -> end */
    if (fat_read(f_fat + off / 512, f_fatsec)) return 0xfff8;
    uint8_t *e = f_fatsec + (off & 511);
    return e[0] | (e[1] << 8);
}
static int fat_end(uint32_t cl) { return f_is32 ? (cl >= 0x0ffffff8) : (cl >= 0xfff8); }

/* A data cluster is walkable iff it is in range [2, f_maxcl) and not an
 * end-of-chain marker. Out-of-range links (corrupt image) end the walk instead
 * of dereferencing a wild LBA. The step budget in each walk (bounded by f_maxcl)
 * additionally breaks a CYCLIC chain (cl -> ... -> cl) that stays in range - a
 * malicious/corrupt FAT could otherwise spin forever. */
static int fat_clus_ok(uint32_t cl) { return cl >= 2 && cl < f_maxcl && !fat_end(cl); }

static int fat_83_char(char c) {
    if (c >= 'a' && c <= 'z') return c - 32;
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '$' || c == '~') return c;
    return 0;
}

static int fat_make83(const char *name, uint8_t *e83) {
    if (!name || !*name || *name == '.' || *name == ' ' || *name == '/' || *name == '\\') return 0;
    for (int i = 0; i < 11; i++) e83[i] = ' ';
    int bi = 0, ei = 8, ext = 0;
    for (int i = 0; name[i] && name[i] != ' '; i++) {
        char c = name[i];
        if (c == '/' || c == '\\' || c == ':') return 0;
        if (c == '.') { if (ext || bi == 0) return 0; ext = 1; continue; }
        int x = fat_83_char(c); if (!x) return 0;
        if (ext) { if (ei >= 11) return 0; e83[ei++] = (uint8_t)x; }
        else     { if (bi >= 8)  return 0; e83[bi++] = (uint8_t)x; }
    }
    return bi > 0;
}

static int dir_name(uint8_t *e, char *out) {
    if (e[0] == 0 || e[0] == 0xe5 || e[11] == 0x0f || (e[11] & 0x08)) return 0;
    int k = 0;
    for (int i = 0; i < 8 && e[i] != ' '; i++) out[k++] = e[i];
    if (e[8] != ' ') { out[k++] = '.'; for (int i = 8; i < 11 && e[i] != ' '; i++) out[k++] = e[i]; }
    out[k] = 0;
    return 1;
}

typedef void (*dir_cb)(uint8_t *e, const char *nm);
static void dir_walk(dir_cb cb) {
    char nm[13];
    if (f_is32) {
        uint32_t cl = f_rootclus, guard = f_maxcl + 8;
        while (fat_clus_ok(cl) && guard--) {
            for (uint32_t sc = 0; sc < f_spc; sc++) {
                if (fat_read(f_data + (cl-2)*f_spc + sc, f_sec)) return;
                for (int o = 0; o < 512; o += 32) {
                    if (f_sec[o] == 0) return;
                    if (dir_name(f_sec + o, nm)) cb(f_sec + o, nm);
                }
            }
            cl = fat_next(cl);
        }
    } else {
        for (uint32_t sc = 0; sc < f_rootsecs; sc++) {
            if (fat_read(f_root + sc, f_sec)) return;
            for (int o = 0; o < 512; o += 32) {
                if (f_sec[o] == 0) return;
                if (dir_name(f_sec + o, nm)) cb(f_sec + o, nm);
            }
        }
    }
}

static void ls_cb(uint8_t *e, const char *nm) {
    uint32_t sz = e[28]|(e[29]<<8)|(e[30]<<16)|((uint32_t)e[31]<<24);
    if (e[11] & 0x10) printf("  %s/\r\n", nm);
    else              printf("  %s  %d\r\n", nm, sz);
}

static int streq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

static char cat_target[16];
static uint32_t cat_clus, cat_size;

/* does dir entry e match the 8.3 name `want` (already uppercased)? fills the
 * cluster / size / is-directory outputs. */
static int dirent_match(uint8_t *e, const char *want, uint32_t *oc, uint32_t *osz, int *odir) {
    char nm[13]; if (!dir_name(e, nm)) return 0;
    char up[13]; int i = 0;
    for (; nm[i]; i++) up[i] = (nm[i] >= 'a' && nm[i] <= 'z') ? nm[i]-32 : nm[i];
    up[i] = 0;
    if (!streq(up, want)) return 0;
    *oc = (e[26]|(e[27]<<8)) | ((uint32_t)(e[20]|(e[21]<<8)) << 16);
    *osz = e[28]|(e[29]<<8)|(e[30]<<16)|((uint32_t)e[31]<<24);
    *odir = (e[11] & 0x10) ? 1 : 0;
    return 1;
}

/* find `want` in the directory whose first cluster is dirclus (0 = the FAT16
 * fixed root region). 1 = found. */
static int dir_lookup(uint32_t dirclus, const char *want, uint32_t *oc, uint32_t *osz, int *odir) {
    if (dirclus == 0 && !f_is32) {                       /* FAT16 fixed root */
        for (uint32_t sc = 0; sc < f_rootsecs; sc++) {
            if (fat_read(f_root + sc, f_sec)) return 0;
            for (int o = 0; o < 512; o += 32) {
                if (f_sec[o] == 0) return 0;
                if (dirent_match(f_sec + o, want, oc, osz, odir)) return 1;
            }
        }
        return 0;
    }
    uint32_t cl = dirclus ? dirclus : f_rootclus;        /* FAT32 root or a subdir */
    uint32_t guard = f_maxcl + 8;
    while (fat_clus_ok(cl) && guard--) {
        for (uint32_t sc = 0; sc < f_spc; sc++) {
            if (fat_read(f_data + (cl-2)*f_spc + sc, f_sec)) return 0;
            for (int o = 0; o < 512; o += 32) {
                if (f_sec[o] == 0) return 0;
                if (dirent_match(f_sec + o, want, oc, osz, odir)) return 1;
            }
        }
        cl = fat_next(cl);
    }
    return 0;
}

/* resolve a (possibly slash-separated) path to a file -> cat_clus/cat_size.
 * "FILE.TXT" or "DIR/SUB/FILE.TXT". 1 = found, 0 = not found. */
static int fat_find(const char *path) {
    while (*path == '/') path++;
    uint32_t cur = f_is32 ? f_rootclus : 0;              /* 0 = FAT16 root region */
    for (;;) {
        char comp[16]; int k = 0;
        while (path[k] && path[k] != '/' && path[k] != ' ' && k < 15) {
            char c = path[k]; comp[k] = (c >= 'a' && c <= 'z') ? c-32 : c; k++;
        }
        comp[k] = 0;
        if (k == 0) return 0;
        const char *rest = path + k; while (*rest == '/') rest++;
        int more = (*rest && *rest != ' ');
        uint32_t oc, osz; int odir;
        if (!dir_lookup(cur, comp, &oc, &osz, &odir)) return 0;
        if (more) {
            if (!odir) return 0;                         /* a non-dir mid-path */
            cur = oc; path = rest;
        } else {
            for (int i = 0; i <= k; i++) cat_target[i] = comp[i];
            cat_clus = oc; cat_size = osz;
            return odir ? 0 : 1;                          /* the leaf must be a file */
        }
    }
}

static uint32_t fat_readfile(uint8_t *buf, uint32_t cap) {
    uint32_t got = 0, left = cat_size, cl = cat_clus, guard = f_maxcl + 8;
    while (fat_clus_ok(cl) && got < cap && left && guard--) {
        for (uint32_t sc = 0; sc < f_spc && got < cap && left; sc++) {
            if (fat_read(f_data + (cl-2)*f_spc + sc, f_sec)) return got;
            uint32_t n = left < 512 ? left : 512;
            if (n > cap - got) n = cap - got;
            memcpy(buf + got, f_sec, n);
            got += n; left -= n;
        }
        cl = fat_next(cl);
    }
    return got;
}

int fat_present(void) { return fat_mount(); }

int fat_ls(void) {
    if (!fat_mount()) { print("fat: no FAT filesystem on the disk\r\n"); return 0; }
    printf("fat: FAT%d root directory:\r\n", f_is32 ? 32 : 16);
    dir_walk(ls_cb);
    return 0;
}

int fat_cat(const char *fn) {
    if (!fat_mount()) { print("fat: no FAT filesystem\r\n"); return 0; }
    if (!fat_find(fn)) { printf("fat: '%s' not found\r\n", cat_target); return 0; }
    printf("fat: %s (%d bytes):\r\n", cat_target, cat_size);
    uint32_t left = cat_size, cl = cat_clus, cap = 16384, guard = f_maxcl + 8;
    while (fat_clus_ok(cl) && left && cap && guard--) {
        for (uint32_t sc = 0; sc < f_spc && left && cap; sc++) {
            if (fat_read(f_data + (cl-2)*f_spc + sc, f_sec)) return 0;
            uint32_t n = left < 512 ? left : 512; if (n > cap) n = cap;
            sys_write((const char *)f_sec, (int)n);
            left -= n; cap -= n;
        }
        cl = fat_next(cl);
    }
    print("\r\n");
    return 0;
}

/* read a file into buf (up to cap bytes); returns bytes read, or -1 if there
 * is no FAT filesystem or the file is not found. For the HTTP file server. */
int fat_file(const char *fn, uint8_t *buf, int cap) {
    if (!fat_mount()) return -1;
    if (!fat_find(fn)) return -1;
    return (int)fat_readfile(buf, (uint32_t)cap);
}

int fat_load(const char *fn, int slot) {
    if (slot < 0 || slot > 7) { print("fat: slot must be 0-7\r\n"); return 0; }
    if (!fat_mount()) { print("fat: no FAT filesystem\r\n"); return 0; }
    if (!fat_find(fn)) { printf("fat: '%s' not found\r\n", cat_target); return 0; }
    uint8_t *fbuf = zpage(4096);
    uint32_t got = fat_readfile(fbuf, 480);          /* a slot holds up to 480 bytes */
    static uint8_t sec[512];
    memset(sec, 0, 512);
    sec[0] = 'A'; sec[1] = 'F';
    int n = 0;
    for (uint32_t i = 0; i < got && n < 480; i++) if (fbuf[i] != '\r') sec[3 + n++] = fbuf[i];
    sec[2] = (uint8_t)n;
    if (sys_write_slot(slot, sec) != 0) { print("fat: slot write refused (diskon?)\r\n"); return 0; }
    printf("fat: loaded %s (%d bytes) into slot %d - run: script %d\r\n", cat_target, n, slot, slot);
    return 0;
}

/* ---- write support: create/overwrite a single-cluster file (FAT16 root) ----
 * The OS can SAVE a file to a FAT disk a PC reads, not just read one. Writes a
 * full cluster CHAIN of any size on FAT16 AND FAT32 (the root is a fixed region
 * on FAT16, a cluster chain on FAT32; fat_dirslot handles both). A driver opts
 * in by registering a block writer with fat_use_write(). */
static int (*fat_write)(uint32_t lba, uint8_t *buf);
static int (*fat_write_n)(uint32_t lba, const uint8_t *buf, uint32_t n);
void fat_use_write(int (*wb)(uint32_t, uint8_t *)) { fat_write = wb; fat_write_n = 0; }

/* set the FAT entry for cluster cl in EVERY FAT copy (FAT16 = 2 bytes, FAT32 = 4
 * bytes with the top nibble preserved). Keeps the copies consistent. */
static int fat_setentry(uint32_t cl, uint32_t val) {
    uint32_t esz = f_is32 ? 4 : 2;
    uint32_t off = cl * esz, sec = off / 512, idx = off & 511;
    if (cl >= f_maxcl || sec >= f_fatsz) return -1;   /* stay inside THIS FAT copy;
                                                       * an inconsistent BPB must not
                                                       * write into the next copy/data */
    for (uint32_t f = 0; f < f_nf; f++) {
        uint32_t lba = f_fat + f * f_fatsz + sec;
        if (fat_read(lba, f_fatsec)) return -1;
        if (f_is32) {
            uint32_t old = f_fatsec[idx] | (f_fatsec[idx+1]<<8) | (f_fatsec[idx+2]<<16) | ((uint32_t)f_fatsec[idx+3]<<24);
            uint32_t nv = (old & 0xf0000000u) | (val & 0x0fffffffu);
            f_fatsec[idx]=(uint8_t)nv; f_fatsec[idx+1]=(uint8_t)(nv>>8);
            f_fatsec[idx+2]=(uint8_t)(nv>>16); f_fatsec[idx+3]=(uint8_t)(nv>>24);
        } else {
            f_fatsec[idx] = (uint8_t)val; f_fatsec[idx + 1] = (uint8_t)(val >> 8);
        }
        if (fat_write(lba, f_fatsec)) return -1;
    }
    return 0;
}

static int fat_freechain(uint32_t cl) {
    uint32_t guard = f_maxcl + 8;
    while (fat_clus_ok(cl) && guard--) {
        uint32_t nx = fat_next(cl);
        if (fat_setentry(cl, 0)) return -1;
        cl = nx;
    }
    return 0;
}

/* find where to write the dir entry for the 8.3 name e83 in the root directory:
 * a same-name file (overwrite -> *oldcl = its first cluster) or the first free
 * slot. Handles the FAT16 fixed root region AND the FAT32 root cluster chain.
 * Returns 1 + the absolute LBA/offset, or 0 if the root is full. */
static int fat_dirslot(const uint8_t *e83, uint32_t *olba, uint32_t *ooff, uint32_t *oldcl) {
    uint32_t flba = 0, foff = 0; int havefree = 0;
    *oldcl = 0;
    uint32_t cl = f_is32 ? f_rootclus : 0, sc = 0, guard = f_maxcl + 8;
    for (;;) {
        uint32_t lba;
        if (f_is32) { if (!fat_clus_ok(cl) || !guard--) break; lba = f_data + (cl - 2) * f_spc + sc; }
        else        { if (sc >= f_rootsecs) break;       lba = f_root + sc; }
        if (fat_read(lba, f_sec)) return 0;
        for (int o = 0; o < 512; o += 32) {
            uint8_t *e = f_sec + o;
            if (e[0] == 0) {                     /* end of directory */
                if (havefree) { *olba = flba; *ooff = foff; } else { *olba = lba; *ooff = (uint32_t)o; }
                return 1;
            }
            if (e[0] == 0xe5) { if (!havefree) { flba = lba; foff = o; havefree = 1; } continue; }
            if (e[11] & 0x0f) continue;          /* skip LFN/volume-label entries */
            int same = 1; for (int k = 0; k < 11; k++) if (e[k] != e83[k]) { same = 0; break; }
            if (same) {
                if (e[11] & 0x10) return -1;     /* name collides with a DIRECTORY -
                                                  * refuse rather than create a
                                                  * duplicate 8.3 entry */
                *olba = lba; *ooff = o;
                *oldcl = (e[26] | (e[27] << 8)) | ((uint32_t)(e[20] | (e[21] << 8)) << 16);
                return 1;
            }
        }
        sc++;
        if (f_is32 && sc >= f_spc) { sc = 0; cl = fat_next(cl); }
    }
    if (havefree) { *olba = flba; *ooff = foff; return 1; }
    return 0;
}

/* optional bulk writer (n consecutive sectors in one request): virtio-blk
 * registers one, which makes a multi-MB save (a screenshot) ~4x fewer requests
 * - under QEMU TCG every request costs ~3 ms, so requests, not bytes, are the
 * cost. Cleared by fat_use_write() so a later driver cannot inherit it. */
void fat_use_write_n(int (*wbn)(uint32_t, const uint8_t *, uint32_t)) { fat_write_n = wbn; }
static uint8_t *f_clbuf;                         /* one-cluster bounce buffer (<= 32 KB) */

/* set one FAT entry inside the sector image `sec` (FAT16 = 2 bytes, FAT32 = 4
 * with the top nibble preserved) */
static void fat_put(uint8_t *sec, uint32_t idx, uint32_t val) {
    if (f_is32) {
        uint32_t old = sec[idx] | (sec[idx+1]<<8) | (sec[idx+2]<<16) | ((uint32_t)sec[idx+3]<<24);
        uint32_t nv = (old & 0xf0000000u) | (val & 0x0fffffffu);
        sec[idx]=(uint8_t)nv; sec[idx+1]=(uint8_t)(nv>>8); sec[idx+2]=(uint8_t)(nv>>16); sec[idx+3]=(uint8_t)(nv>>24);
    } else { sec[idx] = (uint8_t)val; sec[idx + 1] = (uint8_t)(val >> 8); }
}

/* create/overwrite a file: the chain is ALLOCATED FIRST (one sequential scan
 * of the FAT, each sector read once - so a disk-full is known before a byte
 * is written and nothing has to be rolled back), the data goes out one
 * cluster per request where the driver allows, and the FAT entries are
 * written grouped by FAT sector for each FAT copy. 0 ok, negative = error
 * (-5 root full, -6 disk full, -9 bad name / collides with a directory). */
int fat_save(const char *name, const uint8_t *data, uint32_t len) {
    if (!fat_mount())        return -1;
    if (!fat_write)          return -2;          /* driver registered no writer */
    uint32_t spc_bytes = f_spc * 512u;
    uint32_t need = len ? (len + spc_bytes - 1) / spc_bytes : 1;   /* clusters (>=1) */
    uint32_t eof = f_is32 ? 0x0fffffffu : 0xffffu;   /* end-of-chain marker */
    uint32_t esz = f_is32 ? 4 : 2, eps = 512 / esz;   /* FAT entries per sector */

    uint8_t e83[11];                             /* 8.3 name, space-padded, upper */
    if (!fat_make83(name, e83)) return -9;
    uint32_t dlba, doff, oldcl;
    int ds = fat_dirslot(e83, &dlba, &doff, &oldcl);
    if (ds < 0) return -9;                        /* name collides with a directory */
    if (ds == 0) return -5;                       /* root directory full */

    /* 1. allocate: the first `need` free clusters, in ascending order */
    static uint32_t small[64];
    uint32_t *chain = need <= 64 ? small : (uint32_t *)malloc(need * 4);
    if (!chain) return -7;
    uint32_t found = 0;
    for (uint32_t sec = 0; sec * eps < f_maxcl && sec < f_fatsz && found < need; sec++) {
        if (fat_read(f_fat + sec, f_fatsec)) return -1;
        for (uint32_t k = 0; k < eps && found < need; k++) {
            uint32_t cl = sec * eps + k;
            if (cl < 2 || cl >= f_maxcl) continue;
            uint32_t i = k * esz;
            uint32_t v = f_is32 ? ((f_fatsec[i]|(f_fatsec[i+1]<<8)|(f_fatsec[i+2]<<16)|((uint32_t)f_fatsec[i+3]<<24)) & 0x0fffffff)
                                : (uint32_t)(f_fatsec[i] | (f_fatsec[i+1] << 8));
            if (v == 0) chain[found++] = cl;
        }
    }
    if (found < need) return -6;                  /* disk full - nothing written yet */

    /* 2. data: one request per cluster through the bulk writer, else per sector */
    int bulk = fat_write_n && spc_bytes <= 32768;
    if (bulk && !f_clbuf) f_clbuf = zpage(32768);
    if (bulk && !f_clbuf) bulk = 0;
    uint32_t off = 0;
    for (uint32_t c = 0; c < need; c++) {
        uint32_t lba = f_data + (chain[c] - 2) * f_spc;
        if (bulk) {
            uint32_t n = len > off ? len - off : 0; if (n > spc_bytes) n = spc_bytes;
            if (n) memcpy(f_clbuf, data + off, n);
            if (n < spc_bytes) memset(f_clbuf + n, 0, spc_bytes - n);
            if (fat_write_n(lba, f_clbuf, f_spc)) return -1;
            off += spc_bytes;
        } else {
            for (uint32_t sc = 0; sc < f_spc; sc++) {
                memset(f_sec, 0, 512);
                if (off < len) { uint32_t n = len - off; if (n > 512) n = 512; memcpy(f_sec, data + off, n); }
                if (fat_write(lba + sc, f_sec)) return -1;
                off += 512;
            }
        }
        if ((c & 15) == 0) sys_progress((int)(c * 100 / need));
    }

    /* 3. the chain, grouped by FAT sector, in every FAT copy */
    for (uint32_t f = 0; f < f_nf; f++) {
        uint32_t cur = 0xffffffffu; int dirty = 0;
        for (uint32_t c = 0; c < need; c++) {
            uint32_t cl = chain[c], o = cl * esz, sec = o / 512;
            if (sec >= f_fatsz) return -1;
            if (sec != cur) {
                if (dirty && fat_write(f_fat + f * f_fatsz + cur, f_fatsec)) return -1;
                if (fat_read(f_fat + f * f_fatsz + sec, f_fatsec)) return -1;
                cur = sec; dirty = 0;
            }
            fat_put(f_fatsec, o & 511, c + 1 < need ? chain[c + 1] : eof);
            dirty = 1;
        }
        if (dirty && fat_write(f_fat + f * f_fatsz + cur, f_fatsec)) return -1;
    }

    /* 4. the directory entry at its absolute LBA */
    uint32_t first = chain[0];
    if (fat_read(dlba, f_sec)) return -1;
    uint8_t *e = f_sec + doff;
    memset(e, 0, 32);
    for (int k = 0; k < 11; k++) e[k] = e83[k];
    e[11] = 0x20;                                 /* archive */
    e[26] = (uint8_t)first;         e[27] = (uint8_t)(first >> 8);   /* first cluster low */
    e[20] = (uint8_t)(first >> 16); e[21] = (uint8_t)(first >> 24);  /* high (FAT32; 0 on FAT16) */
    e[28] = (uint8_t)len; e[29] = (uint8_t)(len >> 8);
    e[30] = (uint8_t)(len >> 16); e[31] = (uint8_t)(len >> 24);
    if (fat_write(dlba, f_sec)) return -1;
    if (oldcl && fat_freechain(oldcl)) return -1;  /* an overwritten file's old chain */
    return 0;
}

/* copy a file on the same FAT disk: read src into a buffer, write it as dst.
 * Naturally exercises the multi-cluster path for a multi-KB source. Up to 16 KB
 * (one read buffer). 0 = ok, negative = error. */
int fat_copy(const char *src, const char *dst) {
    if (!fat_mount()) return -1;
    uint8_t *buf = zpage(16384);
    if (!buf) return -7;
    int got = fat_file(src, buf, 16384);          /* mount + find + read src */
    if (got < 0) return -8;
    return fat_save(dst, buf, (uint32_t)got);
}

/* ---- for the file manager ('run files') and 'run shot' ------------------- */
static fat_list_cb list_cb;
static void list_fwd(uint8_t *e, const char *nm) {
    uint32_t sz = e[28]|(e[29]<<8)|(e[30]<<16)|((uint32_t)e[31]<<24);
    list_cb(nm, sz, (e[11] & 0x10) ? 1 : 0);
}
/* enumerate the root directory: cb(name, size, isdir). 0 = no FAT. */
int fat_list(fat_list_cb cb) {
    if (!fat_mount()) return 0;
    list_cb = cb;
    dir_walk(list_fwd);
    return 1;
}
int fat_bits(void) { return f_is32 ? 32 : 16; }

/* free / total data space in KB, counting zero FAT entries (each FAT sector
 * read once). 0 = no FAT. */
int fat_space(uint32_t *free_kb, uint32_t *total_kb) {
    if (!fat_mount()) return 0;
    uint32_t esz = f_is32 ? 4 : 2, eps = 512 / esz, freec = 0;
    for (uint32_t sec = 0; sec * eps < f_maxcl && sec < f_fatsz; sec++) {
        if (fat_read(f_fat + sec, f_fatsec)) break;
        for (uint32_t k = 0; k < eps; k++) {
            uint32_t cl = sec * eps + k;
            if (cl < 2 || cl >= f_maxcl) continue;
            uint32_t i = k * esz;
            uint32_t v = f_is32 ? ((f_fatsec[i]|(f_fatsec[i+1]<<8)|(f_fatsec[i+2]<<16)|((uint32_t)f_fatsec[i+3]<<24)) & 0x0fffffff)
                                : (uint32_t)(f_fatsec[i] | (f_fatsec[i+1] << 8));
            if (v == 0) freec++;
        }
    }
    *free_kb  = freec * f_spc / 2;
    *total_kb = (f_maxcl - 2) * f_spc / 2;
    return 1;
}

/* delete a root-directory FILE: mark the entry 0xE5 and free its chain.
 * 0 ok, -1 no FAT / I/O, -2 read-only driver, -3 not found or a directory. */
int fat_delete(const char *name) {
    if (!fat_mount()) return -1;
    if (!fat_write)   return -2;
    uint8_t e83[11];
    if (!fat_make83(name, e83)) return -3;
    uint32_t dlba, doff, oldcl;
    int ds = fat_dirslot(e83, &dlba, &doff, &oldcl);
    if (ds <= 0 || !oldcl) {
        /* fat_dirslot returns a free slot for a missing name (oldcl == 0);
         * an empty file also has cluster 0 - re-check the entry itself */
        if (ds <= 0) return -3;
        if (fat_read(dlba, f_sec)) return -1;
        int same = 1; for (int k = 0; k < 11; k++) if (f_sec[doff + k] != e83[k]) { same = 0; break; }
        if (!same) return -3;
    }
    if (fat_read(dlba, f_sec)) return -1;
    f_sec[doff] = 0xe5;
    if (fat_write(dlba, f_sec)) return -1;
    if (oldcl && fat_freechain(oldcl)) return -1;
    return 0;
}
