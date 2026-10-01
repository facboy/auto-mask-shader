# Options for isolating UI elements, without depth

## 1. Scope and standing

What element-level isolation could do better. **Options, not
a plan**: nothing here is scoped or approved. §5.1's directional densities **have since been implemented**
— the four-axis form, described in that section and in `docs/core-model.md` — §5.6's tile map with
§6's readings on it **has since been built**, as the instrument that decides the rest, and §5.3's
admission test **has since shipped**. What building and watching that instrument settled is in §5.2,
§5.4 and §6: the arrival reading fires, but neither it nor §5.2's per-pixel fill is worth what building
on it would cost — §5.2's was built as a probe and watched in a game, §5.4's is judged against the
premise it would have to break. §5.5's confidence-weighted count **has since been measured out** — the
view built to read it found the band under the protection line was dim scenery drifting below the
comparison's resolution, which a weighted sum would keep *more* of rather than less — and its magnitude
half **has since been closed on that same finding**, which names the very pixels it would charge fastest.
What the instrument also settled is the shape of what is left: §5.7 is dropped with the manual region it
would have seeded, and §5.8's own reading — built, watched and removed — is measured out too, because the
quantity it needs is not in any target. §5.9 is where depth ended up: the mask use this document assumed
away stays impossible, but the premise use works and **has since shipped** as `AutoMaskDepthMotion`. §5.10
is what that shipped premise still gets wrong — the witness it is measured with, not the cue it spends —
and **its reading has since been taken in a game**: the case is real but rare, so the selector shipped with
§5.9 covers it and the premise proper stays unbuilt.

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
4. **The camera-tethered character:** a character pinned to the camera's motion is taken for interface. A
   hand-placed ellipse used to carve the region out; it was removed as unused (see §5.7), so the case is now
   an open cost rather than a setting.
5. **A still patch of world beside a large animating one.** The premise is a single screen-wide share, so a
   river, a waterfall or fire large enough to clear `AutoMaskMotion` marks the world as *drawn* and stillness
   is then credited over every still pixel — including a wall or a backdrop that has not moved at all. §3.3 is
   the same global test failing on a different question (a panel over a *stopped* world); this is the form
   where the world is not stopped, only the patch that gets taken. §5.10 is the option that would read
   viewpoint change rather than picture change to tell them apart.

## 4. Avenues already closed

- **Image-based optical flow.** Built, watched in a real game, and removed; `docs/optical-flow.md` §6.2
  carries the negative result and its §3 and §5 the reasons — a sub-pixel-per-frame drift sits under any
  whole-pixel search floor, and a vector is not the same question as "is this HUD". The drift channel
  answers the same question per pixel, at full resolution, with no search, so a proposal that reopens this
  has to answer that loop failure first.
- **Depth, as a mask.** Confirmed unavailable: `DepthBufferTex` is reachable but the overlay writes no
  depth, so depth speaks for the world and never for the interface, and a depth-change reading would veto
  the whole HUD the moment the camera moved. Depth *is* spent on the premise, as
  `AutoMaskDepthMotion` — the one place it helps, since a panel cannot hide the world's drawing there.
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
box share alone at **Mask grow radius `1`** and up, and only dropped at `0` — so the door earns its keep
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

**Shipped, with the seed as the second door.** A pixel with no claimed neighbour is not refused but
*delayed*: it earns at half the rise (`AUTOMASK_SEED_SHARE`), so a region can only start from a pixel
that holds still for twice `AutoMaskRise`, and a lone speck has nothing to grow from. That door is a
share rather than a refusal for exactly the failure this section names — §5.4's arrival event is
measured out, so nothing else can certify a wholly new element, and a refusal would leave one
unmaskable until mask happened to touch it. The delay lets any element arrive on its own evidence,
twice as late.

It is four taps on the verdict channel the accumulator already holds, behind the live checkbox
`AutoMaskNeighbour` inside `AutoMask` — no pass, shader or target, so no definition, by the deadzone's
rule. Both doors read the verdict rather than colour, and it runs *before* the isolation gate rather
than instead of it: the gate still removes what the delay admitted. `docs/core-model.md` carries the
design; an off-GPU probe (`tools/.work/`, not committed) holds the arithmetic — the lone pixel takes
twice the rise, the supported one the rise, and the rule clear is identical to no rule at all.

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

