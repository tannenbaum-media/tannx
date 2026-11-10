/* fatfs.h - a tiny FAT16/FAT32 layer (read + write), shared by every block
 * driver. The caller registers a block reader (one 512-byte LBA -> buf, 0 on
 * success) with fat_use() - and optionally a writer with fat_use_write() - then
 * lists / reads / loads / saves / copies files. Handles a bare VBR at LBA 0, an
 * MBR partition, or a GPT. exFAT/FAT12 are out of scope. Independent code,
 * unrelated to ChaN's FatFs library despite the similar name. */
#ifndef AGENTOS_FATFS_H
#define AGENTOS_FATFS_H
#include "libc.h"

void fat_use(int (*read_block)(uint32_t lba, uint8_t *buf));
void fat_use_write(int (*write_block)(uint32_t lba, uint8_t *buf)); /* opt-in write */
void fat_use_write_n(int (*wbn)(uint32_t lba, const uint8_t *buf, uint32_t n)); /* opt-in bulk write */
int  fat_save(const char *name, const uint8_t *data, uint32_t len);
                                        /* create/overwrite a FAT16/32 file (cluster chain) */
int  fat_copy(const char *src, const char *dst); /* copy a file on the disk (<=16 KB) */
int  fat_present(void);                 /* mount + 1 if a FAT filesystem is there */
int  fat_ls(void);                      /* list the root directory               */
int  fat_cat(const char *name);         /* print a file's contents               */
int  fat_load(const char *name, int slot); /* load a file into AgentFS slot 0-7  */
int  fat_file(const char *name, uint8_t *buf, int cap); /* read a file -> bytes/-1 */
typedef void (*fat_list_cb)(const char *name, uint32_t size, int isdir);
int  fat_list(fat_list_cb cb);          /* root directory with sizes; 0 = no FAT    */
int  fat_space(uint32_t *free_kb, uint32_t *total_kb); /* free/total data space      */
int  fat_delete(const char *name);      /* delete a root file; 0 / -1 / -2 / -3      */
int  fat_bits(void);                    /* 16 or 32 (after a mount)                  */

#endif /* AGENTOS_FATFS_H */
