#include "jit_region.h"

#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/* The split shape on a host that can make it itself: plain RW memory, an
   alias, and the original turned R-X. Works for macOS binaries without the
   hardened runtime; on iOS the executable half has to come from a debugger. */
static int open_split(HvJitRegion *region, size_t bytes) {
    void *rx = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rx == MAP_FAILED) return -1;
    vm_address_t rw = 0;
    vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &rw, bytes, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max,
                 VM_INHERIT_NONE) != KERN_SUCCESS ||
        mprotect(rx, bytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(rx, bytes);
        return -1;
    }
    if (hv_jit_region_attach(region, rx, (void *)rw, bytes) != 0) return -1;
    region->owned = 1;
    return 0;
}

int hv_jit_region_open(HvJitRegion *region, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (getenv("HV_JIT_SPLIT")) return open_split(region, bytes);
#if TARGET_OS_OSX
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) return -1;
    region->base = p;
    region->capacity = bytes / sizeof(uint32_t);
    region->owned = 1;
    return 0;
#else
    return open_split(region, bytes); /* works only where nothing enforces code signing (tests on a jailbroken device) */
#endif
}

int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (!rx || !rw || bytes < 4096) return -1;
    region->base = rx;
    region->rw_diff = (intptr_t)((uint8_t *)rw - (uint8_t *)rx);
    region->capacity = bytes / sizeof(uint32_t);
    return 0;
}

void hv_jit_region_close(HvJitRegion *region) {
    if (region->owned && region->base) {
        size_t bytes = region->capacity * sizeof(uint32_t);
        if (region->rw_diff) munmap((uint8_t *)region->base + region->rw_diff, bytes);
        munmap(region->base, bytes);
    }
    memset(region, 0, sizeof *region);
}

void hv_jit_write(HvJitRegion *region, uint32_t *start, const void *src, size_t bytes) {
    /* One instruction may be rewritten while other CPUs run it (chaining a branch).
       memcpy may copy a word in pieces, and a CPU fetching in between takes half of
       the old branch and half of the new one: a jump to nowhere. */
    if (bytes == 4) {
        uint32_t word;
        memcpy(&word, src, 4);
#if TARGET_OS_OSX
        if (!region->rw_diff) pthread_jit_write_protect_np(0);
#endif
        __atomic_store_n((uint32_t *)((uint8_t *)start + region->rw_diff), word, __ATOMIC_RELEASE);
        return;
    }
    if (region->rw_diff) {
        memcpy((uint8_t *)start + region->rw_diff, src, bytes);
        return;
    }
#if TARGET_OS_OSX
    pthread_jit_write_protect_np(0); /* MAP_JIT: writable on this thread only, until hv_jit_finish */
#endif
    memcpy(start, src, bytes);
}

void hv_jit_finish(HvJitRegion *region, uint32_t *start, size_t words) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    if (start && words) sys_icache_invalidate(start, words * sizeof(uint32_t));
}

void hv_jit_finish_words(HvJitRegion *region, uint32_t *const *words, size_t n) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    __asm__ volatile("dsb ish" ::: "memory");
    uintptr_t last = 0;
    for (size_t k = 0; k < n; k++) {
        uintptr_t a = (uintptr_t)words[k] & ~(uintptr_t)63;
        if (a == last) continue;
        last = a;
        __asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
        if (k % 20 == 19) __asm__ volatile("dsb ish" ::: "memory"); /* as sys_icache_invalidate does, for the CPUs that need it */
    }
    __asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

void hv_jit_poison(HvJitRegion *region, uint32_t *start, size_t words) {
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(0); /* MAP_JIT: a direct write faults until this */
#endif
    memset((uint8_t *)start + region->rw_diff, 0, words * sizeof(uint32_t));
    hv_jit_finish(region, start, words);
}

/* As sys_icache_invalidate does it (libsystem_platform: DSB, IC IVAU per 64-byte line with a DSB after every 20 for
   the CPUs that need one, DSB, ISB), over both ranges. */
static void ic_lines(uint32_t *start, size_t words, int *n) {
    if (!start || !words) return;
    uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)(start + words);
    for (; a < end; a += 64) {
        __asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
        if (++*n % 20 == 0) __asm__ volatile("dsb ish" ::: "memory");
    }
}

void hv_jit_finish2(HvJitRegion *region, uint32_t *a, size_t na, uint32_t *b, size_t nb) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    int n = 0;
    __asm__ volatile("dsb ish" ::: "memory");
    ic_lines(a, na, &n);
    ic_lines(b, nb, &n);
    __asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

void hv_jit_finish_branch(HvJitRegion *region, uint32_t *word) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    /* The store first (so a refetch finds the new word), then the line, with no wait for every CPU's cache. */
    __asm__ volatile("dsb ish\n\tic ivau, %0" ::"r"((uintptr_t)word & ~(uintptr_t)63) : "memory");
}

static size_t region_cap(const HvJitRegion *region) {
    return region->limit && region->limit < region->capacity ? region->limit : region->capacity;
}

/* Any thread: an even number of words (blocks stay 8-byte aligned), taken atomically. */
uint32_t *hv_jit_reserve(HvJitRegion *region, size_t words) {
    words = (words + 1) & ~(size_t)1;
    size_t seg = region->seg_words;
    if (!seg) {
        size_t at = __atomic_fetch_add(&region->used, words, __ATOMIC_RELAXED);
        if (at + words > region_cap(region)) return NULL; /* full: the flush resets used */
        return region->base + at;
    }
    if (words > seg) {
        region->too_big = 1;
        return NULL;
    }
    /* Within one segment, so taking a segment back never splits a reservation (a CPU's chunk). */
    size_t at = __atomic_load_n(&region->used, __ATOMIC_RELAXED), to;
    do {
        to = at;
        if (to / seg != (to + words - 1) / seg) to = (to / seg + 1) * seg;
        if (to + words > region->end) return NULL; /* full: hv_jit_evict_next makes room */
    } while (!__atomic_compare_exchange_n(&region->used, &at, to + words, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED));
    return region->base + to;
}

void hv_jit_reset(HvJitRegion *region) {
    region->used = 0;
    region->wrapped = 0;
    region->too_big = 0;
    region->end = (size_t)region->seg_words * region->nseg;
    for (uint32_t k = 0; k < HV_JIT_MAX_SEGS; k++) region->seg_epoch[k]++;
}

void hv_jit_ring(HvJitRegion *region, uint32_t nseg) {
    if (nseg > HV_JIT_MAX_SEGS) nseg = HV_JIT_MAX_SEGS;
    size_t seg = nseg >= 2 ? (region_cap(region) / nseg) & ~(size_t)1 : 0;
    if (seg < 2048) seg = 0, nseg = 0; /* under 8 KB a segment holds too few blocks to be worth keeping the rest */
    region->seg_words = seg;
    region->nseg = nseg;
    hv_jit_reset(region);
}

uint32_t hv_jit_evict_next(HvJitRegion *region) {
    size_t seg = region->seg_words, total = seg * region->nseg;
    uint32_t k;
    if (region->end >= total) { /* the last segment is in use: round to the first */
        k = 0;
        region->used = 0;
        region->wrapped = 1;
    } else {
        k = (uint32_t)(region->end / seg);
        region->used = region->end; /* past what reservations that failed added */
    }
    region->end = (k + 1) * seg;
    region->seg_epoch[k]++;
    return k;
}

size_t hv_jit_extent(const HvJitRegion *region) {
    if (region->wrapped) return (size_t)region->seg_words * region->nseg;
    size_t used = region->used, cap = region_cap(region);
    return used < cap ? used : cap;
}
