# Review: drifting scenery still reaching the mask

## 1. Overview & Scope

The compute path's drift channel was added so slowly drifting scenery — a panning skybox, a
distant backdrop — would stop being banked as interface. It does not fully do that: **areas of
the skybox still reach the mask.**

This is the second pass at the question. The first assumed the complaint was the opposite — HUD
failing to be masked — and proposed decoupling the drift average's reset. That is not the failure
on the table, so this review starts over on scenery being *taken in*.

It has since been re-checked against the shader, and **two of its own claims did not survive**:
§2's floor and §2.2's "banked outright" describe a channel with a full-precision store, not the
shipped one, and §4's gate paragraph misread the threshold. §5.4 is the mechanism that ties them
together.

Findings come from a numeric model of `CS_Accum`'s arithmetic, not the GPU; what that does and
does not establish is in §6.

**The two coupled defects it names have since been fixed.** §5.3 (the one-level comparison) and §5.4
(the drift store's precision) are landed together, as §7.5 requires: the comparison subtracts whole
levels rather than the quantized colours, and the two drift targets are `RGBA32F`. The analysis below
is left as it was written, against the shipped arithmetic it describes. §5.1's repeat detector, the
primary answer to the reported symptom, is **not** implemented — the two defects were correctness bugs
in their own right (the second keeping static elements out of the mask on 112 of 252 levels), and with
them fixed the drift channel is left behaving as §2.1's floor table describes.

**A third defect has since been found, and it explains the reported symptom.** §5.2 dismisses the
horizon because raising it moved the swaying bank only "for the accidental reason in §5.4"; the actual
reason is stronger than the review's, and it is not in §5.4 at all. The average's **reset** was keyed to
the same `deadband` as the per-pixel verdict (`next = maxDiff < deadband ? creep : now`). The deadband is
the smallest change called motion, so at the default `AutoMaskEps = 1` it is one level — and the reset
therefore fired on *every* single-level change, which is exactly the sky the channel exists for. Once
reset onto the frame, the next frame's drift reading *is* the frame-to-frame reading: measured over a
creeping sky, the two agreed on **100% of frames at every horizon setting**, 0.5 s to 10 s. The channel
was not floored; it was disabled, and the slider had nothing to move. §2.1's floor table and §2.2's
doubling describe a channel that resets only on a cut, which is what it became when the reset was
decoupled — the rule is now `maxDiff < max(deadband, 8.0)`, so only a change wide enough to be a new
picture snaps the average. Two consequences, against the review's own conclusions: §5.2's "raising the
horizon" now does catch slower drift, at `deadband / K` as §2.1 always said; and §7.4's "every repair to
the existing channel either makes the returning sky worse or leaves it unchanged" held only while the
reset kept the channel inert, since a working average is what the repairs were measured against. §5.1's
repeat detector remains unimplemented and its case — a pixel that *sways* within the horizon rather than
creeping one way — is still the one the channel does not answer, which is the limitation that survives
this fix rather than being closed by it.

**A fourth defect was found later, from an in-game report rather than from this analysis.** The average
was still unbounded, and the ramp reading it still saturated: through a sustained move it crept `horizon`
levels behind, the ramp's three-level span could not see the part of that lag that mattered to the
*premise* (a reading of three levels and a reading of three hundred are the same number to a count that
only asks whether a pixel changed), so the whole screen went on reporting as being drawn for seconds after
the view had stopped — and red over the graded ramp for as long as that lasted. The average is now held
within `AUTOMASK_DRIFT_LAG` deadbands of the frame and the ramp runs from the deadband to that same bound,
so the lag is graded rather than clipped and the fall behind it is an exponential walk of a bounded lag —
about `ln(AUTOMASK_DRIFT_LAG)` horizons, against a whole horizon off a lag that grew without limit.
§2.1's floor is untouched: what an unbounded average bought that this gives up is a reading
proportional to the total displacement, which nothing consumes.

---

## 2. Both channels measure displacement, and a skybox returns

Neither comparison is a movement detector:

```hlsl
float3 diff      = abs(now - before) * 255.0;   // against the previous frame
float3 driftDiff = abs(now - drift)  * 255.0;   // against a long running average
float stable = (maxDiff < deadband && maxDrift < deadband) ? 1.0 : 0.0;
```

The first asks *"how far did this pixel move since last frame?"* — the second *"how far is it from
where it has been on average?"* Both are questions about **displacement**, and a pixel that
*returns* defeats both at once: at every instant it is either where it just was, or near the
middle of where it has been. The motion is real and visible; neither question can see it.

A skybox is exactly this shape. As the image slides across the screen the gradient passes over a
given pixel and is replaced by what arrives behind it, so a **pixel's colour oscillates** while
the picture moves steadily. The drift channel's own comment states the failing assumption
directly: *"building until the pixel sits visibly away from where its colour has been"* — for a
returning pixel, it never does.

### 2.1 A steady pan has a floor — in full-precision arithmetic

The monotonic case is the simpler one and applies to any translating camera. A steadily panning
pixel is caught once the lag the average accumulates reaches the deadband, and that lag is
`rate × K`. So there is a rate below which it is banked at **any** horizon:

| horizon | K at 60 fps | slowest monotonic drift caught | in levels/second |
| ---: | ---: | ---: | ---: |
| 0.5 s | 30 | 0.0333 levels/frame | 2.000 |
| 1 s | 60 | 0.0167 levels/frame | 1.000 |
| 2 s | 120 | 0.0083 levels/frame | 0.500 |
| 4 s | 240 | 0.0042 levels/frame | 0.250 |
| 8 s | 480 | 0.0021 levels/frame | 0.125 |
| 10 s | 600 | 0.0017 levels/frame | 0.100 |

The horizon slider is the only lever on that number, and it is capped at 10 s. **At the default
2 s, any sky region drifting slower than half a level per second is banked no matter what.** A
slow camera turn moves the sky more slowly than that across much of the frame.

One caveat, the second correction to the first pass: this is the floor of the channel
**with a full-precision store**. The shipped average lives in `RGBA16F`, whose resolution is
coarser than the creep step it needs (§5.4), so the shipped channel does not sit on this floor at
all — measured, the shipped configuration keeps a slow pan out of the mask at rates *below* this
table's, for the accidental reason that its frozen average (§5.4) cannot follow the frame. It is
the *repairs* to the channel that fall back to this table, at which point the horizon, and not the
store, is what sets the floor.

### 2.2 A *returning* pixel doubles that floor

Where the local motion reverses before the average can be left a level behind — a camera arc that
turns back, counter-moving cloud layers — the average tracks the excursion and the lag is only
half the swing. The rate needed doubles:

| horizon | monotonic drift caught | swaying motion caught |
| ---: | ---: | ---: |
| 2 s | 0.0083 levels/frame | 0.0167 levels/frame |
| 10 s | 0.0017 levels/frame | 0.0033 levels/frame |

Confined to a one-level excursion — a pixel alternating between two adjacent 8-bit values, which
is the mildest case — the gap between the frame and its average never reaches the deadband in
full-precision arithmetic: measured at level 128, it peaks at **0.50 levels** on a per-frame
alternation and climbs toward 0.99 only as the dwell is stretched to ten seconds a side. That
case is banked outright, and nothing about the setting reaches it.

That figure is in full-precision arithmetic. In the shipped `RGBA16F` store the same excursion
lands just *above* the deadband on most levels (1.000–1.034, the exception being the top band,
where it falls to 0.98), so it does not bank outright but splits: measured over a one-level sway,
**141 of 253 levels bank and 112 read as moving**, and above level 31 the split follows the
store's rounding direction rather than the scene at all. §5.4 has the mechanism.

---

## 3. Why "areas" rather than the whole sky

Two things decide whether a sky region is banked, and the model separates them cleanly. The first
account below is the one the first pass gave; measurement says the second is what the shipped
shader actually does.

**What the first pass said.** Whether a region sits under the floor depends on how far the image
slides *at that pixel* — the product of the local gradient and the drift distance. A smooth sky is
not uniform, so neighbouring regions cross the floor at different rates and the mask comes out
patchy.

**What is measured.** In the shipped arithmetic the split is by **brightness band**, and it has
nothing to do with the local gradient. The average creeps toward the frame by
`(now - drift) / K`, and that increment has to survive rounding into the `RGBA16F` target it is
stored in. For the one-level gap this channel exists to close, the increment at the 2 s default is
0.0083 levels, while the store's half-ulp is 0.0078 at levels 16–31 and 0.0156 at 32–63 (§5.4).
So the average still works in the dark bands and is frozen above level 31. Measured over a
one-level sway (2 s horizon, deadband 1, world being drawn), over levels 1–253 — the two rails are
left out, since a sway touching all-0 or all-255 is voided by the clip exclusion rather than
judged:

| levels | banked | why |
| --- | ---: | --- |
| 1–15 | 15/15 | creep moves the store and closes the gap |
| 16–31 | 16/16 | creep moves the store and closes the gap |
| 32–63 | 16/32 | frozen; split by the store's rounding |
| 64–127 | 32/64 | frozen; split by the store's rounding |
| 128–253 | 62/126 | frozen; split by the store's rounding |

The patchy shape is real, then, but it follows the brightness of the region rather than its
gradient — and the boundary between the two behaviours sits exactly where the creep step meets the
half-ulp. Dark sky banks; half of bright sky banks. That is a correction to §3 as first written:
the gradient account is the full-precision behaviour (§2.1) and is not the mechanism here, and
neither account is distinguishable from the reported symptom alone.

---

## 4. The one-level comparison, and why it is not the whole story

The short comparison is float-fragile, which widens the blind band:

| step | computed diff | read at `AutoMaskEps = 1` |
| --- | --- | --- |
| `L1←L0` … `L128←L127` (8 pairs) | `1.0000000` … `1.0000075` | motion |
| the other 247 adjacent pairs | `0.9999999` | still |

The crossing pairs are `1, 2, 4, 8, 16, 32, 64, 128` — the binade edges. Per level crossed the
comparison trips on 4 of 8 pairs in levels 1–8, 2 of 24 in 9–32, 2 of 96 in 33–128 and 0 of 127
above 128, so dark scenery trips it far more often than bright.

It is **not** the cause of the reported symptom — and correcting it is **not neutral**.
Measured with the comparison forced to whole levels, the one-level swing does not merely stay
banked: the *whole* band banks, 253 of 253 levels instead of 141, because the fragile miss is
what leaves the average frozen instead of snapping onto the pixel (§5.4). Exactness removes
the only thing currently keeping half of the sky out. It is a defect, but it is load-bearing
by accident.

One other consumer of the same value is **not** affected: the motion gate counts a change with
`step(0.001, motion) > 0.5` — the ramp's own threshold is `0.001`, not `0.5` — and `smoothstep`
is continuous, so the two spellings of a one-level step are the same number to it:

| deadband | ramp at a 1-level step | counted toward `live_share` |
| ---: | ---: | --- |
| 1 | 0.2593 | yes |
| 2 | 0.0000 | no |
| 3 | 0.0000 | no |

At the default `AutoMaskEps = 1` there is therefore no gate blindness to the one-level sky: any
non-zero frame-to-frame change is at least a whole level, which is far above the 0.055 levels the
ramp needs to clear the threshold. (The drift side is continuous and its smallest counted reading
is that same 0.055 levels, so the two channels have slightly different noise floors at the gate.)
A ramp absorbs a ULP; a boolean against an integer does not.
*(Correction: the first pass wrote the gate as `smoothstep(...) > 0.5`, which would have needed
`maxDiff > 1.5`. The threshold is on `step(0.001, ...)`, so the conclusion drawn from it — that a
one-level sky cannot hold the premise — is wrong at the default setting, and the hardware check it
proposed is answered by the code. The open question in game is whether the sky's own
movement holds the premise at whatever deadband is set, which the table above answers from
deadband 2 up.)

---

## 5. What would fix it

The finding is structural, not a tuning error, so no slider position resolves it. There are two
correctness-shaped defects here, not one (§5.3 and §5.4), and they are coupled: neither is safe on
its own, and every repair to the existing channel makes the *returning* sky worse rather than
better.

1. **Detect *return*, not displacement.** The question that catches a sky is *"has this pixel
   come back to a value it held a while ago?"* — a repeat detector, and a different signal from
   either of the two being stored now (a recent sample or a coarsely quantized history of the
   pixel, compared for repetition). This is the only one of these that addresses the mechanism.
   It is also the significant change: a new per-pixel store and a new comparison, not a retune.
   The tables in §5.3 are the reason to keep it as the primary answer: the existing channel, in
   its shipped form, is already the best the three variants below manage on a returning sky.
2. **Lower the effective floor of the existing channel** by raising the horizon, since the floor
   is `deadband / K`. That is what the `2.0 s` default was for, and it is capped at 10 s. It does
   reduce the swaying bank — measured, 189/253 at 0.5 s, 141/253 at 2 s, 126/253 at 10 s — but
   for the accidental reason in §5.4, not the floor: a longer horizon shrinks the creep increment,
   so more bands fall into the frozen regime and their verdict falls to the store's rounding.
   §2.1's monotonic floor moves with the slider, but §2.1 describes the full-precision channel
   (§5.4), not the shipped one.
3. **Make the one-level comparison exact** (§4). A correctness fix on its own terms — "the most
   sensitive setting" should mean a one-level change on all 255 pairs, not 8 of them. Measured,
   though, it does not merely fail to remedy the sky; it removes the only thing keeping half of it
   out, because the fragile miss is what leaves the average frozen rather than snapping onto the
   pixel (§5.4):

   | comparison | store | one-level swaying levels banked (of 253) |
   | --- | --- | ---: |
   | shipped (float residue) | `RGBA16F` | 141 |
   | forced exact | `RGBA16F` | 253 |
   | shipped (float residue) | `RGBA32F` | 253 |
   | forced exact | `RGBA32F` | 253 |

   Every repair banks the whole returning band, because the freeze is what was holding it out.
   The shipped configuration is the only one of the four that keeps *any* of the one-level sky in
   the backdrop, and it does so by breaking the average rather than by judging it.

   A note on the monotonic case: a steady pan does not produce a
   steady sub-level signal in the model. A pixel drifts by whole levels, so it sits perfectly still
   for `1/rate` frames and then steps once — at 0.02 levels/frame, one step every 50 frames, well
   inside `AutoMaskForget`'s bridge. The pan's verdict is therefore decided partly by the pixel's
   own quantization staircase and not only by the drift channel, and the two cannot be separated by
   this model. That case needs the in-game overlay to read, not a table.
4. **Store the average at full precision.** This is the finding the first rewrite dropped, and it
   is what explains §3. The average lives in `RGBA16F`, and its creep step for the one-level gap
   the channel exists to close is 0.0083 levels at the 2 s default — under the store's half-ulp
   for every band above level 31:

   | levels | store ulp (levels) | half-ulp | creep step, 1-level gap @ 2 s | moves the store |
   | --- | ---: | ---: | ---: | --- |
   | 1–15 | 0.00097 | 0.00049 | 0.00833 | yes |
   | 16–31 | 0.01556 | 0.00778 | 0.00833 | yes |
   | 32–63 | 0.03113 | 0.01556 | 0.00833 | no |
   | 64–127 | 0.06226 | 0.03113 | 0.00833 | no |
   | 128–255 | 0.12451 | 0.06226 | 0.00833 | no |

   Above level 31 the average cannot creep toward the frame at all. It is frozen between snaps, so
   its lag is not `rate × K` (§2.1) but the distance the pixel has travelled since the last snap,
   and whether a level snaps is governed by §4's residue — which is why §2.2's "banked outright"
   and §2.1's floor describe the full-precision channel and not the shipped one. Widening the
   store to `RGBA32F` does remove the freeze, at twice the memory of the two drift targets — and
   it banks the whole swaying band, because a working average tracks a returning pixel. The two
   defects are really one: the residue decides *whether* the snap fires, and the resolution decides
   what happens when it does not.

   The freeze has a second face, and it runs the *other* way. A frozen average cannot close on a
   pixel either, so if it is left a level or more away it stays there, and the pixel reads as
   moving for as long as it holds — a genuinely static pixel that can never be masked. Measured:
   a pixel that steps one level **once** and then holds perfectly still never recovers the still
   verdict on **112 of the 252** levels, and the set is exactly the levels where both conditions
   hold — the step misses the snap (§4) *and* the frozen gap settles at or above the deadband.
   With a full-precision store the same test fails on 0 of 252 levels. So the pair of arithmetic
   accidents is not only letting scenery in; it is also keeping a static element out, and the same
   two changes close both.

---

## 6. Method and its limits

A standalone model of `CS_Accum`'s arithmetic as it stood when this was written, rather than an
approximation of it: the `round(c*255)/255` quantization, float32 intermediates, the binary16
quantization of the store (round-to-nearest-even), and the state machine with the shipped
`AutoMaskRise`/`AutoMaskFall`/`AutoMaskForget`/`AutoMaskMoveMemory` defaults. `drawn` is held
true so the per-pixel verdict is genuinely exercised. The shader was read for the constants and
the order of operations rather than assumed; the gate's own contribution is analysed separately
in §4.

Limits:

- The signals are synthetic — constant-rate drifts and triangle excursions of a single pixel
  value. That is the right instrument for the arithmetic question being asked, but it is not a
  measured skybox: the *rate* a real sky drifts at a given pixel is not established here, only
  which side of a boundary a given rate falls on.
- The comparisons are modelled exactly (the 8-bit grid, the float32 residue). The one input taken
  on trust was the store: the model assumed a half-precision target rounding to nearest even, as
  that format specifies, and both the band split in §3 and the freeze in §5.4 inherited the
  assumption. The landed fix (§5.3, §5.4) removes the dependency rather than confirming it — the
  drift targets are `RGBA32F` now, at full precision, so the model's store no longer describes the
  shipped one. The band split and the freeze remain the explanation of what the pre-fix channel
  did; they are not predictions about the fixed one.
- §3's gradient account — the first pass's answer — is the *full-precision* behaviour and was not
  what the pre-fix channel did; the band split was. Which band a given sky region falls into was
  inferred rather than measured, since a real sky is not a constant-rate synthetic signal.
- The model reproduces the accumulator, not the GPU. It says nothing about pass wiring, target
  formats in practice, the closing/dilation step's interaction with a partial sky mask, or
  timing.
- The one quantity to settle on hardware is where the channel now stands, since the fix
  replaces the arithmetic the tables were measured on: watch the overlay's motion view (red) over
  a slow pan across a *bright* backdrop and confirm it stays out of the mask. With the store at
  full precision the channel should behave as §2.1's floor describes, which is the behaviour the
  pre-fix `RGBA16F` store could not deliver.
- The second, and the cheaper of the two: put the overlay in its **verdict** view on a static HUD
  and confirm the green is there and stays there over the horizon. §5.4's freeze predicted a
  static element could be locked out on 112 of 252 levels; the full-precision store failed that
  test on 0 of 252, so the green should now be unconditional.
- The model's verdicts are read as mask coverage directly. The real shader puts `PS_Dilate` and
  the `AutoMaskRise`/`AutoMaskFall` timing between the verdict and the published mask, so a
  partially banked region may look more or less continuous on screen than the percentages here.

---

## 7. Summary of Action Items

1. **The reported cause is structural.** Both comparisons measure displacement — against the
   last frame and against a running average — and a skybox returns, so it is never displaced far
   from either reference. The channel's own stated premise ("building until the pixel sits
   visibly away from where its colour has been") simply does not hold for a drifting gradient.
   *(Correction: this is the second cause, not the first. The first is the reset in the header note
   above — the average was snapped by every one-level change, so it never held a baseline for the
   displacement to be measured against. The returning-sway case §1 describes survives the fix
   intact; what does not survive is the claim that a steadily creeping sky is out of the channel's
   reach, which was an artefact of the reset and not of the signal.)*
2. **The shipped channel's floor is not the horizon's floor.** §2.1's `deadband / K` table is the
   full-precision behaviour. In the shipped `RGBA16F` store the creep step for a one-level gap
   (0.0083 levels at 2 s) is under the store's half-ulp above level 31, so the average is frozen
   between snaps and its lag is set by the snap residue, not by `K` (§3, §5.4). Any conclusion
   drawn from the floor table applies to a repaired channel, not to this one.
3. **Expect a band-split sky, not a gradient-split one.** Whether a region is banked tracks its
   brightness band — dark sky banks, roughly half of bright sky banks — because that is where the
   creep step crosses the store's resolution (§3). The first pass's gradient account describes
   the full-precision channel only.
4. **A repeat detector is the signal that would catch it** — "has this pixel returned to a value
   it held before?" — and it is a new store and comparison rather than a retune (§5.1). It is the
   primary answer: every repair to the existing channel either makes the returning sky worse or
   leaves it unchanged (§5.3, §5.4).
   *(Correction: the last sentence no longer holds, and the reason is the decoupled reset. A working
   average does answer the steadily drifting case — measured, it takes a creeping sky out at every
   rate the reset leaves it able to accumulate — so the channel's repairs are not neutral after all.
   The repeat detector keeps the case it was always uniquely able to answer, a pixel that sways
   inside the horizon, and that case is unchanged by the fix: it is now the whole of the detector's
   remaining justification rather than a preference between equals.)*
5. **There are two correctness-shaped defects, and they are coupled (§5.3, §5.4).** Making the
   one-level comparison exact is a defect fix on the slider's own contract, and it is *not*
   neutral: it removes the accidental protection and banks all 253 swaying levels instead of 141.
   Widening the drift store to full precision is the other, and it alone restores the floor
   behaviour — at which point the floor, not the residue, becomes the limit again. Neither should
   be landed alone, and neither remedies the sky.
6. **They run both ways, and the freeze is a mask-eating bug in its own right.** A frozen average
   cannot close on a static pixel either: measured, a pixel that steps one level once and then
   holds never regains the still verdict on 112 of 252 levels, so a static element can be kept out
   of the mask indefinitely at a long horizon. A full-precision store fails that test on 0 of 252
   levels. This is not the reported symptom, and it is checkable in game with the overlay's
   verdict view.
7. **The gate claim in the first pass was wrong and is withdrawn (§4).** The threshold is
   `step(0.001, ...)`, so at the default deadband a one-level change *is* counted toward
   `live_share` and can hold the premise up. A one-level sky is not gate-blind at `AutoMaskEps = 1`.
