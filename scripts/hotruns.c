/* Walk the hot-function byte region with avxemu's decoder; print each decoded
 * emulated op with offset, and mark run boundaries (consecutive faulting ops). */
#include "lde.h"
#include "decode.h"
#include "vexops.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
extern const char *vex_op_name(vex_op op);
int main(int argc, char **argv){
    FILE *f = fopen(argv[1], "rb");
    static uint8_t buf[1<<20];
    size_t n = fread(buf, 1, sizeof buf, f);
    uint64_t base = strtoull(argv[2], 0, 0);
    size_t p = 0; int in_run = 0, runlen = 0; size_t runstart = 0;
    static char runops[4096]; runops[0] = 0;
    while (p < n) {
        int zk, oo; int l = x86_len(buf+p, buf+n, &zk, &oo);
        if (l <= 0) { p++; if (in_run){ printf("RUN @+0x%llx n=%d: %s\n",(unsigned long long)(base+runstart),runlen,runops);in_run=0;} continue; }
        decoded d; int dl = decode(buf+p, &d);
        int faults = (dl > 0 && d.op != 0);
        if (faults) {
            if (!in_run){ in_run=1; runlen=0; runstart=p; runops[0]=0; }
            runlen++;
            strlcat(runops, vex_op_name(d.op), sizeof runops);
            strlcat(runops, d.is_bmi ? "(b) " : "(V) ", sizeof runops);
        } else if (in_run) {
            printf("RUN @+0x%llx n=%d: %s\n", (unsigned long long)(base+runstart), runlen, runops);
            in_run = 0;
        }
        p += l;
    }
    return 0;
}
