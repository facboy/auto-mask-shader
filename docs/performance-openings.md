# Performance openings

What is left after `docs/performance.md`, whose §2–§9 are instruction-level or pass folds that landed,
whose §10 is the drift store's re-centring into half precision, whose §11 skips the picture ramp in
depth-only mode, whose §12 guards the measured step's fetch, whose §13 accounts the anti-bloom pass,
whose §14 guards the isolation gate's test behind its own checkbox, and whose §15 records the three
openings that are closed. §2–§5 below **have since landed** — §2 and §3 as that §7, §4 as that §8, §5 as
that §9 and §7 here as that §10 — and what they argued is the reasoning behind it. The one entry still
open is the pixel-path drift question, §6, the one proposal here that adds cost rather than removing it:
it asks which games the pixel path serves rather than what the frame can stop doing.

Companions: `docs/performance.md` (the cost already measured), `docs/refactor-candidates.md` (what a fold
has to clear — an unmoved hash for every entry point it does not touch), `docs/core-model.md` and
`docs/compute-path.md` (the pass and target counts these would change), `docs/review.md` §2.2 (the
redundancy §2 follows to its conclusion).

## 1. Where the frame's cost sits now

Seven passes and four full-resolution targets at the shipped defaults, five of the passes
full-resolution — the two reduce passes are the sub-resolution pair. At the check's 2560×1440:

| target | format | bytes |
| --- | --- | --- |
| `texAutoAccumA`, `texAutoAccumB` | `RGBA16F` | 29.5 MB each |
| `texAutoHistory`, `texAutoDilate` | `RGBA8` | 14.7 MB each |

88 MB allocated, and every full-resolution pass is at least one read and one write of a target that size,
so the defaults move on the order of 300 MB a frame. §2 and §3 took two targets and four full-resolution
target touches; the openings below are smaller again.

The pair here is the **pixel default's** `RGBA16F`. Under compute `texAutoAccumA` is `RG16F`
(`docs/performance_compute.md` §3), half those bytes for that target; `texAutoAccumB` stays `RGBA16F`
because `tex2Dstore` has no two-component form to narrow its store to.

## 2. Landed: the store target held what the history already holds

`PS_Store` wrote the untouched frame to `texAutoHistory` and `frame.rgb * mask` to `texAutoFrame`;
`PS_Restore` then returned `lerp(live, stored, mask)`. The mask is exactly 0 or 1, so at 1 the lerp
returned `stored` — which is `frame`, the multiply by one — and at 0 it returned `live` and `stored` was
never read. The multiply's only stated value (`docs/review.md` §2.2) was that the target then isolates
the UI for a debug inspection. `texAutoHistory` already held this frame's untouched frame when the
restore ran, so the restore can read the frame there and `texAutoFrame` goes with the multiply — which
holds only once the history is written by a pass that also knows the final mask, which is §3.
`docs/performance.md` §7 is the landed account.

## 3. Landed: the mask rides the history's alpha

Nothing read `texAutoHistory`'s `.a`, and both accumulators take `.rgb`, so the channel was free at both
ends of the frame. That makes `texAutoMap` removable as well: the pass publishing the mask writes it into
the history's alpha beside the frame it is already storing, and `AutoMaskPublished` reads
`step(0.5, …a)`. The three readers — `PS_AntiBloom`, `PS_Restore`, `CS_Tile` — take the mask out of a
target they touch for the frame or for a neighbouring reading, and `PS_Restore` drops from three
full-resolution samples to two.

**The two folds are one pass.** Whichever pass stores the frame must know the final mask, and only the
vertical closing does: the horizontal pass's `.b` is a centre verdict the growth has not finished with.
A pass cannot read a target it writes, so frame and mask go into the history in one `float4` from
`PS_DilateV`, which takes a back-buffer tap the store took, and `PS_Store` and its dispatch go with it.
`PS_DilateH` cannot host the frame half alone: the vertical pass would then have to read the history to
keep the rgb it did not write, and a pass may not sample what it writes (`3020`).

Five full-resolution target touches a frame came off — the store's read of the map and write of the
frame, the closing's write of the map, and the restore's two reads — and one went on, the restore's read
of the history, which now carries both. Net 58.8 MB a frame at 1440p, with the `texAutoFrame` and
`texAutoMap` targets and the `PS_Store` pass; the defaults fell to four full-resolution targets and five
full-resolution passes. Multi-target passes are trusted to bind (`docs/performance.md` §4) and the
mixed-format constraint it names holds: the history and `texAutoDilate` are both `RGBA8`, and
`SRGBWriteEnable` stays off. The accumulator's history read is unaffected — the same bytes from the same
target, written later in the frame — and sampling lands on texel centres, so the alpha the restore reads
is the mask and not a blend of it.

## 4. Landed: the closing's out-of-radius luma fetches

The horizontal loop spanned `min(max(r, reach), AUTOMASK_DILATE_MAX)` and sampled the frame once per
offset for that tap's luma, but every offset past the grow radius is dead to that sample: `AutoMaskEdgeKeep`
returned zero for it whatever the luma read. At **Mask grow radius 0** that was two dead frame taps a
pixel at the default isolation radius, and four at grow 1 with isolation 3. Guarding the sample on
`inRange` leaves the accumulator read, which is the isolation count, and drops only the frame one.
`docs/performance.md` §8 is the landed account: only `PS_DilateH`'s bytecode moves, and the mask is
identical because `keep` was already zero there. The branch is the loop index against a uniform radius,
so it is uniform across the wavefront and costs nothing at the shipped defaults, where the two radii are
equal.

