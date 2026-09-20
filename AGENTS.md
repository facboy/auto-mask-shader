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
`AutoMaskDiagnostics`, `AutoMaskCompute`), which elide a pass rather than hold data. Configuration in a
file the user edits and restarts would be a usability regression, so do not introduce one.

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
The comparison is also quantized onto whole levels (`round(now * 255.0) / 255.0`) before the difference:
the history is stored on that grid, so on a higher-precision back buffer a sub-level change would otherwise
be forgiven by the deadband while the overlay's gain painted those same small differences red. The clip
exclusion is checked after the quantization, on the grid the comparison itself speaks, so the pinned colour
and the history agree on what 'all 0' and 'all 255' mean.

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
what keeps that cost claim honest. The drift channel is the one thing this path *adds*: two full-res
`RGBA16F` ping-pong targets, which the pixel path has nowhere to put and deliberately does not carry.

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
- The **drift channel** rides in the same pass and is guarded with it. Two full-res `RGBA16F` ping-pong
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
  average back to the side the next frame reads.
- **An abrupt change follows at once, and only drift waits.** The average takes a horizon's worth of the
  frame a frame while the short comparison reads still — that is what lets a sub-level shift accumulate —
  but wherever the short comparison already reads a change it *becomes* the frame instead: the shader has
  already taken that frame for motion, and lagging a whole colour distance behind would hold a mask out
  of a scene cut or a load for a horizon on end. So a cut drags the average straight to the new scene and
  only the genuinely sub-deadband movement is left to accumulate. The cost is that a move the short
  comparison reads — a camera pan, a fast object — resets the average rather than being remembered by it;
  the drift channel is the long baseline for the case the short one is blind to, a shift too small to
  cross a level.

Three constraints the dialect imposes on any compute pass here, all found the hard way:

- **Sampling has no implicit derivatives.** `tex2D` is rejected outright at `cs_5_0` (X4532); a compute
  pass must use `tex2Dlod` and name its mip level. The pixel passes are unaffected.
- **A barrier must sit in uniform flow control.** A bounds `return` on the thread address before a
  `barrier()` is rejected (X4026), so the ceil-div guard has to be a predicate:
  `bool live = (tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT)`, with the frame sample and the store
  gated on it rather than skipped early.
- **`groupshared` is a file-scope declaration**, not a local: declaring it inside the shader body is
  error X3010.

`DispatchSizeX/Y` are group counts, taken from `BUFFER_WIDTH`/`BUFFER_HEIGHT` so they stay right at any
resolution, and the dispatch rounds up — which is exactly why the in-shader bounds predicate exists.

### Pass order inside `AutoMask`

Load-bearing, and follows from what each pass reads:

1. `PS_Accum` — builds the new confidence against the *previous* frame, **before** the history store, and
   applies the world-drawn premise by reading the statistic the previous frame left behind. With
   `AutoMaskCompute` on this pass is `CS_Accum` instead: same slot, same work, plus the count.
2. The two sub-resolution passes that average the still flag into the share of the screen being redrawn —
   after the accumulate, since their only input is what it just wrote, and read on the next frame. With
   `AutoMaskCompute` on these two are gone, replaced by `CS_Finish`, which turns the exact count into the
   same share.
3. `PS_Copy`, `PS_Dilate` — the ping-pong back-edge and the boundary close, also before the store.
   `PS_Dilate` is one pass: a 2D max over a tiny fixed neighbourhood, stopping where the luma step read
   from `BackBuffer` exceeds `AutoMaskEdge`. Reading the frame there is safe only because it is before
   every pass that writes it. `PS_Copy` stays a pixel pass in both variants — the accumulator is
   `RGBA16F` and the copy has no statistics to do — and `PS_CopyDrift` is its twin on the compute path.
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
- Three structural switches are preprocessor definitions, not sliders: `AutoMaskAntiBloom`,
  `AutoMaskDiagnostics` and `AutoMaskCompute`. Each is `#ifndef`-guarded with `// [0 or 1]` annotation
  comments, as the pack does it, and each guards everything that feature owns — its **pass and technique
  entry, its shader, and any `texture`/`sampler` only it uses** — because ReShade allocates every
  declared target, so a target left outside its guard is memory paid for a feature that is compiled out.
  Values tuned by watching stay live sliders; adding a fourth definition for one of those would cost a
  recompile per adjustment for no elision worth having.
