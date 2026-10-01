# AGENTS.md

Guidance for AI agents working in this repository: the index of rules every task needs. The reasoning
behind them lives in `docs/`, split by subject so a change loads only the part it touches; read that
pointer.

## What this project is

A standalone ReShade shader that **builds its own UI mask** by watching what holds still: a pixel the
game redraws in place frame after frame is HUD, a pixel the world animates is not. A menu's region
holds still and lands in the mask; closed, that region shows moving world and drops out. It replaces
hand-authored mask images — no coordinates to pick, no mask PNG to paint, no per-element configuration.
The mask answers one question per pixel: **is this HUD or not**.

Designed against Kaiser's `UIDetectMulti` pack, a *separate* project on disk (`/mnt/d/git/Reshade-Shaders`)
sharing no code; `docs/review.md` there holds the design history. Credit for the concept, the
store/restore pattern and the anti-bloom suppression belongs to Kaiser (UIDetectMulti) and Brussels1
(the original work). MIT (see `LICENSE`).

## Repository layout

| Path | Role |
| --- | --- |
| `Shaders/AutoMask.fx` | The shader: uniforms, render targets, pixel shaders, two techniques. |
| `Shaders/AutoMask.fxh` | The shared verdict arithmetic both accumulators call, and nothing else. A **code** header — see below. |
| `tools/verify_shaders.py` | Offline compile-and-cost check, and the prose-budget check for the docs. |
| `tools/pyproject.toml` | The `uv` project the check runs under. Deliberately inside `tools/` — this is a shader project, not a Python one. |
| `README.md` | End-user guide: placement order, how to tune, what it cannot do. |
| `LICENSE` | MIT, with the credit line for the concept, the store/restore pattern and the anti-bloom pass. |
| `docs/core-model.md` | How the mask is decided, in full: the verdict, the hold, the move memory, the clip exclusion, the arithmetic. |
| `docs/compute-path.md` | What `AutoMaskCompute=1` changes, in full: the compute passes, histogram, auto-deadband, drift channel, pass order. |
| `docs/verification.md` | The compile check's design, the toolchain, and the end-to-end scenarios that need a game. |
| `docs/editing-conventions.md` | The reasoning behind the prose-budget, annotation, target-FPS and reset-step rules below. |
| `docs/definitions.md` | Glossary of the vocabulary reused across the shader, the README and the docs. |
| `docs/review.md`, `docs/drift-snap-review.md`, `docs/optical-flow.md` | Recorded design history and closed investigations. |
| `docs/ui-isolation-options.md` | Options for reading interface as a region rather than per pixel, none of them scoped. What §6's instrument decides between. |
| `docs/refactor-candidates.md` | The folds that landed in the shader and the check, what was considered and left, and what is deliberately not a candidate. |
| `docs/performance.md` | Where the frame's cost sits, read off the compiled bytecode, and the closing-loop, back-edge and centre-step savings it justified. |

The one companion header is **`Shaders/AutoMask.fxh`, and it holds code and nothing else**: the shared
arithmetic both accumulators call, no uniform, `texture`, `sampler` or technique. A header of **authored
data** — pixel tables, coordinates, stored colours, or a tuning value a user edits and restarts — is what
this repo refuses, because every tuning value here is a live slider and configuration in a file would be
a usability regression. The code header is not that: including it changes nothing about the panel, the
targets or the bytecode, and it exists so the two accumulators cannot drift apart. It is included **after
this file's uniforms and targets**, because the dialect has no forward declaration, and the check copies
it into `tools/.work/` and holds it to the comment budget with the shader. **Both files must be dropped
into the ReShade folder together**, which `README.md` says.

There is no build system and no CI beyond the offline check, by design. Never vendor ReShade's headers.

## Core model, in brief

The mask is one full-resolution HUD/non-HUD value per pixel, not one per element; per-element identity is
not attempted. Two techniques, and both placements are load-bearing:

1. `AutoMask` — must be **first** in the effect list, to see the untouched back buffer for the stability
   comparison and the frame it stores. Its last pass blacks the masked pixels in the live frame, so a
   bloom pass downstream has no UI to pick up.
2. `AutoMask_Restore` — must be **last**, putting the masked pixels back on top after the user's other
   effects have run. It is the only pass after which nothing else writes the frame, which is why the
   diagnostics corner marker is drawn there rather than in the overlay.

This shader and `UIDetectMulti` are **alternatives, not companions**: both want those same two slots, so
loading both means one reads a frame the other has already written into. The user avoids that rather than
the shader policing it at runtime, and `README.md` covers it for them.

