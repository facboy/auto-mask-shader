# Review: estimating motion vectors from the 2D image

## 1. Overview & Scope

A follow-up to `docs/drift-snap-review.md`, whose finding was that both the frame-to-frame comparison and
the drift average measure **displacement**, and a skybox *returns*, so neither can see it. That review
suggested a per-pixel repeat detector; this one asks whether the motion itself can be estimated instead —
*"where did this patch of image move from, and to?"*.

Constraints taken as given:

- **No depth for a per-pixel verdict.** `DepthBufferTex` is reachable, but the overlay writes no depth, so
  depth speaks for the world and never for the interface. The estimate must come from image content alone;
  `AutoMaskDepthMotion` is what depth *is* spent on (`docs/core-model.md`).
- **The skybox is a flat plane with an animated texture**, so its motion is a coherent uniform 2D
  translation. This is the favourable case — see §2.
- Cost is a real constraint: the drift channel was already sold as "roughly cost-neutral" and was not.

**Built in the smallest form, then removed.** What was built was §6.1's experiment and nothing else,
behind a fourth structural switch and wired into no verdict: one global low-resolution translation
estimate, drawn on the diagnostics overlay. It was watched in a real game and returned a negative result
(§6.2), so the switch, its targets, its four compute passes and its third overlay view are all gone. §6's
own terms decide it: the estimate was to be adopted only if it tracked a real sky, and it did not. What it
cost to keep was ~7 MB of ring and score targets, four passes a frame and a third overlay view, for a
reading the mask never used and the drift channel already provides better, per pixel and at full
resolution.

**The rest of this review is kept in its original voice**, so the reasoning that led to the experiment can
be read against its result: §3's baseline tension is why the probe swept its baseline live, §4's
patchiness is what its coverage map was there to show, and §5's "a vector is not the same question as
'is this HUD'" is why it was an instrument rather than a fix. §9 is closed with it.

**§6.2 answered, in a real game — the negative result the experiment existed to produce.** With the
compute path and the flow switch on, standing still while a sky pans slowly, watched on the flow view:

1. **The sky's motion is below the probe's floor.** One ring pixel is ~4 screen pixels at the fixed
   640×360 ring; a sky drifting a fraction of a screen pixel per frame sits under one ring pixel over
   every stored baseline, so the search reads `(0,0)` — grey, over the whole frame. The drift straddled
   the floor occasionally, the shift crossing a whole ring pixel once per stride and falling back under
   it the next. That is §3's arithmetic seen live, not a tuning failure: the movement has to be whole ring
   pixels per gap before any matcher sees it.
2. **The grey conflates still HUD with barely-moving sky.** A still HUD matches `(0,0)` as perfectly as
   still scenery — one global vector plus a per-cell fit cannot separate them at `(0,0)`, which is §5.1's
   accepted conflation read on real content. Where the sky moved fast enough to cross the floor, sky
   tinted in the pan's direction while the HUD stayed grey: the expected signature of a *fast enough*
   pan, and the only case the probe distinguishes.
3. **Anything animating on its own read untinted** — the per-cell fit rejecting what the global vector
   does not explain, which is §4 working as designed.
4. **The verdict never changed.** The probe is wired into nothing, and every mask scenario behaved with
   the estimate on exactly as with it off.

**Conclusion:** for this mask's verdict, matching adds nothing the existing signals do not already own.
The slow-creep case the mask needs solved is per-pixel time accumulation — the drift channel's mechanism,
already in the shader, with no whole-pixel threshold to cross and no loop failure to answer for. The
matcher refinements that *would* see sub-floor creep (area-averaged storage, sub-pixel readout, sub-level
precision) converge on the drift channel's design at block granularity, and they exist only to sharpen an
instrument the mask does not read. The burden of proof is now on a proposal that answers the loop failure
§3 names before anything is built on a vector.

## 2. Why a flat plane is the good case

The shape of the motion decides whether image-only matching is even applicable:

| sky construction | motion in image space | matchable? |
| --- | --- | --- |
| Rotating dome / skybox sphere | shear, convergence at the poles, rotation — no single translation | no |
| **Flat plane, scrolling/panning animation** | **one coherent `(dx, dy)` across the region** | **yes** |
| Plane with in-place animation (flowing haze) | no translation at all | no vector to find (but see §5) |

A coherent translation is the one signature a matcher handles well. Measured, on a synthetic sky
(vertical gradient plus soft cloud detail) translated by a known amount, then searched with a 9×9 patch
over ±6 px:

| image texture | best offset found (true = 4 px) | SAD min / median |
| --- | --- | --- |
| none — pure gradient | no unique answer; every offset ties | 0.00 / 1.18 |
| any real detail | `+4, 0` — correct | 0.00 / 1.35 |

So when the offset exists, it is findable. The remaining obstacles are about *which* offsets actually
exist and whether they can be trusted at the speeds involved.

## 3. Obstacle: sub-pixel per frame needs a long baseline

