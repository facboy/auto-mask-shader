# Performance

Where the frame's cost actually sits, measured off the compiled bytecode rather than the source, and
the changes that measurement has justified. The pass count and the target count are fixed by
`docs/core-model.md` and `docs/compute-path.md`: every pass is a full-resolution read and write, so
what the frame pays is the bytes moved more than the instructions run.

## 1. What the assembly shows

`uv run tools/verify_shaders.py check --opcodes` reports a static slot count per entry point, which
is a compile-time figure. The two closing passes compile to runtime loops, and a slot count hides both
how far the loop runs and which of its steps do any work. Read off `tools/.work/PS_Dilate*.asm` at the
shipped defaults, the samples a pixel actually costs:

| pass | samples/px, gate off | gate on |
| --- | --- | --- |
| `PS_DilateH` | 6 | 6 |
| `PS_DilateV` | 4 | 8 |
| closing, both passes | **10** | 14 |

The closing is the heaviest part of the full-resolution chain at every shipped setting, against the
accumulator's 8 samples a pixel and the other full-resolution passes at 1–3 each. The accumulator's
static count is what moves under a switch — 152 under `AutoMaskDepthMotion` against 93 without — and its
samples do not: the depth block takes no back-buffer tap, and the one accumulator branch that takes
extra taps at all, `AutoMaskNeighbour`'s four admission ones, ships off. The fixed seven-tap window the
closing began with cost `PS_DilateH` 16 and `PS_DilateV` 16 samples a pixel with the gate off, and 30
for the vertical pass with it on — a figure neither the source nor the static count (51 and 71) shows.
§2's bound takes that to 8 + 8, §5's skipped centre step to 6 + 6, and §6's luma hand-off to 6 + 3.
§7's store fold hands the vertical pass one more back-buffer tap — the frame the store pass used to
read — taking the closing to 6 + 4, in exchange for a whole full-resolution pass.

## 2. The taps neither radius wants

Both loops ran `AUTOMASK_DILATE_MAX` either side whatever the sliders say, so at the default
**Mask grow radius 1** and **Isolation radius 1** the loop took seven taps where three carry either
term. A tap past both radii feeds neither: `inRange` is false, so the closing term is zero, and the
isolation count is gated on `abs(i) <= reach`, so that term is zero too.

Bounding each loop by `min(max(r, reach), AUTOMASK_DILATE_MAX)` cuts the closing roughly in half with
identical output — a tap outside both radii already contributed nothing. It costs a handful of static
instructions — the `max`, the `min` and the `ftoi` that reads the bound — for 3 taps at the defaults
against 7. The explicit `AUTOMASK_DILATE_MAX` term is not redundant: both sliders cap at 3, so it never
tightens the bound, and it is what keeps the loop tied to the constant rather than to the sliders alone.

## 3. The store's second render target

`PS_Store` and `PS_StoreFrame` were two full-resolution passes reading the same `BackBuffer`, one
multiplying by the mask and one copying to the history target. They are one pass now: `PS_Store`
returns the masked pixels and writes the untouched frame to `texAutoHistory` through a second
`SV_Target1`, so the pass count drops by one and a full-resolution back-buffer read goes with it. This
is the one merge a static count could not hide — `PS_StoreFrame` was a whole pass — and the only
change here a readback consumer could be sensitive to, since the accumulator's history read expects
the bytes the merge writes. The offline check parses `RenderTarget1` for it, so a second target a
later edit adds cannot hide from the wiring cross-check.

§7 then took the pass itself: the store target turned out to hold what the history already held, so
`PS_Store` and both its targets are gone and the closing writes the history.

## 4. Both back-edges, folded into the closing