- `AutoMaskTargetFPS` is the one further definition, a setup number rather than a tuning one. The
  frame-count settings are durations, so their `ui_max` caps are seconds × `AutoMaskTargetFPS` (rise
  16.67 s, fall 1.67 s, grace 2 s, move memory 10 s) and grow with the frame rate a user plays at, which
  no literal could. It is not watched and not elided — a runtime `frametime` uniform cannot appear in an
  annotation, which is why it is a definition at all. The drift horizon is a duration of the other kind:
  its slider is already in seconds (cap a literal 10) and the frame count its average remembers is
  derived from it, so `AutoMaskTargetFPS` multiplies it inside the shader. It is declared inside the
  compute guard beside the other uniforms, because the pixel path has no pass that would read it and a
  setting that does nothing is worse than an absent one.
- Update `README.md` in the same conversational, non-programmer voice whenever a user-facing behaviour
  changes.

## Verification

Nothing here is testable automatically in the true sense, so verification is a review pass plus an
offline compile check:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every shader with `fxc` and reports
  instruction counts and opcode histograms. Keep the `tools/.work/` output out of commits.
- The check compiles eight variants — `AutoMaskAntiBloom` and `AutoMaskDiagnostics` each at 0 and 1,
  crossed with `AutoMaskCompute` at 0 and 1, set from the prelude exactly as a ReShade-level definition
  would be — because a `#if` guard can drop a pass from a technique body, and only compiling every
  combination shows that it did. The compute switch is crossed with the other two rather than added
  beside them because it swaps a pass for one of another type instead of removing it, so a guard that
  drops or misbinds a pass has to show at both settings. `--pass-list` prints the wiring, `--opcodes` the
  histogram per shader, `--hashes` the bytecode sha256 of each entry point — which is how the
  `AutoMaskCompute=0` variants are shown to compile byte-for-byte as before a change.
- An entry point is compiled at the profile its shape calls for: `ps_5_0` for a `SV_Target` function,
  `cs_5_0` for a compute one, so a compute pass cannot slip through unread or be compiled as a pixel
  shader. A pass is read for `ComputeShader` as well as `PixelShader`, and a compute pass declaring fewer
  than two `DispatchSize`s exits non-zero the way ReShade rejects it (its error 3012).
- **It must fail loudly on missing data.** An earlier version of the companion tool reported a clean pass
  while emitting no bytecode at all, because a missing hash compares equal to another missing hash. Five
  cases must keep exiting non-zero, each exercised by hand before committing a change here: an empty
  `Shaders/`; a technique whose passes the parser cannot find (cross-checked against the `pass` keyword
  count, so a pattern miss cannot look like a technique with fewer passes); a technique binding a shader
  that does not exist; a shader whose syntax is broken; and a compute pass missing one of its dispatch
  sizes.
- **A spelling the tool rewrites cannot be checked by compiling.** Storage declarations are translated to
  `RWTexture*` before fxc sees them, so a keyword ReShade would reject compiles in the check regardless —
  which is the one failure mode the check cannot see on its own. That already bit: a lowercase `storage2d`
  passed every variant and failed in ReShade with a bare X3000 pointing at the line rather than the case,
  and because the bad declaration dropped its target, two further X3004 errors followed from it. The
  dialect keywords are therefore pinned to ReShade's own lexer — `storage`, `storage1D`, `storage2D`,
  `storage3D` with a **capital** dimension letter, and those four only — and a near-miss is a loud
  failure rather than something to rewrite. Exercise it by hand with the file changed back to the
  lowercase spelling before committing any change to the translation.
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
  the opcode histogram so a parsing miss cannot look like a pass.
- ReShade's compute dialect is not HLSL: `storage2D`/`storage1D`/`storage3D` objects, the group and
  memory barriers, and the `atomic*` family are its own surface vocabulary, and ReShade's own codegen
  translates them (`RWTexture*`, `GroupMemoryBarrierWithGroupSync()`, `Interlocked*`) before handing the
  result to a shader compiler. The check compiles the source itself, so it writes the same translation
  out in `strip_for_fxc`; without it no compute entry point could be compiled at all. The dimension
  letter is capital and those spellings are the only ones the lexer knows: a lowercased one is not a
  keyword, so it is guarded against rather than translated (see the loud-failure list above).
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
