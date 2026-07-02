/* Print each indirect jmp (and its preceding 4 instructions' bytes) in a function. */
#include "lde.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
int main(int argc, char **argv){
    FILE *f=fopen(argv[1],"rb"); static uint8_t data[200*1024*1024];
    size_t n=fread(data,1,sizeof data,f);(void)n;
    uint64_t fs=strtoull(argv[2],0,16), fe=strtoull(argv[3],0,16);
    size_t q=fs; size_t hist[8]={0}; int hn=0;
    while(q<fe){
        int zk,oo;int l=x86_len(data+q,data+fe,&zk,&oo);
        if(l<=0){printf("desync +0x%zx\n",q);break;}
        int term;long t;int ind;
        lde_cflow(data+q,data+fe,l,(long)q,&term,&t,&ind);
        if(ind){
            printf("indirect at +0x%zx: bytes", q);
            for(int i=0;i<l;i++)printf(" %02x",data[q+i]);
            printf("\n  context:");
            for(int h=(hn<4?0:hn-4);h<hn;h++){
                size_t p=hist[h&7]; int zk2,oo2; int l2=x86_len(data+p,data+fe,&zk2,&oo2);
                printf(" [+0x%zx:",p); for(int i=0;i<l2;i++)printf(" %02x",data[p+i]); printf("]");
            }
            printf("\n");
        }
        hist[hn&7]=q; hn++;
        q+=l;
    }
    return 0;
}
