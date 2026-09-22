# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

A standalone ReShade shader that **builds its own UI mask** by watching what holds still: a pixel the
game redraws in place frame after frame is HUD, a pixel the world animates is not. A menu's region
holds still and lands in the mask; closed, that region shows moving world and drops out. It replaces
hand-authored mask images — no coordinates to pick, no mask PNG to paint, no per-element configuration.
The mask answers one question per pixel: **is this HUD or not**.

Designed against Kaiser's `UIDetectMulti` pack, a *separate* project on disk
(`/mnt/d/git/Reshade-Shaders`) sharing no code; `docs/review.md` there holds the design history and the
reasoning behind the decisions below. Credit for the concept, the store/restore pattern and the
anti-bloom suppression belongs to Kaiser (UIDetectMulti) and Brussels1 (the original work). MIT (see
`LICENSE`).

## Repository layout

| Path | Role |
| --- | --- |
| `Shaders/AutoMask.fx` | The shader: uniforms, render targets, pixel shaders, two techniques. |
| `tools/verify_shaders.py` | Offline compile-and-cost check. The only automated verification there is. |
| `tools/pyproject.toml` | The `uv` project the check runs under. Deliberately inside `tools/` — this is a shader project, not a Python one. |
| `README.md` | End-user guide: placement order, how to tune, what it cannot do. |
| `LICENSE` | MIT, with the credit line for the concept, the store/restore pattern and the anti-bloom pass. |

There is **no `.fxh` companion header and there deliberately never will be**. A header holds authored
data — pixel tables, coordinates, stored colours — and this shader has none: every tuning value is a
live slider, and the only preprocessor definitions are the structural switches (`AutoMaskAntiBloom`,
`AutoMaskDiagnostics`, `AutoMaskCompute`, `AutoMaskOpticalFlow`), which elide a pass rather than hold
data. Configuration in a file the user edits and restarts would be a usability regression, so do not
introduce one.

There is no build system and no CI beyond the offline check, by design. Never vendor ReShade's headers.

## Core model

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

### The `.fx` constraints that shape the design

- **A render target cannot be read while it is written.** So the accumulator has to **ping-pong**: read
  `A`, write `B`, then a copy pass brings `B` back to `A`. Compute adds one more form of the same rule: a
  texture written as storage in a pass cannot also be sampled in it, and a compute pass has no render
  target at all — the accumulator's write in `CS_Accum` is a `storage2D` write to `texAutoAccumB`.
- **There are no shared textures.** `ReShade.fxh` declares only `BackBufferTex` and `DepthBufferTex`, so
  another effect's stored frame is unreachable. This shader needs its own store target; it cannot borrow
  `UIDetectMulti`'s `texColorBeforeMulti`.

### The compute path

`AutoMaskCompute=1` swaps the accumulator and the screen-motion gate for compute passes, under a guard
that owns the shaders, the pass entries and every target only they use. The gate half is a replacement
rather than an addition — the coarse grid and its two reduction passes are gone, not skipped — which is
what keeps that cost claim honest. Two readings are *added* rather than replaced, both resting on the
compute path's ability to see every pixel: the drift channel's two full-res `RGBA32F` ping-pong targets,
which the pixel path has nowhere to put and deliberately does not carry, and the histogram's 256×1
`r32u` plus the 1×1 `r32f` step it feeds — 1 KB together — which the coarse grid cannot take at all,
because 1,024 taps cannot tell a level of dithering from a level of real motion.

- `CS_Accum` is `PS_Accum`'s state machine verbatim, plus one count: every pixel it calls changed adds to
  a `groupshared` tally, and one thread per **group** adds that tally to a single 1×1 `r32u` counter, so
  the global counter takes thousands of adds a frame instead of millions. That thread is picked with
  `SV_GroupIndex` (`gi == 0`); `SV_DispatchThreadID` is the *global* thread address, so testing that for
  zero would fire in one group only — the others would never reset or add their tally, and the count
  would be wrong in a way nothing on screen makes obvious.
- `CS_Finish` (1×1 dispatch, right after `CS_Accum`) divides the count by the pixel count, writes the
  share into a 1×1 `r32f` target and zeroes the counter. The pixel passes read that float target through
  a sampler named `MotionStat`, the same name the pixel path gives its RGBA8 statistic, so no guarded
  line is needed at the read sites — only the declaration differs per variant.
- The count replaces `PS_Motion`/`PS_MotionAvg` and the 16×16 coarse target. The gate was 1,024 taps
  standing in for every pixel; it is now exact.
