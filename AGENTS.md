# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

A standalone ReShade shader that **builds its own UI mask** by watching what holds still. A pixel the
game keeps drawing in the same place, frame after frame, is HUD; a pixel the world is animating is
not. When a menu is open its whole region holds still and lands in the mask; when it is closed that
region shows moving world and drops out.

It is a replacement for hand-authoring mask images. There are no pixel coordinates to pick, no mask
PNG to paint and no per-element configuration — the mask answers one question per pixel, **is this
HUD or not**.

The design was worked out against Kaiser's `UIDetectMulti` pack, which is a *separate* project on
disk (`/mnt/d/git/Reshade-Shaders`) and shares no code with this one. Read `docs/review.md` there
for the design history and the reasoning behind the decisions below. Credit for the concept, the
store/restore pattern and the anti-bloom suppression belongs to Kaiser (UIDetectMulti) and Brussels1
(the original work).

Licensed MIT (see `LICENSE`).

## Repository layout

| Path | Role |
| --- | --- |
| `Shaders/AutoMask.fx` | The shader: uniforms, render targets, pixel shaders, two techniques. |
| `tools/verify_shaders.py` | Offline compile-and-cost check. The only automated verification there is. |
| `tools/pyproject.toml` | The `uv` project the check runs under. Deliberately inside `tools/` — this is a shader project, not a Python one. |
| `README.md` | End-user guide: placement order, how to tune, what it cannot do. |
| `LICENSE` | MIT, with the credit line for the concept, the store/restore pattern and the anti-bloom pass. |

There is **no `.fxh` companion header and there deliberately never will be**. A header exists to hold
authored data — pixel tables, coordinates, stored colours — and this shader has none. Every tuning
value is a live slider in the ReShade panel, and the only preprocessor definitions are the two
structural switches (`UIMaskAntiBloom`, `UIMaskDiagnostics`), which are there to elide a pass rather
than to hold data. Putting configuration into a file the user edits and restarts would be a regression
in usability, so do not introduce one.

There is no build system and no CI beyond the offline check, by design. Never vendor ReShade's own
headers.

## Core model

Two techniques, and both placements are load-bearing:

1. `AutoMask` — must be **first** in the effect list. It has to see the untouched back buffer, both
   for the stability comparison and for the frame it stores. Its last pass writes the masked pixels
   black into the live frame, so a bloom pass downstream has no UI to pick up.
2. `AutoMask_Restore` — must be **last**. It puts the masked pixels back on top after the user's
   other effects have run, and it is the only pass after which nothing else writes the frame — which
   is why the diagnostics corner marker is drawn there rather than in the overlay.

This shader and `UIDetectMulti` are **alternatives, not companions**: both want those same two slots,
so loading both means one of them reads a frame the other has already written into. That is left to
the user to avoid rather than policed at runtime, and the README says so plainly.

The mask itself is one full-resolution HUD/non-HUD value per pixel, not one per element. Conflating
health with inventory is accepted by design; per-element identity is not attempted.

Above the per-pixel verdict sits the question that gives it meaning: **is the world being drawn at
all?** This is the premise, not a safety net under it. Stillness on its own proves nothing — a wall
holds still too — so a pixel that holds still is only taken for interface while the world around it can
be seen animating. `UIMaskMotion` is that share of the screen, and its default is not 0: at 0 the map
held on every frame and the mask never formed.

