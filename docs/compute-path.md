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

- `CS_Accum` is `PS_Accum`'s state machine plus one count: every pixel it calls changed adds to
  a `groupshared` tally, and one thread per **group** adds that tally to a single 1×1 `r32u` counter, so
  the global counter takes thousands of adds a frame instead of millions. That thread is picked with
  `SV_GroupIndex` (`gi == 0`); `SV_DispatchThreadID` is the *global* thread address, so testing that for
  zero would fire in one group only — the others would never reset or add their tally, and the count
  would be wrong in a way nothing on screen makes obvious.
- `CS_Finish` (1×1 dispatch, right after `CS_Accum`) divides the count by the pixel count, writes the
  share into a 1×1 `r32f` target and zeroes the counter. The pixel passes read that float target through
  a sampler named `MotionStat`, the same name the pixel path gives its RGBA8 statistic, so no guarded
  line is needed at the read sites — only the declaration differs per variant.
- **The share is over the pixels that can change, not the whole buffer.** A pixel pinned at all 0 or all
  255 can never show a difference, so each one lowers the ceiling the share can reach: at 44% of a frame
  inert, no movement reads above 56%, and an `AutoMaskMotion` above that can never be crossed — the world
  is never seen as drawn and stillness is never credited. That was a reported bug, and not a tuning
  problem: the threshold was reachable only while the frame happened not to have much black in it. The
  tally is therefore of the pixels the verdict could speak about, the same flag the clip exclusion already
  computes: `CS_Accum` counts them in a second `groupshared` tally, `CS_Finish` divides the changed count
  by it, and the histogram's floor share is read against it too, so both rules mean the same thing on a
  frame with a large inert region. On the pixel path the accumulator carries the flag in its spare `.a`
  channel and `PS_Motion`/`PS_MotionAvg` reduce the two shares separately — sums first, then divided, so
  the ratio is of the screen and not an average of per-block ratios. A fully inert frame divides by a
  floor of one, which reads as stopped — the side to be wrong on.
- The count replaces `PS_Motion`/`PS_MotionAvg` and the 16×16 coarse target. The gate was 1,024 taps
  standing in for every pixel; it is now exact.
- The **tile map** rides in its own pass, `CS_Tile`, guarded by the compute switch *and* the diagnostics
  one: the map is an instrument, so it exists only where it can be seen. It reads the picture as a
  `AUTOMASK_TILE_GRID`-square grid, `AUTOMASK_TILE_TAPS`² sample points per cell, and reduces it to three region readings —
  the mask's connected-component count and its largest component's share, the share of the grid enclosed
  by the mask, and the count and area of contiguous wide-change patches. A cell is a share of itself
  rather than a tally of its pixels, which is what keeps the map the same size at any resolution, and the
  readings are relaxations over that fixed grid: a label only ever decreases toward the least index in its
  own region, so `AUTOMASK_TILE_ROUNDS` sweeps — `G × G`, the longest a connected region of a `G×G` grid
  can be — settle any shape exactly. That bound is the whole reason the readings are taken here and not at
  full resolution, where the same test is unbounded. The two *count* readings — components and arrival
  patches — are stored against `AUTOMASK_TILE_COUNT_MAX` rather than as a share of the grid, because a
  count of a few regions against 256 cells moves a bar by one percent of its length; the three share
  readings are stored as the shares they are. A cell is interface as soon as the mask **touches** it
  (`AUTOMASK_TILE_HITS` samples), not when it fills it: this is a footprint reading, and most interface is
  thin against a 160×90 cell. The arrival class is the one reading the map may not take on its own: a
  wide-change cell is an arrival only while the world is **not** being drawn, read from the same share
  `CS_Finish` publishes for the premise, because a panel appearing over an already-stopped world is the
  only case the reading is for and a camera pan is a screen-wide *drawing*, not an arrival. Taken as
  "everything wide that has no mask" it was every cell of the grid on a pan, which is the screen-wide
  orange wash the tile view first shipped with. That gate inherits the premise's denominator, so the
  reported failure recurred whenever the share could not cross the threshold — a large black or
  letterboxed region capped it below the setting, the world read stopped while it was moving, and every
  wide cell then became an arrival. Nothing in the mask reads any of it.