- The **change-size histogram** rides in the same pass and is guarded with it: one `atomicAdd` per pixel
  into one of 256 `r32u` bins, indexed by the whole level of frame-to-frame difference, so the frame
  reports the whole distribution of its own movement rather than only the pixels above a threshold. The
  histogram exists because the pixel path cannot take the reading at all — 1,024 taps cannot tell a level
  of dithering from a level of real motion — and it is what makes an auto-deadband possible: `CS_Finish`
  reads the low levels back, finds the smallest one leaving no more than `AutoMaskNoiseFloor` percent of
  the screen changing above it, and writes that into a second 1×1 `r32f` target the next frame's
  `CS_Accum` reads through a sampler named `AutoStep`, one frame behind exactly as the share is. The
  measurement is per frame and never writes back into the slider. The walk covers levels 1 to 8 only,
  because 8 is where the `AutoMaskEps` slider ends and a step outside that range is not a position the
  manual path could take either. Running out of the range means no level separated the frame's noise from
  its content — what a fully live frame looks like, every level still changing somewhere — and there the
  slider's own value stands rather than the measurement guessing, so a fast camera movement cannot talk
  the shader into forgiving real motion. The bins are filled only while the toggle is on — that is the
  per-pixel atomic, so gating it is what keeps the off path costing what it cost before the feature
  existed — but the clear runs unconditionally, because a toggle flip with the bins left full would have
  the first measured step read off a stale frame. Clearing 256 bins from a 1-thread pass costs nothing
  worth eliding. `AutoMaskAutoStep` and `AutoMaskNoiseFloor` are declared beside the horizon inside the compute
  guard for the same reason it is: the pixel path has no pass that would read them. The auto-deadband is
  a live toggle rather than a fourth structural switch, so its targets stay allocated while it is off —
  the convention is that a value tuned by watching stays a slider and costs nothing but the memory its
  guard already owns, and 1 KB is not worth a recompile per comparison.