`PS_Copy` carried `texAutoAccumB` back to `texAutoAccumA` so next frame's accumulator reads the state
this frame produced, and `PS_CopyDrift` did the same for the drift pair. Neither can be **deleted** — the
accumulator must read one side while writing the other, and ReShade runs one fixed pass list per frame,
so the read/write sides cannot alternate — but both can be **merged** into `PS_DilateH`, which is the
only full-resolution pass that already reads the accumulator: it takes the centre tap of
`texAutoAccumB` anyway, so writing that same value to `texAutoAccumA` as `SV_Target1` is the copy, at no
extra sample; and its read of `texAutoDriftB` for `SV_Target2` is the drift copy, which does cost one
read (no other pass reads the drift channel) but no longer a pass or a dispatch. Two full-resolution
passes go with them.

The two other readers of the live side, `PS_DebugMap` and `CS_Tile`, moved from `A` to `B` with the
accumulator's fold. The drift writer stays `AutoDriftStore` → `texAutoDriftB` and the reader stays
`AutoDriftA`, so the pair keeps its `A`-reads/`B`-writes convention.

The merge is only legal because the host samples a *different* texture than it writes: ReShade errors
`3020` on a pass that samples a texture it also uses as a render target, which is why the copies had to
be passes of their own and why they cannot fold into `PS_Store` (that pass already reads what the copies
write). The drift fold is behind `#if AutoMaskCompute == 1`, since the pixel path has no drift channel:
the shader has two `PS_DilateH` signatures under the guard, differing only by `SV_Target2`.

**Why the merge is trusted to bind.** Multi-target passes are first-class in ReShade, read from its own
source rather than inferred: `effect_parser_stmt.cpp` accepts `RenderTarget0`..`RenderTarget7`
(`state_name` starting `RenderTarget` with a `0`..`7` suffix), stores them by index in an 8-slot
`render_target_names`, and `runtime.cpp` binds each to an RTV and appends its format to the pipeline. So
`RenderTarget1` and `RenderTarget2` are honoured, not ignored. Two constraints come with it: every target
in a pass must share its dimensions, which holds (`BUFFER_WIDTH × BUFFER_HEIGHT` throughout), and
`SRGBWriteEnable` would require *every* target to be `RGBA8` — so it must stay **off** on this pass,
because it writes float formats (`texAutoAccumA`, `RG16F` under compute and `RGBA16F` otherwise, and
`texAutoDriftA`, `RGBA16F`; `docs/performance_compute.md` §3). ReShade defaults it to
false and the shader never sets it.

## 5. The loop's own centre step

Each closing loop still ran an `i = 0` step after the bound above, and every one of its contributions
was already in the centre tap the pass takes before the loop: at zero offset the sampled luma *is*
`lumaCentre`, so `AutoMaskEdgeKeep` returns `1`, and the neighbour *is* `centre`. So `nearby`,
`column`, `diagDown` and `diagUp` seed from `centre` directly and the loop `continue`s on `i == 0`:

- `PS_DilateH`: `nearby = step(0.5, centre.r)` before the loop, `if (i == 0) continue;` inside it.
- `PS_DilateV`: `nearby = centre.g * AUTOMASK_COUNT_SCALE`, `column = diagDown = diagUp = centre.b`,
  and the same skip. `mask` needs no seed, since `centre.r * 1` cannot exceed `mask`.

The centre step was one of the three offsets the bound leaves at the defaults, so skipping it drops the
closing from 16 samples a pixel to **12** (gate off) and from 22 to **16** (gate on). The `continue` and
the four seeds are the only static cost — a handful of slots on each pass — and the branch is on the
loop index, so it is uniform across the wavefront rather than divergent.

## 6. The luma both closings compute