**The statistic is coverage, not magnitude.** What the question needs answered is "is the game
re-drawing the view", so `PS_Motion` counts the share of each block that changed at all, thresholding
the graded magnitude just above zero (a still pixel scores exactly zero, so the flag is recovered
from the same channel). Averaging the magnitude instead let one small bright object in fast
motion declare the whole view live — the opposite of treating the screen as mostly backdrop.
`UIMaskEps` is counted in whole levels out of 255, because that is the only unit the channels have —
the comparison is against an 8-bit history, so the slider steps by whole levels and a fractional value
is a position that cannot exist. Its minimum is 1 rather than 0 for the same reason: one level is the
smallest movement there is, so that is where detection is most sensitive, and a 0 would have been a
position nothing could sit below. The old "0 means off" kept the motion channel, the debt and the overlay
alive while the mask never formed, which is what made 0 look more sensitive than the positions above it.
It decides one thing only, whether the frame moved a pixel; what a change then *costs* the mask is a
separate slider, and the two must not be conflated — the reading the user watches in the overlay is the
same channel the verdict comes from, but the cost is banked against the verdict, not the reading. The two
verdicts are complements of one number rather than two tests that happen to meet: the deadband is read as
whole levels, `max(ceil(UIMaskEps), 1)`, a pixel is still below it and moving at or above it, and the ramp
runs from a level under the deadband to four times it, keeping the same offset under at its ceiling. Foot
and ceiling sit a full level under so that, at the smallest setting, any change at all is seen — the old
ramp footed half a level up and hid every sub-level change, which is what made 0 look more sensitive than
1 — while the setting's own level reads only a quarter of full strength, so the integer levels on either
side of the deadband stay the boundary rather than the deadband itself.

On the still side of the threshold the reading becomes a **hold**, and it is one-sided: while the world
is not being drawn a still pixel is carried over untouched — no rise, no fall, no heal — and a moving
pixel still falls. So a stopped scene can only ever lose mask, never gain it. There are no windows over
it: stillness simply cannot be credited as interface while the view is not being redrawn, because a
stopped world cannot tell a held HUD from its own backdrop. The two sliders that used to express those
windows (`UIMaskTrust`, `UIMaskSettle`) and the still-frame counter that drove them are gone; the cost
is the panel that opens by itself into an already-paused scene, which is caught only if its arrival
lifts the screen-wide reading over `UIMaskMotion`.

Holding rather than adding is what closes the failure the freeze used to have. Because a still frame
used to repay move debt whichever way the threshold went, a camera pan that left the whole backdrop in
debt cleared in lockstep: ~`UIMaskMoveMemory` frames after the motion stopped, the entire screen
crossed into the mask at once. Now the heal is part of crediting stillness, so it stops with the rest of
it — a stopped world repays nothing, and the backdrop stays wherever the pan left it.

Stillness is only a hint, though — the world holds still too — and motion is proof, so the per-pixel
signal is trusted asymmetrically. A change that lasts longer than the hold is **remembered**: it is
what the game re-rendering from a new viewpoint looks like, and no panel is drawn that way. The memory
lives in the sign of the accumulator's confidence, negative and clamped to the deepest a single move
can reach, and a still frame pays it back one frame's worth at a time — so the two ends of the shader
run on their own timescales: ~2 still frames to protect (fast, or a HUD is never captured) against
`UIMaskMoveMemory` still frames to recover from a move (slow, so it outlasts a camera movement).
`UIMaskMoveMemory` is therefore a duration rather than a confidence budget, and 0 restores the old
behaviour exactly. Movement that fits inside the hold is still bridged and never banked, which is what
keeps a draining bar or a scrolling list protected; movement past the hold costs the element its
protection until the debt clears. What a frame then costs is read from the verdict the deadband reached,
not from the graded magnitude: a frame is changing or it is not, and a changing one costs a frame's worth
of `UIMaskFall`, however small the change was — the RGB step decides only that the pixel moved, and what
the move costs is `UIMaskFall` and `UIMaskMoveMemory`'s business. The graded magnitude survives only in
the overlay, where red is the reading the user watches; banking against it would have made the deadband
tune the confidence, which is the conflation the slider's role forbids.

