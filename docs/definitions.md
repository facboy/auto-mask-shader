# Definitions

The vocabulary the shader, the README and the subject docs share, defined once in the sense *this*
shader gives the word. Entries are grouped so each term sits beside the ones it is read against —
`deadband` with `ramp` and `still`, `walk` with `bin` and the histogram. Where a word carries two senses
here — `bank`, `gate`, `hold`, `motion` — both are listed under it.

## The mask and the approach

- **HUD** — the game's interface: the health bar, inventory, map, dialogue box. One side of the one bit
  the mask carries; the world is the other.
- **mask** — one full-resolution HUD/non-HUD value per pixel, written into `texAutoHistory`'s alpha.
  Not one per element: per-element identity is not attempted, and conflating health with inventory is
  accepted by design (`docs/core-model.md`).
- **published mask** — the mask as the restore, anti-bloom and tile passes read it, i.e. after the closing
  radius. The verdict is the same decision *before* the radius, which is what the verdict view draws. It
  rides the history's alpha beside the frame, so the same target answers "what were these pixels" and
  "which of them are interface".
- **element / panel** — a piece of interface. The mask holds no notion of one, so "an element keeps its
  mask" always means the pixels of it do.
- **speck / isolated pixel** — a pixel the verdict claims with too few still pixels around it to be
  interface: a stuck pixel, a lone sample in a noisy gradient. What the isolation gate drops.
- **admission / `AutoMaskNeighbour`** — the spatial term upstream of the verdict: a pixel no claimed
  neighbour touches earns at `AUTOMASK_SEED_SHARE` of the usual rate, so a region can only start from a
  pixel still for twice the rise, and shrinks the isolation gate's job rather than duplicating it. A live
  checkbox inside `AutoMask`, off by default (`docs/core-model.md`).
- **seed rate** — `AUTOMASK_SEED_SHARE`, the `0.5` admission multiplies the rise by for a pixel with no
  claimed neighbour. A share rather than a refusal, so a wholly new element still arrives, twice as late.
- **isolation gate / `AutoMaskIsolated`** — the one spatial term on the verdict *that removes*: a masked
  pixel is kept while its neighbourhood holds `AutoMaskDensity` percent of still pixels, itself counted,
  over the isolation radius — or while one line through it clears the line door. Both tests read the
  verdict and not colour, unlike the closing radius, which only grows the mask. A live checkbox, off by
  default (`docs/core-model.md`).
- **neighbourhood / the box** — the `2r + 1` square the gate reads, `r` the isolation radius. A fixed-size
  box, so the density is the only thing that decides the outcome once the radius is set.
- **density** — `AutoMaskDensity`, the share of that box that must be still, itself counted. A *share*
  rather than a count so it means one thing at every radius: a count would need a cap at the smallest box's
  area, and would mean 100% at one radius and 18% at another. `100` is a fully solid box, `0` keeps
  everything. A line of width `n` fills `n / side` of the box, so a wider box erodes thin strokes.
- **isolation radius / `AutoMaskIsolation`** — `r` for the box the density is measured over, deliberately
  its own setting rather than the closing radius: shape and evidence are different questions, and tying
  them would move what `AutoMaskDensity` means whenever the closing is retuned. Read as 1 at the bottom so
  the setting cannot silently switch the filter off, and capped at `AUTOMASK_DILATE_MAX` because it rides
  the closing's loop — so raising it costs no pass or target, though its width sets how far that loop
  runs.
- **text box / `__UNIFORM_INPUT_FLOAT1`** — the widget `AutoMaskDensity` uses (`ui_type = "input"`): a
  typed field rather than a track, so a share can be set exactly. The other uniform in its category is a
  slider; the widget family follows what the value means.
- **authored mask** — a hand-painted mask image with coordinates and per-element configuration, the
  approach this shader replaces. `UIDetectMulti` uses them.
- **`UIDetectMulti`** — Kaiser's pack, where the concept, the store/restore pattern and the anti-bloom
  trick come from (building on work by Brussels1). An *alternative*, not a companion: both want the
  first and last effect slots, so loading both means one reads a frame the other has written into.

## The signal

- **premise / world-drawn / drawn** — above `AutoMaskMotion` percent of the screen changing, the world is
  taken as being drawn, and only then may stillness be credited as interface. The percent is of the
  pixels that *could* change, not of every pixel: a pinned region is counted out of it. A premise rather
  than a safety net under the verdict, so its default is not `0` (`docs/core-model.md`).
- **depth check** — `AutoMaskDepthMotion`, off by default: a pixel whose linearized depth changed joins
  the changed count the gate reads, on its own step (`AutoMaskDepthEps`, a distance in metres, since the
  depth converts back to metres against the far plane ReShade supplies). It can only add to that count,
  never touch the verdict, and with no depth bound the difference is zero. Depth is the world's, since the
  overlay writes none, so it is a second witness to the premise and never a mask (`docs/core-model.md`).
  With it compiled in, `AutoMaskDepthOnly` picks the witness the reading is taken from — depth added to
  the picture, or depth alone.
