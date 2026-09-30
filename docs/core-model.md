# The core model

How the mask is decided, and why each decision is what it is. Extracted from `AGENTS.md` so the
overview there stays short; read this when a change touches the per-pixel verdict, the one-sided hold,
the move memory, the clip exclusion, or the arithmetic the accumulator runs on.

Two techniques, `AutoMask` first and `AutoMask_Restore` last, and this shader is an alternative to
`UIDetectMulti` rather than a companion — `AGENTS.md` carries both rules and the reason for each.

The mask is one full-resolution HUD/non-HUD value per pixel, not one per element. Conflating health with
inventory is accepted by design; per-element identity is not attempted.

The accumulator's verdict step is fixed at 0.5 and the frame sliders are converted into a step per
frame, so a slider position is the duration it names and nothing else is retuned with it. The move memory
is a count of still frames either way, and the debt it banks is `cost * AutoMaskMoveMemory`, whose depth
does not change how long repayment takes.

The one state machine this describes runs in two places — `PS_Accum` and, on the compute path,
`CS_Accum` — so its parts that do not sample anything are shared helper functions in
`Shaders/AutoMask.fxh`: the premise, the decay step, the published-mask read, the deadband, the
pinned-colour count and the frame rate. Each takes what it needs sampled already, because the two paths
read their textures differently (`tex2D` against `tex2Dlod` with an explicit level) and a helper that
sampled would move one path's sampling onto the other's. The drift terms stay behind the compute guard in
the `.fx`, since the pixel path has no drift pass at all. The header is included *after* the uniforms and
targets the helpers read — the dialect has no forward declaration — and it holds no uniform, target or
technique of its own.
`docs/refactor-candidates.md` records the fold and how it was checked.

Above the per-pixel verdict sits **is the world being drawn at all?** — the premise, not a safety net under
it. Stillness alone proves nothing, since a wall holds still too, so a still pixel is taken for interface
only while the world around it animates. `AutoMaskMotion` is that share of the screen, and its default is
not 0: at 0 the map held on every frame and the mask never formed.

The share is taken over **the pixels that could change, not the whole buffer.** A pixel pinned at all 0 or
at all 255 can never show a difference — 'staying at all 0' is saturation, not stillness, as the clip
exclusion below says — so every such pixel permanently lowers the ceiling the share can reach. A
letterbox, a hard fade or a mostly black view is not a little of that: at 44% of the frame inert no
camera movement can read above 56%, so at the `70` that setting used to be given the world was never seen
as drawn and the mask could not form. Dividing by the pixels that can move makes the premise mean what it
says — *of the pixels that could change, how many did* — and stops it depending on how much of the
picture happens to be black. It is the same flag the verdict already computes, so nothing new is
measured; the excluded pixels are counted instead of silently damping the result.

**The statistic is coverage, not magnitude.** The question is "is the game re-drawing the view", so
`PS_Motion` counts the share of each block whose pixels changed at all, thresholding the graded
magnitude just above zero (a still pixel scores exactly zero, so the flag comes from the same channel).
Averaging the magnitude instead let one small bright object in fast motion declare the whole view live —
the opposite of treating the screen as mostly backdrop.