- The **drift channel** rides in the same pass and is guarded with it. Two full-res `RGBA32F` ping-pong
  targets hold a long-baseline average of each pixel's colour (`drift' = lerp(now, drift, 1 - 1/K)`,
  `K = AutoMaskDrift × AutoMaskTargetFPS` frames), and a pixel is marked moving when **either** the
  frame-to-frame difference or its distance from that average crosses the same deadband; the graded
  overlay carries the max, so red is still the reading the verdict comes from. It exists because the
  frame-to-frame comparison speaks in whole levels: a backdrop shifting by a fraction of one a frame — a
  skybox panning slowly — reads as exactly still there and would be banked as interface, while the
  average accumulates the shift until the pixel sits visibly away from where it has been. The clip-rail
  exclusion applies to the average symmetrically, and stillness now requires both comparisons to read
  still, so the drift channel also feeds the world-drawn count and the premise with it: a slowly panning
  sky can hold the premise up on its own. `PS_CopyDrift`, a pixel pass beside `PS_Copy`, brings the
  average back to the side the next frame reads. The store is the one that cannot be half precision: the
  creep toward a one-level gap is a fraction of a level a frame — at the 2 s default, 0.0083 levels — which
  is under an `RGBA16F` half-ulp above level 31 (0.0156 there, against 0.0078 in the band below), so the
  average sat frozen rather than following the pixel while the short comparison read still. A frozen
  average fails both ways: it cannot accumulate a sub-level shift (so the channel does nothing on the bright
  half of a sky) and it cannot close on a static pixel either, so a pixel left a level away from it read as
  moving for as long as it held. `RGBA32F` is what lets the creep step move the store at every level, and
  its cost is that the two drift targets double, ~59 MB to ~118 MB at 1440p.
- **An abrupt change follows at once, and only drift waits.** The average takes a horizon's worth of the
  frame a frame while the short comparison reads still — that is what lets a sub-level shift accumulate —
  but wherever the short comparison already reads a change it *becomes* the frame instead: the shader has
  already taken that frame for motion, and lagging a whole colour distance behind would hold a mask out
  of a scene cut or a load for a horizon on end. So a cut drags the average straight to the new scene and
  only the genuinely sub-deadband movement is left to accumulate. The cost is that a move the short
  comparison reads — a camera pan, a fast object — resets the average rather than being remembered by it;
  the drift channel is the long baseline for the case the short one is blind to, a shift too small to
  cross a level.

The fourth structural switch, `AutoMaskOpticalFlow`, carries the compute condition in its own guard
rather than sitting beside it, so it always requires the compute path. It owns one **measuring** feature
and nothing else: a ring of eight lagged low-resolution reference frames at a fixed 640×360, a 1×1
`RGBA32F` readout (`dx`, `dy`, confidence, winning slot), a 1×1 `r32f` cursor, a low-res `R8` coverage
map and the `r32f` score surface the search is laid out in. The scale is a design constraint rather
than a detail — the search can only find a shift of one ring pixel or more, so a quarter of a 1440p
frame is what keeps a four-screen-pixel move findable there, and the compute path's old 16×16 coarse
grid could not have served it because a whole-pixel shift lives inside one of its cells. It is an
instrument, not part of the mask: no line of `CS_Accum`'s state machine, the gate, the drift channel
or the mask reads any of its targets, so neither position of the switch changes what is protected.
`CS_FlowReduce` files each frame into the ring slot the cursor names, on the ring's own 640×360 grid
rather than the frame's — the ring is *fixed* resolution, so a dispatch taken from the buffer would
cover pixels it has no texels for — and `CS_Finish` advances the cursor one frame behind, the lag the
share and the measured step already carry. The reduction is the ring's only writer, so it takes the
eight slots as storage and reads the cursor through a sampler.

The search is **three passes, not the one the plan drew**, and the reason is latency rather than
tidiness. The template is the live frame — the same picture the slot just written holds, which is why
that slot is the *newest reference and not a candidate*: matching a frame against itself wins at
`(0,0)` every time, so the slot holding it is read as the template and the seven older slots are the
baselines, one to seven strides back. `CS_FlowMatch` is one thread per (baseline, offset) pair, writing
a score surface — one row per baseline, one column per offset — that `CS_FlowPick` reads to choose; a
single 1×1 pass doing the whole thing would be ~5×10⁴ *dependent* texture fetches in one lane, which no
latency hiding can cover, where the existing 1×1 `CS_Finish` is cheap only because its 256-iteration
loop is stores with at most eight fetches in it. The pick is two passes over the surface, so the two
loops stay separate and the compiler cannot re-read stale values.
The reading is the **ratio of the winner to the runner-up at a different offset**, never the minimum:
over a pure gradient every horizontal offset ties at zero while the offset found there is wrong, so
`best` alone says nothing and the tie is exactly what has to come out as no confidence. Excluding only
the winning *offset* — not the winning cell — is what keeps that true across baselines; a residual floor
behind it rejects the case the ratio cannot see, no offset matching at all, which is what a baseline
drifted past recognition looks like. Both are *rejections, not scores*, and the confidence multiplies
them so either can veto.
`CS_FlowCover` is the estimate's **fit** and deliberately not the cell's brightness: it matches each
cell at the offset and against the baseline the pick settled on, so a featureless stretch of sky and
something moving on its own both read as unexplained — one reading for both of §4's failures, where a
per-cell *contrast* would have shown only the first and a per-cell error at the winning offset would
have called a featureless cell trustworthy, since a uniform patch matches equally badly everywhere.
The coverage map is 40×24 against 40×23 so one cell is exactly 16×15 ring pixels.
`AutoMaskFlowStride` is a slider rather than a drag because it is a frame count rather than a duration,
and it is swept live because sweeping the baseline is the experiment §3 of `docs/optical-flow.md` turns
on; its uniforms are declared beside the horizon for the same reason the horizon's are, the pixel path
having no pass that would read them.

Four constraints the dialect imposes on any compute pass here, all found the hard way:

- **Sampling has no implicit derivatives.** `tex2D` is rejected outright at `cs_5_0` (X4532); a compute
  pass must use `tex2Dlod` and name its mip level. The pixel passes are unaffected.
- **A barrier must sit in uniform flow control.** A bounds `return` on the thread address before a
  `barrier()` is rejected (X4026), so the ceil-div guard has to be a predicate:
  `bool live = (tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT)`, with the frame sample and the store
  gated on it rather than skipped early.
- **`groupshared` is a file-scope declaration**, not a local: declaring it inside the shader body is
  error X3010.
- **A storage object cannot be indexed.** `store[int2(x, y)] = v` looks like HLSL and is not: the
  declaration's element type is a storage type, and the index-expression rule accepts only arrays,
  vectors and matrices, so ReShade rejects the bracket form with X3121 (`array, matrix, vector, or
  indexable object type expected in index expression`), reported against the *use* rather than the
  declaration. Reading and writing one goes through **`tex2Dfetch(store, coord)`** and
  **`tex2Dstore(store, coord, value)`** — the intrinsics are the only legal access, and ReShade's own
  codegen emits the bracket form for them before it calls a shader compiler, which is why the mistake is
  invisible in the emitted HLSL and compiles there. `storage2D<T>` remains the right thing to declare;
  only the access has to go through the intrinsics. The `atomic*` family is the one exception that is
  not a trap: it takes the storage and the coordinate as two arguments rather than indexing
  (`atomicAdd(AutoMotionCount, int2(0, 0), 1u)`), so those calls stay as they are and must not be
  "corrected" into bracket form.

`DispatchSizeX/Y` are group counts, taken from `BUFFER_WIDTH`/`BUFFER_HEIGHT` so they stay right at any
resolution, and the dispatch rounds up — which is exactly why the in-shader bounds predicate exists. The
probe's reduction is the one exception, and for the same reason read the other way: the ring is a *fixed*
640×360, so its dispatch and its predicate are taken from the ring's own size. A buffer-sized dispatch
there would cover pixels the ring has no texels for.

### Pass order inside `AutoMask`

Load-bearing, and follows from what each pass reads:

1. `PS_Accum` — builds the new confidence against the *previous* frame, **before** the history store, and
   applies the world-drawn premise by reading the statistic the previous frame left behind. With
   `AutoMaskCompute` on this pass is `CS_Accum` instead: same slot, same work, plus the count.
2. The two sub-resolution passes that average the still flag into the share of the screen being redrawn —
   after the accumulate, since their only input is what it just wrote, and read on the next frame. With
   `AutoMaskCompute` on these two are gone, replaced by `CS_Finish`, which turns the exact count into the
   same share — and, off the same histogram, the measured step the next frame reads. The auto-deadband
   therefore lands in the same slot and keeps the same one-frame-behind timing as the share: the frame
   being judged is never the frame that set its own threshold.
3. `PS_Copy`, `PS_Dilate` — the ping-pong back-edge and the boundary close, also before the store.
   `PS_Dilate` is one pass: a 2D max over a tiny fixed neighbourhood, stopping where the luma step read
   from `BackBuffer` exceeds `AutoMaskEdge`. Reading the frame there is safe only because it is before
   every pass that writes it. `PS_Copy` stays a pixel pass in both variants — the accumulator is
   `RGBA16F` and the copy has no statistics to do — and `PS_CopyDrift` is its twin on the compute path.
   With the probe on, `CS_FlowReduce` rides between those two and `CS_Finish`, so it reads the frame the
   accumulator read and files its reduction before the cursor advances, with `CS_FlowMatch`,
   `CS_FlowPick` and `CS_FlowCover` behind it — the frame just filed is the template, so the match has
   to follow the reduction, and the pick has to follow the surface the match laid out.
4. `PS_Store`, keeping the mapped pixels.
5. `PS_StoreFrame`, copying the untouched frame into the history target for the next frame.
6. `PS_AntiBloom` — black the masked pixels in the live frame so a bloom pass downstream has no UI to
   pick up. It comes after the store, which is what keeps the real UI for the restore pass; blacking
   earlier would bank the black instead.
7. The diagnostics overlay, last, and only when `AutoMaskDiagnostics` is defined to 1 — a compile-time
   guard on the pass and the shader both, so with it off neither is compiled. It reads the accumulator
   directly rather than recomputing the difference, so it cannot report on itself instead of on the
   shader. It draws one of two views, picked by the live toggle `UIDebugMotion`: red where the graded
   motion reads, or green where the accumulator's own confidence crosses the protection threshold. The
   published mask is deliberately *not* used, so the verdict view shows an element's own area without the
   closing radius grown around it. Both views tint over the stored history frame and only where the
   chosen signal covers — the blend is scaled by the signal, so a pixel it does not name is passed
   through untouched. The map packs both signals into one target: red the graded motion, green and blue
   the same verdict (two channels of one value, because the view reads one or the other), and alpha the
   screen state in two steps. The state is read from the same statistic the gate itself reads, one frame
   behind the frame it describes, so it shows the state that will shortly govern the mask rather than a
   value recomputed a second way, and its strictness must match the gate's: `> AutoMaskMotion`, not
   `step`, which is true at the threshold itself and would disagree on exactly the boundary frame. The
   deadzone ring is drawn over either view.
   The corner marker is **not** drawn here: it is the one thing `AutoMask_Restore` adds, reading that
   alpha channel, because a block drawn inside `AutoMask` is repainted by the restore pass over any pixel
   the mask covers and treated as picture by every effect in between. Two states, two flat colours and no
   blending — magenta while the world is being drawn, yellow while it is not and the mask is being held —
   so the marker is a reading rather than part of the picture and cannot be tinted by anything else on
   screen.

## Editing conventions

- HLSL comments are **short and sparse** (`//UINr 13`). Do not add tutorial narration to the shader. The
  one exception is the ruled credit block at the top of `Shaders/AutoMask.fx` — title, licence and the
  credit to Kaiser's `UIDetectMulti` and Brussels1 — which follows the companion pack's style and is the
  only long comment in the file. Do not add per-function attribution below it.
