#include "lde.h"
#include "decode.h"
#include "vexops.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
extern const char *vex_op_name(vex_op op);
int main(int argc, char **argv){
    FILE *f = fopen(argv[1], "rb");
    static uint8_t buf[1<<20];
    size_t n = fread(buf, 1, sizeof buf, f);
    uint64_t base = strtoull(argv[2], 0, 0);
    size_t p = 0;
    while (p < n) {
        int zk, oo; int l = x86_len(buf+p, buf+n, &zk, &oo);
        if (l <= 0) { p++; continue; }
        decoded d; int dl = decode(buf+p, &d);
        if (dl > 0 && d.op && d.is_bmi)
            printf("+0x%llx %-8s opsize=%d dst=%d a_src=%d b_src=%d dst2=%d mem=%s seg=%d len=%d\n",
                (unsigned long long)(base+p), vex_op_name(d.op), d.opsize, d.dst, d.a_src, d.b_src,
                d.bmi_dst2, (d.a_src==OPND_MEM||d.b_src==OPND_MEM||d.dst_kind==DST_MEM)?"YES":"no", d.seg, dl);
        p += l;
    }
    return 0;
}
