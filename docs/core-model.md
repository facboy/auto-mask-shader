# The core model

How the mask is decided, and why each decision is what it is. Extracted from `AGENTS.md` so the
overview there stays short; read this when a change touches the per-pixel verdict, the one-sided hold,
the move memory, the clip exclusion, or the arithmetic the accumulator runs on.

Two techniques, and both placements are load-bearing:

1. `AutoMask` — must be **first** in the effect list, to see the untouched back buffer for the stability
   comparison and the frame it stores. Its last pass blacks the masked pixels in the live frame, so a
   bloom pass downstream has no UI to pick up.
2. `AutoMask_Restore` — must be **last**, putting the masked pixels back on top after the user's other
   effects have run. It is the only pass after which nothing else writes the frame, which is why the
   diagnostics corner marker is drawn there rather than in the overlay.

This shader and `UIDetectMulti` are **alternatives, not companions**: both want those same two slots, so
loading both means one reads a frame the other has already written into. The user avoids that rather
than the shader policing it at runtime, and the README says so plainly.

The mask is one full-resolution HUD/non-HUD value per pixel, not one per element. Conflating health with
inventory is accepted by design; per-element identity is not attempted.

The accumulator's verdict step is fixed at 0.5 and the frame sliders are converted into a step per
frame, so a slider position is the duration it names and nothing else is retuned with it. The move memory
is a count of still frames either way, and the debt it banks is `cost * AutoMaskMoveMemory`, whose depth
does not change how long repayment takes.

Above the per-pixel verdict sits **is the world being drawn at all?** — the premise, not a safety net under
it. Stillness alone proves nothing, since a wall holds still too, so a still pixel is taken for interface
only while the world around it animates. `AutoMaskMotion` is that share of the screen, and its default is
not 0: at 0 the map held on every frame and the mask never formed.

**The statistic is coverage, not magnitude.** The question is "is the game re-drawing the view", so
`PS_Motion` counts the share of each block whose pixels changed at all, thresholding the graded
magnitude just above zero (a still pixel scores exactly zero, so the flag comes from the same channel).
Averaging the magnitude instead let one small bright object in fast motion declare the whole view live —
the opposite of treating the screen as mostly backdrop.

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
already-paused scene, caught only if its arrival lifts the screen-wide reading over `AutoMaskMotion`.
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

### The isolation gate, which is the one spatial term

The verdict is per pixel and carries no spatial term, so a still pixel with no still pixel near it is
protected on the same evidence as a panel: a stuck pixel, a flat patch between two dithering regions, one
lone sample in a noisy gradient. The missing test is regional, and it belongs on the verdict rather than on
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
means one thing wherever the radius is set: `0` keeps every pixel, `100` wants a fully solid box. The one
consequence to know is that a line of width `n` fills only `n / side` of the box, so a wider isolation
radius erodes thin strokes at a fixed density.

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

What the door reaches, measured rather than assumed: a horizontal, vertical or either diagonal one-pixel
stroke lies along one of the four lines, so it is rescued at every radius — which is the §3.1 case, since
a line of width `n` fills only `n / side` of the box and the box share alone drops *every* one-pixel
stroke from radius 2 up. A stroke between those slopes lies along no single line, and is rescued only
while the pixels it lays in a row or a column clear the floor; where that lapses depends on its slope and
on the radius, which raises the floor with it. At the default radius 2 the one slope still dropped is 2 px
across per 1 px down; by radius 3 the floor is 4, so the run-2 and run-3 slopes lapse too. It is a live
checkbox rather than a fourth structural switch, by the same rule as the deadzone: it owns no pass, shader
or target, riding in the two the closing already has.

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

These are inherent to the signal, not tuning problems, and belong in the README rather than being
discovered:

- **Semi-transparent UI is never protected.** Where the world shows through, the pixel is not stable and
  never accumulates. Those elements stay with `UIDetectMulti`, which uses authored masks.
- **A quiet interior with no ambient animation can accumulate.** Standing still facing a wall or a closed
  door, nothing in frame moving, means the wall holds still. The world-drawn premise closes this rather
  than bounding it: a scene that never goes live never hands out a rise, so there is nothing to gain and
  nothing to tune a window around. Since stillness also cannot repay move debt while the world is stopped,
  a stopped scene is a one-way door — whatever it held when it stopped, it keeps or loses. What remains is
  the deliberate cost: a panel that opens over an already-paused world, whose opening is the only evidence
  in frame, caught only if it lifts the screen-wide reading over `AutoMaskMotion`. A small panel in a
  large still scene may not, and then nothing separates it from the backdrop, because a paused world and a
  quiet room look identical to this shader. Neither the move memory nor the drift channel helps, and for
  the same reason: a wall the player has been facing throughout never moved in the picture and never
  changes, so there is nothing to remember and no drift away from its own average. The move memory does
  catch the wall that was *walked past* and then stopped in front of, which is the common case.
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
