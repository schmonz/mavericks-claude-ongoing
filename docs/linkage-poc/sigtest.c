/* Does avxemu's sigaction interposition survive when it is LINKED rather than
 * INSERTED? Like Bun, this installs its own SIGILL handler and then executes
 * AVX2. If avxemu's interposed sigaction() ran, avxemu keeps SIGILL and the
 * AVX2 op is emulated (exit 0). If the real sigaction() ran, this program's
 * handler stole SIGILL and catches the fault itself (exit 42). */
#include <stdio.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>

static void stole_it(int sig) {
    (void)sig;
    const char m[] = "sigtest: MY handler got SIGILL (avxemu lost the signal)\n";
    write(1, m, sizeof m - 1);
    _exit(42);
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = stole_it;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGILL, &sa, 0);          /* exactly what a crash reporter does */

    uint32_t out[8] = {0}, a[8] = {1,2,3,4,5,6,7,8};
    uint32_t *po = out, *pa = a;
    __asm__ __volatile__(
        "vmovdqu (%1), %%ymm0\n\t"
        "vpaddd  %%ymm0, %%ymm0, %%ymm1\n\t"
        "vmovdqu %%ymm1, (%0)\n\t"
        "vzeroupper\n\t"
        : : "r"(po), "r"(pa) : "ymm0", "ymm1", "memory");

    printf("sigtest: AVX2 emulated fine (%u..%u) — interposition held\n",
           out[0], out[7]);
    return 0;
}
