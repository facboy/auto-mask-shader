# The compute path

What `AutoMaskCompute=1` changes and why. Extracted from `AGENTS.md`; read this when a change touches
the compute passes, the exact motion count, the change-size histogram, the auto-deadband, the drift
channel, or the pass order inside `AutoMask`.

`AutoMaskCompute=1` swaps the accumulator and the screen-motion gate for compute passes, under a guard
that owns the shaders, the pass entries and every target only they use. The gate half is a replacement
rather than an addition — the coarse grid and its two reduction passes are gone, not skipped. Two
readings are *added* rather than replaced, both resting on the compute path's ability to see every pixel:
the drift channel's two full-res `RGBA32F` ping-pong targets, which the pixel path has nowhere to put and
deliberately does not carry, and the histogram's `AUTOMASK_STEP_MAX`×1 `r32u` plus the 1×1 `r32f` step it
feeds — a few dozen bytes together, against 1 KB when the bins were one per level — which the coarse grid
cannot take at all, because 1,024 taps cannot tell a level of dithering from a level of real motion.

- `CS_Accum` is `PS_Accum`'s state machine verbatim, plus one count: every pixel it calls changed adds to
  a `groupshared` tally, and one thread per **group** adds that tally to a single 1×1 `r32u` counter, so
  the global counter takes thousands of adds a frame instead of millions. That thread is picked with
  `SV_GroupIndex` (`gi == 0`); `SV_DispatchThreadID` is the *global* thread address, so testing that for
  zero would fire in one group only — the others would never reset or add their tally, and the count
  would be wrong in a way nothing on screen makes obvious.
- `CS_Finish` (1×1 dispatch, right after `CS_Accum`) divides the count by the pixel count, writes the
  share into a 1×1 `r32f` target and zeroes the counter. The pixel passes read that float target through
  a sampler named `MotionStat`, the same name the pixel path gives its RGBA8 statistic, so no guarded
  line is needed at the read sites — only the declaration differs per variant.
- The count replaces `PS_Motion`/`PS_MotionAvg` and the 16×16 coarse target. The gate was 1,024 taps
  standing in for every pixel; it is now exact.
- The **change-size histogram** rides in the same pass and is guarded with it, and it counts the whole
  distribution of the frame's movement rather than only the pixels above a threshold — which is why an
  auto-deadband is possible at all. The walk's rule: **the measured step is the smallest change size 1–8
  at which no more than `AutoMaskNoiseFloor` percent of the screen is still changing by that much or
  more.** It holds because of how the bins are indexed: the index truncates, so bin `b` is exactly the
  difference the verdict calls motion at `deadband = b` (its test is `maxDiff < deadband`), which makes
  the above-share read off the histogram at a level *the same count* the verdict would act on — same
  units, same boundary, no second convention to keep in step. `CS_Finish` walks the bins from level 1 up,
  subtracting each level's own bin as it passes it, and stops at the first that satisfies the rule; that
  level goes into a second 1×1 `r32f` target the next frame's `CS_Accum` reads through a sampler named
  `AutoStep`, one frame behind exactly as the share is. The measurement is per frame and never writes
  back into the slider. The walk covers levels 1 to 8 only, because 8 is where the `AutoMaskEps` slider
  ends and a step outside that range is not a position the manual path could take either. Running out of
  the range means no level separated the frame's noise from its content — what a fully live frame looks
  like, every level still changing somewhere — and there the slider's own value stands rather than the
  measurement guessing, so a fast camera movement cannot talk the shader into forgiving real motion.
  Because the threshold is a share of the *screen* and not a count of levels, it means the same thing at
  every resolution: at 1440p the `0.5` default is 18,432 pixels.
- **The histogram is tallied in groupshared, not in the global bins.** The first version wrote one
  `atomicAdd` per pixel straight into a 256×1 `r32u` target, and that is the whole of what the toggle
  cost: ~3.7M global atomics a frame at 1440p, nearly all of them aimed at the same bin in a still scene,
  which is the worst case for atomic contention. `CS_Accum` now keeps an 8-bin `groupshared` tally beside
  the moved-pixel one, so a block's pixels contend only with each other, and one thread per group hands
  the totals over — a handful of global adds per group, and a bin no pixel reached is skipped entirely.
  The target is `AUTOMASK_STEP_MAX` wide rather than 256 for the same reason: the walk reads levels 1 to 8
  and nothing else, bins above it were never read, and a pixel that did not change now lands in no bin at
  all, so the quiet majority is counted by its absence instead of by an add apiece onto bin 0. The
  readings are equivalent, not merely similar — verified statement for statement against the old 256-bin
  walk over 20,000 synthetic frames, no mismatch — because the walk sums the bins and subtracts each
  level's own, which is the same arithmetic whether level 0 is stored or left implicit.