- **coverage** — the share of a block whose pixels changed at all. The statistic, deliberately not the
  magnitude: averaging magnitude let one small bright object in fast motion declare the whole view live.
- **motion** — two senses. The *flag*: this pixel changed at all, which is what the gate counts. The
  *graded reading*: how far it changed (`smoothstep` of the difference), kept for the overlay's motion
  view and not for the verdict. Only the flag is load-bearing.
- **level** — one step of 8-bit colour, `1/255`. The unit of `AutoMaskEps`, the deadband and the luma
  step, and the only unit an 8-bit history has.
- **maxDiff / maxDrift** — the largest of the three channel differences in whole levels, against the
  previous frame and against the drift average respectively (`max(diff.r, max(diff.g, diff.b))`). What
  the deadband and the ramp test.
- **deadband** — the smallest change in whole levels counted as motion: `max(ceil(AutoMaskEps), 1)`, or
  the measured step instead while auto-detect is on. Below it a pixel is still, at or above it moving;
  the two verdicts are complements of one number rather than two tests that meet (`docs/core-model.md`).
- **ramp** — `smoothstep(deadband - 1, deadband + 2, maxDiff)`: the graded motion reading over a fixed
  three-level span footed one level under the deadband, so the most sensitive setting sees any change at
  all and the setting's own level reads a quarter of full strength. The drift side has its own ramp, from
  the deadband to `AUTOMASK_DRIFT_LAG` deadbands: it grades the average's lag over the whole range the
  average is allowed to reach, and tops out exactly where that bound clamps.
- **still / stable** — a pixel whose `maxDiff` is under the deadband (on the compute path, under it on
  both comparisons) and whose colour is not pinned. **Moving** is the complement.
- **clip exclusion / pinned colour / rails** — a frame at all `0` or all `255` is saturated rather than
  proved motionless, so it never reads as a hold; moves onto and off a rail are ordinary changes, and a
  single pinned channel does not void the verdict. In a stopped scene it is a one-way door.
- **hold (the held frame)** — while the world is not drawn a still pixel is carried over untouched: no
  rise, no fall, no heal. One-sided, so a moving pixel still falls.
- **one-way door** — the property that follows from the hold and the clip exclusion: a stopped scene can
  only hold or lose mask, never fill in (`docs/core-model.md`).
- **noise** — movement in the picture with nothing moving behind it: dithering, temporal anti-aliasing,
  shimmer. What the RGB step forgives and the noise floor measures.
- **dithering / temporal anti-aliasing (TAA)** — the two named sources of noise, making a static pixel
  differ by a level or two frame to frame (`README.md`).
- **sub-level** — a change smaller than one whole level, so the comparison rounds it to exactly zero.
  The case the drift channel exists for (`docs/compute-path.md`).
- **sub-resolution drift** — scenery sliding across the screen slowly enough that the per-frame colour
  change stays under one level, so the verdict's one-frame comparison reads it as perfectly still and
  credits it as interface. The same arithmetic as sub-level, applied to the world rather than to a
  flickering element; the drift channel is the reading built for it, and the move memory is the other
  lever, since each level the drift does cross knocks the pixels back (`docs/core-model.md`).
- **quiet interior / quiet majority** — a quiet interior is a scene with nothing animating, where
  stillness proves nothing; the quiet majority is the still bulk of the screen a noise floor can be read
  off (`docs/compute-path.md`).
- **backdrop / scenery / world / picture** — the non-interface side of the frame, used interchangeably.
  "World" also names the premise.

## The accumulator

- **accumulator** — the per-pixel state machine, in a ping-pong pair: `texAutoAccumA` is `RG16F` under
  compute (`RGBA16F` on the pixel path) since it is read as `.r`/`.g` only, and `texAutoAccumB` is
  `RGBA16F` because `tex2Dstore` has no `float2` form to narrow its store to
  (`docs/performance_compute.md` §3). Together they hold `.r` confidence, `.g` hold, `.b` motion, `.a`
  whether the pixel could speak (it was not pinned).
- **confidence** — `.r`: positive credit toward interface, negative the move debt. The verdict is
  `step(0.5, confidence)`.
- **verdict step** — `0.5`, fixed. The frame sliders are converted into a step per frame against it, so
  the step itself is never retuned.
- **gain / cost** — the per-frame credit and charge, `0.504 / AutoMaskRise` and `0.504 / AutoMaskFall`.
  The `0.504` keeps a hair above the exact share so the half-precision accumulator crosses the step on
  the frame it should (`docs/core-model.md`).
- **rise** — `AutoMaskRise`: still frames a pixel needs, while the world is drawn, before it is marked.
  Fast, or a HUD is never captured.
