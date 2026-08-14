/* Executes a real AVX2 instruction. On this CPU that faults unless avxemu is
 * live, so the exit code answers "is emulation active in THIS process?" */
#include <stdio.h>
#include <stdint.h>
int main(void) {
    uint32_t out[8] = {0};
    uint32_t a[8] = {1,2,3,4,5,6,7,8};
    uint32_t *po = out, *pa = a;
    __asm__ __volatile__(
        "vmovdqu (%1), %%ymm0\n\t"
        "vpaddd  %%ymm0, %%ymm0, %%ymm1\n\t"
        "vmovdqu %%ymm1, (%0)\n\t"
        "vzeroupper\n\t"
        : : "r"(po), "r"(pa) : "ymm0", "ymm1", "memory");
    printf("probe: %u %u %u %u\n", out[0], out[1], out[6], out[7]);
    return (out[0] == 2 && out[7] == 16) ? 0 : 1;
}
