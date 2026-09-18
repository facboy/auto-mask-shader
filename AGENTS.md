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
for the design history and the reasoning behind the decisions below. Credit for the concept and the
store/restore pattern belongs to Kaiser (UIDetectMulti) and Brussels1 (the original work).

Licensed MIT (see `LICENSE`).

## Repository layout

| Path | Role |
| --- | --- |
| `Shaders/AutoMask.fx` | The shader: uniforms, render targets, pixel shaders, two techniques. |
| `tools/verify_shaders.py` | Offline compile-and-cost check. The only automated verification there is. |
| `tools/pyproject.toml` | The `uv` project the check runs under. Deliberately inside `tools/` — this is a shader project, not a Python one. |
| `README.md` | End-user guide: placement order, how to tune, what it cannot do. |
| `LICENSE` | MIT, with the credit line for the concept and the store/restore pattern. |

There is **no `.fxh` companion header and there deliberately never will be**. A header exists to hold
authored data — pixel tables, coordinates, stored colours — and this shader has none. Every knob is a
slider in the ReShade panel. Putting configuration into a file the user edits and restarts would be a
regression in usability, so do not introduce one.

There is no build system and no CI beyond the offline check, by design. Never vendor ReShade's own
headers.

## Core model

Two techniques, and both placements are load-bearing:

1. `AutoMask` — must be **first** in the effect list. It has to see the untouched back buffer, both
   for the stability comparison and for the frame it stores.
2. `AutoMask_Restore` — must be **last**. It puts the masked pixels back on top after the user's
   other effects have run.

This shader and `UIDetectMulti` are **alternatives, not companions**: both want those same two slots,
so loading both means one of them reads a frame the other has already written into. That is left to
the user to avoid rather than policed at runtime, and the README says so plainly.

The mask itself is one full-resolution HUD/non-HUD value per pixel, not one per element. Conflating
health with inventory is accepted by design; per-element identity is not attempted.

One frame-wide exception sits above the per-pixel verdict. The same frame-to-frame difference is
averaged over the screen, and once it says nothing much is moving the accumulator is **held** — its
whole state carried over, no rise and no fall — so a quiet interior or a static backdrop cannot keep
accumulating while the world view is not being drawn. It holds only after a short settle, so a panel
that opens into an already-paused scene is still scanned before the map locks. It pauses the
accumulator; it never changes whether a pixel is HUD, and per-pixel stability is still the only
verdict. What it is *not*: a camera-motion gate, and not a freeze that overwrites the map.

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
   also applies the stillness gate, reading the statistic the previous frame left behind.
2. The two sub-resolution passes that average the still flag — after the accumulate, since their only
   input is what it just wrote, and read on the next frame.
3. `PS_Copy`, `PS_Dilate` — the ping-pong back-edge and the boundary close, also before the store.
4. `PS_Store`, keeping the mapped pixels.
5. `PS_StoreFrame`, copying the untouched frame into the history target for the next frame.
6. The diagnostics overlay, last, and only when diagnostics are on.

## Editing conventions

- HLSL comments are **short and sparse** (`//UINr 13`). Do not add tutorial narration to the shader.
- LF line endings.
- A uniform annotation must match the declared type: `__UNIFORM_SLIDER_FLOAT1`/`_FLOAT3` for floats,
  `__UNIFORM_SLIDER_BOOL1` for bools. A mismatch is a silent ReShade UI bug.
- `BUFFER_WIDTH`/`BUFFER_HEIGHT` are injected by ReShade at runtime, not defined here. Anything
  buffer-relative stays correct across resolutions; absolute pixel numbers do not.
- Update `README.md` in the same conversational, non-programmer voice whenever a user-facing
  behaviour changes.

## Verification

Nothing here is testable automatically in the true sense, so verification is a review pass plus an
offline compile check:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every pixel shader with `fxc` and
  reports instruction counts and opcode histograms. Keep the `tools/.work/` output out of commits.
- **It must fail loudly on missing data.** An earlier version of the companion tool reported a clean
  pass while emitting no bytecode at all, because a missing hash compares equal to another missing
  hash. If you change the check, keep that property.
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
  standing still somewhere with fire or water in view. The one that settles the stillness gate's
  settle window is a menu opened in a scene the game has already paused. Reviewing a screen capture
  is the next best thing.

## What this shader cannot do

These are inherent to the signal, not tuning problems, and belong in the README rather than being
discovered:

- **Semi-transparent UI is never protected.** Where the world shows through, the pixel is not
  stable and never accumulates. Those elements stay with `UIDetectMulti`, which uses authored masks.
- **A quiet interior with no ambient animation can accumulate.** Standing still facing a wall or a
  closed door, nothing in frame moving, means the wall holds still. The stillness gate is the answer —
  once the settle has passed the map is held and the wall stops accumulating. What remains is the
  settle window itself, and a panel that opens over an already-paused world: long enough settle for
  the panel to be scanned, short enough not to hand a quiet room a free run of accumulation. Nothing
  separates those two cases, because a paused world and a quiet room look identical to this shader,
  which is why the overlay shows the gate holding rather than leaving it to be inferred.
- **HUD that animates more than briefly** needs the hold to bridge it. That makes `UIMaskForget` the
  most important slider rather than a nicety.

## Repository rules

- Do not start work that adds or modifies files while `git status` shows uncommitted changes; stop
  and report the dirty state instead.
- Do not commit unless the user asks for it. When committing, append the co-author trailer:
  `--trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Write commit subjects in the imperative mood, lowercase after the prefix, matching the convention
  used in the companion repo (e.g. `add rise and hold timing to the accumulator`).