`PS_DilateH` takes the centre luma to bound its own taps and publishes the centre verdict, so the
vertical pass can count a column and a diagonal off taps it already takes. It published neither the
luma at the centre nor the one at each loop offset, so `PS_DilateV` computed both a second time from
the frame — a back-buffer read per tap plus one at the centre, for a bound the pass next door had just
derived. Nothing but `PS_DilateV` samples `texAutoDilate`, and its `.a` was written as a constant `1.0`
and read by nobody, so the channel carries the luma instead: the horizontal pass stores `lumaCentre`
there, and the vertical pass reads `centre.a` and the `.a` of the `tex2D(AutoDilate, uv)` tap it already
takes. The closing drops from 12 samples a pixel to **9** with the gate off and from 16 to **13** with
it on; `PS_DilateH` 51 → 50 slots and `PS_DilateV` 71 → 67, with every other entry point's bytecode
unchanged — which is what pins the saving to the two closing passes.

The catch is the grid, and it is the reason the `.a` is a luma and not the raw colour. `texAutoDilate`
is `RGBA8`, while `AutoMaskEdgeKeep` compares `abs(luma - lumaCentre) * 255` against the integer
`AutoMaskEdge`. A tap whose edge lands within a level of that threshold can therefore read on the other
side of it, so the vertical pass's mask differs from the closing it replaces at those taps — by exactly
one level of the comparison, at a contour of the threshold's own width and no other. A closing exists to
absorb soft edges, and the closing radius itself is stepped in whole pixels, so a one-pixel disagreement
at one contour is inside the feature's own resolution rather than outside it. Carrying the luma
unquantized would remove even that, but needs a channel at least as precise as the luma's own 1/255
scale, and none is free — `texAutoAccumB`'s `.a` is the pinned-colour flag `PS_Motion` reads.

## 7. The store target, folded into the closing

`PS_Store` wrote the untouched frame to `texAutoHistory` and `frame.rgb * mask` to `texAutoFrame`, and
`PS_Restore` then did `lerp(live, stored, mask)`. The mask is binary, so at 1 that lerp returns `stored`
— which is `frame`, the multiply by one — and at 0 it returns `live` and `stored` is never read: the two
targets hold the same pixels. So the store target, and the map the closing published for it, both go:
`PS_DilateV` returns `float4(frame.rgb, mask)` into `texAutoHistory`, and the restore reads the frame
back off that alpha.

It has to be the vertical closing. Whichever pass writes the history must know the settled mask, and only
that pass does — so the frame and the mask go into one `float4` from one pass, rather than the frame from
`PS_DilateH` (which would leave the vertical pass sampling a target it writes, error `3020`). The
accumulator already read the history earlier in the frame, so it is safe to write there; only the rgb is
its comparison, and the alpha it now carries is why both accumulators read `.rgb`. `CS_Tile` moves to the
last pass to read the closing's output, and `PS_Store` and its dispatch are gone.

A full-resolution pass goes, and two full-resolution targets (`texAutoFrame`, `texAutoMap`) with it —
~29.4 MB of VRAM at 1440p — together with ~58.8 MB a frame of traffic: the store's read of the map and
write of the frame, the closing's write of the map, and the restore's two reads come off, while the
closing's own frame read and history write and the restore's single history read go on. The restore also
reads back one target fewer, the frame and the mask arriving in a single fetch. The check parses every
`RenderTarget`, so a target a later edit adds to a pass cannot hide from the wiring cross-check.

## 8. The closing's dead out-of-radius taps

The horizontal loop spans `min(max(r, reach), AUTOMASK_DILATE_MAX)` and sampled the frame once per offset
for that tap's luma. Every offset past the grow radius is dead to that sample: `AutoMaskEdgeKeep` returns
zero for it whatever the luma reads, so the fetch bought a bound that cannot apply. The sample is now
inside an `if (inRange)` — `keep` is 0 elsewhere, which is what the old `AutoMaskEdgeKeep` returned for
those offsets anyway, so the mask is identical. The branch is the loop index against a uniform radius,
so the wavefront stays agreed.

