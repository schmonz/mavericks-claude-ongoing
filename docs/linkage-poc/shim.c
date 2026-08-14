/*
 * Proof of concept: do avxemu's interposition by hand.
 *
 * 10.9's dyld registers __DATA,__interpose only for DYLD_INSERT_LIBRARIES
 * images, so a LINKED libavxemu never gets its sigaction()/signal() overrides
 * applied and the app steals SIGILL from the emulator. This shim, linked
 * alongside it, walks the main executable's lazy/non-lazy symbol pointer tables
 * (the "fishhook" technique) and repoints the sigaction/signal slots at
 * avxemu's replacements — the same end state dyld would have produced.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>

static int rebind_in_main(const struct mach_header_64 *hdr, intptr_t slide,
                          const char *want, void *repl) {
    const struct load_command *p =
        (const struct load_command *)((const uint8_t *)hdr + sizeof(*hdr));
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dy = NULL;
    uintptr_t linkedit_base = 0;

    for (uint32_t i = 0; i < hdr->ncmds;
         i++, p = (const struct load_command *)((const uint8_t *)p + p->cmdsize)) {
        if (p->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
            if (strcmp(sg->segname, "__LINKEDIT") == 0)
                linkedit_base = (uintptr_t)slide + sg->vmaddr - sg->fileoff;
        } else if (p->cmd == LC_SYMTAB) {
            st = (const struct symtab_command *)p;
        } else if (p->cmd == LC_DYSYMTAB) {
            dy = (const struct dysymtab_command *)p;
        }
    }
    if (!st || !dy || !linkedit_base) return -1;

    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + st->symoff);
    const char *strtab = (const char *)(linkedit_base + st->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkedit_base + dy->indirectsymoff);

    int count = 0;
    p = (const struct load_command *)((const uint8_t *)hdr + sizeof(*hdr));
    for (uint32_t i = 0; i < hdr->ncmds;
         i++, p = (const struct load_command *)((const uint8_t *)p + p->cmdsize)) {
        if (p->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *sg = (const struct segment_command_64 *)p;
        const struct section_64 *sect =
            (const struct section_64 *)((const uint8_t *)sg + sizeof(*sg));
        for (uint32_t j = 0; j < sg->nsects; j++) {
            uint32_t type = sect[j].flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
                continue;
            void **slots = (void **)((uintptr_t)slide + sect[j].addr);
            uint32_t nslots = (uint32_t)(sect[j].size / sizeof(void *));
            for (uint32_t k = 0; k < nslots; k++) {
                uint32_t symi = indirect[sect[j].reserved1 + k];
                if (symi & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                const char *nm = strtab + symtab[symi].n_un.n_strx;
                if (strcmp(nm, want) != 0) continue;
                uintptr_t page = (uintptr_t)&slots[k] & ~(uintptr_t)0xFFF;
                mprotect((void *)page, 0x1000, PROT_READ | PROT_WRITE);
                slots[k] = repl;
                count++;
            }
        }
    }
    return count;
}

__attribute__((constructor))
static void shim_init(void) {
    void *sa = dlsym(RTLD_DEFAULT, "avxemu_sigaction");
    void *sg = dlsym(RTLD_DEFAULT, "avxemu_signal");
    if (!sa) { fprintf(stderr, "shim: avxemu_sigaction not found\n"); return; }
    const struct mach_header_64 *h =
        (const struct mach_header_64 *)_dyld_get_image_header(0);   /* main executable */
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    int n = rebind_in_main(h, slide, "_sigaction", sa);
    int m = sg ? rebind_in_main(h, slide, "_signal", sg) : 0;
    fprintf(stderr, "shim: rebound sigaction=%d signal=%d slot(s)\n", n, m);
}
