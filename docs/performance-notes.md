# Performance notes (this fork, November 2026)

What was measured on an iPad (iPad17,4, 9 cores, iPadOS 26) running a macOS guest with 6 CPUs and 8 GB,
what was tried, and what the numbers point to next. The raw logs are not in the repository.

## How to measure

- **Engine stats**: `HV_STATS=10` (the app's default) writes a `stats` block to `henge.log` every 10 s.
- **Sampling profiler**: `HV_PROF_IOS=1` in `Documents/henge-env.txt` (host/prof_ios.c). Offsets are symbolized with
  `atos -o Henge.app.dSYM/Contents/Resources/DWARF/Henge -arch arm64 0x100000000+OFFSET` against the build that ran.
- **Frame pacing**: a `pvg-mon` line every 10 s (devices/pvg_metal.m): gaps between presented frames, the longest
  batch of GPU commands, the longest pipeline build. `code cache dropped at` lines carry the same wall clock.
- **Census**: `HV_FLUSH_CENSUS=1` counts what the code cache held each time it filled, and how many of those blocks
  were translated again before the next drop. It stops every CPU for about 0.8 s per drop: for measuring only.
- **Runs nobody has to hold the device for**: `tools/ipad_bench.py` drives the app's autopilot over `devicectl`.
  `testmac` copies the Mac used last as "Test", `save` writes the running Mac out, `baseline store/load NAME` keeps
  and puts back its disk and saved state, and with `HV_RESUME_TEST` set a run picks the saved Mac up whatever build
  saved it. Every run then starts from the same instant. The baseline has to be recorded again when the saved
  layouts change (the engine's fingerprint refuses it).

## What the measurements say

- **Translated code itself is fast.** tests/test_bench.c on a Mac: 1.4-2.3x native.
- **Where busy CPU time goes** (profiler, desktop use and YouTube in Chrome): about 67-75% in translated code,
  21-25% in the engine, 7-8% in system calls (lock waits, memmove). No single engine function is above 2%; the
  indirect-branch and cross-page lookups together are about 5%.
- **Metal replay is not the bottleneck.** Batches of GPU commands take at most a few milliseconds, pipeline builds
  under 1 ms, with rare outliers (24 ms and 120 ms were seen).
- **The code cache fills and is dropped whole, often.** With boot, login, Chrome starting and YouTube: 7-8 drops in
  about three minutes, one every 10-35 s, and translating takes 10-33% of the time under load. Steady playback
  from a resumed Mac is much lighter: one drop in three minutes, 4% of the time translating.
- **What a full cache holds** (census, seven drops): 5.1-5.4 million blocks, 298-314 bytes each for 4.9
  instructions, over only 55-82 MB of distinct guest code. 0-6.5% of the blocks are stale. 15-41% are the same
  physical code translated again at another virtual address (macOS loads programs at a different address in every
  process; one 16 KB page had 272,000 blocks, at least 66 address mappings). 36-54% of a full cache's blocks are
  translated again before the next drop.

## What was tried

1. **Writes beside the code** (commit "A write to a code page that touches none of its translated code drops no
   translation"): a map of where each page's translated code lies; writes that miss it drop nothing. 95-98% of
   writes to code pages are spared.
2. **Writes into the code** (commit "A write into code drops only the blocks around the written bytes"): a
   generation per 256 bytes; exits to another 256 bytes of the page are listed and unchained. Whole-page drops fell
   from about 1,650/s to under 90/s.

Both work as designed and no guest crashes were seen, but neither changed how often the cache fills or how much
time translating takes. The assumption behind them, that self-modifying code was what filled the cache, was wrong:
the census shows almost no stale blocks. The "again" percentages in the stats line were what suggested it; they
come from a bitmap that is never cleared and saturates, and should not be read that way.

## What the numbers point to next

In order of expected effect:

1. **Smaller translations.** More than half of a block is out-of-line slow paths (one per memory access and exit).
   Sharing them through common thunks with a side table could roughly halve the 300 bytes a block; the blocks
   wanted again (600-800 MB today) would then fit in half the cache.
2. **Drop the old part of the cache, not all of it.** About half of a full cache is not wanted again. On its own
   this would save roughly 40% of the retranslations; with (1) the wanted part would mostly survive.
3. **Share translations across virtual addresses.** Would remove the 15-41% of duplicates, but the guest PC is
   built into every translation today: the deepest change.
4. **Cheap experiments not yet run**: 3 or 4 guest CPUs instead of 6 (the device probably has 3 fast cores, and the
   guest's CPUs were 24-75% idle), superblocks, `HV_QOS=ui`.

Two runs of the same build from the same baseline (resume, reload the YouTube page, three minutes of playback)
agree closely: 1 and 1 cache drops, 4.3% and 4.5% of the time translating, 6,893 and 6,751 frames, 74.9% and 74.5%
of busy time in translated code. Differences of that size between builds are noise.

A heavier scripted scenario (several page loads or app launches after the resume) is needed before measuring (1):
steady playback alone drops the cache too rarely to show the difference.

## Known loose ends

- `tests/test_jit` and `tests/test_mem` crash on the Mac used here, before any of these changes.
- One crash in Apple's Metal driver inside `-[HvReplay makeSerialized:length:task:]`
  (`newRenderPipelineStateWithDescriptor:`), preceded by "pass skipped: attachments were never made". Not reproduced,
  not investigated.