**The depth buffer is a second witness to the premise, and only to the premise.** The overlay writes no
depth — a panel drawn over the scene takes the scene's own depth — so depth describes the world and never
the interface, which is why it cannot carry a per-pixel verdict: a pixel whose depth changed is every HUD
pixel too, since the world behind the panel is what the depth shows, so a depth-change test would veto the
whole mask whenever the camera moved. What that absence buys is a reading a panel cannot hide: a panel
removes most of the changed pixels from the *picture*, so a large enough one pushes the share under
`AutoMaskMotion` and the world stops reading as drawn precisely while the panel is open — the premise
questioning a witness the panel itself is hiding. Depth is transparent to that, and to the overlay. So
`AutoMaskDepthMotion` lets a pixel whose depth changed join the changed count the reduce publishes, on its
own step — `AutoMaskDepthEps` is a *share* of the surface's own distance, since depth is a distance and not
an 8-bit channel, which drops the far plane out and lets a walk reach the ramp — and
can only *add* to that count — never remove, never touch the verdict, never protect a pixel on its own. Its
ramp is footed at half that step, unlike the colour witness, which counts any change at all: a share of a
distance spans three orders of magnitude with range, and past a certain distance the depth buffer's own
noise is the same size as the walk's change, so the floor is what keeps that noise out of the share while a
near walk still clears it. A
depth buffer that is not bound reads as the same constant on both sides of the comparison, so the
difference is zero, the count is the picture's own exactly, and the switch degrades to the pixel path
rather than needing a separate fallback. What it does not fix: a panel over an already-stopped world,
where the depth is stopped too and there is no drawing to point at.

**`AutoMaskDepthOnly` is the other question asked of the same cue:** whether the premise should read
*viewpoint* change rather than *picture* change. `AutoMaskDepthMotion` adds depth to the picture's reading,
so a scene whose only movement is texture — water, fire, a scrolling UV — still reads as drawn and a still
patch of world beside it is claimed (the limit below). With the checkbox on, `motion` becomes the depth
term alone, so a depth-static scene reads as stopped and the premise holds instead; only its geometry
moving — a camera move, a scene change, an animated mesh — marks the world drawn. It owns no pass, shader
or target, so it is a live checkbox inside the depth guard by the same rule as admission and the isolation
gate, and the arithmetic it changes is one `max`. It is a measurement rather than a feature: it trades the
colour share's failure for the depth share's — a textural-only scene now withholds stillness from a genuine
HUD — and with no bound depth the term is zero, so the world never reads as drawn and the mask never forms.
`README.md` states both, and `docs/ui-isolation-options.md` §5.10 is the option it measures.

`AutoMaskEps` counts whole levels out of 255 — the only unit an 8-bit history has — so a fractional value
is a position that cannot exist, and its minimum is 1: one level is the smallest movement there is and so
the most sensitive position, while the old "0 means off" kept the motion channel, the debt and the overlay
alive with the mask never forming. It decides one thing only, whether the frame moved a pixel; what a
change *costs* is `AutoMaskFall` and `AutoMaskMoveMemory`'s business, and the overlay reading — the same
channel the verdict comes from — must not be conflated with the cost banked against the verdict. The two
verdicts are complements of one number rather than two tests that meet: the deadband is
`max(ceil(AutoMaskEps), 1)`, a pixel still below it and moving at or above it, and the ramp spans a fixed
three levels footed one under the deadband (`smoothstep(deadband - 1, deadband + 2, maxDiff)`). The foot
sits a full level under so the smallest setting sees any change at all, and the span is fixed rather than
scaled with the deadband — a ceiling that moved with it (`deadband * 4 - 1`) squashed the first visible
levels toward zero as the slider rose (its own level read 0.26 at 1 but 0.005 at 8) — so the integer
levels around the deadband stay the boundary at every position and the setting's own level reads a quarter
of full strength everywhere.

On the still side the reading becomes a **hold**, one-sided: while the world is not being drawn a still
pixel is carried over untouched — no rise, no fall, no heal — while a moving pixel still falls. A stopped
scene can therefore only lose mask, because a stopped world cannot tell a held HUD from its own backdrop,
so stillness is not credited as interface there. The windows that used to express that (`AutoMaskTrust`,
`AutoMaskSettle`) and their still-frame counter are gone; the cost is a panel that opens into an
already-paused scene, caught only if its arrival lifts the reading over `AutoMaskMotion`.
Holding rather than adding also closes the old freeze's failure: a still frame used to repay move debt
either way, so a camera pan that left the whole backdrop in debt cleared in lockstep, the entire screen
crossing into the mask ~`AutoMaskMoveMemory` frames after the motion stopped. Now the heal is part of
crediting stillness and stops with it — a stopped world repays nothing.

