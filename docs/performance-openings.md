# Performance openings

What is left after `docs/performance.md`, whose §2–§6 are instruction-level and landed, and whose §7
records the two openings that are closed. What remains is **traffic**: the full-resolution passes and
targets the frame still moves where it does not have to. Nothing here is built and none of it has been
in a game, so each entry names what it would save and what would have to be watched to accept it.

Companions: `docs/performance.md` (the cost already measured, and §7's two closed items),
`docs/refactor-candidates.md` (what a fold has to clear — an unmoved hash for every entry point it does
not touch), `docs/core-model.md` and `docs/compute-path.md` (the pass and target counts these would
change), `docs/review.md` §2.2 (the redundancy the lead below follows to its conclusion).

## 1. Where the frame's cost sits now

Eight passes and six full-resolution targets at the shipped defaults, of which six passes are
full-resolution — the two reduce passes are the sub-resolution pair. At the check's 2560×1440:

| target | format | bytes |
| --- | --- | --- |
| `texAutoAccumA`, `texAutoAccumB` | `RGBA16F` | 29.5 MB each |
| `texAutoHistory`, `texAutoFrame`, `texAutoDilate`, `texAutoMap` | `RGBA8` | 14.7 MB each |

118 MB allocated, and every full-resolution pass is at least one read and one write of a target that
size, so the defaults move on the order of 400 MB a frame. The savings §2–§6 took are real and small
against that; what is open is the target and pass count itself.

## 2. The store target holds what the history already holds

`PS_Store` writes the untouched frame to `texAutoHistory` and `frame.rgb * mask` to `texAutoFrame`;
`PS_Restore` then returns `lerp(live, stored, mask)`. `mask` is `AutoMaskPublished`, exactly 0 or 1, so
at 1 the lerp returns `stored` — which is `frame`, the multiply by one — and at 0 it returns `live` and
`stored` is never read. Both forms are the same expression, and the multiply's only stated value
(`docs/review.md` §2.2) is that the target then isolates the UI for a debug inspection.

`texAutoHistory` already holds this frame's untouched frame when the restore runs: the accumulator reads
the previous frame out of it early in the technique and `PS_Store` writes this one back. So the restore
can read the frame there and `texAutoFrame` goes with the multiply — which holds only once the history
is written by a pass that also knows the final mask, which is §3.

## 3. The mask rides the history's alpha

Nothing reads `texAutoHistory`'s `.a`. Both accumulators take `.rgb` — `tex2Dlod(AutoHistory, …).rgb` in
`CS_Accum`, `tex2D(AutoHistory, …).rgb` in `PS_Accum` — and the frame is written there at full
resolution anyway, so the channel is free at both ends of the frame.

That makes `texAutoMap` removable as well: the pass publishing the mask can write it into the history's
alpha beside the frame it is already storing, and `AutoMaskPublished` reads `step(0.5, …a)` instead of
`step(0.5, …r)`. The three readers — `PS_AntiBloom`, `PS_Restore`, `CS_Tile` — then take the mask out of
a target they touch for the frame or for a neighbouring reading, and `PS_Restore` drops from three
full-resolution samples to two.

**The two folds are one pass.** Whichever pass stores the frame must know the final mask, and only the
vertical closing does: the horizontal pass's `.b` is a centre verdict the growth has not finished with.
A pass cannot read a target it writes, so frame and mask have to go into the history in one `float4` from
one pass — `PS_DilateV`, which takes a back-buffer tap the store took, returns `float4(frame.rgb, mask)`
into `texAutoHistory`, and `PS_Store` and its dispatch go with it. `PS_DilateH` cannot host the frame half
alone: the vertical pass would then have to read the history to keep the rgb it did not write, and a pass
may not sample what it writes (`3020`).

Five full-resolution target touches a frame come off — the store's read of the map and write of the
frame, the closing's write of the map, and the restore's two reads — and one goes on, the restore's read
of the history, which now carries both. Net 58.8 MB a frame at 1440p, with the `texAutoFrame` and
`texAutoMap` targets and the `PS_Store` pass; the defaults fall to four full-resolution targets and five
full-resolution passes.

Multi-target passes are already trusted to bind (`docs/performance.md` §4), and the mixed-format
constraint it names holds: `texAutoHistory` and `texAutoDilate` are both `RGBA8`, and `SRGBWriteEnable`
stays off. The accumulator's history read is unaffected — it is the same bytes from the same target,
written at a different point in the frame — and sampling lands on texel centres, so the alpha the restore
reads is the mask and not a blend of it.

## 4. The closing's out-of-radius luma fetches

The horizontal loop spans `min(max(r, reach), AUTOMASK_DILATE_MAX)` and samples the frame once per offset
for that tap's luma. Every offset past the grow radius is dead to that sample: `AutoMaskEdgeKeep` returns
zero for it whatever the luma reads, so the fetch is paid for a bound that cannot apply. At **Mask grow
radius 0** — the documented pass-through — that is two dead frame taps a pixel at the default isolation
radius, and at grow 1 with isolation 3 it is four, since the loop spans the larger radius and only the
isolation count reads those taps. Guarding the sample on `inRange` leaves the accumulator read, which is
the count, and drops only the frame one.

The branch is the loop index against a uniform radius, so it is uniform across the wavefront and costs
nothing at the shipped defaults, where the two radii are equal and every offset is in range. It is the
cheapest of these three, and the only one that pays only at some settings rather than at all of them.

## 5. The depth store, folded

`PS_StoreDepth` exists because the accumulator reads `texAutoDepth` for the previous frame and a pass
cannot read what it writes, so this frame's depth needs a writer later in the frame. It samples the depth
buffer and writes one `R32F` target at full resolution. The closing pass runs after the accumulator's
read and can host that write as a third target under the same `AutoMaskDepthMotion` guard: one
full-resolution pass and its dispatch go on the depth path. The bytes do not — the target still has to be
written, or the accumulator compares a stale depth — so what this saves is a pass, not traffic, and it
saves nothing at all with the switch off. The compute path does not avoid the pass either: `CS_Accum` is
the pass that reads the depth it would have to write, and a storage object cannot be read and written in
one dispatch.

## 6. Refused

- **The pixel path's two reduce passes.** `PS_Motion` (16×16, four taps a texel) then `PS_MotionAvg`
  (1×1, 256 taps) is the shape the pixel path uses because it has no atomics — the tally `CS_Accum`
  carries in `groupshared`. Collapsing the pair into one 1×1 pass would take the coarse stage's 1,024 taps
  into a single invocation, or drop to one tap a cell and measure a different statistic; neither is
  cheaper in a way that matters, since the pair costs 1,280 taps a frame against a full-resolution pass's
  millions.
- **The two back-edges.** `docs/performance.md` §4: one side of the accumulator's pair must be read while
  the other is written, and the fixed pass list cannot alternate them.
- **The isolation gate's four taps a loop step, and the accumulator's static footprint.**
  `docs/performance.md` §7: the first is wrong at radius 2 or 3 as a flat gather, the second is a recorded
  hash-stability decision.
- **`PS_AntiBloom` folded into the closing.** The blacking has to land after the store, and a pass that
  names render targets does not write the back buffer — which is what every pass here that names one
  relies on.
- **The diagnostics map's own pass and target.** A definition, off at rest, so a collapse buys nothing
  while it is off.