- **fall** — `AutoMaskFall`: changing frames before it is unmarked. Keep it at or under the rise, or the
  mask lingers over moving scenery.
- **hold (the counter)** — `.g`: the bridge's balance, not the confidence. A changing frame adds one while
  the world is drawn; a still frame pays half of one back.
- **forget / grace period** — `AutoMaskForget`: frames of absence absorbed before decay starts. The
  README's *grace period*, and the most important slider, because bridgeable animation is the common HUD
  case.
- **bridge** — what the hold does: animation that fits inside the window is bridged and never banked as a
  move, so a draining bar or a scrolling list keeps its mask.
- **move memory** — `AutoMaskMoveMemory`: the duration of still frames a move is remembered for. A
  *duration*, not a confidence budget — its depth does not change how long repayment takes — and `0`
  restores the old behaviour exactly.
- **move debt** — the negative confidence a move banks, clamped to `-cost × AutoMaskMoveMemory` and
  charged one frame's worth per changing frame. Repaid by the heal.
- **heal** — one frame of the unmarking countdown per still frame, part of the same credit as the rise,
  so it happens only while the world is drawn. A stopped world repays nothing.
- **decay** — confidence falling once neither stillness nor the bridge applies: `conf - cost × (1 -
  stable)`.
- **clamp** — confidence is bounded to `[-cost × AutoMaskMoveMemory, 1.0]`, so debt has a floor and
  credit a ceiling.
- **state machine** — the branch structure of `PS_Accum`, whose shared parts `CS_Accum` calls as the same
  helpers declared in `Shaders/AutoMask.fxh` (`docs/compute-path.md`).
- **shared helper** — one of the functions `Shaders/AutoMask.fxh` holds: the premise, the decay step, the
  deadband, the pinned-colour count, the depth-change test and the frame rate.
  Each takes what it needs sampled already, so neither path's sampling form moves onto the other's
  (`docs/refactor-candidates.md`).
- **bank** — two senses, told apart by the object. Of *scenery*: wrongly taken into the mask as
  interface, i.e. kept protected because neither comparison caught it — "the sky is banked". Of a *cost*
  or *debt*: accrued — "the debt it banks". Both are about laying something away
  (`docs/drift-snap-review.md`).

## The gate

- **gate / screen-motion gate** — the reading of how much of the screen is being redrawn that decides
  whether the world counts as drawn. Outside this section "gate" also means a preprocessor guard or a
  UI `ui_category_toggle`; the world-drawn sense is the one that decides the verdict.
- **live_share / the share** — the gate's answer as a percentage. `drawn = live_share > AutoMaskMotion`,
  strict: not `step`, which is true at the threshold itself and would disagree on exactly the boundary
  frame (`docs/compute-path.md`).
- **active / eligible** — the pixels that could show a change, i.e. those not pinned at a rail. The share
  is `changed / active` rather than `changed / every pixel`, so a large inert region cannot lower the
  ceiling below what movement can reach (`docs/compute-path.md`).
- **coarse grid** — the pixel path's reduction: `PS_Motion` writes a 16×16 `RGBA8` target, `.r` the
  changed share per block and `.g` the active share, and `PS_MotionAvg` sums both and divides once.
  Replaced, not skipped, when compute is on.
- **tap** — one texture fetch. `PS_Motion` takes four taps per coarse texel, so 1,024 taps stand in for
  every pixel on screen (`docs/review.md`).
- **exact count** — the compute path's replacement for the taps: every pixel the accumulator calls
  changed adds to a per-group tally, and one thread per group adds that tally to a 1×1 counter — with the
  active pixels tallied beside it, since the share divides by those.
- **one frame behind** — the gate's timing, true in both variants: the frame being judged never sets its
  own threshold. It is why the share, and the measured step with it, are read from the previous frame.

## The compute path

- **compute path** — `AutoMaskCompute=1`: the accumulator and the gate run as compute passes. The meaning
  of the mask does not change; the reading becomes exact, and the drift channel and the measured step
  come with it (`docs/compute-path.md`).
- **change-size histogram** — one bin per whole level of frame-to-frame difference, tallied in the same
  pass as the accumulator while auto-detect is on. It counts the whole distribution of the frame's
  movement, not only what is above a threshold, which is what makes a measured step possible.
- **bin** — one histogram texel. The index truncates, so bin `b` is exactly the difference the verdict
  calls motion at `deadband = b`, which keeps the measurement in the verdict's own units. A pixel that
  did not change takes no bin at all, so the quiet majority is counted by its absence.
- **walk** — the loop in `CS_Finish` that reads the bins from level 1 upward, subtracting each level's
  own bin as it passes it, and stops at the first level leaving no more than `AutoMaskNoiseFloor` percent
  of the screen changing by that much or more. That level is the measured step. The walk covers levels
  1–8 only (`AUTOMASK_STEP_MAX`), and running out of the range means the slider's own value stands.
