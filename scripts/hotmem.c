/* Print full mem-operand shape of BMI ops with a memory source in a region,
 * and tally shapes across the whole __text for the tier ops. */
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
    fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t *buf=malloc(n); fread(buf,1,n,f);
    long counts[64][2]; memset(counts,0,sizeof counts); /* [op][reg/mem] */
    long shapes_rip=0, shapes_rspbase=0, shapes_plain=0, shapes_noidx=0;
    size_t p = 0x100000; size_t end = n; /* skip mach-o header region roughly; scan text */
    int shown = 0;
    while (p < end) {
        int zk, oo; int l = x86_len(buf+p, buf+end, &zk, &oo);
        if (l <= 0) { p++; continue; }
        decoded d; int dl = decode(buf+p, &d);
        if (dl > 0 && d.op && d.is_bmi) {
            int mem = (d.a_src==OPND_MEM||d.b_src==OPND_MEM);
            counts[d.op & 63][mem]++;
            if (mem){
                if (d.rip_rel) shapes_rip++;
                else if (d.base==4) shapes_rspbase++;
                else if (d.index==OPND_NONE) shapes_noidx++;
                else shapes_plain++;
                if (d.op==BMI_BZHI && shown<8 && p>0x2560000 && p<0x2580000){
                    printf("bzhi-mem @+0x%zx: base=%d index=%d scale=%d disp=%d rip=%d opsize=%d dst=%d idxreg(b_src)=%d\n",
                        p, d.base, d.index, d.scale, d.disp, d.rip_rel, d.opsize, d.dst, d.b_src);
                    shown++;
                }
            }
        }
        p += l;
    }
    printf("\nop            reg-form   mem-form\n");
    for (int i=0;i<64;i++) if (counts[i][0]+counts[i][1])
        printf("%-12s %8ld %8ld\n", vex_op_name((vex_op)i), counts[i][0], counts[i][1]);
    printf("\nmem shapes: rip-rel=%ld rsp-base=%ld base+idx=%ld base-only=%ld\n",
        shapes_rip, shapes_rspbase, shapes_plain, shapes_noidx);
    return 0;
}