What it pays depends on the settings, and there are none at the shipped defaults: with the two radii
equal every offset of the span is within the grow radius, so the branch is taken throughout and the mask
already matched. It pays where the loop spans past `r` — **Mask grow radius 0** (a documented
pass-through), or isolation wider than growth — where the dead offsets' frame taps go. At grow 0 with the
default isolation the loop keeps its two accumulator taps and drops both frame taps, so `PS_DilateH`'s
loop goes from four samples a pixel to two; the price is 3 static slots, 50 → 53 at the defaults. It is
the one measurement here that changes no pass, target or sample at the settings most users run. Only
`PS_DilateH`'s bytecode moves; every other entry point is unchanged.

## 9. The depth store, folded into the closing

`PS_StoreDepth` was a full-resolution pass whose only job was to leave this frame's linearized depth for
the next frame's comparison, in a target of its own because the accumulator reads it earlier in the frame
and a pass cannot read what it writes. The closing pass already runs after that read, so the write is a
second render target on `PS_DilateV` under the same `AutoMaskDepthMotion` guard — the same shape as the
store fold in §7. One full-resolution pass and its dispatch go on the depth path; the target and its write
stay, so nothing is saved in bytes, only in the pass and its dispatch. It costs `PS_DilateV` four static
slots (68 → 72) and moves nothing else: only `PS_StoreDepth`'s removal and `PS_DilateV`'s bytecode change,
across the eight variants that compile the depth check in. The off path is untouched.

## 10. The drift store, re-centred into half precision

`texAutoDriftA`/`B` stored the long-baseline average outright, which forced `RGBA32F`: an average sits
wherever the pixel's colour sits, and the creep toward a one-level gap — 0.0083 levels a frame at the 2 s
default — is under an `RGBA16F` half-ulp above level 31 (0.0156 there, against 0.0078 in the band below),
so a half-precision average sat frozen rather than following the pixel. A frozen average failed both
ways: it could not accumulate a sub-level shift, so the channel did nothing on the bright half of a sky,
and it could not close on a static pixel either, so a pixel left a level away from it read as moving for
as long as it held (`docs/compute-path.md`).

The pair stores the average's **offset from the frame** instead — `drift - now` — and the average is
reconstructed by adding the frame back. Every stored value is then inside `AUTOMASK_DRIFT_LAG` deadbands
of zero, where the same half-ulp resolves the creep, so both targets are `RGBA16F` and the pair is half
the size: ~59 MB at 1440p against ~118 MB, and ~118 MB a frame of traffic against ~236 MB. No new data
is needed for the reconstruction. The base is the frame the offset was taken against, which is `now` in
`CS_Accum`, and the closing stores that same frame as the history's `.rgb` — so next frame's read takes
it from the `AutoHistory` tap it already makes and adds it to the offset it already reads. The closing's
back-edge needs nothing at all: the offset it carries from B to A is already taken against the frame it
is storing into the history, so the copy stays verbatim.

Only `CS_Accum`'s bytecode moves, and it costs 2 static slots — 194 → 196 without the depth check and
255 → 257 with it, across the four compute variants. `PS_DilateH`'s carry and every other entry point are
hash-identical. The reconstruction inherits the history's `RGBA8` half-level quantization, so a pixel
sitting exactly on the drift ramp's foot can land on the other side of it — the same order as the
one-level move `PS_DilateV`'s luma hand-off already makes (§6). That makes it arithmetic inside a
feedback loop rather than a format swap, so a game is what confirms the channel still reads as it did;
the offline check confirms it compiles and moves nothing else.

## 11. The depth-only mode's picture ramp

`AutoMaskDepthOnly` picked the world-drawn reading with a ternary inside the depth block:
`motion = AutoMaskDepthOnly ? AutoMaskDepthMoved(...) : max(motion, AutoMaskDepthMoved(...))`. fxc
flattens that small a body to a `movc` — it did so for a plain `if` as well — so the picture's own ramp
was built either way and discarded under the tick. Both accumulators now build it inside an explicit
`[branch] if (!AutoMaskDepthOnly)`, which is the one directive fxc honours as real flow control; the
`.asm` shows the ramp inside `if_z cb0[1].z`.