- The credit lives in both `LICENSE` and that header block on purpose: someone copying just the `.fx`
  into their ReShade folder takes the attribution with it.
- LF line endings.
- A uniform annotation must match the declared type: `__UNIFORM_SLIDER_FLOAT1`/`_FLOAT3` for floats,
  `__UNIFORM_SLIDER_BOOL1` for bools. A mismatch is a silent ReShade UI bug. The widget is chosen by the
  macro's family, and the family by what the value means: the duration settings (`AutoMaskRise`,
  `AutoMaskFall`, `AutoMaskForget`, `AutoMaskMoveMemory`, and the compute path's `AutoMaskDrift`) use
  `__UNIFORM_DRAG_FLOAT1`, a drag widget over free values rather than a stepped track; everything else is
  a slider.
- `BUFFER_WIDTH`/`BUFFER_HEIGHT` are injected by ReShade at runtime, not defined here. Anything
  buffer-relative stays correct across resolutions; absolute pixel numbers do not.
- Every pixel shader keeps `float4 pos : SV_Position` as its **first** parameter, even though no body
  reads it. `PostProcessVS` emits the position at `v0` and the UV at `v1`, and a pixel shader's `TEXCOORD`
  inputs are numbered from `v0` in declaration order — so the position is what pushes the UV onto `v1`.
  Drop it and the UV slides into the position's register; the debug layer reports a mismatched input and
  the draw still runs with the input undefined, so every pass samples one texel and the mask fills
  uniformly. `PS_MotionAvg` is the trap: its body has no `dcl_input_ps` at all and the parameter is still
  required, because linkage follows the *declared* signature.