One further exclusion follows from what the channels can tell the comparison: a frame pinned at all 0 or
all 255 is never read as a hold. A wholly clipped colour is saturated rather than proved motionless — the
frame that ran it against the rail pushed it there, so the difference reads zero whatever the game does
underneath — so 'staying at all 0' is not 'staying still', while moves onto and off a rail are read as
usual. A single pinned channel does not void the verdict: the visible channels still carry the evidence,
and voiding on any channel would mis-punish the one-level move off a rail the deadband exists to forgive.
The cost is a frame presented as flat 0 or flat 255 — a letterbox bar, a hard fade, a sky at the top of
the range — earning nothing while it holds; that is the side to be wrong on, because a clipped backdrop
filling the mask is the failure the verdict exists to prevent. In a stopped scene the exclusion is also a
one-way door: a pinned frame takes the moving branch, so the letterboxed region keeps losing mask until
the colour un-pins.

Stillness is only a hint — the world holds still too — and motion is proof, so the per-pixel signal is
trusted asymmetrically. A change that lasts longer than the hold is **remembered** as what re-rendering
from a new viewpoint looks like, and no panel is drawn that way. The memory lives in the sign of the
accumulator's confidence, negative and clamped to the deepest a single move can reach, and a still frame
pays back one frame's worth — so the two ends run on their own timescales: `AutoMaskRise` still frames to
protect (fast, or a HUD is never captured) against `AutoMaskMoveMemory` still frames to recover from a
move (slow, so it outlasts a camera movement). `AutoMaskMoveMemory` is a duration rather than a confidence
budget, and 0 restores the old behaviour exactly. Movement inside the hold is bridged and never banked,
which keeps a draining bar or a scrolling list protected; past the hold it costs the element its
protection until the debt clears, one frame of the unmarking countdown per changing frame however small.
The graded magnitude survives only in the overlay, where red is the reading the user watches.

The frame sliders are whole frames, not confidence per frame: "X frames still before marked" is the fixed
verdict step divided by X, and the conversion keeps a hair above the exact share (0.504 rather than 0.5) so
the half-precision accumulator crosses the step on the frame it should and not one either way. Keep
`AutoMaskFall`'s frames at or under `AutoMaskRise`'s, or the mask lingers over moving scenery.

### Admission, the spatial term upstream of the verdict

The verdict is per pixel, so a lone still pixel is credited on the same evidence as a panel: a stuck
pixel, a flat patch between two dithering regions, one lone sample in a noisy gradient. The isolation
gate below removes such a pixel *after* the fact; admission stops most of it from being claimed at all.
A pixel no claimed neighbour touches earns at `AUTOMASK_SEED_SHARE` of the usual rate, so a region can
only start from a pixel that holds still for twice `AutoMaskRise`, and a lone speck has nothing to grow
from. It is the cheapest spatial prior there is — four taps against the verdict the accumulator already
holds, no pass and no target — and it shrinks the gate's job rather than duplicating it.

The neighbour is read off the verdict channel, not colour, exactly as the gate counts it, so a HUD's
own high-contrast interior still supports its pixels. Its failure mode is a genuinely new element with
no mask region anywhere near it: the seed rate reaches it, only twice as late. That is the price of the
door and it is why the rate is a share of the rise rather than a refusal.

### The isolation gate, the spatial term that removes

The verdict is per pixel and carries no spatial term, so a still pixel with no still pixel near it is
protected on the same evidence as a panel: a stuck pixel, a flat patch between two dithering regions, one
lone sample in a noisy gradient. Admission above turns that into a delay for the pixel with no neighbour;
the gate is what still removes one. The missing test is regional, and it belongs on the verdict rather than on
colour — a neighbour counts toward a pixel only when the comparison itself calls it still. Colour similarity
is the closing radius's own question and the wrong one here, since a HUD's edges are high-contrast while a
speck's neighbourhood is whatever the scene happens to be.