This is the arithmetic that also limits the drift channel. Per-pixel 8-bit change for a sky translating
at various speeds, over a 48×48 synthetic frame:

| shift (px/frame) | mean change (levels) | pixels at ≥1 level |
| ---: | ---: | ---: |
| 0.05 | 0.17 | 12% |
| 0.10 | 0.33 | 22% |
| 0.20 | 0.65 | 40% |
| 0.50 | 1.63 | 69% |

Under ~0.1 px/frame most of the image changes by zero levels between consecutive frames. An integer block
search has nothing to work with:

| shift (px/frame) | per-frame match | 8-frame baseline | 16-frame baseline |
| ---: | --- | --- | --- |
| 0.05 | `(0,0)` (want 0) | `(0,0)` (want 0.4) | `(+1,0)` (want 0.8) |
| 0.10 | `(0,0)` (want 0) | `(+1,0)` (want 0.8) | `(+2,0)` (want 1.6) |
| 0.25 | `(0,0)` (want 0) | `(+2,0)` (want 2) | `(+3,0)` (want 4) |
| 0.50 | `(0,0)` (want 0) | `(+3,0)` (want 4) | diverges |

Per frame the answer is `(0,0)` at every speed — the motion is simply not in the image yet. It becomes
findable only once it accumulates into whole pixels:

| shift (px/frame) | frames for 1 px | frames for 4 px | baseline at 60 fps |
| ---: | ---: | ---: | ---: |
| 0.02 | 50 | 200 | 3.3 s |
| 0.05 | 20 | 80 | 1.3 s |
| 0.10 | 10 | 40 | 0.7 s |

So a detector must compare frames **several hundred milliseconds to several seconds apart** — the same
long-baseline idea the drift average uses, with the same class of problem:

- **Appearance drifts over the baseline.** Clouds evolve, lighting changes; the longer the baseline, the
  worse the match. The 16-frame row of the table above already degrades.
- **A looping animation matches at zero offset.** Skyboxes commonly loop, and once the loop completes the
  content is *identical*, so the best match is `(0,0)` — the detector reads a moving sky as stationary,
  which is precisely backwards. This is a correctness failure, not a tuning difficulty, and cannot be
  fixed by choosing the search window.

The detector therefore has to compare recent-enough frames to stay coherent while comparing
far-enough-apart frames to see whole pixels. That tension is a design constraint, not a slider.

## 4. Obstacle: featureless regions

