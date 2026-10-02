# Review: drifting scenery still reaching the mask

## 1. Overview & Scope

The compute path's drift channel was added so slowly drifting scenery — a panning skybox, a distant
backdrop — would stop being banked as interface. It does not fully do that: **areas of the skybox still
reach the mask.**

The failing mechanism is structural. Both comparisons measure **displacement**, and a skybox *returns*, so
at every instant a given pixel is either where it just was or near the middle of where it has been. The
motion is real and visible and neither question can see it. Four defects followed from that:

1. **The reset was keyed to the deadband**, so at the default `AutoMaskEps = 1` it fired on *every*
   single-level change — exactly the sky the channel exists for. Reset onto the frame, the next frame's
   drift reading *is* the frame-to-frame reading: measured over a creeping sky, the two agreed on **100%
   of frames at every horizon setting**, 0.5 s to 10 s. The channel was not floored, it was disabled, and
   the horizon slider had nothing to move. The rule is now `maxDiff < max(deadband, 8.0)`, so only a change
   wide enough to be a new picture snaps the average.
2. **The one-level comparison subtracted stored colours rather than level counts** (§5.3), so most
   one-level changes read a hair under a level and the most sensitive setting caught only 8 of 255 pairs.
3. **The drift store's precision froze the average** above level 31 of the brightness range (§5.4),
   splitting the sky by brightness band rather than by how fast it moved.
4. **The average was unbounded and the ramp reading it saturates.** Through a sustained move the average
   crept a horizon's worth of levels behind, and a count that only asks whether a pixel changed reads three
   levels and three hundred as the same number, so the whole screen went on reporting as drawn for seconds
   after the view stopped. The average is now held within `AUTOMASK_DRIFT_LAG` deadbands of the frame and
   the ramp runs from the deadband to that same bound, so the tail after a pan is an exponential walk of a
   bounded lag — about `ln(AUTOMASK_DRIFT_LAG)` horizons.

All four are landed, and the store came back to half precision by holding the average's **offset from the
frame** rather than the average, where the same half-ulp resolves the creep (`docs/performance.md` §10).
What survives the fixes is §5.1's case: a pixel that *sways* within the horizon rather than creeping one
way, which the repeat detector would answer and nothing shipped does.

Findings come from a numeric model of `CS_Accum`'s arithmetic, not the GPU; what that does and does not
establish is in §6.

## 2. Both channels measure displacement, and a skybox returns

```hlsl
float3 diff      = abs(now - before) * 255.0;   // against the previous frame
float3 driftDiff = abs(now - drift)  * 255.0;   // against a long running average
float stable = (maxDiff < deadband && maxDrift < deadband) ? 1.0 : 0.0;
```

The first asks *"how far did this pixel move since last frame?"*, the second *"how far is it from where it
has been on average?"* A pixel that *returns* defeats both: it is always either where it just was or near
the middle of where it has been. The drift channel's own comment states the failing assumption directly —
*"building until the pixel sits visibly away from where its colour has been"* — and for a returning pixel
it never does.

### 2.1 A steady pan has a floor

The monotonic case applies to any translating camera, and it is the channel's steady-state behaviour:
a panning pixel is caught once the lag the average accumulates reaches the deadband, and that lag is
`rate × K`. So there is a rate below which it is banked at **any** horizon:

| horizon | K at 60 fps | slowest monotonic drift caught | in levels/second |
| ---: | ---: | ---: | ---: |
| 0.5 s | 30 | 0.0333 levels/frame | 2.000 |
| 1 s | 60 | 0.0167 levels/frame | 1.000 |
| 2 s | 120 | 0.0083 levels/frame | 0.500 |
| 4 s | 240 | 0.0042 levels/frame | 0.250 |
| 8 s | 480 | 0.0021 levels/frame | 0.125 |
| 10 s | 600 | 0.0017 levels/frame | 0.100 |

The horizon slider is the only lever on that number and is capped at 10 s. **At the default 2 s, any sky
region drifting slower than half a level per second is banked no matter what**, and a slow camera turn
moves the sky more slowly than that across much of the frame. The floor is `deadband / K` levels a frame:
raising the horizon catches slower drift, which is what the reset fix restored.

### 2.2 A *returning* pixel doubles that floor

Where the local motion reverses before the average can be left a level behind — a camera arc that turns
back, counter-moving cloud layers — the average tracks the excursion and the lag is only half the swing,
so the rate needed doubles:

| horizon | monotonic drift caught | swaying motion caught |
| ---: | ---: | ---: |
| 2 s | 0.0083 levels/frame | 0.0167 levels/frame |
| 10 s | 0.0017 levels/frame | 0.0033 levels/frame |

Confined to a one-level excursion — a pixel alternating between two adjacent 8-bit values, the mildest
case — the gap between the frame and its average never reaches the deadband in full-precision arithmetic:
measured at level 128 it peaks at **0.50 levels** on a per-frame alternation and climbs toward 0.99 only
as the dwell stretches to ten seconds a side. That is the case §5.1's repeat detector exists for.

