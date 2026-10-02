# Options for isolating UI elements, without depth

## 1. Scope and standing

What element-level isolation could do better. **Options, not a plan**: nothing here is scoped. Four of them
have been settled by building or measuring:

- §5.1's four-axis door **shipped**, and §5.3's admission test **shipped**.
- §5.6's tile map and §6's readings **were built** as the instrument that decides the rest, and the map
  is kept as the tuning instrument for those two shipped rules.
- §5.2's fill, §5.4's arrivals, §5.5's confidence weighting, §5.7's deadzone, §5.8's ratio and §5.10's
  premise are all **measured out or dropped**, each with its reason below. §5.9's depth use **shipped**
  as `AutoMaskDepthMotion`; §5.10's question against it was answered rare, so its selector
  (`AutoMaskDepthOnly`) is enough and the premise proper stays unbuilt.

Companions: `docs/core-model.md` (the verdict the isolation rides on), `docs/compute-path.md` (the compute
path most of this would live in), `docs/optical-flow.md` (the one instrument already built, watched and
removed — the precedent for how to try one).

## 2. What is available, and what is not

Depth is the cue that would make this problem easy. Without it, every cue has to come out of the
composited picture. Three are already spent:

| cue | where it is used | what it decides |
| --- | --- | --- |
| temporal coherence | the accumulator | the per-pixel verdict |
| image structure | the luma step in `PS_DilateH`/`PS_DilateV` (`AutoMaskEdge`) | only where the growth stops |
| spatial coherence on the verdict | the isolation gate, riding in `texAutoDilate` | whether a claimed pixel is kept |

The unused axis is the fourth: **coherence of change events over space** — the verdict judges a pixel,
nothing judges a *region*. Every proposal below worth its cost gives the shader a region to reason about.

## 3. Where isolation actually fails today

1. **Thin interface is eroded by the gate's box count.** A line of width `n` fills `n / side` of the box,
   so a wider `AutoMaskIsolation` costs exactly the elements with the least evidence. §5.1 is the answer.
2. **Interior holes.** An element whose insides animate — a draining bar, a spinner, scrolling text —
   loses those pixels from the verdict, so bloom and every effect in the middle see them.
3. **A panel opening over an already-paused world.** Caught only if the opening lifts the *screen-wide*
   reading past `AutoMaskMotion`. A global test is being asked a local question.
4. **The camera-tethered character:** a character pinned to the camera's motion is taken for interface.
   The hand-placed ellipse that used to carve the region out is gone (§5.7), so the case is an open cost.
5. **A still patch of world beside a large animating one.** The premise is a single screen-wide share, so
   a river, a waterfall or fire large enough to clear `AutoMaskMotion` marks the world *drawn* and
   stillness is credited over every still pixel — including a wall or backdrop that never moved. §3.3 is
   the same global test failing on a different question (a panel over a *stopped* world); §5.10 is the
   option that would tell them apart by reading viewpoint change rather than picture change.

## 4. Avenues already closed

- **Image-based optical flow.** Built, watched in a real game, and removed; `docs/optical-flow.md` §6.2
  carries the negative result and its §3 and §5 the reasons — a sub-pixel-per-frame drift sits under any
  whole-pixel search floor, and a vector is not the same question as "is this HUD". The drift channel
  answers the same question per pixel, at full resolution, with no search, so a proposal that reopens
  this has to answer that loop failure first.
- **Depth, as a mask.** Confirmed unavailable: the overlay writes no depth, so depth speaks for the world
  and never for the interface, and a depth-change reading would veto the whole HUD the moment the camera
  moved. Depth *is* spent on the premise, as `AutoMaskDepthMotion`.
- **Per-element identity.** `docs/core-model.md` accepts conflating health with inventory by design.
  Nothing below asks for a label per element; pooling evidence over the region that *is* the element is a
  weaker and more useful goal.

## 5. The options

### 5.1 A region test instead of the box share

The gate asks "does this pixel belong to something with substance, or is it a speck?" A square box answers
a proxy. Two better-shaped tests were considered:

