# Options for isolating UI elements, without depth

## 1. Scope and standing

What element-level isolation could do better, given that the depth buffer is not available. This is a
list of **options, not a plan**: nothing here is scoped, approved or implemented, and nothing here is
verified. §6's instrument is what decides between them, and it does not exist yet either.

Companions: `docs/core-model.md` (the verdict the isolation rides on), `docs/compute-path.md` (the
compute path most of this would live in), `docs/optical-flow.md` (the one instrument already built,
watched and removed — the precedent for how to try one).

## 2. What is available, and what is not

Depth is the cue that makes this problem easy: interface sits at its own depth, so a depth discontinuity
— or, with motion vectors, a *disparity* between neighbouring pixels' motion — draws the element's
contour for free. Without it, every cue has to come out of the composited picture. Three are already
spent:

| cue | where it is used | what it decides |
| --- | --- | --- |
| temporal coherence | the accumulator | the per-pixel verdict |
| image structure | the luma step in `PS_DilateH`/`PS_DilateV` (`AutoMaskEdge`) | only where the growth stops |
| spatial coherence on the verdict | the isolation gate, riding in `texAutoDilate` | whether a claimed pixel is kept |

The unused axis is the fourth: **coherence of change events over space**. The verdict judges a pixel;
nothing judges a *region*. That is where element-level isolation lags, and every proposal below that is
worth its cost is an attempt to give the shader a region to reason about.

## 3. Where isolation actually fails today

Named against the code, because a proposal is only worth its cost if it closes one of these. Referred to
below as §3.1 to §3.4.

1. **Thin interface is eroded by the gate's box count.** `PS_DilateV` keeps a pixel while
   `nearby >= AutoMaskDensity * 0.01 * side * side`. A line of width `n` fills `n / side` of the box, so
   a wider `AutoMaskIsolation` costs exactly the elements with the least evidence. `README.md` lists it
   under what the shader cannot do, and `docs/core-model.md` calls it the one consequence to know. It is
   a consequence of the *square box*, not of the idea.
2. **Interior holes.** An element whose insides animate — a draining bar, a spinner, scrolling text —
   loses those pixels from the verdict, so bloom and every effect in the middle see them. The outside
   contour is protected; the interior is not.
3. **A panel opening over an already-paused world.** Caught only if the opening lifts the *screen-wide*
   reading past `AutoMaskMotion`. A global test is being asked a local question.
4. **The camera-tethered character** is handled by a hand-placed ellipse
   (`AutoMaskDeadzoneWidth`/`Height`/`Y`) — a region set by eye where a measured one ought to be.

## 4. Avenues already closed

- **Image-based optical flow.** Built, watched in a real game, and removed; `docs/optical-flow.md` §6.2
  carries the negative result and its §3 and §5 the reasons — a sub-pixel-per-frame drift sits under any
  whole-pixel search floor, and a vector is not the same question as "is this HUD". The drift channel
  answers the same question per pixel, at full resolution, with no search, so a proposal that reopens this
  has to answer that loop failure first.
- **Depth.** Confirmed unavailable.
- **Per-element identity.** `docs/core-model.md` accepts conflating health with inventory by design.
  Nothing below asks for a label per element. Pooling evidence over the region that *is* the element is
  a weaker and more useful goal than naming it.

## 5. The options

### 5.1 A region test instead of the box share

The gate's question is "does this pixel belong to something with substance, or is it a speck?" A square
box answers a proxy. Two better-shaped tests:

**Two directional densities, one per axis.** Ask the same substance question of one axis at a time: keep
a pixel while *either* its row or its column clears a floor. A line along either axis fills its own row or
column along its whole length, so it survives; a speck fills neither, because it is one pixel in both. Both
counts are already available at no extra cost: the row count is `PS_DilateH`'s `nearby`, and the vertical
pass can sum the centre verdicts down the column instead of the row counts across it — `texAutoDilate`'s
`.b` is written as a copy of the grown mask and read by nothing, so pointing it at the centre verdict
(`step(0.5, centre)`) gives `PS_DilateV` the column count from the tap it already takes. Same targets, same
two passes, no new tap.

*The floor cannot be `AutoMaskDensity`.* That number is a share of the **box**, and one axis is not the box:
the density allows `0.01 × AutoMaskDensity × side²` still pixels, while a row holds only `side`. At the `33`
default and radius 1 that is 2.97 of the row's 3 pixels, and above radius 1 it comes to more still pixels
than the row has — 8.25 against 5 at radius 2, 16.17 against 7 at radius 3 — so no pixel could ever clear
it. An axis test needs a threshold that is a share of *that axis*, and **half of it** is the natural one: at
every radius it sits between a speck (`1/side`, at most one third, since the smallest box is 3 across) and
a line filling its own axis (`1`).

*Limitation, and it is decisive for thin elements:* a 45° one-pixel line has exactly one pixel in every row
and every column it crosses, so both its shares are `1/side` and it fails the same test a speck fails.
Axis-aligned lines are fixed; diagonals are not — and a shallow diagonal only partly so, since it fills more
of a row than of a column. That is why this is the cheap half of the pair rather than the answer.