- **commit / dwell / `AUTOMASK_STEP_DWELL`** — the run of frames a measured step must stand for before
  the walk's answer is adopted, and the constant that bounds it — a second, derived from
  `AutoMaskTargetFPS`. The walk is fed by motion measured against the step it sets, and the level its
  answer lands on moves with whatever is moving: a patch of grass or water covering more than the floor
  holds the step above the size of its own change. A scene change answers a level and holds it; a mover
  that comes and goes in the floor's tail does not. The step is still measured fresh every frame and
  still never written back into the slider, one frame behind as before.
- **auto-deadband / measured step / auto-detect** — the same feature named three ways: the deadband the
  walk measures each frame, held in a 1×1 `RGBA32F` target that carries the committed step, the answer
  being compared against it and the frames that answer has stood for, clamped to 1–8, used only while
  `AutoMaskAutoStep` is ticked, and never written back into the slider. The clamp also keeps an unwritten
  target off the slider's own scale.
- **tally** — the per-group `groupshared` count. The histogram is tallied in groupshared rather than in
  the global bins, so a block's pixels contend only with each other and the screen costs a handful of
  adds per group instead of one per pixel (`docs/compute-path.md`).
- **group / group index** — a thread group in a dispatch. The tally hand-over and the shared-memory clear
  are done by `gi == 0` (`SV_GroupIndex`), because `SV_DispatchThreadID` is the *global* address and
  testing that for zero would fire in one group only.
- **atomic / atomic contention** — `atomicAdd` onto a global bin or counter. The worst case is a still
  scene, where nearly every pixel's add lands on the same bin; groupshared tallying is the answer to it.
- **ping-pong** — read `A`, write `B`, then a write back brings `B` to `A`. Required because a render
  target cannot be read while it is written, and ReShade runs one fixed pass list per frame, so the
  read/write sides cannot simply alternate.
- **back-edge** — the write that closes the ping-pong. Both ride as second and third render targets on
  `PS_DilateH`, which already reads the live sides: the accumulator's on the centre tap the closing
  takes anyway, and the drift pair's on its own read. Neither copy is a pass of its own.
- **storage target / `storage2D`** — a texture the compute path writes as storage. It cannot be indexed:
  `tex2Dfetch` and `tex2Dstore` are the only legal access, and the bracket form ReShade rejects looks
  like ordinary HLSL (`docs/verification.md`).
- **`DispatchSize`** — the group counts of a compute pass, taken from `BUFFER_WIDTH`/`BUFFER_HEIGHT` so
  they stay right at any resolution. The dispatch rounds up, which is why the in-shader bounds predicate
  exists.

## The drift channel

- **drift channel / drift average** — the compute path's second reading: a long-baseline average of each
  pixel's colour, footed at the same deadband as the frame-to-frame difference and read over its own
  longer ramp. A pixel is moving when *either* comparison says so, and the drift side also feeds the
  world-drawn count and the premise. The store holds the average's offset from the frame rather than the
  average, and the read adds the frame back (`docs/compute-path.md`).
- **EMA** — exponentially weighted moving average: what the drift average is, `drift' = lerp(now, drift,
  1 - 1/K)`.
- **drift horizon / K** — `AutoMaskDrift` seconds × `AutoMaskTargetFPS` = `K` frames, the length of the
  average's memory. Longer catches slower drift; shorter brings the mask back sooner after an abrupt
  change. It no longer decides how long a camera pan keeps the screen reading as drawn: that is the
  bound below.
- **drift reach / `AUTOMASK_DRIFT_LAG`** — how far the average may sit from the frame, in deadbands, and
  so the top of the drift ramp: the average is clamped inside it, so the lag is graded rather than
  clipped. Unclamped it creeps a rate × horizon levels behind a sustained move, and that lag — a move's
  tail, which is how long a stopped view still reads as drawn — then takes a horizon to walk back.
- **creep** — the average following the frame by a fraction of a level a frame while the short
  comparison reads still. The one-level gap the channel exists to close creeps at 0.0083 levels a frame
  at the 2 s default, which is why a whole-value store needed full precision (`docs/drift-snap-review.md`).
- **snap / reset** — where the average *becomes* the frame instead of creeping, keyed to `maxDiff <
  max(deadband, 8.0)`: a change wide enough to be a new picture. Keyed to the deadband it would fire on
  every one-level change and leave the channel inert. The `8` is deliberately its own literal, not
  `AUTOMASK_STEP_MAX`: the two answer different questions (`docs/editing-conventions.md`).
- **cut** — a scene cut or a load: a change far wider than the reset floor. The average follows it at
  once, so the mask is never held off waiting for a stale average.
