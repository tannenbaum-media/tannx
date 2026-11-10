/* chime.c - the HDA system sounds: 'run beep' (what the shell's `beep`
 * launches when an HDA controller is present) and 'run chime' (the boot
 * chime, started by the kernel only in a `make CHIME=1` build so the
 * headless gate stays deterministic). Both are quiet no-ops without HDA:
 * the kernel keeps its PC-speaker beep for that case. */
#include "audio.h"

int chime_main(const char *arg) {
    if (au_init(0) < 0) { if (arg[0] == 'b') print("beep: no HDA codec\r\n"); return 0; }
    if (arg[0] == 'b') {                              /* beep: two quick mint notes */
        au_tone(880, 90, 9000);
        au_tone(1320, 140, 8000);
        print("Beep! (HDA)\r\n");
        return 0;
    }
    /* chime: a rising major triad, soft and short - "the forest wakes up" */
    au_tone(523, 110, 7000);                          /* C5 */
    au_tone(659, 110, 7000);                          /* E5 */
    au_tone(784, 110, 7000);                          /* G5 */
    au_tone(1047, 320, 8000);                         /* C6, held */
    printf("chime: played (HDA), out-lpib %u t %u\r\n", au_out_lpib(), sys_uptime());
    return 0;
}