So the gate rides in the two closing passes, in the channels they leave unused. `PS_DilateH` counts the still
pixels in each output pixel's row and writes the count into `.g` of `texAutoDilate` scaled by
`AUTOMASK_COUNT_SCALE`, so a whole count lands on a whole byte, and writes the centre's own verdict into
`.b`; `PS_DilateV` sums those rows into the box's still total and reads `.b` down the column, across the
two diagonals, for the line test below. The box is the isolation radius (`AutoMaskIsolation`), not the
closing's: the closing is how far the mask is grown, which is about shape, while the box is how much
corroboration a pixel needs, which is about evidence, and tying them would move the gate's meaning
whenever the closing is retuned. It is read as one pixel at the bottom so the setting cannot silently
switch the filter off, and it is applied to every masked pixel rather than only the ones the verdict
claimed, so what the closing grew around a speck goes with it. Only the growth keeps the luma bound: a
contour inside a HUD must not cost the pixel support.

The test is a **share** of that box, not a count of pixels: `AutoMaskDensity` percent of its area, the
pixel itself counted. A count would be capped by the smallest box's area, so the same slider value would
mean a solid box at one radius and a sparse one at another — 100% at a 3×3 and 18% at 7×7. As a share it
means one thing wherever the radius is set: `0` keeps every pixel, `100` wants a fully solid box. A line
of width `n` fills only `n / side` of the box, so a wider isolation radius erodes thin strokes at a fixed
density.

**A second door answers that consequence: one line through the pixel is enough.** Along one of the four
lines through a masked pixel — its row, its column, its two diagonals, each within the same isolation
radius — a stroke holds its whole length, where the box asks it to fill a share of an area it is too thin
to fill. The pixel is kept while its box clears the density *or* its best line clears
`max(reach + 1, AUTOMASK_AXIS_MIN)`: `reach + 1` is more than half the 2·reach+1 line, and
`AUTOMASK_AXIS_MIN` is 3, the whole of the smallest line, so a lone pixel, an adjacent pair and a short
run stay specks. The row count is `PS_DilateH`'s own `.g`; the column and the two diagonals come off the
centre verdict `.b` that pass now publishes, read at the taps `PS_DilateV` already takes, so the door costs
no new pass, no new target and no extra uniform — a handful of taps in a pass that already runs, and only
while the gate is ticked, because they are skipped with it. The door keeps the property the count does: it
is on the verdict, not on colour. And because the box share stays as a first door rather than being
replaced, the gate can only **rescue** a pixel the box dropped and never newly drops one, so with the
checkbox clear the mask is byte-identical to the closing alone.

What the door reaches: a horizontal, vertical or either diagonal one-pixel stroke lies along one of the
four lines, so it is rescued at every radius — which is the §3.1 case, since a line of width `n` fills
only `n / side` of the box and the box share alone drops *every* one-pixel stroke from radius 2 up. A
stroke between those slopes lies along no single line, and is rescued only while the pixels it lays in a
row or a column clear the floor; where that lapses depends on its slope and on the radius, which raises
the floor with it. At the default radius 2 the one slope still dropped is 2 px across per 1 px down; by
radius 3 the floor is 4, so the run-2 and run-3 slopes lapse too. It is a live checkbox rather than a
fourth structural switch, by the same rule as admission: it owns no pass, shader or target, riding in
the two the closing already has.

**The closing radius sets how much there is left to rescue.** The gate runs on the mask the closing
produced, and the luma bound stops the closing growing *across* a contour but not *along* it: a one-pixel
hairline is thickened along its own length into a band the closing's width, and that band is wide enough
for the box share to clear on its own. Measured on flat-luma-free scenery, a 1-px hairline against a
180-level step is kept by the box share alone at closing radius `1` and up, and only dropped when the
closing is `0` — the pass-through position, where the gate is looking at the verdict itself. So the door
earns its keep where a stroke stays thinner than the closing made it: with the closing at `0` a 1-px
hairline goes from 0% kept to 100%, and at any closing the 2-px bar and a solid block's interior are
rescued at isolation `3`. Tuning the door therefore means setting the closing low enough that the gate has
a thin stroke to judge, which is the opposite of tuning the closing for shape.