- **store (the drift store)** — the target the average lives in; "the store's precision" means its
  format and its ulp. It holds the average's offset from the frame, so the pair is `RGBA16F` and comes
  to about 59 MB at 1440p (`README.md`).
- **ulp / half-ulp** — the spacing of a floating-point format and half of it. Why the store is
  `RGBA16F`: with the offset held near zero an `RGBA16F` half-ulp is ~0.001 of a level, under the
  0.0083-level creep step, where a whole-value store at level 31 had 0.0156 and sat frozen
  (`docs/compute-path.md`).
- **binade** — a power-of-two band of floating-point values (1–2, 2–4, …). Its edges are the eight
  adjacent 8-bit pairs where subtracting stored colours rather than level counts read exactly `1.0`
  instead of `0.9999999` (`docs/drift-snap-review.md`).
- **float residue** — the difference left by comparing quantized colours instead of level counts: most
  one-level changes read a hair under a level, which `maxDiff < deadband` forgives at `AutoMaskEps = 1`
  (`docs/core-model.md`).

## The settings

Every tuning value the user adjusts is a live slider; the preprocessor definitions are the structural
switches and the setup constants listed below. Tuning guidance is in `README.md`; what each setting is
*for* is in the entry above it. The rows are in panel order: the first four, the frame-count durations,
are the `Frame timing` section, and `AutoMaskMotion` opens `Is the scene in motion?` with the depth
readings.

| Uniform | Panel label | The term, in one line |
| --- | --- | --- |
| `AutoMaskRise` | Frames still before marked as interface | Duration of stillness needed to mark; sets the gain. |
| `AutoMaskFall` | Frames moving before unmarked as interface | Duration of change before unmarking; sets the cost. |
| `AutoMaskForget` | Frames of absence before decay starts | The bridge's window; animation inside it is never banked. |
| `AutoMaskMoveMemory` | Frames a move is remembered | Duration of still frames a move is remembered for; the debt clamp. |
| `AutoMaskMotion` | Motion needed to trust stillness (percent) | Share of the screen that must change before stillness is credited. The premise; opens `Is the scene in motion?`. |
| `AutoMaskDepthEps` | Depth step counted as a change (metres) | How far a surface must move toward or away from the view in one frame to count; uniform across the screen, since the change converts back to metres against the far plane ReShade supplies. The depth ramp is footed at half this, so smaller changes add nothing. Read only with `AutoMaskDepthMotion`. |
| `AutoMaskDepthOnly` | Depth only, not added to the picture | Which witness the world-drawn reading is taken from with depth compiled in — depth added to the picture, or depth alone; also read only with `AutoMaskDepthMotion`. |
| `AutoMaskDepthFOV` | Camera field of view (degrees) | The vertical fov the surface orientation is reconstructed with, so surfaces a walk cannot move can be left out of the depth reading; a wrong value tilts it rather than changing which surfaces those are. |
| `AutoMaskDilate` | Mask grow radius | How far the mask is grown to close anti-aliased edges and thin text. |
| `AutoMaskEdge` | Luma step counted as a boundary | The luma difference, 0–255, past which that growth stops. |
| `AutoMaskDrift` | Drift horizon (seconds) | The drift average's memory, in seconds; `0` turns the comparison off. |
| `AutoMaskNeighbour` | Stop specks entering the mask | Whether a pixel with no claimed neighbour earns at half rate, so a region starts only from a pixel still for twice the rise. |
| `AutoMaskEps` | RGB step counted as a change | The deadband in whole levels out of 255; decides only whether a pixel moved. Last row of `AutoMask`, so it sits above the group that measures it. |
| `AutoMaskAutoStep` | Auto-detect RGB step | Whether the deadband is measured rather than read from the slider. |
| `AutoMaskNoiseFloor` | Noise floor (percent) | The share of the screen the walk's rule is set at; gated by the toggle above. |
| `AutoMaskIsolated` | Enable isolated pixel removal | The gate the isolation count sits behind; off, the mask is the closing radius alone. |
| `AutoMaskDensity` | Still neighbourhood density (percent) | Share of the box that must be still, itself counted; a text box, stepped by 1. The other way to stay in is the line door. |
| `AutoMaskIsolation` | Isolation radius in pixels | How far that density and the line door are measured; its own radius rather than the closing's. |
| `UIDebugMotion` | Diagnostics: motion view | Which reading the overlay draws: motion view (red) or verdict view (green). |
| `UIDebugGain` | Diagnostics: motion gain | Multiplier making a small change visible in the overlay. |
| `UIDebugConfidence` | Diagnostics: confidence view | Whether the overlay draws the accumulator's own confidence as two flat colours — cyan claimed, magenta earning — instead of the graded reading. |
| `UIDebugDepthNormal` | Diagnostics: depth normals | Whether the overlay draws each surface's orientation instead — white where it faces up or down. Read only with `AutoMaskDepthMotion`, which is the only thing that can sample depth. |
| `UIDebugTile` | Diagnostics: tile view | Whether the overlay draws the tile map instead: a cell in its class, with the region readings as bars. Compute-only, since the map is. |