Two changes to an existing signal rather than additions. They were grouped under one precondition — a
reading before either becomes a rule — but they read **different quantities** and stand or fall
separately, so they are decided separately.

#### 5.5.1 Confidence-weighted count — measured out

The gate counts `step(0.5, neighbour)`. Summing the neighbour's `confidence` instead removes the cliff at
exactly `0.5` and turns `AutoMaskDensity` into "share of confidence". It stays on the verdict's own channel,
so it keeps the property the docs care about — the count is not on colour.

**The view was built, and it drew two flat colours rather than a ramp.** A fourth overlay view,
`UIDebugConfidence` splits the accumulator's charge at the 0.5 verdict step and draws one colour for
interface the mask already claims and another for the band under the line that it does not, leaving
everything at or below zero as the plain picture. It needs no pass, target or definition — confidence is
already in `.r` of `texAutoAccumA` — and it draws on the pixel path as well as the compute one, which is why
it is a diagnostics view rather than a reading on the tile map. It rides the free `.b` channel of
`texAutoDebug`, so the tile view's `.rgb` and the screen state's `.a` are untouched, and no variant of the
compile changed shape. The flat colours were the second cut: a brightness ramp asked for shades to be
compared, which is not something an eye can do, and it put the wide debt a move leaves into the lower part
of the scale so healing world read as a halo.

**Measured out: the band is dim drifting scenery, which is the wrong sign.** The reading is a thin band
over UI interiors — the wanted case, an element's own edge earning as it settles — and a **much larger one
over plain scenery with no menu open**, in the dim, smoothly shaded regions of it. The mechanism was read
out over four rounds of in-game testing and is not the one this section first assumed:

- **It is not a forgiving deadband.** At the `AutoMaskEps` default of `1` the verdict's test is
  `maxDiff < 1`, i.e. the quantised change must be *exactly zero*; there is no band for a small change to
  slip under, and a credited pixel is provably bit-identical to its predecessor.
- **It is sub-resolution drift.** The comparison's baseline is one frame and its unit is one whole level,
  so scenery sliding across the screen at a fraction of a level a frame reads as perfectly still — and the
  per-frame change is roughly screen speed times local gradient, so dim, low-contrast regions cross a
  level least. Bright detail crosses one almost every frame and is knocked out constantly; the dim
  silhouettes hold for seconds at a time and are genuinely, measurably still in between. The arithmetic is
  already in `docs/optical-flow.md` §3, which measured the same floor for the sky: under ~0.1 px/frame
  most of the image changes by zero levels between consecutive frames.
- **The band is the heal, and its width scales with the rise.** Each level-crossing floors a whole patch,
  which then walks back up through the band and into the mask. `AutoMaskMoveMemory` is exactly that walk —
  it appears in the arithmetic only as the debt's floor — so sweeping it from `120` to `600` frames shrank
  the band and then removed it entirely, bracketing the crossing interval at a few seconds. Confirmed, not
  inferred: the patch width tracks `AutoMaskRise`, which is the signature of charge earned over time rather
  than of any shape or colour rule.
- **A longer drift horizon made it worse, which is the premise at work.** The channel is the reading built
  for movement this slow, but it can only *remove* credit per pixel; what it also does is feed the
  changed count, and so the world-drawn share (`docs/compute-path.md`). A longer horizon catches the
  drifting sky as changed, holds the premise up, and it is only while the premise is up that the dim
  scenery earns — so the horizon's measured sign is the opposite of its per-pixel one.

That closes the option, and not merely because the mass is small. A weighted sum reads that same charge as
**corroboration**, so at a fixed `AutoMaskDensity` the gate would keep *more* of the drifting scenery, not
less — the opposite of the sharpening the upgrade was for. The case against is not "nothing to weigh" but
"what is there should not count". Admission does not rescue it either: a large region of it holds no
claimed pixel anywhere, so every pixel earns at the same seed rate and the region is **delayed about
twice, not prevented**; the spatial gate does not either, because a band several pixels across clears both
of its doors — the line door keeps any run of three still pixels at every density. The two spatial rules
test *shape*, and this failure is not a shape problem.