The heal is one frame's worth of `UIMaskFall` per still frame regardless of the slider, which is what
keeps the memory a duration the user can reason about rather than a confidence number they have to
convert. It runs as part of the same credit as the rise, so it happens while the world is drawn and
stops while it is not — paying down a debt is still crediting the pixel, and a stopped world is not
evidence. `UIMaskForget` is what protects a briefly-animating element from being banked in the first
place, so it and `UIMaskMoveMemory` are tuned against each other.

### The `.fx` constraints that shape the design

- **A render target cannot be read while it is written.** There are no atomics and no compute
  shaders in this dialect, so the accumulator has to **ping-pong**: read `A`, write `B`, then a copy
  pass brings `B` back to `A`.
- **There are no shared textures.** `ReShade.fxh` declares only `BackBufferTex` and `DepthBufferTex`,
  so another effect's stored frame is unreachable. This shader needs its own store target; it cannot
  borrow `UIDetectMulti`'s `texColorBeforeMulti`.

### Pass order inside `AutoMask`

Load-bearing, and follows from what each pass reads:

1. `PS_Accum` — builds the new confidence against the *previous* frame, **before** the history store. It
   also applies the world-drawn premise, reading the statistic the previous frame left behind.
2. The two sub-resolution passes that average the still flag into the share of the screen being
   redrawn — after the accumulate, since their only input is what it just wrote, and read on the next
   frame.
3. `PS_Copy`, `PS_Dilate` — the ping-pong back-edge and the boundary close, also before the store.
   `PS_Dilate` is one pass: a 2D max over a tiny fixed neighbourhood, stopping where the luma step
   read from `BackBuffer` exceeds `UIMaskEdge`. Reading the frame there is safe only because it is
   before every pass that writes it.
4. `PS_Store`, keeping the mapped pixels.
5. `PS_StoreFrame`, copying the untouched frame into the history target for the next frame.
6. `PS_AntiBloom` — black the masked pixels in the live frame so a bloom pass downstream has no UI to
   pick up. It comes after the store, which is what keeps the real UI for the restore pass; blacking
   earlier would bank the black instead.
7. The diagnostics overlay, last, and only when `UIMaskDiagnostics` is defined to 1 — a compile-time
   guard on the pass and the shader both, so with it off neither is compiled. It reads the accumulator
   directly rather than recomputing the difference, so it cannot report on itself instead of on the
   shader. Its channels are: red the graded motion, green the published mask (binary — a green pixel
   with no blue is the closing radius, not the accumulator), blue the accumulator's signed confidence
   packed around mid-blue so the memory is drawn rather than clamped away (`AutoDebug` is RGBA8 and a
   signed value would lose its lower half), and alpha the screen state in two steps. The state is read
   from the same statistic the gate itself reads, one frame behind the frame it describes, so it shows
   the state that will shortly govern the mask rather than a value recomputed a second way. Its
   strictness must match the gate's: `> UIMaskMotion`, not `step`, which is true at the threshold
   itself and would disagree on exactly the boundary frame.
   The corner marker is **not** drawn here: it is the one thing `AutoMask_Restore` adds, reading that
   alpha channel, because a block drawn inside `AutoMask` is repainted by the restore pass over any
   pixel the mask covers and treated as picture by every effect in between. Two states, two flat
   colours and no blending — magenta while the world is being drawn, yellow while it is not and the
   mask is being held — so the marker is a reading rather than part of the picture and cannot be tinted
   by anything else on screen.

## Editing conventions

- HLSL comments are **short and sparse** (`//UINr 13`). Do not add tutorial narration to the shader.
  The one exception is the ruled credit block at the top of `Shaders/AutoMask.fx` — title, licence and
  the credit to Kaiser's `UIDetectMulti` and Brussels1 — which follows the companion pack's style and
  is the only long comment in the file. Do not add per-function attribution below it.
- The credit lives in both `LICENSE` and that header block on purpose: someone copying just the `.fx`
  into their ReShade folder takes the attribution with it.