**Connected-component area.** Keep a masked pixel while its connected component on the verdict holds at
least a minimum area. That is the criterion `docs/definitions.md` describes wanting — it already notes the
gate is *not* a plain morphology — and it is line-preserving by construction, in any orientation, because
a line is connected and a speck is not. Full-resolution labelling in HLSL is awkward, so scope it:

- **Quarter resolution**, where components are large by definition. The reduction must be a **max** over
  the block, not an average, or a 1-px line vanishes into it on the way down.
- **8-connectivity**, so a one-pixel-wide diagonal survives as a connected run rather than a broken one.
- **A bounded reconstruction** — a fixed-iteration dilation of the low-res "belongs to a large component"
  mask, capped by a named constant in the `AUTOMASK_DILATE_MAX` style, erring toward keeping. 8 iterations
  at quarter resolution is ~32 screen px of reach.
- **The area floor as a share of the low-res frame**, so it means one screen area at every resolution — a
  low-res texel is 16 screen px², so the floor is expressed in tens of pixels.
- Growth stays at full resolution; only the *decision* is made coarse. A coarse decision dilated back up
  is conservative in the good direction: a thin element is kept, and a speck is still not one.

Cost: a reduction, a handful of bounded low-res passes and a lookup — well under a full-resolution pass in
taps. It is compute-only in practice, and belongs behind the compute guard beside the tile map of §5.6.

### 5.2 Fill interiors bounded by a persistent contour

§3.2 is what reaches bloom. A bounded fill of mask-enclosed regions closes it — but only if
the enclosing contour is trusted, or a gap in a panel becomes a hole punched through to the world.

The depth-free trust test is cheap: **require the contour to be persistent.** The edge bounding the region
must sit at the same place with the same luma step for several frames. That reuses `AutoMaskEdge`'s taps
plus one small per-pixel history, and it distinguishes a panel's own outline from a chance arrangement of
still pixels around a gap. This is the single change that most improves "the element as a whole is
protected" over "the still parts of it are".

### 5.3 Admit only non-isolated entrants

The cheapest spatial prior there is: a pixel may enter the mask only if it already has a masked neighbour.
Noise specks can then never seed a region, while real interface grows from whichever of its pixels first
holds still. One extra test at admission — not a new pass, and not a new target.

Its failure mode is a genuinely new element with no mask region anywhere near it, so it needs a second
door: an arrival event (§5.4) or a high-confidence seed. It also makes the isolation gate's job much
smaller, by not admitting most of what the gate currently has to remove.

### 5.4 Localise the premise, for arrivals only

The recorded hole is the panel opening over an already-stopped world. A menu opening produces a signature
nothing else does: a **large, contiguous, simultaneous change with an edge-like boundary that then stops
changing.** Detected at low resolution — a contiguous patch whose pixels stepped by a wide margin this
frame and hold still after — it lets a rise be credited *inside that patch* while the world is stopped,
which is precisely what the screen-wide share cannot do for a small panel (§3.3).

Do **not** generalise this into a local "the world is being drawn around here" premise. That trade looks
attractive, because it would also help a quiet scene with one concentrated animating element. It weakens
the premise exactly where the premise is the only defence: a still patch of world surrounded by animating
world is what a distant static ridge looks like too. An arrival event is bounded, singular and
verifiable; a localised premise is none of those.

### 5.5 Two one-line signal upgrades

Both are worth an overlay reading before either is worth a rule.

- **Confidence-weighted count.** The gate counts `step(0.5, neighbour)`. Summing the neighbour's
  `confidence` instead removes the cliff at exactly `0.5` and turns `AutoMaskDensity` into "share of
  confidence". It stays on the verdict's own channel, so it keeps the property the docs care about — the
  count is not on colour.
- **Stratify stillness by magnitude.** The verdict already knows whether a change was *exactly zero* or
  merely inside the deadband, and a pixel bit-identical across frames is stronger evidence of an interface
  draw than one a level off. The premise already guards the stopped-scene case, and dither and TAA mean
  exactness is not universal, so this is a weight and not a rule.

### 5.6 A tile map, off the tally that already exists

Every option above wants a coarse spatial map of "how much of this tile is still, or moving". The compute
path already builds exactly that shape of statistic: `CS_Accum` keeps a `groupshared` moved-pixel tally
and an 8-bin histogram per group, and one thread per group hands the totals over. A per-tile still *sum*
is the same trick with a different index.

One precision: a group is `[numthreads(64, 4, 1)]`, so the existing tally lands on a 64×4 block, not a
square tile. A square map — which is what a component reduction wants, and what an arrival patch test wants
— takes its own small index in the same groupshared array and its own target, still at a handful of global
adds per group. A fixed-size target, in the `texMotionCoarse` 16×16 precedent, keeps it resolution-independent
and small.