## 3. Why "areas" rather than the whole sky

Two things decide whether a sky region is banked, and they are the two accounts of this review. How far the
image slides *at that pixel* — the product of the local gradient and the drift distance — is what §2.1's
floor says, and a smooth sky is not uniform, so neighbouring regions cross the floor at different rates and
the mask comes out patchy.

In the *pre-fix* arithmetic, with the store frozen (§5.4), the split was by **brightness band** instead:
the average creeps toward the frame by `(now - drift) / K`, and that increment has to survive rounding into
the store. For the one-level gap the channel exists to close, the increment at the 2 s default is 0.0083
levels, while the old `RGBA16F` whole-value store's half-ulp was 0.0078 at levels 16–31 and 0.0156 at
32–63. So the average worked in the dark bands and was frozen above level 31. Measured over a one-level
sway (2 s horizon, deadband 1, world being drawn), over levels 1–253 — the two rails are left out, since a
sway touching all-0 or all-255 is voided by the clip exclusion rather than judged:

| levels | banked | why |
| --- | ---: | --- |
| 1–15 | 15/15 | creep moves the store and closes the gap |
| 16–31 | 16/16 | creep moves the store and closes the gap |
| 32–63 | 16/32 | frozen; split by the store's rounding |
| 64–127 | 32/64 | frozen; split by the store's rounding |
| 128–253 | 62/126 | frozen; split by the store's rounding |

That is the measured evidence for §5.4's defect: dark sky banked, half of bright sky banked, and the
boundary exactly where the creep step met the half-ulp. With the store holding the average's offset the
creep survives at every brightness, so §2.1's floor is the limit again and the band split describes only
the pre-fix channel.

## 4. The one-level comparison

The short comparison was float-fragile, which widened the blind band:

| step | computed diff | read at `AutoMaskEps = 1` |
| --- | --- | --- |
| `L1←L0` … `L128←L127` (8 pairs) | `1.0000000` … `1.0000075` | motion |
| the other 247 adjacent pairs | `0.9999999` | still |

The crossing pairs are `1, 2, 4, 8, 16, 32, 64, 128` — the binade edges. Per level crossed the comparison
trips on 4 of 8 pairs in levels 1–8, 2 of 24 in 9–32, 2 of 96 in 33–128 and 0 of 127 above 128, so dark
scenery tripped it far more often than bright. The comparison now subtracts **whole levels**, so all 255
adjacent pairs register.

That fix was not neutral, which is why it had to land with §5.4's: the fragile miss was what left the
average frozen instead of snapping onto the pixel, and exactness alone banks the whole returning band (253
of 253 one-level swaying levels instead of 141). The two are coupled.

The gate consumer was never blind to a one-level change, contrary to this review's first pass: it counts a
change with `step(0.001, motion)` rather than `smoothstep(...) > 0.5`, and at `AutoMaskEps = 1` any
non-zero frame-to-frame change is at least a whole level, far above the 0.055 levels the ramp needs.

| deadband | ramp at a 1-level step | counted toward `live_share` |
| ---: | ---: | --- |
| 1 | 0.2593 | yes |
| 2 | 0.0000 | no |
| 3 | 0.0000 | no |

So a one-level sky *does* hold the premise at the default setting, and from deadband 2 up it does not.

## 5. What would fix it

The finding is structural, not a tuning error, so no slider position resolves it. Four things follow, and
the two that are coupled — the comparison's exactness and the store's precision — are neither of them safe
alone.

- **§5.1 — Detect *return*, not displacement.** *"Has this pixel come back to a value it held a while
  ago?"* — a repeat detector, and a different signal from either of the two being stored now. It is the
  only one of these that addresses the mechanism, and it is the significant change: a new per-pixel store
  and a new comparison, not a retune. **Not implemented.** With the reset decoupled and the store
  re-centred, the channel answers the steadily drifting sky, so the case left for a repeat detector is
  the one it was always uniquely able to answer: a pixel that *sways* inside the horizon (§2.2).
- **§5.2 — Lower the effective floor of the existing channel** by raising the horizon, since the floor
  is `deadband / K`. That is what the `2.0 s` default was for and it is capped at 10 s. It was dismissed
  the first time for the wrong reason — "the accidental reason in §5.4" — and now stands as §2.1 always
  said: a longer horizon catches slower drift.
- **§5.3 — Make the one-level comparison exact** (§4). A correctness fix on its own terms, now landed.
- **§5.4 — Store the average at full precision.** This is the finding that explains §3 and it is landed,
  in the offset form (`docs/performance.md` §10): the store holds `drift - now`, whose value sits inside
  `AUTOMASK_DRIFT_LAG` deadbands of zero where half precision resolves the 0.0083-level creep.

