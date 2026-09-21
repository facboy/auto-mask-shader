# Review: estimating motion vectors from the 2D image

## 1. Overview & Scope

A follow-up to `docs/drift-snap-review.md`. That review found that both the frame-to-frame
comparison and the drift average measure **displacement**, and a skybox *returns*, so neither can
see it. The suggested remedy was a per-pixel repeat detector.

This document examines a different remedy: **detect the motion vector.** Rather than asking
whether a pixel stayed put, ask *"where did this patch of image move from, and to?"* — the "these
pixels over these frames show an object moving from A to B" framing.

Constraints taken as given:

- **No depth.** Confirmed: the depth buffer is not available to this shader. The estimate must
  come from image content alone.
- **The skybox is a flat plane with an animated texture**, so its motion is a coherent uniform 2D
  translation. This is the *favourable* case — see §2.
- Cost is a real constraint: the drift channel was justified as "roughly cost-neutral" and it
  already was not (`docs/drift-snap-review.md`, and the stage notes in
  `.junie/plans/automask-compute-gate-and-drift-channel.md`). Anything added here is a further
  addition, not a replacement.

**Adopted, in the smallest form.** The reversal §6 asks for has been recorded in
`.junie/plans/automask-compute-gate-and-drift-channel.md`, whose *Out of scope* entry for block
matching now says it is reopened rather than silently dropped. What is built is **§6.1's experiment
and nothing else**: one global low-resolution translation estimate per frame, drawn on the
diagnostics overlay behind a fourth structural switch (`AutoMaskOpticalFlow`, compute path required)
and wired into no verdict — no vector feeds the accumulator, the gate, the drift channel or the mask.
It exists to answer §6.2's two questions against a real skybox, and if either answer is no then §6.3
is not worth starting. The rest of this review stands as written: §3's baseline tension is why the
probe sweeps its baseline live and reports which one matched, §4's patchiness is what its coverage
map is there to show, and §5's "a vector is not the same question as 'is this HUD'" is why it is an
instrument rather than a fix. The repeat detector of `docs/drift-snap-review.md` §5.1 is still not
implemented — the two are alternatives, and §6's "Against the alternative" is the comparison between
them.

**Nothing below this line has been revised to match the probe.** This is a feasibility review as
written; it is kept that way on purpose, so the reasoning that led to the experiment can be read
against its result.

---

## 2. Why a flat plane is the good case

The shape of the motion decides whether image-only matching is even applicable:

| sky construction | motion in image space | matchable? |
| --- | --- | --- |
| Rotating dome / skybox sphere | shear, convergence at the poles, rotation — no single translation | no |
| **Flat plane, scrolling/panning animation** | **one coherent `(dx, dy)` across the region** | **yes** |
| Plane with in-place animation (flowing haze) | no translation at all | no vector to find (but see §5) |

A coherent translation is the one signature a matcher handles well, so the flat-plane assumption
turns the hostile case into the tractable one. That is the strongest argument for this approach.

Measured, on a synthetic sky (vertical gradient plus soft cloud detail) translated by a known
amount, then searched with a 9×9 patch over ±6 px:

| image texture | best offset found (true = 4 px) | SAD min / median |
| --- | --- | --- |
| none — pure gradient | no unique answer; every offset ties | 0.00 / 1.18 |
| any real detail | `+4, 0` — correct | 0.00 / 1.35 |

So when the offset exists, it is findable. The remaining obstacles are about *which* offsets
actually exist and whether they can be trusted at the speeds involved.

---

## 3. Obstacle: sub-pixel per frame needs a long baseline

This is the arithmetic that also limits the drift channel, and it is the crux.

Per-pixel 8-bit change for a sky translating at various speeds, over a 48×48 synthetic frame:

| shift (px/frame) | mean change (levels) | pixels at ≥1 level |
| ---: | ---: | ---: |
| 0.05 | 0.17 | 12% |
| 0.10 | 0.33 | 22% |
| 0.20 | 0.65 | 40% |
| 0.50 | 1.63 | 69% |

