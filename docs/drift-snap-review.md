# Review: drifting scenery still reaching the mask

## 1. Overview & Scope

The compute path's drift channel was added so slowly drifting scenery — a panning skybox, a
distant backdrop — would stop being banked as interface. It does not fully do that: **areas of
the skybox still reach the mask.**

This is the second pass at the question. The first assumed the complaint was the opposite — HUD
failing to be masked — and proposed decoupling the drift average's reset. That is not the failure
on the table, so this review starts over on scenery being *taken in*.

Findings come from a numeric model of `CS_Accum`'s arithmetic, not the GPU; what that does and
does not establish is in §7.

**No code, setting or default has been changed.** The review was read-only and is recorded rather
than actioned.

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

### 2.1 Measured: a steady pan also has a floor

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

### 2.2 And a *returning* pixel doubles the floor

Where the local motion reverses before the average can be left a level behind — a camera arc that
turns back, counter-moving cloud layers — the average tracks the excursion and the lag is only
half the swing. The rate needed doubles:

| horizon | monotonic drift caught | swaying motion caught |
| ---: | ---: | ---: |
| 2 s | 0.0083 levels/frame | 0.0167 levels/frame |
| 10 s | 0.0017 levels/frame | 0.0033 levels/frame |

Confined to a one-level excursion — a pixel alternating between two adjacent 8-bit values, which
is the mildest case — the measured peak lag is **0.96 levels**, below the deadband at every
horizon from 0.5 s to 10 s. That case is banked outright, and nothing about the setting reaches
it.

---

## 3. Why "areas" rather than the whole sky

Whether a sky region sits under the floor depends on how far the image slides *at that pixel*,
which is the product of the local gradient and the drift distance. A smooth sky is not uniform —
it carries many levels per screen through cloud and horizon gradients and almost none in the flat
stretches — so neighbouring regions cross the floor at different rates and the mask comes out
patchy. That is what "areas of the skybox" looks like, and it is why the mask on a sky reads as a
partial blot rather than a clean edge.

Modelled over a full mask cycle (2 s horizon, deadband 1, world being drawn), mask coverage by
how far the local drift carries a pixel:

| local drift | mask coverage |
| --- | ---: |
| steady, below 0.0083 levels/frame | 100% |
| steady, at or above it | 0% |
| swaying within a 1-level excursion | 100% at every horizon 0.5–10 s |

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

It is worth recording, but it is **not** the cause of the reported symptom, and the honest
statement of that is a correction to the first pass: making this comparison exact does not stop
the sky being banked. Measured with the comparison forced to whole levels, the one-level swing
is still 100% banked, because the drift channel is blind to it for its own independent reason
(§2). The fix is a correctness improvement, not a remedy.

Two places the same value is used are unaffected, and the difference is instructive: the motion
gate tests `smoothstep(deadband - 1, deadband + 2, maxDiff) > 0.5`, which needs `maxDiff > 1.5`,
so a one-level step contributes nothing to the gate whether it computes `0.9999999` or `1.0`. A
ramp absorbs a ULP; a boolean against an integer does not.

**Needs hardware:** whether that gate blindness matters. A sky drifting a level per frame
contributes zero to `live_share`, so it cannot hold the world-drawn premise up on its own — but
the character and effects normally do, so it may never show. The check is the diagnostics
overlay: on a sky-heavy frame with nothing else moving, does the corner marker stay magenta when
it should go yellow?

---

## 5. What would fix it

The finding is structural, not a tuning error, so no slider position resolves it.

1. **Detect *return*, not displacement.** The question that catches a sky is *"has this pixel
   come back to a value it held a while ago?"* — a repeat detector, and a different signal from
   either of the two being stored now (a recent sample or a coarsely quantized history of the
   pixel, compared for repetition). This is the only one of these that addresses the mechanism.
   It is also the significant change: a new per-pixel store and a new comparison, not a retune.
2. **Lower the effective floor of the existing channel** by raising the horizon, since the floor
   is `deadband / K`. That is what the `2.0 s` default was for, and it does move the monotonic
   and swaying floors (§2.1, §2.2) — but it is capped at 10 s, so it cannot reach a drift under
   0.1 levels/second, and it does nothing at all for the one-level swaying band.
3. **Make the one-level comparison exact** (§4). A correctness fix on its own terms — "the most
   sensitive setting" should mean a one-level change on all 255 pairs, not 8 of them — but
   measured, it does not remedy the sky.

---

## 6. Method and its limits

A standalone model of `CS_Accum`'s arithmetic rather than an approximation of it: the
`round(c*255)/255` quantization, float32 intermediates, the binary16 quantization of the store
(round-to-nearest-even), and the state machine with the shipped
`AutoMaskRise`/`AutoMaskFall`/`AutoMaskForget`/`AutoMaskMoveMemory` defaults. `drawn` is held
true so the per-pixel verdict is genuinely exercised; the gate's own contribution is analysed
separately in §4.

Limits worth stating plainly:

- The signals are synthetic — constant-rate drifts and triangle excursions of a single pixel
  value. That is the right instrument for the arithmetic question being asked, but it is not a
  measured skybox: the *rate* a real sky drifts at a given pixel is not established here, only
  that anything under the floor is banked.
- §3's account of *which* regions is the most inferential part. It follows from a real sky having
  varying local gradient, which is true of any gradient, but the patchiness is not measured.
- The model reproduces the accumulator, not the GPU. It says nothing about pass wiring, target
  formats in practice, the closing/dilation step's interaction with a partial sky mask, or
  timing.
- The one quantity worth settling on hardware is where the boundary actually falls in a given
  game: watch the overlay's motion view (red) over a slow pan and see whether the sky lights up
  at all. §2 says it should not, wherever the local drift is under the floor.

---

## 7. Summary of Action Items

1. **The reported cause is structural.** Both comparisons measure displacement — against the
   last frame and against a running average — and a skybox returns, so it is never displaced far
   from either reference. The channel's own stated premise ("building until the pixel sits
   visibly away from where its colour has been") simply does not hold for a drifting gradient.
2. **There is a hard floor in levels/second, set by the horizon.** At the default 2 s a steady
   drift under 0.5 levels/second is banked; at the 10 s cap, under 0.1. A one-level swaying
   region is banked at every setting (§2.1, §2.2).
3. **Expect patchy sky coverage, not a clean edge**, since whether a region is banked depends on
   its own local drift rate (§3).
4. **A repeat detector is the signal that would catch it** — "has this pixel returned to a value
   it held before?" — and it is a new store and comparison rather than a retune (§5.1).
5. **Do not expect the existing levers to close it.** The horizon helps the monotonic and
   swaying floors but is capped; making the one-level comparison exact is a correctness fix that
   does not remedy the sky (§4, §5.3).