The cost is one static slot on each depth variant's accumulator, `PS_Accum` 151 → **152** and `CS_Accum`
256 → **257**, and the depth-off path is byte-identical: only the eight `*-depth` variants' two
accumulators move. What it buys is runtime rather than static, and only while the tick is on — the mode
`README.md` recommends where depth is available. Under it `PS_Accum` skips one `smoothstep` and its
`max` (7 instructions) and `CS_Accum` skips two `smoothstep` calls and two `max` (14), per pixel, in the
full-resolution pass that is already the heaviest on the compute path. With the tick off the branch is
taken and the ramp runs as before, trading the flattened `movc` for a branch — roughly neutral. The
condition is a uniform, so the whole wavefront takes one side and no divergence is introduced. Nothing
else in the block is skippable: `maxDiff` and `maxDrift` still feed `stable`, the next frame's average
and the histogram.

## 12. The measured step's fetch, branch-guarded

`deadband = AutoMaskAutoStep ? clamp(tex2Dlod(AutoStep, …).r, 1.0, 8.0) : AutoMaskDeadband()` selected
between the measured step and the slider, and fxc emitted the fetch ahead of the `movc` — so the 1×1
`texAutoStep` was sampled at every pixel of `CS_Accum` and thrown away whenever the toggle was off, which
is its default. It now builds `AutoMaskDeadband()` and refines it inside `[branch] if (AutoMaskAutoStep)`,
putting the fetch in `if_nz cb0[3].y` so the toggle-off path takes the `else` alone and issues no sample.

`CS_Accum` 196 → **198** and 257 → **259** with the depth check: two static slots for one fetch off every
pixel, the fetch being one of the six taps the accumulator took unconditionally. Only the four compute
variants' `CS_Accum` moves; the pixel path has no `AutoStep` to fetch, since the measured step is a
compute-path feature. It is the same shape as §11 — a uniform that selects rather than branches, and the
`[branch]` that makes it branch — and it is the last dead per-pixel tap on the compute path.

## 13. Openings left

- **The isolation gate's four taps a loop step — measured, and left.** The note this replaces proposed
  a flat 3×3 gathering "cheaper per tap". It is not available: the four counts are runs of `2·reach + 1`
  pixels *through* the pixel, and a 3×3 holds only the `reach = 1` case. At `Isolation radius 2` or `3`
  each run is 5 or 7 pixels long, so a 3×3 gather would be **wrong** rather than merely unprofitable,
  and the current form already reads each line once (the row tap doubles as the column tap). The gate's
  own addition is the two diagonal taps, and only while its checkbox is ticked: `AutoMaskIsolated` is a
  uniform, so off it compiles to an untaken `if_nz` and no sample is issued — at the defaults,
  `PS_DilateV` 4 → 8 samples a pixel when the gate is switched on. What the four runs already get for
  free is the box share and the column count, both read out of the one `texAutoDilate` tap per offset.
- **The accumulator's static footprint — arithmetic, not an opening.** `PS_Accum` (93, or 152 with the
  depth check) and `CS_Accum` (198, or 259) carry the pinned-colour count's four `eq` groups of three
  `and`s each. The count feeds `stable` and the changed/active tally, so it is computed on both paths
  whatever else changes; there is no cheaper form of it to fold into. `AutoMaskClipped` returning `int`
  rather than `float` is a separate, smaller pin with no cost either way: a `float` return reorders
  `iadd`/`itof` against `and`/`add` without changing the instruction count, so it is neither a saving nor
  a blocker — `docs/refactor-candidates.md` records it as type honesty plus a bytecode-stability choice
  made during a fold, not a performance decision.

Both are instruction-level and closed. The one opening left is the pixel-path drift question, a
full-resolution pass rather than an instruction, which `docs/performance-openings.md` §6 collects.