- LF line endings.
- A uniform annotation must match the declared type: `__UNIFORM_SLIDER_FLOAT1`/`_FLOAT3` for floats,
  `__UNIFORM_SLIDER_BOOL1` for bools. A mismatch is a silent ReShade UI bug.
- `BUFFER_WIDTH`/`BUFFER_HEIGHT` are injected by ReShade at runtime, not defined here. Anything
  buffer-relative stays correct across resolutions; absolute pixel numbers do not.
- Every pixel shader keeps `float4 pos : SV_Position` as its **first** parameter, even though no body
  reads it. `PostProcessVS` emits the position at `v0` and the UV at `v1`, and a pixel shader's
  `TEXCOORD` inputs are numbered from `v0` in declaration order — so the position is what pushes the UV
  onto `v1`. Drop it and the UV slides into the position's register; the debug layer reports a
  mismatched input and the draw still runs with the input undefined, so every pass samples one texel
  and the mask fills uniformly. `PS_MotionAvg` is the trap: its body has no `dcl_input_ps` at all and
  the parameter is still required, because linkage follows the *declared* signature.
- Two structural switches are preprocessor definitions, not sliders: `UIMaskAntiBloom` and
  `UIMaskDiagnostics`. Each is `#ifndef`-guarded with `// [0 or 1]` annotation comments, as the pack
  does it, and each guards everything that feature owns — its **pass and technique entry, its shader,
  and any `texture`/`sampler` only it uses** — the point being that ReShade allocates every declared
  target, so a target left outside its guard is memory paid for a feature that is compiled out. Values
  tuned by watching stay live sliders; adding a third definition for one of those would cost a
  recompile per adjustment for no elision worth having.
- Update `README.md` in the same conversational, non-programmer voice whenever a user-facing
  behaviour changes.

## Verification

Nothing here is testable automatically in the true sense, so verification is a review pass plus an
offline compile check:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every pixel shader with `fxc` and
  reports instruction counts and opcode histograms. Keep the `tools/.work/` output out of commits.
- The check compiles four variants — `UIMaskAntiBloom` and `UIMaskDiagnostics` each at 0 and 1, set
  from the prelude exactly as a ReShade-level definition would be — because a `#if` guard can drop a
  pass from a technique body, and only compiling every combination shows that it did. `--pass-list`
  prints the wiring, `--opcodes` the histogram per shader.
- **It must fail loudly on missing data.** An earlier version of the companion tool reported a clean
  pass while emitting no bytecode at all, because a missing hash compares equal to another missing
  hash. Four cases must keep exiting non-zero, and each is exercised by hand before committing a
  change here: an empty `Shaders/`; a technique whose passes the parser cannot find (cross-checked
  against the `pass` keyword count, so a pattern miss cannot look like a technique with fewer passes);
  a technique binding a shader that does not exist; and a shader whose syntax is broken.
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

  Compiling is `/Gec /T ps_5_0 /E <entry> /Fc <asm> /Fo <binary>`; the instruction count is read from
  `// Approximately N instruction slots used` in the assembly, and that count is cross-checked
  against the opcode histogram so a parsing miss cannot look like a pass.