- Four structural switches are preprocessor definitions, not sliders: `AutoMaskAntiBloom`,
  `AutoMaskDiagnostics`, `AutoMaskCompute` and `AutoMaskOpticalFlow`. Each is `#ifndef`-guarded with
  `// [0 or 1]` annotation comments, as the pack does it, and each guards everything that feature owns —
  its **pass and technique entry, its shader, and any `texture`/`sampler` only it uses** — because
  ReShade allocates every declared target, so a target left outside its guard is memory paid for a
  feature that is compiled out. The fourth also carries the compute switch as a condition, rather than
  sitting beside it: it requires `AutoMaskCompute=1`, so with compute off it is simply the pixel path — a
  combination that is compiled rather than assumed. Values tuned by watching stay live sliders; a
  definition is only for work that can be elided.
- `AutoMaskTargetFPS` is the one further definition, a setup number rather than a tuning one. The
  frame-count settings are durations, so their `ui_max` caps are seconds × `AutoMaskTargetFPS` (rise
  10 s, fall 1 s, grace 5 s, move memory 10 s) and grow with the frame rate a user plays at, which
  no literal could. It is not watched and not elided — a runtime `frametime` uniform cannot appear in an
  annotation, which is why it is a definition at all. The drift horizon is a duration of the other kind:
  its slider is already in seconds (cap a literal 10, step 0.25, default 2) and the frame count its
  average remembers is derived from it, so `AutoMaskTargetFPS` multiplies it inside the shader. Its
  default is the one value chosen from the mechanism rather than from the frame sliders' convention:
  the settled lag is the per-frame shift times the horizon in frames, so the shortest horizon that can
  clear the deadband out of a sub-level shift is what makes the channel do anything at all — a default
  of a few frames reads as no drift whatsoever. It is declared inside the compute guard beside the other
  uniforms, because the pixel path has no pass that would read it and a setting that does nothing is
  worse than an absent one. `AutoMaskAutoStep` and `AutoMaskNoiseFloor` sit there with it for the same
  reason.
- Update `README.md` in the same conversational, non-programmer voice whenever a user-facing behaviour
  changes.

## Verification

Nothing here is testable automatically in the true sense, so verification is a review pass plus an
offline compile check:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every shader with `fxc` and reports
  instruction counts and opcode histograms. Keep the `tools/.work/` output out of commits.