- The **change-size histogram** rides in the same pass and is guarded with it, and it counts the whole
  distribution of the frame's movement rather than only the pixels above a threshold — which is why an
  auto-deadband is possible at all. The walk's rule: **the measured step is the smallest change size 1–8
  at which no more than `AutoMaskNoiseFloor` percent of the screen is still changing by that much or
  more.** It holds because of how the bins are indexed: the index truncates, so bin `b` is exactly the
  difference the verdict calls motion at `deadband = b` (its test is `maxDiff < deadband`), which makes
  the above-share read off the histogram at a level *the same count* the verdict would act on — same
  units, same boundary, no second convention to keep in step. `CS_Finish` walks the bins from level 1 up,
  subtracting each level's own bin as it passes it, and stops at the first that satisfies the rule; that
  level goes into the committed step, the `RGBA32F` 1×1 target the next frame's `CS_Accum` reads through a
  sampler named `AutoStep`, one frame behind exactly as the share is. The target's other two channels
  carry the answer being compared against the committed one and the frames it has stood for, so the
  commit below costs no second target. The measurement is per frame and never writes
  back into the slider. The walk covers levels 1 to 8 only, because 8 is where the `AutoMaskEps` slider
  ends and a step outside that range is not a position the manual path could take either. Running out of
  the range means no level separated the frame's noise from its content — what a fully live frame looks
  like, every level still changing somewhere — and there the slider's own value stands rather than the
  measurement guessing, so a fast camera movement cannot talk the shader into forgiving real motion.
  Because the threshold is a share of the *screen* and not a count of levels, it means the same thing at
  every resolution: at 1440p the `0.5` default is 18,432 pixels.
- **A step is committed only after a run of frames agree on it.** The walk is fed by motion measured
  against the same step it sets, and the share it reads moves with whatever is moving — a patch of grass
  or a stretch of water covering more than `AutoMaskNoiseFloor` of the screen holds the step above the
  size of its own movement, and the red is then graded against that step. The red and the verdict both
  read the number, so the coupling is not cosmetic: a step held too high for a still scene has counted
  nothing changed, which drives the share toward zero and can close the premise over scenery. A reading
  is therefore held until `AUTOMASK_STEP_DWELL` consecutive frames have answered the same level. A scene
  change is a whole new distribution and still crosses it; what the hold filters is the same scene's
  frame-to-frame movement in and out of the floor's tail. The dwell bounds how long a held reading
  stands rather than naming a value anyone tunes, so it is a named constant by the same rule as
  `AUTOMASK_STEP_MAX`, and it is derived from `AutoMaskTargetFPS` so the hold is a second rather than a
  frame count. The length is a judgement with no GPU to check it against; the motion view over a steady
  mover is where it is judged.
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
  would read them. The auto-deadband is a live toggle rather than a structural switch, so its
  targets stay allocated while it is off — the convention is that a value tuned by watching stays a slider
  and costs nothing but the memory its guard already owns, and 1 KB is not worth a recompile per
  comparison.