## 5. Landed: the depth store folded into the closing

`PS_StoreDepth` existed because the accumulator reads `texAutoDepth` for the previous frame and a pass
cannot read what it writes, so this frame's depth needed a writer later in the frame. It sampled the
depth buffer and wrote one `R32F` target at full resolution. The closing runs after the accumulator's
read and now hosts that write as a second render target under the same `AutoMaskDepthMotion` guard: one
full-resolution pass and its dispatch go on the depth path, but not the bytes — the target still has to
be written, or the accumulator compares a stale depth. It saves nothing at all with the switch off, where
the guard compiles the second target and the store out together. `docs/performance.md` §9 is the landed
account; only `PS_DilateV` moves and `PS_StoreDepth` is gone, across the eight variants that compile the
depth check in.

## 6. Not a saving: the drift channel on the pixel path

`docs/compute-path.md` calls the drift channel the reading the pixel path "has nowhere to put and
deliberately does not carry", and `README.md` sells it with the compute switch. Whether to mirror it into
`PS_Accum` anyway is the one question here that is not about bytes saved: a title that presents a D3D9 or
D3D10 device, or a D3D11 one below feature level 11_0, runs ReShade and its `ps_4_0` effects but has no
compute pass at all, so the switch buys nothing there and the pixel path is the only route to a feature
the README advertises. Left for now: build it when a game like that turns up, with the scene in hand to
judge it against.

Mechanically it is among the smallest changes here. `PS_Accum` takes a second render target,
`texAutoDriftB`, `PS_DilateH`'s guarded signature loses the guard for the drift back-edge it already
carries on the compute path, the two targets move out of the compute block into the shared declarations,
and the verdict grows `maxDrift < deadband`. Nothing about it needs compute.

What it costs is the largest number in this document, and it is why the entry is here at all. The pair is
half precision now (§7 landed), so these are the half-size figures:

| | added |
| --- | --- |
| `memory` | 59 MB — two `RGBA16F` full-resolution targets at 1440p |
| `traffic` | ~118 MB a frame: the accumulator and the closing each read and write the pair |

Two thirds again the memory of the whole default path, on the oldest renderers the shader runs under.
Behind its own definition the feature would cost nothing when off, so this is not a trade against the
default path but a question about who pays. Two things decide it, and neither is settled by the code:

- **Whether the title can serve the target.** A D3D9 or D3D10 device is where the guarantees about float
  render targets and about multi-target passes are thinnest. The default path already writes `RGBA16F`
  beside `RGBA8` on the closing pass, and the drift pair is `RGBA16F` too now that §7 has landed, so a
  mixed-format pass is not new — but the offline check compiles at `ps_5_0` and never sees a device.
- **The deferral's figure was low by one target.** The compute plan expected a pixel mirror to ride two
  `RGBA16F` targets, "~28 MB at 1440p" — half of what that pair actually costs, since a `RGBA16F` texel
  is eight bytes. Use the 59 MB above.

When it is built the shape is a third structural definition owning the two targets, since a feature with
targets to its name gets a definition rather than a checkbox — and the store it carries is the
re-centred one §7 landed.

## 7. Landed: the drift store, re-centred into half precision

The channel shipped storing the average itself, which forced `RGBA32F`: an average sits wherever the
pixel's colour sits, and the creep toward a one-level gap — 0.0083 levels a frame at the 2 s default — is
under an `RGBA16F` half-ulp above level 31, so a half-precision average sat frozen rather than following
the pixel. The re-centring is built: store `drift - now` inside `AUTOMASK_DRIFT_LAG` deadbands of zero,
and add the frame back on the read. Both targets are `RGBA16F` and the pair is half the size, ~59 MB and
~118 MB a frame against ~118 MB and ~236 MB. `docs/performance.md` §10 is the landed account, and the
saving stands on its own rather than as §6's enabler.

## 8. Refused

- **The pixel path's two reduce passes.** `PS_Motion` (16×16, four taps a texel) then `PS_MotionAvg`
  (1×1, 256 taps) is the shape the pixel path uses because it has no atomics — the tally `CS_Accum`
  carries in `groupshared`. Collapsing the pair into one 1×1 pass would take the coarse stage's 1,024
  taps into a single invocation, or drop to one tap a cell and measure a different statistic; neither is
  cheaper in a way that matters, since the pair costs 1,280 taps a frame against a full-resolution pass's
  millions.
- **The two back-edges.** `docs/performance.md` §4: one side of the accumulator's pair must be read while
  the other is written, and the fixed pass list cannot alternate them.
- **The isolation gate's four taps a loop step, and the accumulator's static footprint.**
  `docs/performance.md` §15: the first is wrong at radius 2 or 3 as a flat gather, so there is no cheaper
  form of the same count; the second is arithmetic the verdict needs, not a saving.
- **`PS_AntiBloom` folded into the closing.** The blacking has to land after the pass that reads the
  frame the history is stored from, and a pass that names render targets does not write the back buffer.
  The pass ships on by default, so it is accounted rather than saved: `docs/performance.md` §13.
- **The diagnostics map's own pass and target — refused on the wrong basis, reopened.** It was refused as
  "a definition, off at rest, so a collapse buys nothing while it is off", which weighs the default
  setting rather than the on-build. ReShade exposes `AutoMaskDiagnostics` in the UI, so the on-build is a
  shipped variant and pays its pass and target every frame; `docs/performance_diagnostics.md` is the
  account, and §3 there is the fold this entry left on the table.