Every rule below follows from a decision reasoned in `docs/core-model.md`; read it before
changing the verdict, the hold, the move memory, the clip exclusion or the accumulator's arithmetic:

- **Coverage, not magnitude**, is the statistic: the share of each block whose pixels changed at all.
- **The frame sliders are durations.** The verdict step is fixed at 0.5 and the frame count is converted
  into a step per frame, so a slider position is the duration it names. The conversion keeps a hair above
  the exact share (0.504, not 0.5) so the half-precision accumulator crosses the step on the frame it
  should. Keep `AutoMaskFall`'s frames at or under `AutoMaskRise`'s, or the mask lingers over moving
  scenery.
- **`AutoMaskMotion` is the premise, not a refinement.** Stillness alone proves nothing, so a still pixel
  is taken for interface only while the world around it animates; its default is not 0. The share is over
  the pixels that **could** change, not every pixel: a pinned one is counted out, so a black or letterboxed
  region cannot hold the reading below the threshold however much is moving elsewhere. That covers pixels
  at a rail, not merely dark ones — a static black backdrop is not pinned and still counts, so a very dark
  view can still put the threshold out of reach.
- **`AutoMaskEps` counts whole levels out of 255** and decides one thing only: whether the frame moved a
  pixel. What a change *costs* is `AutoMaskFall` and `AutoMaskMoveMemory`'s business. Its minimum is 1;
  the deadband is `max(ceil(AutoMaskEps), 1)`.
- **The comparison subtracts level counts, not quantized colours** (`round(now * 255.0)` against
  `round(before * 255.0)`), and the clip exclusion is checked after that on the same grid.
- **The hold is one-sided:** while the world is not being drawn a still pixel is carried over untouched —
  no rise, no fall, no heal — while a moving pixel still falls. A stopped scene can only lose mask.
- **The move memory is a duration** of still frames, negative in the accumulator's confidence, and 0
  restores the old behaviour exactly.
- **The verdict carries no spatial term of its own.** Two things add one. **Admission is the term upstream
  of the verdict:** a pixel no claimed neighbour touches earns at `AUTOMASK_SEED_SHARE` of the rise, so a
  region can only start from a pixel still for twice the rise and a lone speck cannot seed one — the
  cheapest spatial prior, four taps against the verdict the accumulator already holds. `AutoMaskNeighbour`
  gates it as a live checkbox inside `AutoMask`, because it owns no pass, shader or target; it is off by
  default, so the mask is the verdict exactly as before. **The isolation gate is the term downstream:** a
  masked pixel is kept only while enough still pixels surround it, counted on the verdict rather than on
  colour, over its own isolation radius. It is the only thing that removes a pixel the verdict claimed, so
  it ships off too.

`docs/compute-path.md` holds what `AutoMaskCompute=1` swaps in — the exact motion count, the change-size
histogram and auto-deadband, the `RGBA32F` drift channel, and the pass order inside `AutoMask`. The drift
average is held within `AUTOMASK_DRIFT_LAG` deadbands of the frame — the reach divided onto the value's
own scale, since `now` is normalized and the bound is a level count — and the ramp that reads it runs from
the deadband to that same bound: a ramp can only say how far the frame has got from its average, so an
average allowed to creep further behind says nothing extra — while an unbounded one is left tens of levels
behind by a camera pan and takes a horizon to walk back, which is what keeps the whole screen reading as
being drawn after the view has stopped. The measured step is committed only after
`AUTOMASK_STEP_DWELL` frames answer the same level, because the walk is fed by motion measured against
that same step: a mover covering more than the floor holds it above the mover's own size, and the red
graded against it goes off screen-wide.

## Editing conventions

- HLSL comments are **short and sparse** (`//UINr 13`). Do not add tutorial narration to the shader. The
  one exception is the ruled credit block at the top of `Shaders/AutoMask.fx` — title, licence and the
  credit to Kaiser's `UIDetectMulti` and Brussels1 — which follows the companion pack's style. Do not add
  per-function attribution below it.
- The same prose budget covers the HLSL comments and the docs here; `docs/editing-conventions.md` holds
  its reasoning and the worked example. `uv run tools/verify_shaders.py check-docs` refuses the framing
  phrases and a `//` block longer than `COMMENT_BLOCK_MAX` (4 lines), and `--list` prints both; a line or
  block that genuinely needs the room carries `prose-ok`. The credit block's `////...` fence is exempt.