Under ~0.1 px/frame most of the image changes by zero levels between consecutive frames. An
integer block search has nothing to work with:

| shift (px/frame) | per-frame match | 8-frame baseline | 16-frame baseline |
| ---: | --- | --- | --- |
| 0.05 | `(0,0)` (want 0) | `(0,0)` (want 0.4) | `(+1,0)` (want 0.8) |
| 0.10 | `(0,0)` (want 0) | `(+1,0)` (want 0.8) | `(+2,0)` (want 1.6) |
| 0.25 | `(0,0)` (want 0) | `(+2,0)` (want 2) | `(+3,0)` (want 4) |
| 0.50 | `(0,0)` (want 0) | `(+3,0)` (want 4) | diverges |

Per frame the answer is `(0,0)` at every speed — the motion is simply not in the image yet. It
becomes findable only once it accumulates into whole pixels:

| shift (px/frame) | frames for 1 px | frames for 4 px | baseline at 60 fps |
| ---: | ---: | ---: | ---: |
| 0.02 | 50 | 200 | 3.3 s |
| 0.05 | 20 | 80 | 1.3 s |
| 0.10 | 10 | 40 | 0.7 s |
| 0.25 | 4 | 16 | 0.3 s |

So a detector must compare frames **several hundred milliseconds to several seconds apart**. That
is the same long-baseline idea the drift average uses, and it inherits the same class of problem:

- **Appearance drifts over the baseline.** Clouds evolve, lighting changes; the longer the
  baseline, the worse the match. The 16-frame row of the second table already degrades.
- **A looping animation matches at zero offset.** Skyboxes very commonly loop. Once the loop
  completes, the content is *identical*, so the best match is `(0,0)` — the detector reads a
  moving sky as stationary, which is precisely backwards. This is a correctness failure, not a
  tuning difficulty, and it cannot be fixed by choosing the search window.

The detector therefore has to compare recent-enough frames to stay coherent while comparing
far-enough-apart frames to see whole pixels. That tension is a design constraint, not a slider.

---

## 4. Obstacle: featureless regions

Where the SAD surface is flat, the argmin is noise rather than a measurement. A pure gradient has
no horizontal structure, so every horizontal offset ties exactly (first row of the §2 table).

This is the same split that produces the patchy sky mask reported in
`docs/drift-snap-review.md`: the contrasty regions are detectable and the flat ones are not.
Matching does not remove that boundary — it moves it from "how much did this pixel change" to
"does this patch have enough texture to match", which is a different distribution over the same
screen. Expect a different patchiness, not the absence of it.

---

## 5. Obstacle: a vector is not the same question as "is this HUD"

Even a perfect vector does not answer the mask's question by itself. Three gaps:

1. **Speed is not identity.** A HUD element that animates — a scrolling list, a draining bar —
   moves; so does scenery. A vector does not distinguish them, so a motion estimate is a *support*
   for the verdict rather than a replacement for it. (It does directly strengthen the world-drawn
   premise, though: a coherent sky translation is direct evidence the world is being drawn.)
2. **"In-place" animation has no vector.** A sky whose texture *evolves* rather than translates
   has no `(dx, dy)` to find. Such a sky changes every frame, so the existing short comparison
   should already catch it — but that is a different mechanism doing the work, not this one.
3. **An object's vector is not a pixel's fate.** "An object moves from A to B" is a statement
   about a *region*. Per-pixel matching is unaffordable and unnecessary: the sane shape is to
   estimate a small number of vectors per frame (one global, or on a tile grid), then have each
   pixel inherit its region's verdict. That is a **per-frame regional estimator with its own
   history** — a fourth signal alongside the accumulator, the coverage gate and the drift
   average, each with its own tuning, and the first three already interact.

---

## 6. What this would take, and what I would do first

The repo has already ruled this out once.
`.junie/plans/automask-compute-gate-and-drift-channel.md` lists **"Block matching / optical
flow"** under *Out of scope*, alongside the pixel-shader EMA fallback. Adopting this path is a
deliberate reversal of that decision, so it should be recorded as one rather than slipped in.