- The **drift channel** rides in the same pass and is guarded with it. Two full-res `RGBA32F` ping-
  pong targets hold a long-baseline average of each pixel's colour (`drift' = lerp(now, drift, 1 -
  1/K)`, `K = AutoMaskDrift × AutoMaskTargetFPS` frames), and a pixel is marked moving when
  **either** the frame-to-frame difference or its distance from that average crosses its own ramp —
  footed at the same deadband the verdict uses, topping out at `AUTOMASK_DRIFT_LAG` deadbands, which
  is the bound the average is held inside below; the graded overlay carries the max, so red is still
  the reading the verdict comes from. It exists because the frame-to-frame comparison speaks in
  whole levels: a backdrop shifting by a fraction of one a frame — a skybox panning slowly — reads
  as exactly still there and would be banked as interface, while the average accumulates the shift —
  up to the bound below — until the pixel sits visibly away from where it has been. The clip-rail
  exclusion applies to the average symmetrically, and stillness now requires both comparisons to
  read still, so the drift channel also feeds the world-drawn count and the premise with it: a
  slowly panning sky can hold the premise up on its own. That second direction is measurable, and it
  surprised the one check that looked for it: with a slowly drifting sky on screen, a longer horizon made
  the mask credit *more* dim scenery rather than less, not because the channel granted it credit per
  pixel — it can only remove that — but because catching the sky as changed held the premise up, and the
  premise is what lets any still pixel earn (`docs/ui-isolation-options.md` §5.5.1). The average is
  carried back to the side the next frame reads by the closing pass, as a second render target: the
  drift copy has no pass of its own. The store is the one that
  cannot be half precision: the creep toward a one-level gap is a fraction of a level a frame — at
  the 2 s default, 0.0083 levels — which is under an `RGBA16F` half-ulp above level 31 (0.0156
  there, against 0.0078 in the band below), so the average sat frozen rather than following the
  pixel while the short comparison read still. A frozen average fails both ways: it cannot
  accumulate a sub-level shift (so the channel does nothing on the bright half of a sky) and it
  cannot close on a static pixel either, so a pixel left a level away from it read as moving for as
  long as it held. `RGBA32F` is what lets the creep step move the store at every level, and its cost
  is that the two drift targets double, ~59 MB to ~118 MB at 1440p.
- **The average is held inside its own reach, and that is what bounds a move's tail.** A bounded ramp can
  only report the lag it can reach, so an average allowed past it stores lag that changes nothing but how
  long the tail lasts — and a *creeping* one lags by the rate times the horizon in levels, tens of them
  through a camera pan. Walking that back under the deadband takes a horizon, so the whole screen went on
  reading as drawn — and, over the graded ramp, red — for seconds after the picture stopped: measured on a
  constant-rate pan of 1 s then stopped (deadband 1), the premise cleared in 7.7 s before and 1.4 s now at
  the 2 s horizon, and 40.4 s against 6.9 s at 10 s. `deadband / K` still sets how slow a drift the channel
  reaches; "how long a pan lingers" is no longer one of the horizon's jobs.
- **The reach has to be expressed on the value's own scale.** `now` and `drift` are normalized
  (`nowLevels / 255.0`) while the reach is a level count, so a clamp written `now ± deadband ×
  AUTOMASK_DRIFT_LAG` names a threshold 255 times the bound it means, which a 0..1 value can never reach.
  Inert, the bound leaves the tail in seconds: measured from a capture of a real pan, the motion view's
  red and the still verdict lasted 5–10 s at the 2 s horizon against about one second once the reach is
  divided onto that scale. The paragraph above describes a bound that holds, which this is what makes it.
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
  now catches slower movement instead of changing nothing. A move the short comparison reads at a few
  levels — a camera pan — still does not reset the average, so it stays in the drift reading while it
  lasts; that is the memory working as intended. It no longer lingers past the move, though, because the
  average is held inside its own reach: the tail after a pan stops is the lag's own exponential walk back —
  about `ln(AUTOMASK_DRIFT_LAG)` horizons off a *bounded* lag, against one horizon off a lag the pan grew
  without limit.

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
   `AutoMaskCompute` on this pass is `CS_Accum` instead: same slot, same work, plus the count — the
   verdict arithmetic both accumulators share comes from `Shaders/AutoMask.fxh` (the premise, the decay
   step, the published-mask read, the deadband, the pinned-colour count and the frame rate), so the two
   paths cannot drift apart in what they decide. Admission rides here — four taps on the verdict channel
   it already holds, behind `AutoMaskNeighbour`, and the same four on both paths.
2. The two sub-resolution passes that average the still flag into the share of the screen being redrawn —
   after the accumulate, since their only input is what it just wrote, and read on the next frame. With
   `AutoMaskCompute` on these two are gone, replaced by `CS_Finish`, which turns the exact count into the
   same share — and, off the same histogram, the measured step the next frame reads. The auto-deadband
   therefore lands in the same slot and keeps the same one-frame-behind timing as the share: the frame
   being judged is never the frame that set its own threshold.
3. `PS_DilateH`, `PS_DilateV` — the boundary close, and both ping-pong back-edges. The horizontal
   pass reads the live side `texAutoAccumB` and writes it back to `texAutoAccumA` as a second render
   target: that write **is** the copy `PS_Copy` used to be, and its read is the centre tap the pass
   already takes, so the back-edge costs no extra sample. On the compute path it takes a third target,
   `texAutoDriftA`, and carries the drift average back the same way — the copy `PS_CopyDrift` used to
   be — so the drift pair has no pass of its own either. `PS_Dilate` is one pass: a 2D max over a tiny
   fixed neighbourhood, stopping where the luma step read from `BackBuffer` exceeds `AutoMaskEdge`.
   Reading the frame there is safe only because it is before every pass that writes it. The isolation
   gate rides in these two passes too, off their own target: it is a pixel-pass feature, so it reads the
   same on both variants and has no compute spelling.
4. `CS_Tile` — the tile map and its region readings, only with `AutoMaskCompute` **and**
   `AutoMaskDiagnostics` both on. It comes after the closing, so a cell is the mask the shader published
   rather than the verdict under it, and before `PS_Store`, since the arrival reading is taken off the
   accumulator's own graded motion and the premise share `CS_Finish` has just published — both of which
   describe this frame, and both of which the store would otherwise leave describing the last one.
5. `PS_Store` — one pass writing two targets: the mapped pixels into `texAutoFrame`, and the untouched
   frame into `texAutoHistory` for the next frame. Both read the same `BackBuffer`, so the second target
   costs one full-resolution pass fewer than a store pass and a history pass would.
6. `PS_StoreDepth` — only with `AutoMaskDepthMotion`, and last of the store group: it leaves this frame's
   linearized depth for the next frame's comparison, and the accumulator read that target earlier in the
   frame, so nothing samples what this writes. It is one full-resolution pass on both paths and writes the
   `R32F` target the accumulator's depth term reads.
7. `PS_AntiBloom` — black the masked pixels in the live frame so a bloom pass downstream has no UI to
   pick up. It comes after the store, which is what keeps the real UI for the restore pass; blacking
   earlier would bank the black instead.
8. The diagnostics overlay, last, and only when `AutoMaskDiagnostics` is defined to 1 — a compile-time
   guard on the pass and the shader both, so with it off neither is compiled. It reads the accumulator
   directly rather than recomputing the difference, so it cannot report on itself instead of on the
   shader. It draws one of three views: red where the graded motion reads, green where the accumulator's
   own confidence crosses the protection threshold, or — on the second live toggle — two flat colours
   split at that threshold, one the mask already claims and one it does not, with everything at or below
   zero left plain, so no shade has to be compared — the view that read `docs/ui-isolation-options.md`
   §5.5.1; the two toggles are mutually exclusive and the colours are drawn where the verdict would be. A
   third, `UIDebugTile` (compute-only, since the tile map it draws exists only there), replaces both with
   the cell classes `CS_Tile` wrote: a square of the 16×16 grid drawn in its class — green mask, black
   world, red a wide change with no mask on it while the world is stopped, orange a world cell sealed off
   by mask — and the five region readings as bars along the top.
   The published mask is deliberately *not* used, so the verdict view shows an element's own area without
   the closing radius grown around it. Every per-pixel view tints the stored history frame and only where
   the chosen signal covers — the blend is scaled by the signal, so a pixel it does not name is passed
   through untouched. The map packs the view's own channels into one target: red the graded motion, green
   the verdict, blue the confidence grade, and alpha the screen state in two steps; the tile view takes
   rgb together where it draws, which is why the grade is read from blue only while it is off. The same
   blue carries it on the pixel path, where no grid view exists to use it.
   The state is read from the same statistic the gate itself reads, one frame behind the frame it
   describes, so it shows the state that will shortly govern the mask rather than a value recomputed a
   second way, and its strictness must match the gate's: `> AutoMaskMotion`, not `step`, which is true at
   the threshold itself and would disagree on exactly the boundary frame.
   The corner marker is **not** drawn here: it is the one thing `AutoMask_Restore` adds, reading that
   alpha channel, because a block drawn inside `AutoMask` is repainted by the restore pass over any pixel
   the mask covers and treated as picture by every effect in between. Two states, two flat colours and no
   blending — magenta while the world is being drawn, yellow while it is not and the mask is being held —
   so the marker is a reading rather than part of the picture and cannot be tinted by anything else on
   screen.