- **structural switch** — a preprocessor definition that removes a feature from the compile: each is
  `#ifndef`-guarded and owns its pass, technique entry, shader and private targets. The four are
  `AutoMaskAntiBloom` (1), `AutoMaskDiagnostics` (0), `AutoMaskCompute` (0) and `AutoMaskDepthMotion`
  (0). Off, the work is not skipped but absent — and a target left outside its guard is memory paid for
  a feature that is compiled out.
- **`AutoMaskTargetFPS`** — the one further definition, a setup number rather than a tuning one: seconds
  × this gives the frame-count caps and the drift horizon in frames. A runtime `frametime` uniform
  cannot appear in an annotation, which is why it is a definition at all.
- **category / `ui_category_toggle`** — a grouping in the ReShade panel. ReShade can only hide a whole
  category at a time, off a boolean's `ui_category_toggle`, and it never hides that boolean itself — so
  a gated setting belongs in its own category with the gate first, and there is no per-uniform
  visibility annotation (`docs/editing-conventions.md`). A category is a contiguous run of uniforms, so
  one named again further down the list draws a second heading with the same name. The six names used
  are `Frame timing`, `Is the scene in motion?`, `AutoMask`, `RGB step detection`, `Isolated pixels`
  and `Diagnostics` — the last inside the diagnostics switch, so it is not drawn unless that is on.
- **`AUTOMASK_STEP_MAX`** — `8`: the last level the walk measures in, and the end of the `AutoMaskEps`
  slider with it. Named because the histogram's width, the clear loop, the bin clamp and the walk's
  range must not drift apart.
- **`AUTOMASK_STEP_DWELL`** — a second in frames (`AutoMaskTargetFPS`): how long a measured step must
  stand before it is committed. A bound on how long a held reading lasts rather than on a loop or a
  value anyone tunes.
- **`AUTOMASK_DILATE_MAX`** — `3`: the cap on the dilation loops' half-width and on `AutoMaskDilate`. Each
  loop runs the wider of the two radii, clamped to this, so it bounds the loop rather than fixing it. The
  precedent for a definition that bounds a loop rather than eliding a pass.
- **`AUTOMASK_DRIFT_LAG`** — `2`: how far the drift average is held from the frame, in deadbands, and the
  top of the drift ramp. A bound on a value rather than on a loop, and the reason the horizon no longer
  sets how long a pan lingers. The clamp divides it onto the value's own scale: `now` is normalized and
  the reach is a level count, so left in levels it names 255 times what it means and holds nothing.
- **the reset's wide step** — `max(deadband, 8.0)`, in the drift average's reset. Deliberately not a
  slider: it has to stay at or above the deadband so the two thresholds cannot collapse into one, and
  the `max` means it cannot if either cap is ever raised.
- **duration (what a frame slider means)** — the frame-count settings are whole frames converted into a
  step per frame, so a slider position is the duration it names and nothing else is retuned with it.
  The drift horizon is a duration of the other kind: its slider is already in seconds.
- **widget family** — the choice between `__UNIFORM_DRAG_FLOAT1` and `__UNIFORM_SLIDER_FLOAT1`. The
  duration settings drag over free values; everything else is a stepped slider. A mismatch between the
  annotation's family and the declared type is a silent ReShade UI bug.

## Passes and wiring

- **technique** — a ReShade list entry holding passes. Two here: `AutoMask`, which must be first, and
  `AutoMask_Restore`, which must be last.
- **pass** — one shader invocation with its render target. A preprocessor guard can drop one from a
  technique body, which is why every combination is compiled.
- **effect list** — ReShade's ordered list of enabled effects. The placement rules are about position in
  it: `AutoMask` compares untouched frames only if nothing has written them first.
- **store/restore pattern** — let the user's effects run on the frame with the masked pixels blacked, put
  them back in `AutoMask_Restore`. The credit for it belongs to Kaiser's `UIDetectMulti`. The frame is
  kept in `texAutoHistory`, written by the closing pass with the mask in its alpha.
- **anti-bloom** — `PS_AntiBloom` blacking the masked pixels in the live frame so a bloom pass downstream
  has no UI to pick up. The real pixels are put back by the restore, so the final picture is unchanged.
- **closing radius / dilation** — the two separable `PS_DilateH`/`PS_DilateV` passes growing the mask,
  stopped where the luma step of a tap exceeds `AutoMaskEdge`. The horizontal pass reads each tap's luma
  from the back buffer and writes its own centre's into `texAutoDilate`'s `.a`; the vertical pass bounds
  its taps by that stored luma, so the frame is read for it once rather than twice. `PS_DilateH` also
  carries both ping-pong back-edges, and `PS_DilateV` writes next frame's history — the frame it was
  drawn over with the settled mask in the alpha — so neither the copies nor the store are passes of
  their own.