**Two directional densities, one per axis — shipped, with the diagonals added.** Keep a pixel while
*either* its row or its column clears a floor; a line along either axis fills its own row or column along
its whole length, while a speck fills neither. Both counts are free: the row count is `PS_DilateH`'s
`nearby`, and `texAutoDilate`'s unused `.b` takes the centre verdict so `PS_DilateV` can sum the column
from the tap it already takes. The floor cannot be `AutoMaskDensity`, which is a share of the **box**:
at the `33` default it comes to more still pixels than a row has (8.25 against 5 at radius 2), so no
pixel could clear it. A share of *that axis*, half of it, sits between a speck (`1/side`) and a full line.

The decisive limitation is the 45° one-pixel line: it has one pixel in every row *and* every column, so
both shares are `1/side` and it fails exactly as a speck does. The shipped version therefore counts four
lines — row, column and both diagonals — keeping the box share as a first door so the change can only
rescue a pixel the box dropped. A straight, vertical or diagonal one-pixel stroke is rescued at every
radius; a stroke between those slopes only while the pixels it lays in an axis clear
`max(reach + 1, 3)`, so the mid-slopes lapse as the radius raises that floor. The floor's minimum of 3
keeps a lone pixel, an adjacent pair and a short run out. `docs/core-model.md` carries the design.

One interaction decides how much the fix is worth: the gate judges the mask **after the closing**, so a
stroke the closing has already thickened along its own length is no longer thin to the box share. Measured,
a 1-px hairline is kept by the box share alone at **Mask grow radius `1`** and up, and only dropped at
`0` — so the door earns its keep where the closing is low, and at the default closing the visible
difference is a 2-px bar or a block's interior at a wide **Isolation radius**.

**Connected-component area — measured out.** The criterion is right — a component's area is line-preserving
in any orientation, where four axes cover only four directions — but the labelling is an unbounded
propagation. Over adversarial shapes, a comb of diameter 165 low-res texels needs **50** rounds where
`log2` of that diameter is 8, and a cap that stops a long component converging leaves its far texels
uncertified — dropped, which is the erosion the filter exists to fix. Distance-doubling converges in a
true `log2` of rounds but costs thousands of taps per texel per round, so the bounded-pass rule this repo
keeps is not satisfiable for exact component area.

*Where both stop.* Neither separates a one-pixel stroke at an in-between slope from a short run: a bounded
local count sees the same evidence, and an exact component would need an unbounded propagation. A stroke of
run 1 is never rescued by any bounded test here.

### 5.2 Fill interiors bounded by a persistent contour

§3.2 is what reaches bloom. A bounded fill of mask-enclosed regions closes it — but only if the enclosing
contour is trusted, or a gap in a panel becomes a hole punched through to the world. The depth-free trust
test is cheap: **require the contour to be persistent**, i.e. the same place and luma step for several
frames, reusing `AutoMaskEdge`'s taps plus one small per-pixel history.

**Measured out: built as a probe and watched in a game.** A **morphological closing** of the published
mask on a grid eight times coarser than the screen, drawn blue in the overlay, asked the per-pixel question
the tile map's hole reading cannot reach. A closing is bounded where §5.1's labelling was not, so it was
the right shape and cheap to build. It does not answer it: at the slider's minimum every marked pixel was
reachable from the border, so it marked the gaps between elements and open scenery rather than an interior.
Three measured reasons:

- **A closing is a local rule, and a hole and a gap give it the same evidence.** Two layouts differing only
  in topology — one element with a slot cut through it, two elements the same distance apart — present a
  byte-identical window at the band's centre. The difference is whether the two walls are the *same
  connected region*, which is the unbounded question §5.1 measured out.
- **The reach that fills an interior is the reach that bridges the gaps.** Gaps between interface run
  14–30 px; a menu interior is 130 px and up, and a closing spans about twice its reach.
- **The reduced grid breaks the contour before the rule runs.** Sampling the mask once per cell leaves a
  thin rim a dashed path, so a *closed* outline arrives open and there is nothing enclosed to fill.

The persistence test does not rescue it: a border broken into dashes is perfectly stable, so a history
would certify it as a trusted contour. A persistence store separates coincidental stillness from an
authored line; it cannot separate an authored line from an authored line with breaks in it.