This is the enabler for §5.4 and §5.7, and it is also the reduction §5.1's component test needs to start
from. The directional densities need none of it — their counts ride in the two closing passes already. It
costs almost nothing, and it is also the natural home for a future *regional* accumulator, should the
verdict ever be pooled spatially — the change most likely to reduce speck noise without touching the
per-pixel tuning.

### 5.7 Auto-place the center deadzone

The deadzone is the shader's one *authored* region, and it exists because a camera-tethered character is
indistinguishable from a HUD by the comparison. It is also three sliders a user tunes by eye. With the
tile map in hand, the ellipse's position, width and height can be seeded from the largest centred still
region that persists while the world is being drawn, with the existing sliders kept as an override. Low
cost, modest value, and it removes the worst manual step in the shader.

### 5.8 Exploratory, as a reading only: the alpha-composite signature

The one avenue that could change the semi-transparent case. Semi-transparent UI composites as
`pixel = α · ui + (1 − α) · world`, so its frame-to-frame change is the world's change *attenuated by a
spatially constant factor*: the ratio of a pixel's motion to its neighbourhood's motion carries the `α`,
and a local motion statistic — §5.6's tile map — is what makes that ratio measurable.

It is confounded by dither and TAA, which attenuate for their own reasons, so its first form must be an
overlay reading of the ratio's distribution over a known translucent HUD. The flow probe is the precedent:
an instrument first, a mechanism only if a real game says so.

## 6. Measure first: the instrument

The repo's own method is that a claim is measured before it is mechanised — no noise floor without the
histogram, no vector without the probe. The instrument here is small: a third reading on the diagnostics
overlay, beside the motion and verdict views.

- **Region coherence:** the connected-component count of the current mask, and the largest component's
  share of it. If today's mask is one or two large components, §5.1's component test is not worth its
  cost. If it is a long tail of specks, it is worth everything — and the tail itself is the measure of
  how much the isolation gate is being asked to clean up.
- **Holes:** the share of the screen that is mask-enclosed but unmasked. That is §3.2's size in the
  user's own game, which is the only thing that says whether §5.2 earns its history.
- **Arrival candidates:** for §5.4, the count and total area of contiguous wide-change patches per frame
  during a stopped scene. A panel opening that produces no such patch at the threshold being tested is
  the answer "no", and the case stays a documented cost.

All three are low-resolution readings off the tile map of §5.6, which is why that is the first thing to
build and the thing that decides the rest.

## 7. Conventions any of this must keep

- **Compute-only where the tile map is needed**, following the drift channel and the histogram: guarded by
  `AutoMaskCompute`, owning its targets, leaving the `AutoMaskCompute = 0` entry-point hashes
  byte-identical.
- **A live checkbox, not a fourth structural switch**, for anything that owns no pass, shader or target of
  its own — the deadzone and isolation precedent — with the gate first in its own category. Anything with
  a pass or a target of its own gets a definition, per the same rule read the other way.
- **A named bound** (`AUTOMASK_..._MAX`) for any capped iteration, as `AUTOMASK_DILATE_MAX` does, so the
  cap cannot drift from the loop that reads it.
- **Cost honesty in `README.md`.** The drift channel's cost claim and the flow probe's both had to be
  corrected once already; a tile map plus a reconstruction loop is an *addition*, not a retune, and the
  README says so in those words.
- **Verification stays a review pass plus the offline check** — `uv run tools/verify_shaders.py check`
  across all eight variants, pixel-path hashes unchanged, and no new warnings, since a warning is a
  failure here. None of this is verifiable without a game, and §6's readings are what a game gets used
  for.

## 8. Summary of options

| | option | closes | cost | gate |
| --- | --- | --- | --- | --- |
| 5.1 | directional densities | §3.1, axis-aligned only | no new taps, riding the existing passes | live checkbox |
| 5.1 | connected-component area | §3.1 in any orientation | reduction + bounded low-res passes | live checkbox, compute-only |
| 5.2 | contour-bounded fill | §3.2 | fill + a small contour history | live checkbox |
| 5.3 | non-isolated admission | speck seeding | one test at admission | live checkbox |
| 5.4 | arrival detection | §3.3 | tile map + a patch test | live checkbox, compute-only |
| 5.5 | weighted count / exact-still weighting | tuning sharpness | none | none, unless it proves out |
| 5.6 | tile map | enables §5.1's components, §5.4 and §5.7 | a groupshared index and a small target | compute-only |
| 5.7 | auto-placed deadzone | §3.4's manual tuning | off the tile map | override sliders stay |
| 5.8 | alpha-composite ratio | reading only | off the tile map | diagnostics, compute-only |

If two were to be taken first: **the connected-component area filter of §5.1** is the highest-value
change, because it fixes a limitation the docs currently call inherent and gives every later option a
region to work with; and **the arrival detection of §5.4** is the only one that closes a case the docs
currently list as unfixable without eyes on a real game. Both are gated on §6's readings.