- **opening / the gate's operation** — what the isolation gate does to the mask, but not a plain
  morphology: it is the closing with a count test on top, not a min of the mask over the box. A pixel
  survives when the verdict's own count in its box clears the threshold, so a pixel the closing grew out
  over thin neighbourhood goes, and a pixel inside a solid panel stays whatever its own verdict was. It
  rides in the closing's own two passes, in the channels `texAutoDilate` leaves unused, and not on
  `AutoMaskEdge`: a contour inside a HUD must not cost the pixel its support.
- **line door (the isolation gate's second test)** — after the box share, the gate's other way to keep a
  pixel: one of the four lines through it — row, column, either diagonal, out to the isolation radius —
  holding `max(reach + 1, AUTOMASK_AXIS_MIN)` still pixels. It exists because a one-pixel stroke fills
  only `n / side` of the box and the share alone erodes it. The row count is the horizontal pass's `.g`;
  the other three are read off `.b`, the centre verdict that pass publishes, at taps the vertical pass
  already takes: no new pass, target or uniform, and skipped while the gate is off.
- **`AUTOMASK_AXIS_MIN`** — `3`: the floor under the line door, so the smallest line (3 across) is its
  whole length and a lone pixel, a pair or a short run stay specks. The door's floor is
  `max(reach + 1, AUTOMASK_AXIS_MIN)`.
- **luma step** — `AutoMaskEdge` compared against `dot(colour, float3(0.299, 0.587, 0.114))`, the Rec.601
  luma the dilation reads from the frame. The horizontal pass reads it from the frame; the vertical pass
  reads the luma the horizontal one stored in `texAutoDilate`'s `.a`, quantized to that `RGBA8` grid, so a
  tap's edge within one level of `AutoMaskEdge` can land on either side of it.
- **diagnostics overlay** — the block drawn in `AutoMask_Restore` only when `AutoMaskDiagnostics == 1`,
  with no pass or target of its own. It reads the accumulator directly, so it cannot report on itself
  instead of on the shader.
- **motion view / verdict view / confidence view** — the overlay's per-pixel readings, picked by two
  live toggles: red where the frame sees a change; green where the pixel has earned protection *without*
  the closing radius; or, with the second toggle, the accumulator's own confidence as a grade, its middle
  the 0.5 protection line. It draws **two flat colours rather than a ramp** — cyan where the verdict would
  already claim the pixel, magenta where it is earning but has not crossed — and leaves everything at or
  below zero untinted, so the wide debt range a move leaves does not read as a halo. Read in a game it
  found a thin band over UI interiors and a much larger one over dim scenery with no interface in it:
  scenery drifting too slowly to change a pixel between two frames reads as still, and still is what the
  verdict credits — §5.5.1 of `docs/ui-isolation-options.md`. The tile view overrides both per-pixel views.
- **tile map / tile view** — the picture as a fixed 16×16 grid, each cell sampled at `AUTOMASK_TILE_TAPS`²
  points, reduced to region readings: the mask's component count and largest share, the enclosed share,
  and the count and area of contiguous wide-change patches *while the world is stopped* — a wide change
  during a camera move is that move, not an arrival. A cell is mask as soon as the mask touches it — a
  footprint reading, not a filled one. An instrument only, nothing in the mask reads it; `UIDebugTile`
  draws it, and the five readings as bars are filled against
  `AUTOMASK_TILE_COUNT_MAX` for the two counts and their own share for the three. Compute-only, riding
  both the compute and diagnostics guards.
- **corner marker** — the bottom-left block drawn by `AutoMask_Restore`, so nothing downstream can paint
  over it: magenta while the world is drawn, yellow while it is not. It reads
  the state about to govern the mask, one frame ahead of the decision.
- **variant** — one compiled combination of the preprocessor switches; the offline check compiles sixteen
  (`AutoMaskAntiBloom` and `AutoMaskDiagnostics` each at 0 and 1, crossed with `AutoMaskCompute` and
  `AutoMaskDepthMotion`).
- **`BUFFER_WIDTH` / `BUFFER_HEIGHT`** — injected by ReShade at runtime, not defined here. Anything
  buffer-relative stays correct across resolutions; absolute pixel numbers do not.
- **prelude** — the definitions the offline check injects before compiling (`__RESHADE__`,
  `BUFFER_WIDTH`, `BUFFER_RCP_WIDTH`, `RGBA8`, …), because ReShade injects them and `fxc` will not
  compile without them.
- **`PostProcessVS`** — ReShade's vertex shader, emitting the position at `v0` and the UV at `v1`. That
  is why every pixel shader keeps `float4 pos : SV_Position` first even though no body reads it: drop it
  and the UV slides into the position's register, and every pass samples one texel.

## Verification

- **offline check** — `tools/verify_shaders.py` under `uv run`: it preprocesses and compiles every shader
  variant with `fxc` and reports instruction counts and opcode histograms. The only automated
  verification there is (`docs/verification.md`).
- **`init` / `check`** — the two commands. `init` fetches the pinned ReShade headers; `check` compiles.
  `--pass-list` prints the wiring, `--opcodes` the histogram per shader, `--hashes` the bytecode sha256
  of each entry point.
- **entry point** — one shader function compiled on its own, at the profile its shape calls for: `ps_5_0`
  for an `SV_Target` function, `cs_5_0` for a compute one.
- **`WARN`** — a warning reported by the check. A failure, not a note, because ReShade prints the same
  warning into the log the user reads at load.
- **`X3579`** — the one filtered warning: the harness compiling a file-scope `groupshared` tally into a
  *pixel* entry point, where ReShade emits one pass's reachable code and would not. The harness's own
  artefact, not the shader's.
- **`strip_for_fxc`** — the check's rewrite of the dialect into HLSL before `fxc` sees it (`storage2D`,
  `tex2Dfetch`/`tex2Dstore`, barriers, the `atomic*` family). It is also why a clean compile says nothing
  about those spellings: they are pinned by the tool instead.
