# Performance openings

What is left after `docs/performance.md`, whose §2–§9 are instruction-level or pass folds that landed,
and whose §10 records the two openings that are closed. §2–§5 below **have since landed** — §2 and §3 as
that §7 (the store target and the published map gone, the closing writing the frame with the mask in its
alpha), §4 as that §8 (the closing's dead out-of-radius frame taps guarded) and §5 as that §9 (the depth
store folded into the closing) — and what they argued is kept as the reasoning behind it. Two entries are
still open. The pixel-path drift channel, §6, is the one proposal here that adds cost rather than removing
it: it asks which games the pixel path serves rather than what the frame can stop doing. The drift store's
re-centring, §7, is a saving on the channel the compute path already ships. Neither is built and neither
has been in a game, so each names what it would cost or save and what would have to be watched to accept
it.

Companions: `docs/performance.md` (the cost already measured, and §10's two closed items),
`docs/refactor-candidates.md` (what a fold has to clear — an unmoved hash for every entry point it does
not touch), `docs/core-model.md` and `docs/compute-path.md` (the pass and target counts these would
change), `docs/review.md` §2.2 (the redundancy §2 follows to its conclusion).

## 1. Where the frame's cost sits now

Seven passes and four full-resolution targets at the shipped defaults, five of the passes
full-resolution — the two reduce passes are the sub-resolution pair. At the check's 2560×1440:

| target | format | bytes |
| --- | --- | --- |
| `texAutoAccumA`, `texAutoAccumB` | `RGBA16F` | 29.5 MB each |
| `texAutoHistory`, `texAutoDilate` | `RGBA8` | 14.7 MB each |

88 MB allocated, and every full-resolution pass is at least one read and one write of a target that
size, so the defaults move on the order of 300 MB a frame. §2 and §3 took two targets and four
full-resolution target touches; the openings below are smaller again than that.

## 2. Landed: the store target held what the history already holds

`PS_Store` wrote the untouched frame to `texAutoHistory` and `frame.rgb * mask` to `texAutoFrame`;
`PS_Restore` then returned `lerp(live, stored, mask)`. `mask` is `AutoMaskPublished`, exactly 0 or 1, so
at 1 the lerp returned `stored` — which is `frame`, the multiply by one — and at 0 it returned `live` and
`stored` was never read. Both forms are the same expression, and the multiply's only stated value
(`docs/review.md` §2.2) was that the target then isolates the UI for a debug inspection.

`texAutoHistory` already held this frame's untouched frame when the restore ran: the accumulator reads
the previous frame out of it early in the technique and `PS_Store` wrote this one back. So the restore
can read the frame there and `texAutoFrame` goes with the multiply — which holds only once the history
is written by a pass that also knows the final mask, which is §3. Both are gone; `docs/performance.md`
§7 is the landed account.

## 3. Landed: the mask rides the history's alpha

Nothing read `texAutoHistory`'s `.a`. Both accumulators take `.rgb` — `tex2Dlod(AutoHistory, …).rgb` in
`CS_Accum`, `tex2D(AutoHistory, …).rgb` in `PS_Accum` — and the frame is written there at full
resolution anyway, so the channel is free at both ends of the frame.

That makes `texAutoMap` removable as well: the pass publishing the mask writes it into the history's
alpha beside the frame it is already storing, and `AutoMaskPublished` reads `step(0.5, …a)` instead of
`step(0.5, …r)`. The three readers — `PS_AntiBloom`, `PS_Restore`, `CS_Tile` — take the mask out of a
target they touch for the frame or for a neighbouring reading, and `PS_Restore` drops from three
full-resolution samples to two.

**The two folds are one pass.** Whichever pass stores the frame must know the final mask, and only the
vertical closing does: the horizontal pass's `.b` is a centre verdict the growth has not finished with.
A pass cannot read a target it writes, so frame and mask go into the history in one `float4` from one
pass — `PS_DilateV`, which takes a back-buffer tap the store took, returns `float4(frame.rgb, mask)` into
`texAutoHistory`, and `PS_Store` and its dispatch go with it. `PS_DilateH` cannot host the frame half
alone: the vertical pass would then have to read the history to keep the rgb it did not write, and a pass
may not sample what it writes (`3020`).

Five full-resolution target touches a frame came off — the store's read of the map and write of the
frame, the closing's write of the map, and the restore's two reads — and one went on, the restore's read
of the history, which now carries both. Net 58.8 MB a frame at 1440p, with the `texAutoFrame` and
`texAutoMap` targets and the `PS_Store` pass; the defaults fell to four full-resolution targets and five
full-resolution passes.

Multi-target passes are already trusted to bind (`docs/performance.md` §4), and the mixed-format
constraint it names holds: `texAutoHistory` and `texAutoDilate` are both `RGBA8`, and `SRGBWriteEnable`
stays off. The accumulator's history read is unaffected — it is the same bytes from the same target,
written at a later point in the frame — and sampling lands on texel centres, so the alpha the restore
reads is the mask and not a blend of it.

## 4. Landed: the closing's out-of-radius luma fetches

The horizontal loop spans `min(max(r, reach), AUTOMASK_DILATE_MAX)` and sampled the frame once per offset
for that tap's luma. Every offset past the grow radius is dead to that sample: `AutoMaskEdgeKeep` returned
zero for it whatever the luma read, so the fetch was paid for a bound that could not apply. At **Mask grow
radius 0** — the documented pass-through — that was two dead frame taps a pixel at the default isolation
radius, and four at grow 1 with isolation 3, since the loop spans the larger radius and only the isolation
count reads those taps. Guarding the sample on `inRange` leaves the accumulator read, which is the count,
and drops only the frame one. `docs/performance.md` §8 is the landed account: only `PS_DilateH`'s bytecode
moves, and the mask is identical because `keep` was already zero there.

The branch is the loop index against a uniform radius, so it is uniform across the wavefront and costs
nothing at the shipped defaults, where the two radii are equal and every offset is in range. It was the
cheapest entry here, and the only one that paid only at some settings rather than at all of them.

## 5. Landed: the depth store folded into the closing

`PS_StoreDepth` existed because the accumulator reads `texAutoDepth` for the previous frame and a pass
cannot read what it writes, so this frame's depth needed a writer later in the frame. It sampled the depth
buffer and wrote one `R32F` target at full resolution. The closing pass runs after the accumulator's read
and now hosts that write as a second render target under the same `AutoMaskDepthMotion` guard: one
full-resolution pass and its dispatch go on the depth path. The bytes do not — the target still has to be
written, or the accumulator compares a stale depth — so what this saves is a pass, not traffic, and it
saves nothing at all with the switch off, where the guard compiles the second target and the store out
together. `docs/performance.md` §9 is the landed account; only `PS_DilateV` moves and `PS_StoreDepth` is
gone, across the eight variants that compile the depth check in.

## 6. Not a saving: the drift channel on the pixel path

`docs/compute-path.md` calls the drift channel the reading "the pixel path has nowhere to put and
deliberately does not carry", and `README.md` sells it with the switch. Whether to mirror it into
`PS_Accum` anyway is the one question here that is not about bytes saved: it is about the games the
switch cannot reach. A title that presents a D3D9 or D3D10 device, or a D3D11 one below feature level
11_0, runs ReShade and its `ps_4_0` effects but has no compute pass at all, so the switch buys nothing
there and the pixel path is the only route to a feature the README advertises.

Left for now: build it when a game like that turns up, with the scene in hand to judge it against. The
shape below is what that delivery would take, and §7 is the store form it should carry, so the start is a
decision about the scene rather than about the arithmetic.

Mechanically it is among the smallest changes here, and the design anticipated it. The compute plan puts
a pixel-side mirror out of the first version's scope and calls it "a small mechanical lift, not a
redesign": `PS_Accum` takes a second render target, `texAutoDriftB`, `PS_DilateH`'s guarded signature
loses the guard for the drift back-edge it already carries on the compute path, the two targets move out
of the compute block into the shared declarations, and the verdict grows `maxDrift < deadband`. Nothing
about it needs compute.

What it costs is the largest number in this document, and it is why the entry is here at all:

| | added |
| --- | --- |
| `memory` | 118 MB — two `RGBA32F` full-resolution targets at 1440p |
| `traffic` | ~236 MB a frame: the accumulator and the closing each read and write the pair |

More than half again the whole rest of the default path, and it lands on the oldest renderers the shader
runs under rather than on old hardware — the driver is a title that only ever presents a D3D9 or D3D10
device. Behind its own definition the feature would cost nothing when off, so this is not a trade
against the default path but a question about who pays.

Two things decide it, and neither is settled by the code:

- **Whether the title can serve the target.** The channel stores `RGBA32F` because half precision
  freezes it (`docs/compute-path.md`), and a D3D9 or D3D10 device is where the guarantees about float
  render targets and about multi-target passes are thinnest. The default path already writes `RGBA16F`
  beside `RGBA8` on the closing pass, so a mixed-format pass is not new — an `RGBA32F` member of that set
  is — and the offline check compiles at `ps_5_0` and never sees a device.
- **The deferral was costed at a number that no longer holds.** The compute plan expects a pixel mirror
  to ride two `RGBA16F` targets, "~28 MB at 1440p" — which is half of what that pair actually costs
  (a `RGBA16F` texel is eight bytes, so the pair is ~59 MB; the plan's figure is one target's worth). The
  shipped channel is `RGBA32F`, ~118 MB at the same size, because at the 2 s default the creep is 0.0083
  levels a frame against a half-ulp above level 31 of 0.0156, so a half-precision average sits frozen
  rather than following the pixel. A mirror of what shipped is therefore twice the deferred format's true
  size, and four times the figure the deferral wrote.
- **Whether the mirror carries the shipped store or §7's re-centred one.** Storing `drift - now` puts
  the pair on the half-precision format §7 measures for the shipped channel, so it is the only version of
  this entry that suits the renderers in question — a mirror of the shipped `RGBA32F` store is twice the
  deferred format's true size — and the version worth measuring first.

So the answer waits on a game rather than on the arithmetic: build it when a title like that is in hand,
with the scene to judge the added reading against. When it is built the shape is a third structural
definition owning the two targets, since a feature with targets to its name gets a definition rather
than a checkbox — and §7's re-centred form is what it should carry.

## 7. Saving: the drift store, re-centred into half precision

The shipped channel stores the average itself, so a pixel's value sits wherever its colour sits and the
store must be `RGBA32F`: at the 2 s default the creep toward a one-level gap is 0.0083 levels a frame,
under a half-ulp above level 31, so a half-precision average sits frozen rather than following the pixel
(`docs/compute-path.md`). Storing `drift - now` instead puts every stored value inside
`AUTOMASK_DRIFT_LAG` deadbands of zero — the reach the average is already held in — where half precision
holds ample relative precision. The pair the compute path ships halves with it: ~118 MB to ~59 MB of VRAM
at 1440p, and ~236 MB to ~118 MB a frame, since the store's write and the closing's read-and-write each
halve, 32 to 16 bytes a pixel.

It needs no new data, and it adds the reconstruction to one read. The base a delta is taken against is the
frame itself: the accumulator's `before` is `AutoHistory`'s `.rgb`, which the closing stored as the frame
it was drawn over (`PS_DilateV`'s return) — so the value `drift - now` subtracted is the same one next
frame's read adds back, `drift = A.rgb + before`. The closing's carry needs no arithmetic at all: the
delta it moves from B to A is already re-centred on the frame it is storing into the history, so it stays
a verbatim copy. The clip rails move onto the reconstructed value, exact where they matter: a pixel pinned
at 0 or 1 adds back the frame that was taken away and reads 0 or 1 again, while a rail the clamp reaches
with the frame merely near zero lands near it.

It is not a format swap. The reconstruction inherits the history's own `RGBA8` half-level quantization, so
a pixel sitting exactly on the drift ramp's foot can flip — the same order as the one-level move
`PS_DilateV`'s luma hand-off already makes (`docs/performance.md` §6). That makes it arithmetic inside a
feedback loop rather than a port, so it needs the measured proof the 32-bit store needed, with a scene in
hand; an offline compile cannot see it happen. Unlike §6 it changes the path that ships rather than a path
nobody runs, which is what puts it first.

## 8. Refused

- **The pixel path's two reduce passes.** `PS_Motion` (16×16, four taps a texel) then `PS_MotionAvg`
  (1×1, 256 taps) is the shape the pixel path uses because it has no atomics — the tally `CS_Accum`
  carries in `groupshared`. Collapsing the pair into one 1×1 pass would take the coarse stage's 1,024
  taps into a single invocation, or drop to one tap a cell and measure a different statistic; neither
  is cheaper in a way that matters, since the pair costs 1,280 taps a frame against a full-resolution
  pass's millions.
- **The two back-edges.** `docs/performance.md` §4: one side of the accumulator's pair must be read while
  the other is written, and the fixed pass list cannot alternate them.
- **The isolation gate's four taps a loop step, and the accumulator's static footprint.**
  `docs/performance.md` §8: the first is wrong at radius 2 or 3 as a flat gather, the second is a
  recorded hash-stability decision.
- **`PS_AntiBloom` folded into the closing.** The blacking has to land after the pass that reads the
  frame the history is stored from, and a pass that names render targets does not write the back
  buffer — which is what every pass here that names one relies on.
- **The diagnostics map's own pass and target.** A definition, off at rest, so a collapse buys nothing
  while it is off.