Before any of it, the cheapest decisive experiment:

1. **One global translation estimate per frame**, computed at low resolution (the existing
   pipeline already downsamples for the gate), over a sliding baseline of ~0.5–2 s. Print it to
   the diagnostics overlay and watch it against a real panning sky.
2. That answers the two questions that matter and that this model cannot: **does your sky
   actually produce a coherent vector**, and **is the estimate stable** frame to frame. If either
   is no, the rest is not worth building.
3. Only if it tracks: decide the baseline policy (§3 — the loop failure needs the estimate
   anchored to recent content, which is a design decision, not a constant), then how many regions
   are worth estimating (§5.3).

### Against the alternative

`docs/drift-snap-review.md` §5.1 proposed a per-pixel **repeat detector** — "has this colour come
back to a value it held before?" Both are new stores and new comparisons; the difference in
character:

| | repeat detector | region motion estimate |
| --- | --- | --- |
| granularity | per pixel | per region (global or tile grid) |
| cost model | scales like the accumulator | fixed per frame × regions × search area |
| handles flat plane | yes | yes, and describes it honestly |
| handles dome | partially | poorly — no coherent vector |
| handles loops | yes (repeat is the signal) | **no** — matches at zero offset (§3) |
| output | "this pixel moves", no direction | a vector: speed and direction |
| strengthens world-drawn premise | indirectly | directly |

For a *flat animated plane* specifically, matching is the more honest description of what is
happening on screen and returns more information. For a *dome*, the repeat detector is the better
bet. Neither is cheap, and neither is a retune of what exists.

---

## 7. Method and its limits

The matching tests are on synthetic skies — a vertical gradient plus soft blobs, translated
bilinearly so sub-pixel motion is representable, quantized to 8-bit levels, then searched with an
integer SAD. Two configurations produced the tables, which is worth stating because they differ:

| table | image | patch | search |
| --- | --- | --- | --- |
| §2 offset recovery | 64×64 | 9×9 | ±6 px |
| §3 change and match | 48×48 | 7×7 | ±3 px |

- It answers the existence question — *is there a correct offset, and can a search find it* — and
  the accumulation arithmetic of §3, which does not depend on the image at all.
- It is **not** a measurement of any real game's sky, and it says nothing about doing this at full
  resolution on a GPU, the cost of the search, or how a real skybox's texture and loop behaviour
  would behave. §6.1 is the experiment that would answer those.
- The "SAD min / median" column is a crude confidence measure; a real implementation would need a
  proper ratio test or a variance floor to detect the degenerate (flat) case of §4. Note that for
  the pure-gradient row it is `0.00 / 1.18` yet the offset found is wrong: the min is zero at
  *every* horizontal offset there, which is exactly why the ratio, not the minimum, is the reading.
- The 16-frame row of §3 diverging at 0.5 px/frame is a small-patch artefact as much as a
  baseline one — a 7×7 patch has left the ±3 px window at 8 px. It is included because the
  failure direction (a long baseline matching worse, not better) is the point.

---

## 8. Summary of Action Items

1. **Applicable in principle, and a flat plane is the favourable case** — a coherent translation
   is exactly what image-only matching handles well, and a known 4 px shift is recovered from
   synthetic sky frames with any real texture present (§2).
2. **The crux is the baseline, not the search.** Sub-pixel per-frame motion is invisible to a
   single-frame search (`(0,0)` at every speed tested), and needs frames 0.3–3 s apart to become
   whole pixels — at which point appearance drift and, fatally, a **looping animation matching at
   zero offset** come into play (§3).
3. **Featureless sky regions stay undetectable**, so expect a different patchiness rather than
   none — the same split behind the reported "areas of the skybox" (§4).
4. **It is a fourth signal, not a fix for the existing three**: a per-frame regional estimator
   with its own history and tuning, giving a vector that supports but does not replace the
   verdict (§5).
5. **The repo already scoped this out** and a reversal should be recorded as such. The cheapest
   decisive test is one global low-resolution translation estimate on the overlay before building
   anything else (§6).