- LF line endings.
- A uniform annotation must match the declared type: `__UNIFORM_SLIDER_FLOAT1`/`_FLOAT3` for floats,
  `__UNIFORM_SLIDER_BOOL1` for bools. A mismatch is a silent ReShade UI bug. The widget family is chosen
  by what the value means: the duration settings (`AutoMaskRise`, `AutoMaskFall`, `AutoMaskForget`,
  `AutoMaskMoveMemory`, and the compute path's `AutoMaskDrift`) use `__UNIFORM_DRAG_FLOAT1`; a share uses
  the typed field `__UNIFORM_INPUT_FLOAT1` (`AutoMaskDensity`, which is `ui_step = 1.0` so it stays whole);
  everything else is a slider. See `docs/editing-conventions.md`.
- ReShade can only hide a whole **category** of settings at a time, via `ui_category_toggle` on the
  boolean that *opens* it, and it never hides that boolean itself. So a gated setting belongs in its own
  category with the gate first — never inside `AutoMask`, where unticking would hide every other slider.
  There is no per-uniform visibility annotation, and a category is a **contiguous run** of uniforms: the
  same name used again further down the list draws a second heading. A category can also carry no gate at
  all, purely to name a group — `Frame timing` does that for the four frame-count durations, and `Is the
  world being drawn?` for the motion threshold and the depth readings under it, none of which is ever
  hidden. See `docs/editing-conventions.md`.
- The **accumulator's state machine is written once**, in `Shaders/AutoMask.fxh`. `PS_Accum` and
  `CS_Accum` differ only in how a texture is sampled and in the drift channel the compute path alone
  carries, so the parts that sample nothing — the premise, the decay step, the published-mask read and
  the values they read (the deadband, the pinned-colour count, the frame rate) — are those shared
  functions. Every helper takes what it needs **already sampled**, or the two paths' sampling forms
  would move onto each other's, and the drift terms stay behind `AutoMaskCompute` in the `.fx`. The
  include sits after the uniforms and targets the helpers read, since the dialect has no forward
  declaration. See `docs/refactor-candidates.md`.
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
  `AutoMaskDiagnostics`, `AutoMaskCompute` and `AutoMaskDepthMotion`. Each is `#ifndef`-guarded with
  `// [0 or 1]` annotation comments, as the pack does it, and each guards everything that feature owns —
  its **pass and technique entry, its shader, and any `texture`/`sampler` only it uses** — because ReShade
  allocates every declared target, so a target left outside its guard is memory paid for a feature that is
  compiled out. Values tuned by watching stay live sliders; adding a definition for one of those would
  cost a recompile per adjustment for no elision worth having. `AutoMaskTargetFPS` is a further
  definition but not a structural switch — it elides nothing, and is named below.
- **`AutoMaskDepthMotion` is the depth premise, not a depth mask.** The overlay writes no depth — it takes
  the scene's — so depth describes the world and never the interface, and a per-pixel depth verdict would
  veto the whole HUD whenever the camera moved. What depth *does* give is the world-drawn premise, the one
  reading a large open panel hides from itself, and that is all this switch feeds: a pixel whose depth
  changed joins the changed count the reduce publishes, on its own step (`AutoMaskDepthEps`, a distance in
  metres — the linearized depth is a distance over the far plane, which ReShade supplies, so the change
  converts back to metres and is uniform across the screen). It can only *add* to that share, never remove.
  A depth buffer
  that is not bound reads as a constant on both sides of the comparison, so the difference is zero and the
  premise is the picture's own exactly — which is why the online-game case degrades to the old behaviour
  rather than needing a fallback path. It owns one `R32F` target and one full-resolution store pass, both
  inside the guard; that target is read by the accumulator and written by a later store pass, so no pass
  reads what it writes, and it is not the ping-pong the accumulator itself needs. `AutoMaskDepthOnly`, a
  live checkbox beside it inside the guard, is the measurement §5.10 of `docs/ui-isolation-options.md`
  asks for: it takes the world-drawn reading from the depth term alone rather than from depth added to the
  picture, so the premise reads viewpoint change instead of picture change. Together with the switch it
  draws the three states the two controls reach — picture alone (the switch off), both (on, this off) and
  depth alone (on, this on) — as a labelled choice rather than one the reader has to infer. It owns no
  pass, shader or target — one `max` in each accumulator — so it is a checkbox and not a definition, and
  with it on a depth-static scene reads as stopped, while no bound depth leaves the world never reading as
  drawn. See `docs/core-model.md` and `docs/verification.md`.
- The **isolation gate is gated by a live checkbox, not a fourth definition.** It owns no pass, shader or
  target of its own — it is a count and a branch inside the two closing passes — so a `#if` would buy a
  handful of instructions in one entry point while costing a recompile per toggle. `AutoMaskIsolated`
  instead opens `Isolated pixels` with `ui_category_toggle`, which is what makes the two settings below it
  live and hideable at once. A feature with a pass, a shader or a target to its name still gets a
  definition; a branch inside an existing pass does not.
- The **tile map is an instrument, not a filter**: `CS_Tile` reads the picture as a fixed 16×16 grid,
  reduces it to a component count, an enclosed share and the wide-change patches, and nothing in the mask
  reads any of it. Four things decide whether it means anything, and each was got wrong once: a cell is
  interface when the mask **touches** it rather than fills it (a footprint reading; a share made thin UI
  read black), **wide is read off the accumulator's own graded motion** rather than a raw difference (the
  map's own test called a held UI edge red), and the enclosure growth is **conducted by every non-mask
  cell** with only world cells counted (letting the mask absorb it let a pan's wide cells read the screen
  as enclosed). The fourth is the premise: **an arrival candidate exists only while the world is not
  being drawn**, read off the share the verdict's own gate uses, because a camera pan is a screen-wide
  drawing and reading it as arrivals turned every cell of the grid red. The two *count* readings are
  stored against `AUTOMASK_TILE_COUNT_MAX`, not as a share of the grid: a count of a few regions against
  256 cells would move a bar by one percent of its length. It rides both the compute and diagnostics
  guards, since it exists only to be watched, and it was the first thing built of
  `docs/ui-isolation-options.md` §6's readings, because the other two needed it. **It outlived them**:
  the options it was built to decide (§5.2's fill, §5.4's arrivals and §5.8's ratio) are all closed, and
  it stays as the tuning instrument for the two spatial rules that shipped — the isolation gate and the
  admission seed — which are region questions no per-pixel view can show. Honest and free at rest, which
  is the test that keeps it: absent from every variant but the one where the overlay and the compute path
  are both on.
- The **confidence view is the same kind of instrument as the tile map, and deliberately not on it.**
  `UIDebugConfidence` reads the accumulator's own confidence instead of deciding it, so the mass sitting
  just under the 0.5 line — what §5.5 of `docs/ui-isolation-options.md` would have weighed rather than
  counted — is visible. It owns no pass, target or definition and rides the channel the pixel path
  already carried the verdict in, so unlike the tile view it draws on **both** paths: it answers a
  per-pixel question, which no map does, and §5.5 rides no map for the same reason. It draws **two flat
  colours rather than a ramp** — cyan already claimed, magenta earning but short of the line — and leaves
  everything at or below zero plain, since a move's debt is not evidence; a grade would ask shades to be
  compared, which is the read that went wrong. Read in a game it found a thin band over UI interiors and
  a much larger one over dim scenery, which **closed §5.5.1**: charge over dim world is corroboration a
  weighted gate would keep *more* of, and it comes from the comparison crediting scenery that drifts too
  slowly to change a pixel between two frames — sub-resolution drift, not a forgiving deadband. The same
  finding closed §5.5.2, which would charge exactly those bit-still pixels faster, so both halves are shut.
- **The isolation gate follows admission's rule** rather than getting a definition of its own: it owns
  no pass, shader or target, its counts riding in the two channels `texAutoDilate` leaves unused on the
  two closing passes. `AutoMaskIsolated` opens `Isolated pixels` with `ui_category_toggle`, and the test it
  gates is a share of the box (`AutoMaskDensity`), the pixel itself counted, so one number means the same
  thing at every radius — **or** one line through the pixel (`max(reach + 1, AUTOMASK_AXIS_MIN)`), which is
  what keeps a one-pixel stroke the box share would erode. The line count is the horizontal pass's `.g` and
  the centre verdict it publishes in `.b`, read down the column and the two diagonals: the column and the
  box share ride the vertical taps the closing already takes, while the two diagonals are its own samples,
  so the door costs no pass, target or uniform and is both taken and sampled only while the gate is on.
  Both doors sit on the verdict, not on colour. The box share stays a first door, so the gate can only
  rescue a pixel it would have dropped and never newly drops one.
- The **isolation radius is its own setting** (`AutoMaskIsolation`), not the closing radius: shape and
  evidence are different questions, and tying them would move what `AutoMaskDensity` means whenever the
  closing is retuned. The density is a share rather than a count, so it means one thing at every radius; a
  count would need a cap at the smallest box's area. The radius rides the closing's own loop, so it adds
  no pass or target and caps at `AUTOMASK_DILATE_MAX` with it — though its width does set how far that
  loop runs; read as 1 at the bottom, so the gate cannot silently switch off. `AutoMaskDensity` is an
  `__UNIFORM_INPUT_FLOAT1` — a typed field rather than a track, because it names a share. `AutoMaskDepthEps`
  names a distance in metres, small enough that a walk's fraction of a metre a frame sits mid-range and the
  far field's noise sits under the foot; it is also a `__UNIFORM_DRAG_FLOAT1`, since a stepped track cannot
  cover 0.001 to 2 and be usable at either end.
- `AutoMaskTargetFPS` is the one further definition, a setup number rather than a tuning one: it multiplies
  seconds into frames for the `ui_max` caps and for the drift horizon. See `docs/editing-conventions.md`.
- The reset's wide step is `max(deadband, 8.0)` rather than a bare literal, so it can never collapse back
  into the verdict deadband if either cap is ever raised; it is deliberately not a slider. See
  `docs/editing-conventions.md`.
- Update `README.md` in the same conversational, non-programmer voice whenever a user-facing behaviour
  changes.

## Verification

Nothing here is automatically testable, so verification is a review pass plus an offline compile check.
`docs/verification.md` is the full account; the essentials:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every shader with `fxc` and reports
  instruction counts and opcode histograms. `--pass-list` prints the wiring, `--opcodes` the histogram
  per shader, `--hashes` the bytecode sha256 of each entry point. Keep the `tools/.work/` output out of
  commits. `pyproject.toml` lives in `tools/` so `uv run` finds it from the repo root.
- The check compiles sixteen variants — `AutoMaskAntiBloom` and `AutoMaskDiagnostics` each at 0 and 1,
  crossed with `AutoMaskCompute` and `AutoMaskDepthMotion` at 0 and 1 — because a `#if` guard can drop a
  pass from a technique body, and only compiling every combination shows that it did.
- **A warning is a failure, not a note.** ReShade prints every warning its compile emits into the log the
  user reads at load, so `check` reports one as `WARN` and exits non-zero on it. The single filtered
  exception is `X3579`, the harness's own artefact.
- **It must fail loudly on missing data.** Ten cases must keep exiting non-zero — an empty `Shaders/`,
  an unfindable technique pass list, a technique binding a missing shader, broken shader syntax, a
  compute pass missing a `DispatchSize`, two variants under one name, a call to an intrinsic `fxc` has
  but ReShade does not, an identifier ReShade's lexer reserves though HLSL does not, the header
  `AutoMask.fx` includes deleted from `Shaders/`, and a render target a pass declares that the pass
  reading does not carry.
  `docs/verification.md` names each and the construct that exercises it.
- **Some spellings cannot be checked by compiling**, because the tool rewrites them before `fxc` sees
  them: the storage keywords, the `tex2Dfetch`/`tex2Dstore` intrinsics, and the bracket form they
  translate to. Those are pinned by the tool instead, and `fmod` is refused outright. Do not "tidy" any
  of these guards back. The same blind spot covers a dialect construct the tool does *not* rewrite but
  `fxc` accepts anyway — a `groupshared` array indexed dynamically, say — so a new one is verified
  against ReShade's own parser and codegen rather than inferred from a passing compile.
  `docs/verification.md` is the full list.
- **Real end-to-end testing means loading both techniques in ReShade in a game**, which an agent cannot
  do. State that clearly instead of claiming the change is verified, and name the scenarios that need
  eyes on them — `docs/verification.md` lists them per feature.

## What this shader cannot do

These are inherent to the signal rather than tuning problems, and they belong in `README.md`:

- Semi-transparent UI is never protected.
- A quiet interior with no ambient animation can accumulate.
- A still patch of world beside a large animating one is credited as interface: the premise is a single
  screen-wide share, so any region large enough to clear `AutoMaskMotion` marks the world drawn and every
  still pixel is then claimed, including world that never moved (`docs/ui-isolation-options.md` §5.10).
- Scenery that drifts too slowly to change a pixel between two frames is credited as interface, in the
  dim regions where the same movement changes a level least.
- Something animating in a stopped scene is given up.
- Bloom can still find an edge at the HUD contour.
- A HUD that flickers without moving is given up by the drift channel.
- HUD that animates more than briefly needs the hold to bridge it, which makes `AutoMaskForget` the most
  important slider.
- Interface thinner than the isolation filter's neighbourhood is dropped by that filter, which is why it
  ships off.

The full reasoning for each — including why the move memory and the drift channel cannot help with the
quiet interior, and why the slow-drift case defeats both the premise and the move memory until the memory
is long enough to outlast the drift's level crossings — is in `docs/core-model.md`.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop and
  report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the convention used
  in the companion repo (e.g. `add rise and hold timing to the accumulator`).