The heal is one frame of the unmarking countdown per still frame, part of the same credit as the rise, so
it happens while the world is drawn and stops while it is not — a stopped world is not evidence.
`AutoMaskForget` protects a briefly-animating element from being banked at all and runs as a balance
rather than an unbroken run: a changing frame adds one to the bridge and a still frame pays half of one
back, so the bridge banks while the animation outweighs its pauses; it and `AutoMaskMoveMemory` are tuned
against each other. An unbroken run let a pixel that animates with still gaps inside every window — a list
scrolling at half the frame rate, flickering shimmer — hold its mask indefinitely while visibly animating.
The comparison is quantized onto whole levels and the **level counts** are what it subtracts
(`round(now * 255.0)` against `round(before * 255.0)`), not the quantized colours. The history is stored on
that grid, so on a higher-precision back buffer a sub-level change would otherwise be forgiven by the
deadband while the overlay's gain painted those same small differences red — but subtracting the stored
colours rather than their levels makes most one-level changes read a hair under a level, `0.9999999` on 247
of the 255 adjacent pairs (the exceptions are the binade edges), which `maxDiff < deadband` forgives at
`AutoMaskEps = 1`. The most sensitive setting caught only 8 of the 255 one-level changes; comparing the
counts makes it 255 of 255, which is what "the most sensitive" has to mean. The clip exclusion is checked
after the quantization, on the grid the comparison itself speaks, so the pinned colour and the history
agree on what 'all 0' and 'all 255' mean.

## The `.fx` constraints that shape the design

- **A render target cannot be read while it is written.** So the accumulator has to **ping-pong**: read
  `A`, write `B`, then a copy pass brings `B` back to `A`. Compute adds one more form of the same rule: a
  texture written as storage in a pass cannot also be sampled in it, and a compute pass has no render
  target at all — the accumulator's write in `CS_Accum` is a `storage2D` write to `texAutoAccumB`.
- **There are no shared textures.** `ReShade.fxh` declares only `BackBufferTex` and `DepthBufferTex`, so
  another effect's stored frame is unreachable. This shader needs its own store target; it cannot borrow
  `UIDetectMulti`'s `texColorBeforeMulti`.

## What the signal cannot do

These are inherent to the signal, not tuning problems, and belong in the README:

- **Semi-transparent UI is never protected.** Where the world shows through, the pixel is not stable and
  never accumulates. Those elements stay with `UIDetectMulti`, which uses authored masks.
- **A quiet interior with no ambient animation can accumulate.** Standing still facing a wall or a closed
  door, nothing in frame moving, means the wall holds still. The world-drawn premise closes this rather
  than bounding it: a scene that never goes live never hands out a rise, so there is nothing to gain and
  nothing to tune a window around. Since stillness also cannot repay move debt while the world is stopped,
  a stopped scene is a one-way door — whatever it held when it stopped, it keeps or loses. What remains is
  the deliberate cost: a panel that opens over an already-paused world, whose opening is the only evidence
  in frame, caught only if it lifts the reading over `AutoMaskMotion`. A small panel in a
  large still scene may not, and then nothing separates it from the backdrop, because a paused world and a
  quiet room look identical to this shader. Neither the move memory nor the drift channel helps, and for
  the same reason: a wall the player has been facing throughout never moved in the picture and never
  changes, so there is nothing to remember and no drift away from its own average. The move memory does
  catch the wall that was *walked past* and then stopped in front of, which is the common case.