- **Real end-to-end testing means loading both techniques in ReShade in a game**, which an agent
  cannot do. State that clearly instead of claiming the change is verified, and say which scenarios
  would need eyes on it: walking with the HUD up, a menu open, standing still in a quiet room, and
  standing still somewhere with fire or water in view. Reviewing a screen capture is the next best
  thing.
  The hold's two-sidedness is what to watch in a stopped scene, and it is two scenarios: a room with
  nothing animating in it must leave the mask empty rather than filling it — and must stay empty
  indefinitely, since a stopped world can no longer add at any point — while something still animating
  in a stopped scene (a spinner, a background loop) must fall out of the mask rather than sitting in
  it. The marker is worth checking for a second reason on any change that touches either technique: it
  is the only thing drawn after the restore, so if it is missing or tinted, the pass that draws it has
  been moved or overwritten rather than the mask being wrong. In a stopped scene it must read yellow,
  and in a drawn one magenta; the mask in a yellow frame may only shrink, so if it grows there the
  hold has stopped being one-sided.
  The move memory adds two scenarios of its own, and they are the pair the whole setting is balanced
  between: pan the camera across detailed scenery and then stop, with no interface in view — nothing
  the camera swept over should be grabbed as HUD, and with the world now stopped it must *stay* out for
  good rather than clearing itself `UIMaskMoveMemory` frames later, which is the screen-wide fill the
  one-sided hold exists to prevent; and then the same, with an animating element on screen the whole
  time — a draining bar or a scrolling list that moves for longer than `UIMaskForget` — which should
  lose its protection to the memory, and get it back once the animation stops and the world is drawn
  again. If both behave, the setting is doing what it says. Watching blue in the
  overlay is the cheap way to see the memory being spent, since it is the only view of it — and the
  corner marker tells you whether the blues you are looking at are current.

## What this shader cannot do

These are inherent to the signal, not tuning problems, and belong in the README rather than being
discovered:

- **Semi-transparent UI is never protected.** Where the world shows through, the pixel is not
  stable and never accumulates. Those elements stay with `UIDetectMulti`, which uses authored masks.
- **A quiet interior with no ambient animation can accumulate.** Standing still facing a wall or a
  closed door, nothing in frame moving, means the wall holds still. This used to be the design's
  weakest point — the gate existed to bound it and the overlay existed to show it being bounded — but
  the world-drawn premise closes it rather than bounding it: a scene that never goes live never hands
  out a rise at all, so there is nothing to gain and nothing to tune a window around. Since stillness
  also cannot repay move debt while the world is stopped, a scene that has stopped is a one-way door:
  whatever it held when it stopped, it keeps or loses.
  What remains is the deliberate cost: a panel that opens over an already-paused
  world, whose opening is the only evidence in frame, and which is therefore caught only if that
  opening lifts the screen-wide reading over `UIMaskMotion`. A small panel in a large still scene may
  not, and then nothing separates it from the backdrop, because a paused world and a quiet room look
  identical to this shader.
  The move memory does not help here and cannot, which is the sharper way to state the limit: a wall
  the player has been facing throughout never moved in the picture, so there is nothing to remember.
  It catches the wall that was *walked past* and then stopped in front of, which is the common case;
  it cannot catch the one that was never in motion to begin with.
- **Something animating in a stopped scene is given up.** A spinner, a flashing icon, a background
  loop: while the world is not being drawn those pixels are still changing, so they read as moving and
  fall out of the mask even though they may genuinely be interface. That is the price of the hold being
  one-sided, and it is the right side to be wrong on — protecting a moving pixel in a stopped scene
  means protecting the backdrop the moment it happens to be the thing that moved.
- **Bloom can still find an edge at the HUD contour.** Suppression removes the UI as a bloom source,
  but a hard black step against a bright scene is itself contrast. Neither this shader nor
  `UIDetectMulti` blurs that step: the pack's blend is `lerp(colorOrig, color, maskChan)`, exactly
  proportional to the mask, over unfiltered samplers and masks that were hard-edged in practice. The
  softness either comes from the mask (there) or from the map (here, via `UIMaskDilate` and the luma
  stop); nothing is added by the anti-bloom pass itself.
- **HUD that animates more than briefly** needs the hold to bridge it. That makes `UIMaskForget` the
  most important slider rather than a nicety, and it is now a hard boundary rather than a matter of
  degree: animation that fits inside the hold is bridged and never banked, while animation that
  outlasts it is taken for the world and costs the element its protection until `UIMaskMoveMemory`
  still frames have passed. The two sliders are tuned against each other — `UIMaskForget` must exceed
  the longest animation any real element performs.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop
  and report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the convention
  used in the companion repo (e.g. `add rise and hold timing to the accumulator`).
