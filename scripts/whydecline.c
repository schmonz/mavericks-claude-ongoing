/* For given __text offsets: find containing function (LC_FUNCTION_STARTS),
 * report span, decode-cleanliness, has_indirect, and branch targets landing in
 * (site, site+5). Mirrors tramp.c collect_branch_targets via lde_cflow. */
#include "lde.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
static uint64_t uleb(const uint8_t**p,const uint8_t*e){uint64_t r=0;int s=0;uint8_t b;do{if(*p>=e)return r;b=*(*p)++;r|=(uint64_t)(b&0x7f)<<s;s+=7;}while(b&0x80);return r;}
int main(int argc, char **argv){
    FILE *f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t *data=malloc(sz); fread(data,1,sz,f);
    struct mach_header_64 *mh=(void*)data;
    struct load_command *lc=(void*)(mh+1);
    uint64_t text_addr=0,text_size=0; uint32_t fs_off=0,fs_size=0;
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(lc->cmd==LC_SEGMENT_64){ struct segment_command_64 *sg=(void*)lc;
            if(!strcmp(sg->segname,"__TEXT")){ struct section_64 *s=(void*)(sg+1);
                for(uint32_t j=0;j<sg->nsects;j++) if(!strcmp(s[j].sectname,"__text")){text_addr=s[j].addr;text_size=s[j].size;} } }
        else if(lc->cmd==LC_FUNCTION_STARTS){ struct linkedit_data_command *ld=(void*)lc; fs_off=ld->dataoff; fs_size=ld->datasize; }
        lc=(void*)((char*)lc+lc->cmdsize);
    }
    /* collect function starts (vmaddr) */
    const uint8_t *fp=data+fs_off, *fe=fp+fs_size;
    static uint64_t starts[1<<21]; int ns=0;
    uint64_t addr=0x100000000ull; /* textseg vmaddr */
    while(fp<fe){ uint64_t d=uleb(&fp,fe); if(!d)break; addr+=d; if(ns<(1<<21)) starts[ns++]=addr; }
    for(int ai=2; ai<argc; ai++){
        uint64_t site=0x100000000ull+strtoull(argv[ai],0,16);
        int lo=0,hi=ns-1,idx=-1;
        while(lo<=hi){int mid=(lo+hi)>>1; if(starts[mid]<=site){idx=mid;lo=mid+1;}else hi=mid-1;}
        uint64_t fstart=starts[idx], fend=(idx+1<ns)?starts[idx+1]:text_addr+text_size;
        printf("site +0x%llx: fn [+0x%llx,+0x%llx) span=%llu%s\n",
            site-0x100000000ull, fstart-0x100000000ull, fend-0x100000000ull,
            fend-fstart, (fend-fstart>256*1024)?" >256K-CAP-DECLINE":"");
        /* walk fn: decode-clean? indirect? targets in (site,site+5)? */
        uint8_t *text=data; size_t q=fstart-0x100000000ull, fe2=fend-0x100000000ull;
        int ind=0, clean=1; int hits=0;
        while(q<fe2){
            if(fe2-q<=15){int pad=1;for(size_t r=q;r<fe2;r++)if(text[r]&&text[r]!=0xCC&&text[r]!=0x90){pad=0;break;}if(pad)break;}
            int zk,oo;int l=x86_len(text+q,text+fe2,&zk,&oo);
            if(l<=0){clean=0;printf("  decode desync at +0x%zx\n",q);break;}
            int term;long t;int in2;
            lde_cflow(text+q,text+fe2,l,(long)q,&term,&t,&in2);
            if(in2){ind++;}
            if(t>=0){ uint64_t ta=(uint64_t)t+0x100000000ull;
                if(ta>site&&ta<site+5){hits++;printf("  branch at +0x%zx targets site+%llu\n",q,ta-site);} }
            q+=l;
        }
        printf("  clean=%d indirect-jmps=%d targets-in-window=%d\n",clean,ind,hits);
    }
    return 0;
}