- **A still patch of world beside a large animating one can accumulate too.** The premise is one screen-wide
  share, so it answers "is anything being drawn", not "which part". A river, a waterfall or fire covering
  enough of the view clears `AutoMaskMotion`, the world reads as drawn, and stillness is then credited
  everywhere — including a wall, a closed door or the backdrop behind a menu, none of which moved. The
  quiet interior above is the same failure with *nothing* animating; this is the form where the world is not
  stopped, only the patch that gets taken, and it is the commoner one. Depth does not close it: as moving
  geometry, water changes depth too, so `AutoMaskDepthMotion` holds the premise up rather than down. What
  distinguishes the two cases is whether the *viewpoint* changed, not whether pixels changed — the option
  `docs/ui-isolation-options.md` §5.10 records, unscoped.
- **Scenery that drifts too slowly to change a pixel between two frames.** The comparison's baseline is one
  frame and its unit is one whole level, so scenery sliding across the screen at a fraction of a level a
  frame reads as *exactly* no change — and no change is the whole of the evidence the verdict asks for.
  This is not the quiet interior and is not closed by the premise: the world genuinely is being drawn, so
  the crediting follows the shader's own rules, and the drifting region genuinely is a run of pixels that
  held still. Dim, smoothly shaded regions are where it bites, because the same movement across the screen
  changes a level far less there than on bright detail. The move memory does not close it either, in its
  ordinary form: there is no single move to remember, only a drift. It reaches the case only where the
  memory outlasts the interval between the drift's level crossings — each crossing knocks the pixels back,
  and the memory sets whether they heal before the next one, which is why sweeping it from `120` to `600`
  frames removes the credit outright. The drift channel is the reading built for movement this slow, since
  its baseline is long enough for the drift to accumulate into whole levels; but it also feeds the
  world-drawn count, and on the scene measured a longer horizon made the credit *worse*, because catching
  the drifting sky held the premise up. §5.5.1 of `docs/ui-isolation-options.md` carries the readings.
- **Something animating in a stopped scene is given up.** A spinner, a flashing icon, a background loop:
  while the world is not being drawn those pixels are still changing, so they read as moving and fall out
  of the mask even though they may genuinely be interface. That is the price of the hold being one-sided,
  and the right side to be wrong on — protecting a moving pixel in a stopped scene means protecting the
  backdrop the moment it happens to be the thing that moved.
- **Bloom can still find an edge at the HUD contour.** Suppression removes the UI as a bloom source, but a
  hard black step against a bright scene is itself contrast. Neither this shader nor `UIDetectMulti` blurs
  that step: the pack's blend is `lerp(colorOrig, color, maskChan)`, exactly proportional to the mask,
  over unfiltered samplers and masks that were hard-edged in practice. The softness either comes from the
  mask (there) or from the map (here, via `AutoMaskDilate` and the luma stop); nothing is added by the
  anti-bloom pass itself.
- **A HUD that flickers without moving is given up by the drift channel.** Dithering and temporal
  anti-aliasing make a static pixel wander a level or two frame to frame, and a working average is what
  reads that as drift: measured on the compute path, an element that oscillates by two levels at 60 fps
  loses its mask at the 2 s default where the pre-fix channel kept it only because it was frozen. This is
  the deliberate price of the channel doing its job, and there is no setting that escapes it: a shorter
  horizon trades away the *slowest* drift it was catching, and a higher RGB step forgives the flicker but
  raises the drift comparison's own deadband by the same amount, since the drift reading is compared
  against that same number — so it gives up the same slow end rather than buying the element back. A
  one-level flicker is safe at every horizon because the short comparison forgives it first; a two-level
  flicker and drift at 0.05 levels a frame cannot both be had, and the motion view is where to see how
  much drift each slider position still catches.
- **HUD that animates more than briefly** needs the hold to bridge it, which makes `AutoMaskForget` the
  most important slider rather than a nicety — and it is a hard boundary rather than a matter of degree:
  animation that fits inside the hold is bridged and never banked, while animation that outlasts it is
  taken for the world and costs the element its protection until `AutoMaskMoveMemory` still frames have
  passed. The two sliders are tuned against each other — `AutoMaskForget` must exceed the longest
  animation any real element performs.