- **workspace sources** — the shader *and* its `.fxh`, copied into `tools/.work/` before preprocessing,
  since the include resolves against the including file's directory. A copy left from an earlier run is
  deleted first, so a removed header fails loudly rather than resolving from a stale copy.
- **identifier check (`--hashes`)** — the bytecode sha256 of every entry point, before and after a change.
  All 82 coming out identical is what establishes that a refactor changed no code, and it covers the
  compute path as well as the pixel one.
- **pinned spelling** — a spelling the check refuses rather than translates — a lowercased storage
  keyword, a wrong argument count, the bracket form the translation produces, and `fmod` — because a
  rewrite would hide the failure from `fxc` and let it reach a game.
- **loud failure** — the check's contract that missing data exits non-zero rather than reporting a clean
  pass. `docs/verification.md` names the ten cases and the construct that exercises each, from an empty
  `Shaders/` to a deleted `AutoMask.fxh` and a render target a pass declares but the reading misses.
- **reserved word** — a word ReShade's lexer emits as a token rather than an identifier (`sample`,
  `new`, `this`, `half`), while HLSL has no such token, so `fxc` compiles it and ReShade fails the load
  with X3000. `RESERVED_WORD` refuses it, read from ReShade's own lexer rather than guessed.

## Signals considered and rejected

- **displacement** — what both the frame-to-frame comparison and the drift average measure: how far a
  pixel is from a reference. Neither is a movement detector, and a returning pixel defeats both
  (`docs/drift-snap-review.md`).
- **returning pixel / sway** — a pixel whose colour oscillates while the picture moves steadily, so it is
  always where it just was or near the middle of where it has been. The case the drift channel does not
  answer, and a repeat detector would.
- **monotonic drift** — a pixel moving one way only, the case the drift channel does answer once the
  shift accumulates past the deadband. The floor is `deadband / K` levels a frame.
- **long baseline** — comparing frames far enough apart for sub-pixel motion to accumulate into whole
  pixels. Both the drift average and a matcher need one; appearance drifts over it.
- **repeat detector** — the unimplemented remedy of `docs/drift-snap-review.md` §5.1: has this pixel come
  back to a value it held before? A new store and comparison, not a retune.
- **optical flow / block matching** — estimating motion vectors from the image alone, so a region's
  motion is described rather than detected. Built as a probe, answered negatively in a real game, and
  removed (`docs/optical-flow.md`).
- **motion vector** — the `(dx, dy)` of a region. A statement about a region, not a pixel's fate, and not
  the same question as "is this HUD".
- **SAD** — sum of absolute differences, the matching metric. Its minimum is not a confidence measure on
  a flat patch, where every offset ties exactly.
- **patch / search window** — the block matched, and the offsets searched for it.
- **ring** — the probe's rolling store of past frames at reduced resolution.
- **per-cell fit / parabolic fit** — the probe's refinements: rejecting per cell what the one global
  vector does not explain, and refining the winning offset to a sub-pixel one.
- **loop failure** — a looping animation is identical once its loop completes, so a matcher reports zero
  offset and reads a moving sky as stationary. A correctness failure, not a tuning difficulty.
- **flat plane / dome** — the two sky constructions. A flat plane's motion is one coherent translation,
  which a matcher handles; a dome's is shear and convergence, which it does not.
- **per-frame regional estimator** — what a working matcher would have been: a fourth signal alongside
  the accumulator, the coverage gate and the drift average, each with its own tuning. It would support
  the verdict rather than replace it.