- The bins are still filled only while the toggle is on, and the flush with them, so the off path does no
  histogram work beyond the shared-memory clear — which is the group's own scratch space, not the bins the
  next frame reads, and therefore has to run regardless. The *global* bins are cleared in `CS_Finish` (now
  8 writes from a 1-thread pass instead of 256) because a toggle flip with them left full would have the
  first measured step read off a stale frame. `AutoMaskAutoStep` and `AutoMaskNoiseFloor` are declared
  beside the horizon inside the compute guard for the same reason it is: the pixel path has no pass that
  would read them. The auto-deadband is a live toggle rather than a fourth structural switch, so its
  targets stay allocated while it is off — the convention is that a value tuned by watching stays a slider
  and costs nothing but the memory its guard already owns, and 1 KB is not worth a recompile per
  comparison.
- The **drift channel** rides in the same pass and is guarded with it. Two full-res `RGBA32F` ping-pong
  targets hold a long-baseline average of each pixel's colour (`drift' = lerp(now, drift, 1 - 1/K)`,
  `K = AutoMaskDrift × AutoMaskTargetFPS` frames), and a pixel is marked moving when **either** the
  frame-to-frame difference or its distance from that average crosses the same deadband; the graded
  overlay carries the max, so red is still the reading the verdict comes from. It exists because the
  frame-to-frame comparison speaks in whole levels: a backdrop shifting by a fraction of one a frame — a
  skybox panning slowly — reads as exactly still there and would be banked as interface, while the
  average accumulates the shift until the pixel sits visibly away from where it has been. The clip-rail
  exclusion applies to the average symmetrically, and stillness now requires both comparisons to read
  still, so the drift channel also feeds the world-drawn count and the premise with it: a slowly panning
  sky can hold the premise up on its own. `PS_CopyDrift`, a pixel pass beside `PS_Copy`, brings the
  average back to the side the next frame reads. The store is the one that cannot be half precision: the
  creep toward a one-level gap is a fraction of a level a frame — at the 2 s default, 0.0083 levels — which
  is under an `RGBA16F` half-ulp above level 31 (0.0156 there, against 0.0078 in the band below), so the
  average sat frozen rather than following the pixel while the short comparison read still. A frozen
  average fails both ways: it cannot accumulate a sub-level shift (so the channel does nothing on the bright
  half of a sky) and it cannot close on a static pixel either, so a pixel left a level away from it read as
  moving for as long as it held. `RGBA32F` is what lets the creep step move the store at every level, and
  its cost is that the two drift targets double, ~59 MB to ~118 MB at 1440p.
- **An abrupt change follows at once, and only drift waits.** The average takes a horizon's worth of the
  frame a frame while the short comparison reads still — that is what lets a sub-level shift accumulate —
  but where the frame changes by a *wide* step it *becomes* the frame instead: a scene cut or a load is
  far wider than that step, and lagging a whole colour distance behind would hold a mask out of a cut for
  a horizon on end. So a cut drags the average straight to the new scene and only the genuinely
  sub-deadband movement is left to accumulate.
- **The reset is keyed to a fixed wide step and not to the deadband.** The deadband is the smallest
  change called motion, so at the most sensitive setting it is one level — and a reset keyed to it fires
  on *every* single-level change, which is precisely the sky the channel exists for. Its first frame then
  reset the average onto the frame, and the next frame's drift reading was the frame-to-frame reading by
  construction: measured over a creeping sky at `AutoMaskEps = 1`, the two agreed on **100%** of frames
  at every horizon setting, so neither the channel nor its slider did anything. The two thresholds answer
  different questions — "did this pixel move?" against "is this a new picture?" — and only the second
  belongs on the reset, which is why the rule is `maxDiff < max(deadband, 8.0)` rather than `maxDiff <
  deadband`. The floor the reset sets is deliberately low against a cut (8 levels is a fast pan at 60
  fps), so `AutoMaskDrift` stays the only lever on how slow a drift the channel reaches and raising it
  now catches slower movement instead of changing nothing. The cost is that a move the short comparison
  reads at a few levels — a camera pan — no longer resets the average, so it stays in the drift reading
  for the horizon rather than being wiped by it; that is the memory working as intended, and it is why
  pan-then-stop recovery rests on `AutoMaskMoveMemory` rather than on the average snapping (a pan is
  still rejected either way, by the accumulating lag it builds once it no longer resets).

## Four constraints the dialect imposes on any compute pass here

- **Sampling has no implicit derivatives.** `tex2D` is rejected outright at `cs_5_0` (X4532); a compute
  pass must use `tex2Dlod` and name its mip level. The pixel passes are unaffected.
- **A barrier must sit in uniform flow control.** A bounds `return` on the thread address before a
  `barrier()` is rejected (X4026), so the ceil-div guard has to be a predicate:
  `bool live = (tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT)`, with the frame sample and the store
  gated on it rather than skipped early.
- **`groupshared` is a file-scope declaration**, not a local: declaring it inside the shader body is
  error X3010. An **array** of them is fine, and so is `atomicAdd` on a dynamically indexed element
  (`atomicAdd(groupHist[bin], 1u)`): the index-expression rule admits arrays, and the atomic intrinsics
  take the addressed element rather than an object. That is what lets the histogram be tallied where it
  is cheap. Verified against ReShade v6.8.0's own parser and HLSL codegen — the shared tally emits as
  `groupshared uint V__groupHist[8];` and the adds as `InterlockedAdd(V__groupHist[bin], 1u, _res)`,
  which is the codegen path the game takes. That same index-expression rule is the trap in the very
  next bullet, for the opposite reason:
- **A storage object cannot be indexed.** `store[int2(x, y)] = v` looks like HLSL and is not: the
  declaration's element type is a storage type, and the index-expression rule accepts only arrays,
  vectors and matrices, so ReShade rejects the bracket form with X3121 (`array, matrix, vector, or
  indexable object type expected in index expression`), reported against the *use* rather than the
  declaration. Reading and writing one goes through **`tex2Dfetch(store, coord)`** and
  **`tex2Dstore(store, coord, value)`** — the intrinsics are the only legal access, and ReShade's own
  codegen emits the bracket form for them before it calls a shader compiler, which is why the mistake is
  invisible in the emitted HLSL and compiles there. `storage2D<T>` remains the right thing to declare;
  only the access has to go through the intrinsics. The `atomic*` family is the one exception that is
  not a trap: it takes the storage and the coordinate as two arguments rather than indexing
  (`atomicAdd(AutoMotionCount, int2(0, 0), 1u)`), so those calls stay as they are and must not be
  "corrected" into bracket form.

`DispatchSizeX/Y` are group counts, taken from `BUFFER_WIDTH`/`BUFFER_HEIGHT` so they stay right at any
resolution, and the dispatch rounds up — which is exactly why the in-shader bounds predicate exists.

## Pass order inside `AutoMask`

Follows from what each pass reads:

1. `PS_Accum` — builds the new confidence against the *previous* frame, **before** the history store, and
   applies the world-drawn premise by reading the statistic the previous frame left behind. With
   `AutoMaskCompute` on this pass is `CS_Accum` instead: same slot, same work, plus the count.
2. The two sub-resolution passes that average the still flag into the share of the screen being redrawn —
   after the accumulate, since their only input is what it just wrote, and read on the next frame. With
   `AutoMaskCompute` on these two are gone, replaced by `CS_Finish`, which turns the exact count into the
   same share — and, off the same histogram, the measured step the next frame reads. The auto-deadband
   therefore lands in the same slot and keeps the same one-frame-behind timing as the share: the frame
   being judged is never the frame that set its own threshold.
3. `PS_Copy`, `PS_Dilate` — the ping-pong back-edge and the boundary close, also before the store.
   `PS_Dilate` is one pass: a 2D max over a tiny fixed neighbourhood, stopping where the luma step read
   from `BackBuffer` exceeds `AutoMaskEdge`. Reading the frame there is safe only because it is before
   every pass that writes it. `PS_Copy` stays a pixel pass in both variants — the accumulator is
   `RGBA16F` and the copy has no statistics to do — and `PS_CopyDrift` is its twin on the compute path.
   The isolation gate rides in these two passes too, off their own target: it is a pixel-pass feature, so
   it reads the same on both variants and has no compute spelling.
4. `PS_Store`, keeping the mapped pixels.
5. `PS_StoreFrame`, copying the untouched frame into the history target for the next frame.
6. `PS_AntiBloom` — black the masked pixels in the live frame so a bloom pass downstream has no UI to
   pick up. It comes after the store, which is what keeps the real UI for the restore pass; blacking
   earlier would bank the black instead.
7. The diagnostics overlay, last, and only when `AutoMaskDiagnostics` is defined to 1 — a compile-time
   guard on the pass and the shader both, so with it off neither is compiled. It reads the accumulator
   directly rather than recomputing the difference, so it cannot report on itself instead of on the
   shader. It draws one of two views, picked by the live toggle `UIDebugMotion`: red where the graded
   motion reads, or green where the accumulator's own confidence crosses the protection threshold. The
   published mask is deliberately *not* used, so the verdict view shows an element's own area without the
   closing radius grown around it. Both views tint over the stored history frame and only where the
   chosen signal covers — the blend is scaled by the signal, so a pixel it does not name is passed
   through untouched. The map packs both signals into one target: red the graded motion, green and blue
   the same verdict (two channels of one value, because the view reads one or the other), and alpha the
   screen state in two steps. The state is read from the same statistic the gate itself reads, one frame
   behind the frame it describes, so it shows the state that will shortly govern the mask rather than a
   value recomputed a second way, and its strictness must match the gate's: `> AutoMaskMotion`, not
   `step`, which is true at the threshold itself and would disagree on exactly the boundary frame. The
   deadzone ring is drawn over either view.
   The corner marker is **not** drawn here: it is the one thing `AutoMask_Restore` adds, reading that
   alpha channel, because a block drawn inside `AutoMask` is repainted by the restore pass over any pixel
   the mask covers and treated as picture by every effect in between. Two states, two flat colours and no
   blending — magenta while the world is being drawn, yellow while it is not and the mask is being held —
   so the marker is a reading rather than part of the picture and cannot be tinted by anything else on
   screen.