- The check compiles sixteen variants — `AutoMaskAntiBloom` and `AutoMaskDiagnostics` each at 0 and 1,
  crossed with `AutoMaskCompute` at 0 and 1, crossed again with `AutoMaskOpticalFlow` at 0 and 1, set
  from the prelude exactly as a ReShade-level definition would be — because a `#if` guard can drop a
  pass from a technique body, and only compiling every combination shows that it did. Each switch is
  crossed rather than added beside the others because it swaps a pass for one of another type instead
  of removing it, so a guard that drops or misbinds a pass has to show at both settings. The fourth is
  crossed the same way for a second reason: it is nested inside the compute guard, so `-flow` at
  compute off is the negative control — the plain pixel path, which has to compile as the same path
  the switch leaves alone rather than as a combination nobody ever compiled. `--pass-list` prints the
  wiring, `--opcodes` the histogram per shader, `--hashes` the bytecode sha256 of each entry point —
  which is how the variants with a switch off are shown to compile byte-for-byte as before a change.
- An entry point is compiled at the profile its shape calls for: `ps_5_0` for a `SV_Target` function,
  `cs_5_0` for a compute one, so a compute pass cannot slip through unread or be compiled as a pixel
  shader. A pass is read for `ComputeShader` as well as `PixelShader`, and a compute pass declaring fewer
  than two `DispatchSize`s exits non-zero the way ReShade rejects it (its error 3012).
- **A warning is a failure, not a note.** ReShade prints every warning its compile emits into the log the
  user reads at load, so shipping one is shipping an unreadable log — which is how a real warning gets
  missed. `check` therefore reports a warning entry as `WARN` and exits non-zero on it. The one exception
  is `X3579` (`ps_5_0 does not support groupshared, groupshared ignored`), which is the harness's own
  artefact rather than the shader's: the whole preprocessed file is compiled once per entry point, so fxc
  sees the compute path's file-scope `groupshared` tally while compiling a *pixel* entry point, where
  ReShade — emitting one pass's shader from that pass's reachable code — does not. The game's log carrying
  no such warning is what says the cause is the harness, so it is filtered on the reported code (this
  `fxc` rejects `/wd`: `Unknown or invalid option`) and nothing else is. Exercise the gate by hand before
  committing a change to it: put any of the constructs below back and it must exit non-zero naming the
  code.
- The shader is written so that `check` is silent, and each rewrite is the *only* thing that silences its
  code — do not "tidy" one back into the warning shape. Two of the four were seen in a real ReShade log,
  which is why they are the ones to leave alone: `X3556` eight times and `X4000` twice. The other two the
  check reports and a per-pass emit happens not to — a difference in what gets compiled, not a reason to
  put them back. A `clipped` accumulator declared `float3` makes `clipped == 0.0` a three-wide test whose
  `&&` truncation is X3206, so it is a `float` (the `all()` answer is one value, not one per channel); a
  slot-picking row of bare `if (...) return X;` statements with the last return unconditional reads to fxc
  as a function that may return nothing (X4000), so both such helpers are an `if`/`else if`/`else` chain;
  a flat counter unpacked with `int i % W` and `int i / W` is X3556 (integer modulus/division), so those
  counters are `uint` and the divisions take `uint` operands — the numbers are identical either way, and
  unsigned is the form fxc accepts without complaint; and two loops declaring the same counter name in one
  scope is X3078, so each walk names its own. The first two are outright bugs in the log and the last two
  are pure cost, so none is a cosmetic preference.
- **It must fail loudly on missing data.** An earlier version of the companion tool reported a clean pass
  while emitting no bytecode at all, because a missing hash compares equal to another missing hash. Seven
  cases must keep exiting non-zero, each exercised by hand before committing a change here: an empty
  `Shaders/`; a technique whose passes the parser cannot find (cross-checked against the `pass` keyword
  count, so a pattern miss cannot look like a technique with fewer passes); a technique binding a shader
  that does not exist; a shader whose syntax is broken; a compute pass missing one of its dispatch
  sizes; a variant list carrying two entries under one name, which would show the same combination
  twice and leave the other uncompiled — coverage read off a report that does not have it; and a call to
  an intrinsic `fxc` implements but ReShade does not, below.
- **A spelling the tool rewrites cannot be checked by compiling.** Storage declarations are translated to
  `RWTexture*` before fxc sees them, so a keyword ReShade would reject compiles in the check regardless —
  which is the one failure mode the check cannot see on its own. That already bit: a lowercase `storage2d`
  passed every variant and failed in ReShade with a bare X3000 pointing at the line rather than the case,
  and because the bad declaration dropped its target, two further X3004 errors followed from it. The
  dialect keywords are therefore pinned to ReShade's own lexer — `storage`, `storage1D`, `storage2D`,
  `storage3D` with a **capital** dimension letter, and those four only — and a near-miss is a loud
  failure rather than something to rewrite. Exercise it by hand with the file changed back to the
  lowercase spelling before committing any change to the translation.