Where the SAD surface is flat, the argmin is noise rather than a measurement: a pure gradient has no
horizontal structure, so every horizontal offset ties exactly (§2's first table row). This is the same
split that produces the patchy sky mask reported in `docs/drift-snap-review.md` — contrasty regions are
detectable and flat ones are not. Matching does not remove that boundary; it moves it from "how much did
this pixel change" to "does this patch have enough texture to match". Expect a different patchiness,
not the absence of it. A variance floor or a ratio test is the standard remedy, and neither exists in an
8-bit SAD over a smooth gradient.

## 5. Obstacle: a vector is not the same question as "is this HUD"

1. **Speed is not identity.** A HUD element that animates — a scrolling list, a draining bar — moves, and
   so does scenery, so a vector does not distinguish them: a motion estimate *supports* the verdict
   rather than replacing it. It does directly strengthen the world-drawn premise, since a coherent sky
   translation is direct evidence the world is being drawn.
2. **"In-place" animation has no vector.** A sky whose texture *evolves* rather than translates has no
   `(dx, dy)` to find. Such a sky changes every frame, so the existing short comparison should already
   catch it — a different mechanism doing the work, not this one.
3. **An object's vector is not a pixel's fate.** "An object moves from A to B" is a statement about a
   *region*. Per-pixel matching is unaffordable and unnecessary: the sane shape is to estimate a small
   number of vectors per frame (one global, or on a tile grid), then have each pixel inherit its region's
   verdict. That is a **per-frame regional estimator with its own history** — a fourth signal alongside
   the accumulator, the coverage gate and the drift average, each with its own tuning.

## 6. What this would take, and what I would do first

The repo has already ruled this out once:
`.junie/plans/automask-compute-gate-and-drift-channel.md` lists **"Block matching / optical flow"** under
*Out of scope*. Adopting it is a deliberate reversal of that decision, to be recorded as one rather than
slipped in.

Before any of it, the cheapest decisive experiment:

1. **One global translation estimate per frame**, at low resolution, over a sliding baseline of ~0.5–2 s,
   printed to the diagnostics overlay and watched against a real panning sky.
2. That answers the two questions the model cannot: **does your sky actually produce a coherent vector**,
   and **is the estimate stable** frame to frame. If either is no, the rest is not worth building.
3. Only if it tracks: decide the baseline policy (§3 — the loop failure needs the estimate anchored to
   recent content, a design decision rather than a constant), then how many regions are worth estimating
   (§5.3). **It did not track, so this step was never taken** — §6.2 is the answer, and it closed §6.3.

### Against the alternative

`docs/drift-snap-review.md` §5.1 proposed a per-pixel **repeat detector** — "has this colour come back to
a value it held before?" Both are new stores and new comparisons; the difference in character:

| | repeat detector | region motion estimate |
| --- | --- | --- |
| granularity | per pixel | per region (global or tile grid) |
| cost model | scales like the accumulator | fixed per frame × regions × search area |
| handles flat plane | yes | yes, and describes it honestly |
| handles dome | partially | poorly — no coherent vector |
| handles loops | yes (repeat is the signal) | **no** — matches at zero offset (§3) |
| output | "this pixel moves", no direction | a vector: speed and direction |
| strengthens world-drawn premise | indirectly | directly |

For a *flat animated plane* matching is the more honest description and returns more information; for a
*dome* the repeat detector is the better bet. Neither is cheap, and neither is a retune of what exists.

## 7. Method and its limits

The matching tests are on synthetic skies — a vertical gradient plus soft blobs, translated bilinearly so
sub-pixel motion is representable, quantized to 8-bit levels, then searched with an integer SAD. Two
configurations produced the tables:

| table | image | patch | search |
| --- | --- | --- | --- |
| §2 offset recovery | 64×64 | 9×9 | ±6 px |
| §3 change and match | 48×48 | 7×7 | ±3 px |

- It answers the existence question — *is there a correct offset, and can a search find it* — and the
  accumulation arithmetic of §3, which does not depend on the image at all.
- It is **not** a measurement of any real game's sky, and says nothing about doing this at full resolution
  on a GPU, the cost of the search, or a real skybox's texture and loop behaviour. §6.1 was the experiment
  that would answer those, and it has since been run and answered them negatively (§6.2).
- The "SAD min / median" column is a crude confidence measure. For the pure-gradient row it is `0.00 /
  1.18` yet the offset found is wrong: the min is zero at *every* horizontal offset there, which is why
  the ratio, not the minimum, is the reading.
- The 16-frame row of §3 diverging at 0.5 px/frame is a small-patch artefact as much as a baseline one —
  a 7×7 patch has left the ±3 px window at 8 px. It is included for its failure direction.

## 8. Summary of Action Items

1. **Applicable in principle, and a flat plane is the favourable case** — a coherent translation is
   exactly what image-only matching handles well, and a known 4 px shift is recovered from synthetic sky
   frames with any real texture present (§2).
2. **The crux is the baseline, not the search.** Sub-pixel per-frame motion is invisible to a single-frame
   search (`(0,0)` at every speed tested), and needs frames 0.3–3 s apart to become whole pixels — at
   which point appearance drift and, fatally, a **looping animation matching at zero offset** come into
   play (§3).
3. **Featureless sky regions stay undetectable**, so expect a different patchiness rather than none (§4).
4. **It is a fourth signal, not a fix for the existing three**: a per-frame regional estimator with its
   own history and tuning, giving a vector that supports but does not replace the verdict (§5).
5. **The repo already scoped this out**, and a reversal should be recorded as such. The cheapest decisive
   test is one global low-resolution translation estimate on the overlay before building anything else
   (§6).

**All five items were acted on, and the outcome closes the line.** The reversal was recorded and the §6.1
experiment was built; it then returned "no at this scale" against the real sky it was asked about (§6.2),
so items 1–4 describe a path whose decisive test failed rather than a plan still to be taken, and item 5's
reversal has been reversed back.

## 9. Scoped follow-up: sub-level precision in the ring — closed, not built

The two refinements that landed (area-averaged reduction, sub-pixel readout) sharpened the instrument
without changing what it could see. The third piece — precision in the ring store, which would have let
the overlay *demonstrate* sub-level drift on a slow sky — is kept as the record of what it would have
cost:

- **Where the information is destroyed.** The reduce pass stored `round(c * 255)` in `RGBA8`. A sky
  drifting 1/16 level per frame moves a stored texel's *true* value by a quarter level per stride at
  stride 4, and each stored frame rounds to the same level, so consecutive slots are bit-identical and
  the SAD is identical at every offset. Nothing downstream can recover what was never stored.
- **What it would have taken.** The ring becomes `RGBA16F` (the minimum: the drift channel's own analysis
  puts the per-frame creep at ~0.0083 levels at a 2 s horizon, under a half-ulp in the upper half of the
  range) or `RGBA32F` (the safe choice). The 7 MB ring becomes 14 or 28 MB, the texel stops rounding, and
  the SAD compares fractional levels — so the ratio test needs re-deriving against a fractional unit,
  though it survives: a flat patch still ties and a real match still wins by margin.
- **Why it was never the mask-side fix, and is now not built at all.** All of this answers one question
  per block, while the drift channel answers it per pixel at full resolution with no search at all. The
  creep the mask needs caught is per-pixel; the drift channel is the tool. Sub-level precision was worth
  building only if the probe was wanted as a *demonstration* instrument, and §6.2's negative result is
  what says nobody wants that.
