/*
 * Ask a shipped libavxemu.dylib whether it still carries the two correctness
 * fixes that make Claude Code run on a no-AVX2 Mac. Both are merged upstream
 * (6e5c71b, 052b7b2), but install.sh re-downloads the dylib on every run, so
 * verify rather than assume -- an install.sh run on 2026-08-12 silently
 * replaced a fixed dylib with a stock one and brought the startup spin back.
 *
 *   cc -I<Porting-Resources>/avxemu/src -o /tmp/avxemu_probe scripts/avxemu_probe.c
 *   /tmp/avxemu_probe [path/to/libavxemu.dylib]
 *
 * Exit 0 = both fixes present. The dylib exports decode/avxemu_emulate, so the
 * probe drives real instruction bytes rather than trusting a version string.
 */
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include "regfile.h"

#define DEFAULT_DYLIB "/Users/schmonz/.local/share/claude-mavericks/libavxemu.dylib"

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : DEFAULT_DYLIB;
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 2; }
    int (*dec)(const uint8_t *, decoded *)        = dlsym(h, "decode");
    int (*emu)(const decoded *, avxemu_regfile *) = dlsym(h, "avxemu_emulate");
    if (!dec || !emu) { printf("missing decode/avxemu_emulate exports\n"); return 2; }
    printf("probing %s\n\n", path);
    int bad = 0;

    /* 1. The startup spin: the 66 prefix must make lzcnt 16-bit.
     *    66 f3 0f bd cf = lzcnt cx, di   /   f3 0f bd cf = lzcnt ecx, edi
     *    A buggy decoder drops the 66 and reports opsize=32, so a 16-bit
     *    lzcnt comes back 16 too high and JSC's scan loop never terminates. */
    {
        const uint8_t i16[16] = {0x66,0xf3,0x0f,0xbd,0xcf};
        const uint8_t i32[16] = {0xf3,0x0f,0xbd,0xcf};
        decoded d16, d32;
        memset(&d16, 0, sizeof d16); memset(&d32, 0, sizeof d32);
        int l16 = dec(i16, &d16), l32 = dec(i32, &d32);
        int ok = (l16 == 5 && l32 == 4 && d16.opsize == 16 && d32.opsize == 32);
        printf("lzcnt 66-prefix decode : opsize %d (16-bit form) / %d (32-bit form)  %s\n",
               d16.opsize, d32.opsize, ok ? "OK" : "BROKEN");
        if (!ok) bad = 1;
    }

    /* 2. VPMOVMSKB r32, xmm (VEX.128) must yield a 16-bit mask, upper bits
     *    zero. vec_exec always packs lo | hi<<16; for the 128-bit form the hi
     *    half is the stale upper 128 of the source. Same failure family: a
     *    scan loop reading phantom high bits never terminates. */
    {
        const uint8_t insn[2][16] = { {0xC5,0xF9,0xD7,0xC1}, {0xC5,0xFD,0xD7,0xC1} };
        const unsigned long long want[2] = { 0xfULL, 0xffff000fULL };
        for (int w = 0; w < 2; w++) {
            decoded d; avxemu_regfile rf;
            memset(&d, 0, sizeof d); memset(&rf, 0, sizeof rf);
            if (!dec(insn[w], &d)) { printf("vpmovmskb VEX.%s: decode declined\n", w?"256":"128"); return 2; }
            for (int i = 0;  i < 4;  i++) rf.ymm[1][i] = 0xFF;   /* low 128: 4 set bytes */
            for (int i = 16; i < 32; i++) rf.ymm[1][i] = 0xFF;   /* high 128: all set    */
            if (!emu(&d, &rf)) { printf("vpmovmskb VEX.%s: emulate declined\n", w?"256":"128"); return 2; }
            int ok = rf.gpr[0] == want[w];
            printf("vpmovmskb VEX.%s upper : 0x%016llx (want 0x%llx)  %s\n",
                   w ? "256" : "128", (unsigned long long)rf.gpr[0], want[w], ok ? "OK" : "BROKEN");
            if (!ok) bad = 1;
        }
    }

    puts(bad ? "\nFAIL: this dylib is missing a fix -- do not trust it."
             : "\nPASS: both correctness fixes present.");
    return bad;
}
