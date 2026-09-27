# Options for isolating UI elements, without depth

## 1. Scope and standing

What element-level isolation could do better, given that the depth buffer is not available. **Options, not
a plan**: nothing here is scoped or approved. §5.1's directional densities **have since been implemented**
— the four-axis form, described in that section and in `docs/core-model.md` — and §5.6's tile map with
§6's readings on it **has since been built**, as the instrument that decides the rest. What building and
watching that instrument settled is in §5.2, §5.4 and §6: the arrival reading fires, but neither it nor
§5.2's per-pixel fill is worth what building on it would cost — §5.2's was built as a probe and watched
in a game, §5.4's is judged against the premise it would have to break. The other options stand as
written.

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

The unused axis is the fourth: **coherence of change events over space** — the verdict judges a pixel,
nothing judges a *region* — and every proposal below worth its cost gives the shader a region to reason
about.

## 3. Where isolation actually fails today

Named against the code, as §3.1 to §3.4 below.

1. **Thin interface is eroded by the gate's box count.** `PS_DilateV` keeps a pixel while
   `nearby >= AutoMaskDensity * 0.01 * side * side`. A line of width `n` fills `n / side` of the box, so
   a wider `AutoMaskIsolation` costs exactly the elements with the least evidence. `README.md` lists it
   under what the shader cannot do, and `docs/core-model.md` calls it a consequence of the *square box*,
   not of the idea.
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

**Shipped, with the diagonals added.** The version implemented in `PS_DilateH`/`PS_DilateV` counts four
lines rather than two — row, column, and both diagonals — which covers the 45° case this section calls
decisive, and keeps the box share as a first door so the change can only rescue a pixel the box dropped.
A straight, vertical or diagonal one-pixel stroke is rescued at every radius; a stroke between those slopes
only while the pixels it lays in an axis clear `max(reach + 1, 3)`, so the mid-slopes lapse as the radius
raises that floor. The floor's own minimum of 3 is what keeps a lone pixel, an adjacent pair and a short
run out. `docs/core-model.md` carries the design and `README.md` the user-facing limits; the measurements
are in a scratch probe under `tools/.work/` (not committed).

One interaction decides how much the fix is worth: the gate judges the mask **after the closing**, so a
stroke the closing has already thickened along its own length is no longer thin to the box share and the
door has nothing to rescue. Measured with the contour's luma step in place, a 1-px hairline is kept by the
box share alone at **Closing radius `1`** and up, and only dropped at `0` — so the door earns its keep
where the closing is low, and the visible difference at the default closing is a 2-px bar or a block's
interior at a wide **Isolation radius** instead.

**Connected-component area.** Measured and not affordable. The criterion is right — a component's area is
line-preserving in any orientation, where four axes cover only four directions — but the labelling is a
propagation, and its round count is not bounded by anything the shader can name. Built over adversarial
shapes, a comb (a spine with a bar at each end, diameter 165 low-res texels) needs **50** rounds where
`log2` of the diameter is 8: pointer jumping accelerates a label only while it is still moving toward its
own index, and the path that carries the minimum up the far bar runs against that order. The cap cannot be
lowered to a fixed small number, because a cap that stops a long component converging leaves its far texels
uncertified — dropped, which is the thin-interface erosion the filter exists to fix. Distance-doubling
converges in a true `log2` of rounds but costs thousands of taps per texel per round. So the bounded-pass
rule this repo keeps is not satisfiable for exact component area, and the four-axis door is what fixes the
named case instead.

*What the two share, and where it stops.* Neither separates a one-pixel stroke at an in-between slope from
a short run of pixels: a bounded local count sees the same evidence, and an exact connected component would
keep the stroke but needs an unbounded propagation to compute. A stroke of run 1 is therefore never rescued
by any bounded test here.

Cost was scoped as a reduction, a handful of bounded low-res passes and a lookup — well under a
full-resolution pass in taps, compute-only behind the compute guard beside the tile map of §5.6. The
measurement above removes the premise: the "handful of bounded passes" is not bounded.