### 5.3 Admit only non-isolated entrants

The cheapest spatial prior there is: a pixel may enter the mask only if it already has a masked
neighbour, so noise specks can never seed a region while real interface grows from whichever of its pixels
first holds still. One extra test at admission — not a new pass or target. Its failure mode is a genuinely
new element with no mask region anywhere near it, which needs a second door: an arrival event (§5.4) or a
high-confidence seed.

**Shipped, with the seed as the second door.** A pixel with no claimed neighbour is not refused but
*delayed*: it earns at half the rise (`AUTOMASK_SEED_SHARE`), so a region can only start from a pixel that
holds still for twice `AutoMaskRise`. That door is a share rather than a refusal because §5.4's arrival
event is measured out, so nothing else could certify a wholly new element and a refusal would leave one
unmaskable. It is four taps on the verdict channel the accumulator already holds, behind the live checkbox
`AutoMaskNeighbour` inside `AutoMask` — no pass, shader or target, so no definition. Both doors read the
verdict rather than colour, and it runs *before* the isolation gate rather than instead of it.

### 5.4 Localise the premise, for arrivals only — measured out

A panel opening over an already-stopped world is caught only if its opening lifts the screen-wide share.
The option was to read a *local* arrival — a wide change with no mask on it, while the world is stopped —
and unlock the rise for it. The instrument exists (§5.6's map publishes the reading; the overlay shows it),
and the answer is no: the reading fires, but the window it would cover is one or two frames while the
unlock would have to hold for the whole rise, and crediting a rise to a stopped world is the one thing the
premise exists to forbid. Its costs stack against it too: the map would have to leave the diagnostics
guard since the mask would read it, and a certification error holds scenery as interface, the worst
outcome this shader can produce.

### 5.5 Two one-line signal upgrades

Two changes to an existing signal rather than additions. They read **different quantities** and stand or
fall separately, so they are decided separately.

#### 5.5.1 Confidence-weighted count — measured out

The gate counts `step(0.5, neighbour)`; summing the neighbour's `confidence` instead removes the cliff at
exactly `0.5` and turns `AutoMaskDensity` into "share of confidence", staying on the verdict's own channel.

**The view was built, and it drew two flat colours rather than a ramp.** `UIDebugConfidence` splits the
accumulator's charge at the 0.5 verdict step: one colour for interface the mask already claims and another
for the band under the line it does not, leaving everything at or below zero as the plain picture. It needs
no pass, target or definition, draws on both paths, and reads the accumulator's own `.b` channel. Flat
colours were the second cut: a brightness ramp asked for shades to be compared and put the wide debt a move
leaves into the lower part of the scale, so healing world read as a halo.

**The band is dim drifting scenery, which is the wrong sign.** It is thin over UI interiors — the wanted
case — and **much larger over plain scenery with no menu open**, in the dim, smoothly shaded parts. Read
out over four rounds of in-game testing:

- **It is not a forgiving deadband.** At `AutoMaskEps = 1` the test is `maxDiff < 1`, i.e. the change must
  be *exactly zero*, so a credited pixel is provably bit-identical to its predecessor.
- **It is sub-resolution drift.** The comparison's baseline is one frame and its unit one whole level, so
  scenery sliding at a fraction of a level a frame reads as perfectly still. The per-frame change is
  roughly screen speed times local gradient, so dim low-contrast regions cross a level least. The same
  arithmetic is in `docs/optical-flow.md` §3.
- **The band is the heal, and its width scales with the rise.** Each level-crossing floors a whole patch,
  which then walks back up through the band. `AutoMaskMoveMemory` is exactly that walk, so sweeping it
  from `120` to `600` frames removed the band entirely, and the patch width tracks `AutoMaskRise`.
- **A longer drift horizon made it worse, which is the premise at work.** The channel can only *remove*
  credit per pixel, but it also feeds the changed count and so the world-drawn share: a longer horizon
  catches the drifting sky as changed, holds the premise up, and it is only while the premise is up that
  the dim scenery earns.

A weighted sum reads that same charge as **corroboration**, so at a fixed density the gate would keep
*more* of the drifting scenery, not less — the opposite of the sharpening the upgrade was for. Neither
spatial rule rescues it: admission delays a large region about twice rather than preventing it, and a band
several pixels across clears both of the gate's doors. The two spatial rules test *shape*, and this failure
is not a shape problem. Two mechanism notes stand regardless: a weighted sum is never more than the count
it replaces, so at a fixed density it drops less only where the charge is real, and it would make a region
still healing from a move count as weak support.

#### 5.5.2 Stratify stillness by magnitude — closed, and narrower than it looks

The verdict knows whether a change was *exactly zero* or merely inside the deadband, and a bit-identical
pixel is stronger evidence of an interface draw. **Its premise is narrower than the section first
assumed:** at the `AutoMaskEps` default of `1` every still pixel is already bit-identical, so the weighting
speaks only where the deadband is **2 or more** — a non-default setting rather than a general one.

**It was closed on 5.5.1's reading rather than on a change-size readout of its own**, which is a departure
from this repo's measure-first method and is recorded as one. The pixels the dim drifting scenery is
credited on are bit-identical to their predecessor by definition, and this is precisely the change that
would charge *those* pixels faster than any other, deepening the one failure this document has measured.

### 5.6 A tile map, off the tally that already exists

Every option above wants a coarse spatial map of "how much of this tile is still, or moving". The compute
path already builds that shape of statistic in `CS_Accum`'s `groupshared` tally, and a per-tile sum is the
same trick with a different index. A group is `[numthreads(64, 4, 1)]`, so the existing tally lands on a
64×4 block, not a square tile; a square map takes its own index and target, still at a handful of global
adds per group, and a fixed-size target keeps it resolution-independent.

**Built, with §6's readings, and kept for the spatial rules rather than for those options.** The map is
`CS_Tile`: a fixed 16×16 grid, 8 sample points per axis, each cell a *share* of itself rather than a tally,
which is what makes it resolution-independent without a per-pixel atomic. The readings are relaxations over
that grid, so their round count is `G × G`, a property of the grid rather than of the picture. It is gated
by the compute *and* diagnostics switches, because it is an instrument and exists only where it can be
seen, and nothing in the mask reads it.

Its own questions are settled — §5.2's fill, §5.4's arrivals and §5.8's ratio are all closed — so its
standing is now the tuning instrument for the isolation gate and the admission seed, which are region
questions no per-pixel view can show. It earns that on the test the repo applies to any instrument: honest
(its three readings were mirrored against an independent labelling and flood, 0 mismatches) and free at
rest (absent from all four compute-off and diagnostics-off variants).

### 5.7 Auto-place the center deadzone — dropped with the manual region

The center deadzone was the shader's one *authored* region, for a camera-tethered character the comparison
cannot distinguish from a HUD. It was **removed outright**: keeping it parked still ran the ellipse test on
every pixel of the full-resolution accumulator — 20 instructions in `PS_Accum` and 22 in `CS_Accum` — for
a branch false on every frame. With the manual region gone this option has nothing to seed, and auto-placing
a region nobody enables would be building on what was deleted. The case is an open cost in §3.4.

### 5.8 The alpha-composite signature — measured out, and the reading removed

Semi-transparent UI composites as `pixel = α · ui + (1 − α) · world`, so its frame-to-frame change is the
world's change attenuated by a spatially constant factor, and the ratio of a pixel's motion to its
neighbourhood's was to carry the `α`.

**The instrument it needs is not the one §5.6 built.** `CS_Tile` accumulates *coverage*, never magnitude —
a share of a region that changed cannot form a ratio of a pixel's motion to its neighbourhood's. The
magnitude exists only in the change-size histogram behind the auto-deadband, which is one distribution for
the whole frame with no spatial locality. So it was built as its own pass, `CS_Alpha`, each cell the mean
of the accumulator's graded motion over the taps that moved at all, against the grid's own rate over the
cells the mask does not touch.

**It was watched in a game and removed.** The failure is the graded channel, and it is arithmetic rather
than tuning: the accumulator stores `smoothstep(deadband−1, deadband+2, maxDiff)`, which **saturates at
one** — a certainty, not a magnitude. At `AutoMaskEps = 1` a one-level world change reads `0.26` and a
six-level one reads `1.0`, so a panel is detectable only where the world behind it moves by roughly 2–5
levels a frame: below that the world's own small change puts the ratio in the band and a panel is
indistinguishable from dim moving scenery, and above it both saturate and the attenuation is gone. The
three symptoms reported from a game are exactly this: dim scenery reading as attenuation, an open menu
reading as world, and a still panel reading as nothing at all. The instrument was removed with the
mechanism still unbuilt, and the semi-transparent case stays the documented limit. A future proposal owes
the repo a **proportional** magnitude first.

### 5.9 The depth check — shipped, and the only depth use that survives

The constraint that depth is unavailable for the interface is real but narrower than "unavailable":
`DepthBufferTex` is reachable, and the overlay writes no depth — a panel takes the scene's — so depth
describes the world and never the interface. That rules out a **mask**: a depth-change verdict would fire
on every HUD pixel whenever the camera moved, vetoing the whole element exactly when the mask has to form.
It does not rule out the **premise**, which is "is the world being drawn", a question depth answers
directly and a panel cannot hide the way it hides the picture. A per-pixel depth test adds false claims
over the world; the premise adds no per-pixel claim at all, only a screen-wide reading.

**Shipped** as `AutoMaskDepthMotion`, a fourth structural switch, off by default. It adds a pixel's depth
change to the changed count `CS_Finish` publishes, on its own step (`AutoMaskDepthEps`, a distance in
metres rather than a share, since the far plane ReShade supplies lets the change convert back). It can
only add to that count, never remove, and never touches the verdict. With no depth bound the sampled
texture is a constant on both sides, the difference is zero, and the reading is the picture's own exactly.
It owns one `R32F` target, written by the closing pass inside the guard and after the accumulator's read.
It does nothing for a panel over an already-stopped world — that stays §3.3's cost. Unverified in a game:
whether DSR's depth is usable and what step it needs; `docs/verification.md` names the scenario.

### 5.10 A viewpoint-change premise — the false witness §5.9 leaves standing, measured rare

§5.9 spends depth on the premise but keeps its **witness** unchanged: `AutoMaskDrawn` reads the share of
pixels whose *colour* changed, and that share cannot tell apart two things. A camera that moves repaints
the view, and a still pixel beside it is informative. A static camera over animating **texture** — flowing
water, fire, a scrolling UV, a video backdrop — repaints pixels too, but nothing about the viewpoint
changed, so a wall, a closed door or a menu backdrop is still ambiguous with a HUD. This is the
animated-neighbour form of §3.3's failure and the commoner presentation: a quiet room where *nothing*
animates at least has a stopped premise, while a room with a river in it does not.

`AutoMaskDepthMotion` does not close it, because water as moving **geometry** changes depth too, so the
`max` is more firmly on. What would close it is a reading of **viewpoint change** rather than picture
change, taken from a depth-change share instead of (or in addition to) the colour share: a still camera
over flowing water leaves depth flat, so the world reads as stopped and stillness is withheld, while a
camera pan or a scene change moves depth across the frame. It is a **global** reading for the reason §5.9
gives — a HUD over a static wall has the wall's own zero depth change.

**The trade is the mirror of the changed-share's, and it is not obviously a win.** Where the changed-share
banks a static world, a depth-change premise *withholds* stillness in every scene whose only animation is
textural, so a genuine HUD stops earning too. A persistent HUD survives (captured while the camera moves
and held after), but a notification fading in over static scenery may not be captured until the view moves.
It also still misses animated **geometry**. So it trades one false positive for one false negative and does
not close the class; the honest shape is to *select* between the witnesses rather than replace one with
the other.

**Measured in a game, and the answer is rare.** `AutoMaskDepthOnly` on a real scene showed the views it
names are reachable but **very few**, so the cost above is paid on a handful of frames rather than a mode
of play. Two things make that decisive. The false positive fires on *every* frame of such a view, while the
false negative it trades for needs a *fresh* element to appear during one with the camera dead still — a
persistent HUD pays nothing there. And selection is already shipped: the two controls are a live choice, so
the game that has these views keeps **Depth only** on for its own preset and every other game leaves it
off. Building the premise proper, or the blend of witnesses, would be a new unmeasured rule running on
every frame to serve views that turn up a handful of times.

Two causes of "the picture moved and depth did not" look alike, and only one is this section. *Textural*
animation under a still camera is the case, and **Depth only** is right there. A camera panning while the
depth term stays flat is a depth-configuration fault instead: a rotation swings the sampled distance at
every silhouette, so the symptom is the other one — a genuine element failing to be captured while the
view moves. Off-GPU, with no depth bound the depth share is zero, so the switch falls back to the colour
share rather than holding forever.

**The measurement is a live switch, not a probe.** A side-by-side reading would need a channel the
accumulator does not have, so the cheap form is to *select* the witness: `AutoMaskDepthOnly`, inside the
depth guard, makes `motion` the depth term alone instead of `max(depth, picture)`. It owns no pass, shader
or target, so it is a live checkbox and not a definition, and the arithmetic it changes is a single `max`.
It costs nothing already paid, and its label spells out the three states the pair reaches — picture alone,
both, depth alone. Its known failure is stated in `README.md`: with no bound depth the world reads as never
drawn, the same degradation the additive form turns into a harmless zero.

## 6. Measure first: the instrument

The repo's method is that a claim is measured before it is mechanised. The instrument here is a third
reading on the diagnostics overlay, beside the motion and verdict views:

- **Region coherence:** the connected-component count of the current mask, and the largest component's
  share of it. A mask of one or two large components makes §5.1's component test not worth its cost; a
  long tail of specks makes it worth everything, and the tail's size measures how much the isolation gate
  is being asked to clean up.
- **Holes:** the share of the screen that is mask-enclosed but unmasked — §3.2's size in the user's own
  game. Its floor is structural: a hole must miss the mask on about two cells in each direction before it
  registers, so a reading of zero is evidence of no *menu-sized* hole rather than of no holes.
- **Arrival candidates:** for §5.4, the count and total area of contiguous wide-change patches per frame
  during a stopped scene.

**Built, as one step with §5.6.** `CS_Tile` writes all three and the tile view (`UIDebugTile`) draws the
map behind them. The decisions left open:

- **The readings are relaxations over the grid, and the round count is its size.** A label only ever
  decreases toward the least index in its own region, so `G × G` sweeps settle any shape exactly. This is
  the bound §5.1 could not name at full resolution, and it is available only because the readings are
  taken at tile resolution: it counts cells of a 256-cell grid, a floor on the region it names. §5.1's
  component-area filter is therefore still measured out — this is a coarse instrument, not a revival.
- **Enclosure is a border-seeded growth, with the mask its only wall**: every cell but the mask conducts
  the growth and only world cells are counted, so a wide-change cell cannot wall the world off. Whatever
  the growth never reaches is enclosed, which makes the reading a *lower* bound on §3.2's size.
- **Holes are counted off the published mask**, i.e. after the closing, so a speck the closing grew around
  is not an enclosed region. That is the region a fill would act on.
- **A cell is interface when the mask touches it**, not when it fills it: a footprint reading, because most
  interface is thin against a 160×90 cell and a share threshold made every partial UI cell read black.
- **An arrival is gated by the premise, not only by the width of the change.** A wide-change cell with no
  mask on it is an arrival candidate only while the world is *not* drawn. Without the gate the reading was
  "what moved", which on a pan is the whole grid.
- **Wide is read off the accumulator's own graded motion channel**, not a raw frame difference the map
  measures for itself: measuring its own let the map call a held UI edge red, since a sub-pixel shift of a
  hard contour is tens of raw levels yet inside the verdict's deadband.
- **It is gated by compute and diagnostics together**, and read by nothing in the mask. The two count
  readings are stored against `AUTOMASK_TILE_COUNT_MAX` so a bar means something.

## 7. Conventions any of this must keep

- **Compute-only where the tile map is needed**, following the drift channel and the histogram: guarded by
  `AutoMaskCompute`, owning its targets, leaving the `AutoMaskCompute = 0` entry-point hashes
  byte-identical.
- **A live checkbox, not a structural switch**, for anything that owns no pass, shader or target of its
  own — the deadzone and isolation precedent — with the gate first in its own category. Anything with a
  pass or a target of its own gets a definition, read the other way: the tile view is the live toggle
  `UIDebugTile`, while the pass and targets behind it are the compute definition. The tile map needs
  **two** definitions at once, since the instrument is only usable where it can be seen.
- **A named bound** (`AUTOMASK_..._MAX`) for any capped iteration, as `AUTOMASK_DILATE_MAX` does, so the
  cap cannot drift from the loop that reads it.
- **Cost honesty in `README.md`.** The drift channel's cost claim and the flow probe's both had to be
  corrected once already; a tile map plus a reconstruction loop is an *addition*, not a retune.
- **Verification stays a review pass plus the offline check** — `uv run tools/verify_shaders.py check`,
  pixel-path hashes unchanged, no new warnings. None of this is verifiable without a game.

## 8. Summary of options

| | option | closes | cost | gate |
| --- | --- | --- | --- | --- |
| 5.1 | directional densities | §3.1 for axis and diagonal strokes; mid-slopes lapse as the radius rises | no new taps, riding the existing passes | live checkbox — **shipped, four-axis** |
| 5.1 | connected-component area | §3.1 in any orientation | the passes are not boundable, measured | live checkbox, compute-only — **measured out** |
| 5.2 | contour-bounded fill | §3.2 | fill + a small contour history | live checkbox — **bounded form built as a probe and measured out** |
| 5.3 | non-isolated admission | speck seeding | four taps on the verdict already in hand, and no new target | live checkbox — **shipped, with the seed as the second door** |
| 5.4 | arrival detection | §3.3 | tile map + a patch test | live checkbox, compute-only — **measured out: the window is narrower than the rise it would unlock** |
| 5.5.1 | confidence-weighted count | tuning sharpness | an overlay view off the accumulator, no pass or target | live checkbox inside the gate — **measured out: the band under the line is dim scenery drifting below the comparison's resolution, so weighting keeps more of it** |
| 5.5.2 | magnitude weighting | tuning sharpness, and only where the deadband is 2+ | none for the rule; it charges the pixels 5.5.1 was measured on faster | none — **closed on 5.5.1's reading** |
| 5.6 | tile map | its three readings; kept as the tuning instrument for the shipped spatial rules | a pass, a 16×16 target and a 2×1 reading target | compute + diagnostics — **shipped, and kept after the options it was built to decide were settled** |
| 5.7 | auto-placed deadzone | §3.4's manual tuning | off the tile map | — **dropped: the manual region was removed as unused** |
| 5.8 | alpha-composite ratio | reading only | a new per-cell magnitude statistic, built as a pass with a `RGBA32F` grid and a share target | compute + diagnostics — **measured out and removed: the graded channel saturates, so the ratio cannot separate a panel from moving world** |
| 5.9 | depth check | §3.3 in the common case (the panel no longer hides the drawing), not the panel over a stopped world | one `R32F` target, written on the closing pass; degrades to the picture's own premise with no depth bound | preprocessor definition, off — **shipped as `AutoMaskDepthMotion`** |
| 5.10 | viewpoint-change premise | the animated-neighbour form of §3.3 — a still patch banked because a *different* region repaints | a depth-change share in place of the colour share; still misses animated geometry, and withholds stillness in textural-only scenes | live checkbox — **the selector shipped as `AutoMaskDepthOnly` and the case measured rare in a game, so the selector is enough; the premise itself is not scoped** |

The four-axis door and the admission seed shipped; the tile map and §6's readings were built as one
instrument step with nothing wired into the mask, and the map outlived its brief because the two spatial
rules that *did* ship are region questions it is the only view of. §5.2's fill, §5.4's arrivals, §5.5's
confidence weighting, §5.8's ratio and §5.10's premise are closed with the reasons in their sections, and
§5.9's depth check is the one depth use that survives.