The mechanism notes stand regardless. **A weighted sum is never more than the count it replaces** — every
term is at most one — so at a fixed density it drops less only where the charge is real. And it would make
a region **still healing from a move** count as weak support, a way to erode a real element the count never
had. Precision is not an objection: the box holds at most 49 pixels, so `AUTOMASK_COUNT_SCALE`'s 255 leaves
the sum ample resolution. The view that decided it stays in the shader.

#### 5.5.2 Stratify stillness by magnitude — closed, and narrower than it looks

The verdict already knows whether a change was *exactly zero* or merely inside the deadband, and a pixel
bit-identical across frames is stronger evidence of an interface draw than one a level off. The premise
already guards the stopped-scene case, and dither and TAA mean exactness is not universal, so this is a
weight and not a rule.

**Its premise is narrower than the section first assumed.** The verdict is `maxDiff < deadband`, so at the
`AutoMaskEps` default of `1` every still pixel is already bit-identical and there is nothing left to
stratify: the weighting speaks only where the deadband is **2 or more**, which makes this a question about
a non-default setting rather than a general one.

**Its own reading was dropped, because 5.5.1's already answers it.** This half reads *change magnitude*, not
charge, which is why the two were split rather than decided together. The compute path still bins change
sizes for the auto-deadband (`texAutoMotionHist`), so the distribution it wanted sits beside machinery that
exists; nothing draws it, and it is not worth building for a rule a later reading has condemned.

The pixels the drifting dim scenery is credited on are bit-identical to their predecessor by definition —
that is the whole mechanism — and 5.5.2 is precisely the change that would charge *those* pixels faster than
any other. So the confidence view's finding decides this half too, not only 5.5.1: the reading owed as the
rule's only justification came back against it, and where it speaks at all it deepens the one failure this
document has measured, in the same wrong direction. The coupling runs the same way — charging exact-still
pixels faster fills the grade higher and thins the band 5.5.1 was measured on, never revives it.

It is closed **on that reading's argument rather than on a change-size readout of its own**, which is a
departure from this repo's measure-first method and is recorded as one. A reading could still be taken to
weigh the screen's mass in the band it wants to stratify, but its job would now be to overturn a measured
cost rather than to justify an untested rule.

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

This was the enabler §5.7 and §5.8 each assumed they needed, and neither took it up: §5.7 is dropped with
the manual region it would have seeded, and §5.8 was built as its own pass and then measured out, its
coverage count unable to carry a magnitude. The directional densities need none of it — their counts ride
in the two closing passes already. It is also the natural home for a future *regional* accumulator, should
the verdict ever be pooled spatially — the change most likely to reduce speck noise without touching the
per-pixel tuning.

**Built, with §6's readings, and kept for the spatial rules rather than for those options.** The map is
`CS_Tile` and the readings are §6's three: it is a fixed 16×16 grid, 8 sample points per axis, and each
cell is a *share* of itself rather than a tally of its pixels — which is what makes it resolution-independent
without the per-pixel atomic the tally shape would need. The two design points this section left open are
settled as: the readings are relaxations over that fixed grid, so their round count is `G × G`, a property
of the grid rather than of the picture (§5.1's component filter had no such bound at full resolution — see
the correction below); and the map is gated by the compute *and* diagnostics switches, because it is an
instrument and exists only where it can be seen. It is read by nothing in the mask.

**Its own questions are all settled; what keeps it is the shipped rules.** §5.2's fill, §5.4's arrivals
and §5.8's ratio are all recorded above, so the map is no longer the first step of a plan and the options it
was built to decide are closed. The isolation gate and the admission seed are still open to tuning, and both
are region questions — how many pieces a mask has broken into, where its wide changes sit against the
enclosing contour — that no per-pixel view can show. So its standing is the tuning instrument for those two
settings. It earns that on the test the repo applies to any instrument: honest (its three readings were
mirrored against an independent labelling and flood, 0 mismatches) and free at rest (`CS_Tile` is absent
from all four of the compute-off and diagnostics-off variants, so it costs a pass, a grid and a share target
only in the combination where it can be seen).