### 5.2 Fill interiors bounded by a persistent contour

§3.2 is what reaches bloom. A bounded fill of mask-enclosed regions closes it — but only if
the enclosing contour is trusted, or a gap in a panel becomes a hole punched through to the world.

The depth-free trust test is cheap: **require the contour to be persistent.** The edge bounding the region
must sit at the same place with the same luma step for several frames. That reuses `AutoMaskEdge`'s taps
plus one small per-pixel history, and it distinguishes a panel's own outline from a chance arrangement of
still pixels around a gap. This is the single change that most improves "the element as a whole is
protected" over "the still parts of it are".

**Measured out: the bounded fill was built as a probe and watched in a game.** The per-pixel question the
tile map's hole reading cannot reach was asked directly, with a **morphological closing** of the published
mask on a grid eight times coarser than the screen, drawn blue in the overlay. A closing is bounded where
§5.1's labelling was not — it fills pockets narrower than its structuring element, cannot cross a wider
gap, and only ever adds — so it was the right shape for the question and cheap to build. It does not answer
it. On the frames watched at the slider's minimum (one cell, an 8-px reach) **every marked pixel was
reachable from the border**: none was enclosed, so it marked the gaps between elements and open scenery
rather than an interior. Three reasons, all measured off-GPU:

- **A closing is a local rule, and a hole and a gap give it the same evidence.** At any background pixel
  its whole decision is "is there mask within a square of my reach?". Two layouts that differ only in
  topology — one element with a slot cut through it, and two elements the same distance apart — present a
  byte-identical window at the band's centre, yet one is enclosed and the other is not. The difference is
  whether the two walls are the *same connected region*, which is exactly the unbounded question §5.1
  measured out.
- **The reach that fills an interior is the reach that bridges the gaps.** Gaps between interface run
  14–30 px; a menu interior is 130 px and up. A closing spans about twice its reach, so filling an
  interior takes a reach that also swallows the surrounding layout.
- **The reduced grid breaks the contour before the rule runs.** Sampling the mask once per cell leaves a
  thin rim a dashed path, so a *closed* outline arrives open and there is nothing enclosed to fill.

The persistence test above does not rescue it, which is why the section's own contribution stays a
proposal: a border broken into dashes is perfectly stable, so a history would certify it as a trusted
contour and the fill would still find nothing closed. A persistence store separates *coincidental
stillness* from *an authored line*; it cannot separate *an authored line* from *an authored line with
breaks in it*.

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

**Measured out: the window is narrower than the rise it would have to unlock.** The map certifies a wide
change as an arrival; the per-pixel verdict still grows the mask, at `0.504 / AutoMaskRise` a frame. A
cell is 160×90 px, so the map could not paint a panel even if it were read that way, and a panel pixel
whose own change is under the deadband gets nothing from any of it.

How narrow: a stopped world is unchanging and still counted, so at the `50` default the arrival fails to
clear the share only for a panel covering under half the screen — and a frame later the panel is still,
the share collapses to near zero, and the premise locks out. Thirty frames of rise against a window of
one or two is the whole feature. Contrast decides which form the event takes: above the drift store's
fixed eight-level reset the average snaps and the panel is one frame of change then still, the clean
signature; between the deadband and eight levels it creeps in over about `AutoMaskDrift ×
AutoMaskTargetFPS` frames, neither simultaneous nor finished; under the deadband nothing registers, and
the screen-wide premise is as blind to that panel as the reading is.

Three costs stack against it. The map would have to leave the diagnostics guard, since the mask would
read it: a pass, a 16×16 target and the small reading target, allocated for every `AutoMaskCompute = 1`
user. The arrival has to latch for the whole rise rather than the frame it fires. And the rule it breaks
is the one the model is built on — *a stopped scene can only lose mask* — so a certification error holds
scenery as interface, the worst outcome this shader can produce, and the reading certifying it is one this
repo has already got wrong three times.

### 5.5 Two one-line signal upgrades

Both need an overlay reading before either becomes a rule.

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