The four configurations of the two coupled defects, as measured:

| comparison | store | one-level swaying levels banked (of 253) |
| --- | --- | ---: |
| shipped (float residue) | whole-value `RGBA16F` | 141 |
| forced exact | whole-value `RGBA16F` | 253 |
| shipped (float residue) | `RGBA32F` | 253 |
| forced exact | `RGBA32F` | 253 |

Every repair banks the whole returning band, because the freeze was what held it out — which is why the
coupling had to be broken by the reset rather than by one change at a time.

**The freeze ran both ways, and that half was a mask-eating bug of its own.** A frozen average cannot
close on a pixel either, so a pixel left a level away from it stays there and reads as moving for as long
as it holds: measured, a pixel that steps one level **once** and then holds perfectly still never regains
the still verdict on **112 of the 252** levels, exactly where the step missed the snap (§4) *and* the
frozen gap settled at or above the deadband. With the store holding the offset, the same test fails on 0
of 252 levels.

## 6. Method and its limits

A standalone model of `CS_Accum`'s arithmetic as it stood when this was written, rather than an
approximation of it: the `round(c*255)/255` quantization, float32 intermediates, the binary16 quantization
of the store (round-to-nearest-even), and the state machine with the shipped
`AutoMaskRise`/`AutoMaskFall`/`AutoMaskForget`/`AutoMaskMoveMemory` defaults. `drawn` is held true so the
per-pixel verdict is genuinely exercised. The shader was read for the constants and the order of operations
rather than assumed.

Limits:

- The signals are synthetic — constant-rate drifts and triangle excursions of a single pixel value. That
  is the right instrument for the arithmetic question being asked, but it is not a measured skybox: the
  *rate* a real sky drifts at is not established here, only which side of a boundary a given rate falls
  on. The one-level sway's band split by brightness was inferred rather than measured, since a real sky is
  not a constant-rate synthetic signal.
- The comparisons are modelled exactly (the 8-bit grid, the float32 residue). The one input taken on
  trust was the store: the model assumed a half-precision target rounding to nearest even, and both the
  band split in §3 and the freeze in §5.4 inherit that assumption. The model describes the **pre-fix**
  channel; the band split and the freeze are the explanation of what it did, not predictions about the
  shipped one.
- A monotonic pan does not produce a steady sub-level signal in the model: a pixel drifts by whole levels,
  so it sits perfectly still for `1/rate` frames and then steps once. At 0.02 levels/frame that is one step
  every 50 frames, well inside `AutoMaskForget`'s bridge, so the pan's verdict is decided partly by the
  pixel's own quantization staircase and not only by the drift channel. That case needs the in-game
  overlay to read, not a table.
- The model reproduces the accumulator, not the GPU. It says nothing about pass wiring, target formats in
  practice, the closing/dilation step's interaction with a partial sky mask, or timing.
- The two things to settle on hardware, both with the overlay: watch the motion view (red) over a slow pan
  across a *bright* backdrop and confirm it stays out of the mask, which is the behaviour the pre-fix
  store could not deliver; and put the verdict view on a static HUD element and confirm the green is there
  and stays there over the horizon, which the frozen whole-value store could not deliver either.
- The model's verdicts are read as mask coverage directly. The shader puts `PS_Dilate` and the
  `AutoMaskRise`/`AutoMaskFall` timing between the verdict and the published mask, so a partially banked
  region may look more or less continuous on screen than the percentages here.

## 7. Summary of Action Items

1. **The reported cause is structural.** Both comparisons measure displacement and a skybox returns, so
   neither can see it. The reset defect disabled the channel on top of that, and its fix is what makes the
   floor table apply: a steadily creeping sky is caught at `deadband / K` levels a frame.
2. **The two coupled correctness defects are landed together.** The one-level comparison subtracts whole
   levels and the store carries full precision in the offset form; neither is safe alone, since exactness
   without the store change banks the whole returning band.
3. **The bounded reach fixes a fourth defect.** An unbounded average kept the whole screen reading as drawn
   for seconds after a pan stopped; the average is held inside `AUTOMASK_DRIFT_LAG` deadbands and the ramp
   runs to that bound, so a move's tail is an exponential walk rather than a horizon.
4. **A repeat detector is still the signal that would catch the swaying case** — a new store and comparison
   rather than a retune — and it is the whole of that remedy's remaining justification: every repair to the
   existing channel now answers the steadily drifting sky, and only a pixel that sways inside the horizon
   is left unanswered.
5. **The freeze was also a mask-eating bug in its own right**: a static element could be kept out of the
   mask indefinitely at a long horizon, on 112 of 252 levels. With the offset store it fails on 0 of 252.
6. **The one-level change does count toward the premise** at the default `AutoMaskEps = 1`, contrary to
   this review's first pass: the gate is `step(0.001, motion)`, not a threshold on the ramp.