- **The same rule covers the access intrinsics, and it bit a second time.** `tex2Dfetch`/`tex2Dstore` are
  translated to bracket form before fxc sees them, so their spellings are pinned the same way (a
  lowercased one is a loud failure, and a wrong argument count is too — it cannot be translated and must
  not be dropped). The sharper case is the *inverse*: because the translation produces the bracket form,
  that form compiles here even though ReShade rejects it, so the check would pass the very bug it exists
  to catch. A storage object indexed directly is therefore a loud failure in its own right (see the
  dialect constraint above), alongside the spelling and arity guards. Exercise all three by hand before
  committing a change to the translation, plus a texture indexed with brackets as the negative control,
  which must stay untouched.
- **The same caveat has a third form, and it is not a translation gap at all.** `fmod` is genuine HLSL
  that `fxc` implements and ReShade's parser simply does not carry, so a clean compile here is guaranteed
  and the effect still fails at load with X3004 (`undeclared identifier or no matching intrinsic
  overload`). It was written into the ring cursor's wrap — eight UAV slots and a float were both
  considered on the way to it — and it passed all sixteen variants before failing in the game. The names
  `fxc` has and ReShade's own table does not are therefore refused outright, that set being read from
  `source/effect_symbol_table_intrinsics.inl` rather than guessed: it is a deny set, so an ordinary
  identifier is never mistaken for a missed intrinsic, and a shader that defines its own function of one
  of those names is still allowed to call it. ReShade does provide `frac`, `floor`, `round`, `saturate`,
  `lerp`, `smoothstep`, `step`, `mad` and the `tex2D*` family — the whole vocabulary this shader uses —
  so a wrap around an integer is `%` rather than `fmod`. Exercise it by hand with `fmod` put back before
  committing a change to that guard.
- `pyproject.toml` lives in `tools/`, not at the repo root: this is a shader project, and `uv run`
  discovers the project by searching upward from the script, so the root-level command above works.

### The toolchain, which is not obvious

The compile check needs `fxc.exe`, which is a Windows binary run under WSL:

- It is looked up as `$FXC`, then `shutil.which("fxc.exe")`, then the newest
  `/mnt/c/Program Files (x86)/Windows Kits/10/bin/*/x64/fxc.exe`.
- Paths are translated with `wslpath -w` before being handed to `fxc`.
- The source must be preprocessed with these defined, because ReShade injects them and `fxc` will not
  compile without them:

  ```hlsl
  #define __RESHADE__ 52000
  #define __RESHADE_FXC__ 1
  #define BUFFER_WIDTH      2560
  #define BUFFER_HEIGHT     1440
  #define BUFFER_RCP_WIDTH  (1.0 / 2560.0)
  #define BUFFER_RCP_HEIGHT (1.0 / 1440.0)
  #define RGBA8 28
  ```

  Compiling is `/Gec /T <profile> /E <entry> /Fc <asm> /Fo <binary>`, with `ps_5_0` for a pixel entry
  point and `cs_5_0` for a compute one; the instruction count is read from
  `// Approximately N instruction slots used` in the assembly, and that count is cross-checked against
  the opcode histogram so a parsing miss cannot look like a pass. The compile's warning output is read
  too, because that is the same text ReShade puts in the log it shows at load (see the warning gate
  above).
- ReShade's compute dialect is not HLSL: `storage2D`/`storage1D`/`storage3D` objects, the group and
  memory barriers, and the `atomic*` family are its own surface vocabulary, and ReShade's own codegen
  translates them (`RWTexture*`, `GroupMemoryBarrierWithGroupSync()`, `Interlocked*`) before handing the
  result to a shader compiler. The check compiles the source itself, so it writes the same translation
  out in `strip_for_fxc`; without it no compute entry point could be compiled at all. The dimension
  letter is capital and those spellings are the only ones the lexer knows: a lowercased one is not a
  keyword, so it is guarded against rather than translated (see the loud-failure list above).
- The access intrinsics are part of the same translation: `tex2Dfetch(s, coord)` and
  `tex2Dstore(s, coord, value)` become `s[coord]` before fxc sees them, because a storage object cannot
  be indexed in the dialect at all and those calls are the only legal access. So the same
  unverifiable-by-compiling caveat applies, in both directions — the spelling and argument count are
  pinned (see the loud-failure list above), and the bracket form the translation produces, which ReShade
  would reject, is refused rather than passed.
