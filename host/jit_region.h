#ifndef HENGEVM_JIT_REGION_H
#define HENGEVM_JIT_REGION_H

#include <stddef.h>
#include <stdint.h>

#define HV_JIT_MAX_SEGS 64

/* One executable region for translated blocks. Blocks are appended and never
   freed one by one. As a ring (hv_jit_ring): the region is cut into segments
   filled in turn, and when it fills only the oldest segment is taken back
   (hv_jit_evict_next; the machine drops the blocks in it). Otherwise, or when
   the ring cannot make room, the whole region is reset.

   Two shapes. macOS: one MAP_JIT mapping, made writable per thread while code
   is copied in (rw_diff is 0). iOS: an executable mapping a debugger granted
   (StikDebug or the built-in helper) plus a writable alias of the same pages
   made with vm_remap; code is written through base + rw_diff and runs at base.
   Everything outside this file and the final copy in the translator sees only
   the executable addresses. HV_JIT_SPLIT=1 makes the macOS build use the iOS
   shape, to test it. */
typedef struct HvJitRegion {
    uint32_t *base;     /* executable addresses */
    intptr_t rw_diff;   /* writable alias = base + rw_diff (bytes), or 0 */
    size_t capacity;    /* in instructions */
    size_t used;        /* in instructions */
    size_t limit;       /* in instructions; 0: all of it (HV_JIT_CAP: a smaller cache in the same region, to compare) */
    int owned;          /* mapped here (closed here) rather than handed in */
    /* The ring: seg_words 0 means none. used is where the next reservation goes, end where reservations stop
       (the start of the oldest code still kept), and a reservation never crosses from one segment into the next. */
    size_t seg_words;
    uint32_t nseg;
    size_t end;
    int wrapped;        /* written all the way round since the last reset: every segment may hold code */
    int too_big;        /* a reservation larger than a segment failed: only a reset makes room for it */
    uint32_t seg_epoch[HV_JIT_MAX_SEGS]; /* bumped as each segment is taken back: space reserved in it before is gone */
} HvJitRegion;

int hv_jit_region_open(HvJitRegion *region, size_t bytes);
/* Use memory the host already has: rx executable, rw a writable alias of it (or rx itself on macOS MAP_JIT). */
int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes);
void hv_jit_region_close(HvJitRegion *region);

/* Copy `words` instructions to start (an executable address) and make them runnable. */
void hv_jit_write(HvJitRegion *region, uint32_t *start, const void *src, size_t bytes);
void hv_jit_finish(HvJitRegion *region, uint32_t *start, size_t words);
/* hv_jit_finish for two ranges at once (a block's hot and cold parts): one wait for the instruction caches, not two. */
void hv_jit_finish2(HvJitRegion *region, uint32_t *a, size_t na, uint32_t *b, size_t nb);
/* After rewriting one B (an unconditional branch) as another B, which a CPU may run as it changes (Arm allows it for
   B): the instruction caches drop the line without waiting for them all to have done so. A CPU still running the old
   branch takes the way the old one went (chaining: the exit's stub, which follows the slot) until its cache lets go. */
void hv_jit_finish_branch(HvJitRegion *region, uint32_t *word);

/* After rewriting single words with hv_jit_write while no CPU runs translated code: one barrier for all of them, not
   one per word (an eviction can undo hundreds of thousands of chained exits). */
void hv_jit_finish_words(HvJitRegion *region, uint32_t *const *words, size_t n);
/* Debugging (HV_JIT_POISON): zero `words` instructions at start (an executable address), so running them faults. */
void hv_jit_poison(HvJitRegion *region, uint32_t *start, size_t words);

/* Space for `words` instructions, or NULL when the region is full. */
uint32_t *hv_jit_reserve(HvJitRegion *region, size_t words);
/* Back to empty (and the ring, if any, to its first segment). */
void hv_jit_reset(HvJitRegion *region);
/* Use the region (as limited) as a ring of nseg segments, or not (nseg < 2, or segments too small to be worth it).
   Only while it is empty: right after hv_jit_reset. */
void hv_jit_ring(HvJitRegion *region, uint32_t nseg);
/* The ring is full: take back the oldest segment for the next reservations and return its index. Its code must be
   unreachable before anything runs again (the caller has every CPU stopped). */
uint32_t hv_jit_evict_next(HvJitRegion *region);
/* Instructions from base that may hold code: for diagnostics that scan or bound the region. */
size_t hv_jit_extent(const HvJitRegion *region);

#endif