### 5.7 Auto-place the center deadzone — dropped with the manual region

The center deadzone was the shader's one *authored* region, and it existed because a camera-tethered
character is indistinguishable from a HUD by the comparison. It was a feature the maintainer never used,
and it was **removed outright**: keeping it parked still ran the ellipse test on every pixel of the
full-resolution accumulator — measured at 20 instructions in `PS_Accum` and 22 in `CS_Accum`, about a
fifth of each — for a branch that was false on every frame. With the manual region gone this option has
nothing to seed and is dropped with it: auto-placing a region nobody enables would be building on what
was deleted. The case it addressed is now an open cost in §3.4, and a future answer has to earn a region
from the mask rather than from a slider.

### 5.8 The alpha-composite signature — measured out, and the reading removed

The one avenue that could change the semi-transparent case. Semi-transparent UI composites as
`pixel = α · ui + (1 − α) · world`, so its frame-to-frame change is the world's change *attenuated by a
spatially constant factor*, and the ratio of a pixel's motion to its neighbourhood's motion was to carry
the `α`.

**The instrument it needs is not the one §5.6 built.** That claim — "a local motion statistic, §5.6's
tile map" — did not survive the code. `CS_Tile` accumulates *coverage*, never magnitude: `masked +=
step(0.5, …)` and `wide += step(AUTOMASK_TILE_WIDE, …)` are counts of taps over a threshold, and a share
of a region that changed cannot form a ratio of a pixel's motion to its neighbourhood's. The magnitude
does exist on the compute path, in the change-size histogram behind the auto-deadband — but that is one
distribution for the whole frame, with no spatial locality at all. So its first form was **a new
statistic**, and it was built as one: `CS_Alpha`, a pass over the tile map's own grid, each cell the mean
of the accumulator's graded motion over the taps that moved at all, taken against the grid's own rate over
the cells the mask does not touch.

**It was then watched in a game and removed.** Three cuts were needed before it drew anything honest — a
fixed class boundary, then a ramp over the whole grid, then the band alone — and the defects in those were
the reading's, not the display's: the ratio must be a mean over *lit taps on both sides*, or a mostly-still
cell is inflated into the frame's own rate, and a cell with no lit taps stores a ratio of zero, which paints
as the *brightest* thing on screen. With all three fixed the display was honest and the option was still
not: the quantity it reads cannot carry the answer.

**The failure is the graded channel, and it is arithmetic rather than tuning.** The accumulator stores
`smoothstep(deadband−1, deadband+2, maxDiff)`, which **saturates at one** — it is a certainty, not a
magnitude. At the `AutoMaskEps` default of `1` a world change of one level reads `0.26` and a six-level one
reads `1.0`, and a panel at 50% opacity reads half the world's change on that *curve*: so a panel is only
detectable where the world behind it moves by roughly 2–5 levels a frame, below that the world's own small
change puts the ratio in the band and a panel is indistinguishable from dim moving scenery, and above it
both panel and world saturate to `1.0` and the attenuation is gone. Measured over that span, the ratio a
50%-transparent panel produces runs from 0.29 (inside the band, i.e. a false positive) through 0.50 to
1.00 (invisible). The three symptoms reported from a game are exactly this: **dim scenery reading as
attenuation**, **an open menu reading as world**, and **a still panel or permanent UI reading as nothing at
all**, because a panel with no world movement behind it has no lit taps and no ratio.

That is the same class of result as §5.2 and §5.4: not a feature to add, an avenue to stop. The instrument
was therefore removed with the mechanism still unbuilt — no `CS_Alpha`, no grid, no share target, no view —
and the semi-transparent case stays the documented limit it always was (`README.md`, `docs/core-model.md`
§"What the signal cannot do"). A future proposal has to start by saying where a **proportional** per-pixel
or per-cell motion magnitude would come from, since the channel this one read saturates by construction.

### 5.9 The depth check — shipped, and the only depth use that survives

Depth was the one cue this document opened by setting aside, and the setting-aside was too broad. The
constraint is real but narrower than "unavailable": `DepthBufferTex` is reachable, and in DSR the overlay
writes no depth — a panel takes the scene's — so depth describes the world and never the interface. That
rules out a **mask**: a depth-change verdict would fire on every HUD pixel whenever the camera moved,
because the world behind the panel is what the depth shows, and it would veto the whole element exactly
when the mask has to form. It does not rule out the **premise**, because the premise is not about the
overlay — it is "is the world being drawn", and depth answers that directly and cannot be hidden by a
panel the way the picture can.

The two are worth separating because they fail in opposite directions. A per-pixel depth test adds false
claims (it is most active over the world, which is where a false claim is worst). The premise adds no
per-pixel claim at all: it only feeds the screen-wide gate, so its worst case is a mis-set threshold on a
setting that already ships with a fallback. That asymmetry is why a depth *premise* is affordable where
the depth *mask* this document assumed was never on the table.

**Shipped** as `AutoMaskDepthMotion`, a fourth structural switch, off by default. It adds a pixel's depth
change to the changed count `CS_Finish` publishes, on its own step (`AutoMaskDepthEps`, a distance in metres
rather than a share, since the far plane ReShade supplies lets the change convert back to the metres it
was). It can only add to that count, never
remove, and never touches the verdict — which is what keeps it from being the mask refused above. With no
depth bound the sampled texture is a constant on both sides, the difference is zero, and the reading is the
picture's own exactly: the online-game case degrades rather than needing a second path. It owns one `R32F`
target, written by the closing pass rather than a store pass of its own, both inside the guard, and the
store is ordered after the accumulator's read so no pass reads and writes the same target. It does
nothing for a panel over an already-stopped world, where the depth is stopped too — that stays §3.3's
cost.

Unverified in a game: the whole of it. The mechanism and the fallback are off-GPU properties, but whether
DSR's depth is usable and what step it needs are questions only a game answers; `docs/verification.md`
names the scenario.

### 5.10 A viewpoint-change premise — the false witness §5.9 leaves standing, measured rare

§5.9 spends depth on the premise but keeps the premise's **witness** unchanged: `AutoMaskDrawn` reads the
share of pixels whose *colour* changed, and that share cannot tell apart two different things. A camera
that moves repaints the view, and a still pixel beside it is genuinely informative — it is not world. A
static camera over animating **texture** — flowing water, fire, a scrolling UV, a video backdrop — repaints
pixels too, but nothing about the viewpoint changed, so a wall, a closed door or the backdrop behind a menu
is still ambiguous with a HUD exactly as it was. The changed-share fires and stillness is credited over
world that never moved. This is the animated-neighbour form of §3.3's global-test failure, and it is the
commoner presentation: a quiet room where *nothing* animates at least has a stopped premise, while a room
with a river in it does not. `README.md` names it as a limit.

`AutoMaskDepthMotion` does not close it, because it joins the same count: water as moving **geometry**
changes depth too, so the `max` is more firmly on, not less. What would close it is a reading of
**viewpoint change** rather than of picture change — and depth is the natural source, because texture
animation moves pixels without moving depth. Under this option the premise would be taken from a
depth-change share instead of (or in addition to) the colour share: a still camera over flowing water
leaves depth flat, so the world reads as stopped and stillness is withheld; a camera pan or a scene change
moves depth across the frame, so it reads as drawn.

It is a **global** reading — one share, no per-pixel claim — for the reason §5.9 gives: depth speaks for
the world, and a HUD over a static wall has the wall's own depth and the wall's own zero depth change, so
no per-pixel depth test can separate them.

**The trade is the mirror of the changed-share's, and it is not obviously a win.** Where the changed-share
banks a static world, a depth-change premise *withholds* stillness in every scene whose only animation is
textural — so the hold engages and a genuine HUD stops earning too. A persistent HUD survives this (it is
captured while the camera moves and held after), but a fresh element appearing with the camera dead still —
a notification fading in over static scenery — may not be captured until the view moves. It also still
misses animated **geometry**: an NPC walking, foliage swaying, cloth; those move depth and would read as
drawn. So it trades one false positive for one false negative and does not close the class; it decides
which failure a given game lives with. That is the same asymmetry as §5.9 and the RGB-versus-depth
question behind it — the two witnesses fail in opposite directions, so the honest shape of a fix is to
*select* between them (a mode or a live toggle) rather than to replace one with the other.

**Measured in a game, and the answer is rare.** The reading this section asked for — how often a
textural-only scene occurs, and how much mask a static backdrop takes in one — has been taken with
`AutoMaskDepthOnly` on a real scene: the views it names are reachable, but **very few**, so the cost above
is paid on a handful of frames rather than a mode of play. Two things make that count decisive rather than
merely small. The false positive fires on *every* frame of such a view, while the false negative it trades
for needs a *fresh* element to appear during one with the camera dead still — a persistent HUD is captured
while the view moves and held after, so it pays nothing there. And selection is already shipped: the two
controls are a live choice, so the game that has these views keeps **Depth only** on for its own preset and
every other game leaves it off. Building the premise proper — or the blend of the two witnesses this
section calls the honest shape — would be a new unmeasured rule running on every frame to serve views that
turn up a handful of times. So it lands where §5.2, §5.4 and §5.8 did: the case is real, the mechanism is
not worth mechanising, and the free control stays.

Two causes of "the picture moved and depth did not" look alike, and only one is this section. Animation
that is *textural* — flowing water, fire, a scrolling UV, a video backdrop — under a still camera is the
case, and **Depth only** is right there. A camera that is panning while the depth term stays flat is a
depth configuration fault instead, not a win: a rotation swings the sampled distance at every silhouette,
so a pan that reads as stopped is a far-plane or depth-settings mismatch, and the symptom is the other one
— a genuine element failing to be captured while the view moves.

Off-GPU, one property is checkable by hand: with no depth bound the depth share is zero, so the reading is
"never drawn" and the switch would have to fall back to the colour share rather than holding forever — the
same degradation `AutoMaskDepthMotion` already relies on.

**The measurement is a live switch, not a probe.** A side-by-side reading would need a channel the
accumulator does not have — its four are all spent — so the cheap form is to *select* the witness rather
than to draw two: `AutoMaskDepthOnly`, inside the depth guard, makes `motion` the depth term alone instead
of `max(depth, picture)`. It owns no pass, shader or target, so by §7's rule it is a live checkbox and not
a definition, and the arithmetic it changes is a single `max`. What it costs is nothing that was not
already paid — `maxDiff` is computed for the verdict regardless, and the depth term for the premise — so
the switch is free and flipping it in a game reads the comparison in one session. Its label spells out the
three states the pair reaches — picture alone, both, depth alone — so the choice is read off the panel
rather than inferred. Its known failure is stated in `README.md`: with no bound depth the world reads as
never drawn, which is the same degradation the additive form turns into a harmless zero.

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
  is the live toggle `UIDebugTile`, while the pass and targets behind it are the compute definition. The
  tile map is the one feature here that needs **two** definitions at once, since the instrument is only
  usable where it can be seen.
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
| 5.3 | non-isolated admission | speck seeding | four taps on the verdict already in hand, and no new target | live checkbox — **shipped, with the seed as the second door** |
| 5.4 | arrival detection | §3.3 | tile map + a patch test | live checkbox, compute-only — **measured out: the window is narrower than the rise it would unlock** |
| 5.5.1 | confidence-weighted count | tuning sharpness | an overlay view off the accumulator, no pass or target | live checkbox inside the gate — **measured out: the band under the line is dim scenery drifting below the comparison's resolution, so weighting keeps more of it** |
| 5.5.2 | magnitude weighting | tuning sharpness, and only where the deadband is 2+ | none for the rule; it charges the pixels 5.5.1 was measured on faster, and its own reading was dropped | none — **closed on 5.5.1's reading** |
| 5.6 | tile map | its three readings; kept as the tuning instrument for the shipped spatial rules | a pass, a 16×16 target and a 2×1 reading target | compute + diagnostics — **shipped, and kept after the options it was built to decide were settled** |
| 5.7 | auto-placed deadzone | §3.4's manual tuning | off the tile map | — **dropped: the manual region was removed as unused** |
| 5.8 | alpha-composite ratio | reading only | a new per-cell magnitude statistic, built as a pass with a `RGBA32F` grid and a share target | compute + diagnostics — **measured out and removed: the graded channel saturates, so the ratio cannot separate a panel from moving world** |
| 5.9 | depth check | §3.3 in the common case (the panel no longer hides the drawing), not the panel over a stopped world | one `R32F` target, written on the closing pass; degrades to the picture's own premise with no depth bound | preprocessor definition, off — **shipped as `AutoMaskDepthMotion`** |
| 5.10 | viewpoint-change premise | the animated-neighbour form of §3.3 — a still patch banked because a *different* region repaints | a depth-change share in place of the colour share; still misses animated geometry, and withholds stillness in textural-only scenes | live checkbox — **the selector shipped as `AutoMaskDepthOnly` and the case measured rare in a game, so the selector is enough; the premise itself is not scoped** |

**The directional densities are shipped**, in the four-axis form that covers the diagonals too.
**§5.6's tile map and §6's readings are shipped as one instrument step**, which is the order §6 asks for:
nothing is wired into the mask. **It is also the one instrument here that outlived its brief** — every
option it was built to decide (§5.2, §5.4, §5.7, §5.8) is now closed, and it stays because the two spatial
rules that *did* ship are region questions it is the only view of.

**§5.4's arrival reading is measured out too.** It fires, but the case it closes is a panel small enough to
stay under the screen share, opened abruptly into a world that stopped silently, and the unlock would have
to hold for the whole rise across a window of one or two frames — while crediting a rise to a stopped world
is the one thing the premise exists to forbid.

**§5.2's fill was measured out**: built as a bounded probe, watched in a game, and found to mark the gaps
between elements rather than an interior, which the persistence test does not repair and no reach
separates. The connected-component area filter §5.1 ranked highest is measured out for the same reason at
full resolution — the round count a labelling needs is set by the picture, not by a named bound — so the
four-axis door answers §3.1 in its place.

**§5.3's admission test is shipped.** The door it needed is the seed rather than an arrival: a pixel with
no claimed neighbour earns at half the rise, so a region starts only from a pixel still for twice the
rise. That is what makes it ship at all — §5.4's arrival was the other door this section named and it is
measured out, so a plain refusal would leave a wholly new element unmaskable. It shrinks the isolation
gate's job, which was its point.

Of the rest, §5.5's confidence-weighted count is measured out — the band under the line is dim scenery
drifting below the comparison's resolution, which weighting would keep more of rather than less, and which
neither spatial rule can remove because it has the shape the gate is built to keep. Its magnitude half is
closed on the same reading: it charges exactly the bit-still pixels that finding implicates, faster than any
other, so 5.5.1's result is its verdict rather than its cost.

**§5.8's reading was built and is measured out.** The ratio needs a magnitude, so it was its own pass,
`CS_Alpha`, measuring each cell's mean graded motion against the grid's own rate. Watched in a game it read
dim scenery as attenuation and an open menu as world, and the arithmetic says why: the accumulator's graded
motion **saturates at one**, so a panel is only separable from moving world where the world behind it moves
by about 2–5 levels a frame, and a still panel has no ratio at all. Same class of result as §5.2 and §5.4,
so the instrument was removed with the mechanism still unbuilt. The semi-transparent case stays a
documented limit, and a future proposal owes the repo a **proportional** magnitude first.

**§5.9's depth check is shipped, and §5.10's question against it has been answered rare.** The depth
check closes §3.3 in the common case; the witness it spends — the picture's own changed share — is what
§5.10 would replace, and the case it exists for is real but turns up in **very few** views in a played
game. Since the two witnesses are already a live choice, `AutoMaskDepthOnly` covers those views in a preset
and every other game leaves it off, so the premise proper and the blend this section called the honest
shape both stay unbuilt: a rule running on every frame for views that turn up a handful of times is not
worth its cost, the same verdict §5.2, §5.4 and §5.8 reached.