- A barrier must sit in uniform flow control, so in a compute shader the `BUFFER_*` bounds guard for a
  ceil-div dispatch has to be a predicate rather than an early `return` — fxc rejects a `return` on the
  thread address before a barrier outright (X4026).
- **Real end-to-end testing means loading both techniques in ReShade in a game**, which an agent cannot
  do. State that clearly instead of claiming the change is verified, and name the scenarios that need
  eyes on them. Reviewing a screen capture is the next best thing. Watching the overlay in its motion view
  is the cheap way to see movement the deadband is still admitting, and the corner marker tells you
  whether the reading you are looking at is current.
  - Walking with the HUD up, a menu open, standing still in a quiet room, and standing still somewhere
    with fire or water in view.
  - The hold's two-sidedness in a stopped scene: a room with nothing animating must leave the mask empty
    rather than filling it — and stay empty indefinitely, since a stopped world can no longer add — while
    something still animating there (a spinner, a background loop) must fall out of the mask.
  - The marker, on any change that touches either technique: it is the only thing drawn after the
    restore, so if it is missing or tinted the pass that draws it has been moved or overwritten rather
    than the mask being wrong. It must read yellow in a stopped scene and magenta in a drawn one, and the
    mask in a yellow frame may only shrink — if it grows there, the hold has stopped being one-sided.
  - The move memory's pair, which is what the setting is balanced between: pan across detailed scenery
    and stop, with no interface in view — nothing the camera swept over should be grabbed as HUD, and with
    the world stopped it must *stay* out for good rather than clearing itself `AutoMaskMoveMemory` frames
    later, which is the screen-wide fill the one-sided hold prevents; then the same with an animating
    element on screen throughout — a draining bar or a scrolling list moving longer than
    `AutoMaskForget` — which should lose its protection to the memory and get it back once the animation
    stops and the world is drawn again.
  - The drift channel's pair, both on the compute path: pan slowly across otherwise still scenery — a
    sky, a distant backdrop — and the backdrop must stay out of the mask while a HUD in the same frame
    stays in, which the overlay's motion view is where to watch, since the short comparison alone shows
    the sky as clean; then cut between two scenes, or load one, and the mask must reform within a handful
    of frames rather than staying blank for the horizon. The third is a HUD that does not move but does
    flicker — a static element with temporal anti-aliasing on it — which must not be evicted by the
    channel at the default horizon; if it is, the horizon is what to shorten.
  - The auto-deadband's pair, both on the compute path: the same scene with the toggle on and off, and
    the step the measurement settles on should sit above the dithering the overlay shows as red without
    losing movement you can see — with the toggle off it must match the manual slider exactly, slider
    value and all. The third is a fully live frame — pan across detailed scenery with auto-detect on —
    where there is no quiet majority to measure and the slider's own value is what must govern, so the
    mask cannot start forgiving real motion just because the camera is moving.
  - The exact comparison, at `AutoMaskEps = 1`, where it is a visible change rather than an arithmetic
    one: the motion view over a large smooth gradient — a sky, a wall lit by a lamp — must now show a
    red rim wherever the ramp crosses a level, since every one-level change trips the verdict where only
    the binade edges used to. The mask must not start eating scenery on that account: a gradient region
    that animates is now read as moving at the smallest setting, so a backdrop that *stops* against a
    bright scene is the case to look at — it should still earn its mask once the world is drawn over it,
    the same as any other still pixel. Raising `AutoMaskEps` is the remedy if the extra red is noise, and
    the setting now means what its label says at every position.
  - The drift store's precision, on the compute path: pan slowly across a *bright* sky or backdrop — the
    upper half of the brightness range — and it must stay out of the mask, which the dark half already
    did. The reverse case is the one to watch with the verdict view: a static element sitting a level away
    from where its own average had settled used to be locked out indefinitely, so put the overlay in its
    verdict view on a still HUD element and confirm the green is there and stays there over the horizon.

## What this shader cannot do

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
- **HUD that animates more than briefly** needs the hold to bridge it, which makes `AutoMaskForget` the
  most important slider rather than a nicety — and it is a hard boundary rather than a matter of degree:
  animation that fits inside the hold is bridged and never banked, while animation that outlasts it is
  taken for the world and costs the element its protection until `AutoMaskMoveMemory` still frames have
  passed. The two sliders are tuned against each other — `AutoMaskForget` must exceed the longest
  animation any real element performs.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop and
  report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the convention used
  in the companion repo (e.g. `add rise and hold timing to the accumulator`).