**Built, with §6's readings rather than on its own.** The map is `CS_Tile` and the readings are §6's three:
it is a fixed 16×16 grid, 8 sample points per axis, and each cell is a *share* of itself rather than a
tally of its pixels — which is what makes it resolution-independent without the per-pixel atomic the tally
shape would need. The two design points this section left open are settled as: the readings are relaxations
over that fixed grid, so their round count is `G × G`, a property of the grid rather than of the picture
(§5.1's component filter had no such bound at full resolution — see the correction below); and the map is
gated by the compute *and* diagnostics switches, because it is an instrument and exists only where it can
be seen. It is read by nothing in the mask.

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

The repo's method is that a claim is measured before it is mechanised — no noise floor without the
histogram, no vector without the probe. The instrument here is small: a third reading on the diagnostics
overlay, beside the motion and verdict views.

- **Region coherence:** the connected-component count of the current mask, and the largest component's
  share of it. If today's mask is one or two large components, §5.1's component test is not worth its
  cost. If it is a long tail of specks, it is worth everything — and the tail's size is the measure of
  how much the isolation gate is being asked to clean up.
- **Holes:** the share of the screen that is mask-enclosed but unmasked. That is §3.2's size in the
  user's own game, which is the only thing that says whether §5.2 earns its history. Its floor is
  structural: a hole must miss the mask on about two cells in each direction before it registers, so a
  reading of zero is evidence of no *menu-sized* hole rather than of no holes. Asking the per-pixel
  question directly is what §5.2's bounded fill was built for, and it was then measured out.
- **Arrival candidates:** for §5.4, the count and total area of contiguous wide-change patches per frame
  during a stopped scene. A panel opening that produces no such patch at the threshold being tested is
  the answer "no", and the case stays a documented cost.

All three are low-resolution readings off the tile map of §5.6, so that map is the first thing to build,
and it decides the rest.

**Built, as one step with §5.6.** `CS_Tile` writes both, and the tile view (`UIDebugTile`) draws the map
behind them so a reading can be seen against the picture that produced it. The decisions the section left
open are settled against the code:

- **The readings are relaxations over the grid, and the round count is its size.** A label only ever
  decreases toward the least index in its own region, so `G × G` sweeps — 256 at 16×16, the longest a
  connected region of that grid can be — settle any shape exactly. This is the bound §5.1 could not name
  at full resolution, and it is available only because the readings are taken at tile resolution: it
  counts cells of a 256-cell grid, which is a floor on the region it names rather than the region itself.
  §5.1's component-area filter is therefore still measured out as written — this is a coarse instrument,
  not a revival of that filter.
- **Enclosure is a border-seeded growth, with the mask its only wall**: every cell but the mask conducts
  the growth, and only world cells are counted, so a wide-change cell cannot wall the world off from the
  border. Whatever the growth never reaches is enclosed. At 16 cells across a hole has to be a real hole
  to register, which makes the reading a *lower* bound on §3.2's size.
- **Holes are counted off the mask the shader published**, i.e. after the closing, so a speck the closing
  grew around is not an enclosed region. That is the region a fill would act on.
- **A cell is interface when the mask touches it**, not when it fills it: a footprint reading. Most
  interface is thin against a 160×90 cell, so a share threshold made every partial UI cell read black.
- **An arrival is gated by the premise, not only by the width of the change.** A wide-change cell with no
  mask on it is an arrival candidate only while the world is *not* being drawn, read off the same share the
  verdict's premise uses. §5.4's signature is a panel opening over an already-stopped world; a camera pan
  is a screen-wide drawing and every moving cell of it is that drawing. Without the gate the reading was
  simply "what moved", which on a pan is the whole grid — the screen-wide orange the tile view shipped
  with, and a reminder that §5.4 must keep the premise rather than replace it.
- **Wide is read off the accumulator's own graded motion channel**, not a raw frame difference the map
  measures for itself: measuring its own let the map call a held UI edge red, since a sub-pixel shift of a
  hard contour is tens of raw levels yet still inside the verdict's deadband. Reading the verdict's own
  number is what stops the two disagreeing.
- **It is gated by compute and diagnostics together**, and read by nothing in the mask. The two count
  readings are stored against `AUTOMASK_TILE_COUNT_MAX` so a bar means something: a count of a few
  regions against the grid's 256 cells would fill one percent of a bar.

## 7. Conventions any of this must keep

- **Compute-only where the tile map is needed**, following the drift channel and the histogram: guarded by
  `AutoMaskCompute`, owning its targets, leaving the `AutoMaskCompute = 0` entry-point hashes
  byte-identical.
- **A live checkbox, not a fourth structural switch**, for anything that owns no pass, shader or target of
  its own — the deadzone and isolation precedent — with the gate first in its own category. Anything with
  a pass or a target of its own gets a definition, per the same rule read the other way: so the tile view
  is the live toggle `UIDebugTile`, while the pass and targets behind it are the compute definition. This
  one is the first feature here to need **two** definitions at once, since the instrument is only usable
  where it can be seen.
- **A named bound** (`AUTOMASK_..._MAX`) for any capped iteration, as `AUTOMASK_DILATE_MAX` does, so the
  cap cannot drift from the loop that reads it.
- **Cost honesty in `README.md`.** The drift channel's cost claim and the flow probe's both had to be
  corrected once already; a tile map plus a reconstruction loop is an *addition*, not a retune, and the
  README says so in those words.
- **Verification stays a review pass plus the offline check** — `uv run tools/verify_shaders.py check`
  across all eight variants, pixel-path hashes unchanged, and no new warnings, since a warning is a
  failure here. None of this is verifiable without a game; §6's readings are what a game gets used for.

## 8. Summary of options

| | option | closes | cost | gate |
| --- | --- | --- | --- | --- |
| 5.1 | directional densities | §3.1 for axis and diagonal strokes; mid-slopes lapse as the radius rises | no new taps, riding the existing passes | live checkbox — **shipped, four-axis** |
| 5.1 | connected-component area | §3.1 in any orientation | the passes are not boundable, measured | live checkbox, compute-only — **measured out** |
| 5.2 | contour-bounded fill | §3.2 | fill + a small contour history | live checkbox — **bounded form built as a probe and measured out** |
| 5.3 | non-isolated admission | speck seeding | one test at admission | live checkbox |
| 5.4 | arrival detection | §3.3 | tile map + a patch test | live checkbox, compute-only — **measured out: the window is narrower than the rise it would unlock** |
| 5.5 | weighted count / exact-still weighting | tuning sharpness | none | none, unless it proves out |
| 5.6 | tile map | enables §5.4 and §5.7 | a pass, a 16×16 target and a 2×1 reading target | compute-only — **shipped with §6** |
| 5.7 | auto-placed deadzone | §3.4's manual tuning | off the tile map | override sliders stay |
| 5.8 | alpha-composite ratio | reading only | off the tile map | diagnostics, compute-only |

**The directional densities are shipped**, in the four-axis form that covers the diagonals too.
**§5.6's tile map and §6's readings are shipped as one instrument step**, which is the order §6 asks for:
nothing is wired into the mask.

**§5.4's arrival reading is measured out too.** It fires, but the case it closes is a panel small enough to
stay under the screen share, opened abruptly into a world that stopped silently, and the unlock would have
to hold for the whole rise across a window of one or two frames — while crediting a rise to a stopped world
is the one thing the premise exists to forbid.

**§5.2's fill was measured out**: built as a bounded probe, watched in a game, and found to mark the gaps
between elements rather than an interior, which the persistence test does not repair and no reach
separates. The connected-component area filter §5.1 ranked highest is measured out for the same reason at
full resolution — the round count a labelling needs is set by the picture, not by a named bound — so the
four-axis door answers §3.1 in its place.

Of the rest, §5.3 is the cheapest and the only one that shrinks what the gate has to clean up; §5.5 needs
a reading before it is a rule, and §5.7 and §5.8 ride the map.
