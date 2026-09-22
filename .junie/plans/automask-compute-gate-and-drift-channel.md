---
sessionId: session-260920-133332-25iw
---

# Requirements

### Overview & Goals

Add a guarded compute-shader bundle to `Shaders/AutoMask.fx` behind a third structural preprocessor switch (`AutoMaskCompute`), delivering three things the pixel-shader path cannot:

1. **An exact world-drawn gate** — every pixel counted via `atomicAdd` with a `groupshared` per-group reduction, replacing the 16×16 coarse/avg approximation (`PS_Motion`/`PS_MotionAvg`, 1,024 taps standing in for ~3.7M pixels).
2. **The EMA drift channel** — a long-baseline color history that sees slow backdrop motion (the slow-skybox failure) that the frame-to-frame 8-bit comparison reads as exactly zero.
3. **A change-size histogram** — 256 `atomicAdd` bins that can auto-derive `AutoMaskEps` from the measured noise floor instead of manual tuning.

The compute path is a **replacement, not an addition**: roughly cost-neutral GPU time, one fewer full-res pass pair, statistic no longer lagging a stage behind. Off by default and effectively free when off (guarded-out shaders never compile, guarded-out targets never allocate).

**Pixel-shader-only EMA later: yes.** The drift logic is isolated in a small guarded block per this plan (one sample, one lerp, one max into the motion flag), sharing the uniforms and pass slots, so a later delivery can mirror it into `PS_Accum` behind its own guard for D3D9/D3D10 users — a small mechanical lift, not a redesign.

### Scope

**In scope**
- `AutoMaskCompute` preprocessor switch, same `#ifndef` + `// [0 or 1]` convention as `AutoMaskAntiBloom`/`AutoMaskDiagnostics`, guarding its shaders, pass entries, and compute-only targets.
- `CS_Accum`: the identical per-pixel state machine as `PS_Accum` plus the coverage/histogram atomics.
- `CS_Finish`: a 1×1-thread pass right after `CS_Accum` that writes the share statistic (float, readable by the existing pixel passes) and clears the counters/histogram each frame.
- EMA drift channel: packed in two new full-res RGBA16F ping-pong targets, one new duration slider (`AutoMaskDrift`, "Drift horizon (seconds)", drag widget per the frame-count convention).
- Histogram + auto-deadband: `AutoMaskAutoStep` bool toggle; on, the deadband is overridden per frame by the histogram's noise floor (`AutoMaskNoiseFloor` percent slider); off, `AutoMaskEps` rules exactly as today.
- `tools/verify_shaders.py`: compute-entry compilation (`cs_5_0`), `ComputeShader`/`DispatchSizeX/Y/Z` pass parsing, and the variant matrix extended to both switch settings.
- README updates in the same voice, per stage.

**Out of scope**
- A pixel-shader-only EMA fallback variant (deliberately deferred; see above).
- Any change to the two-technique contract, pass order semantics, or the anti-bloom/restore passes (they stay pixel passes — compute cannot write the back buffer).
- Block matching / optical flow. **Reversed, then reversed back.** `docs/optical-flow.md` §6 reopened
  it as a *fourth signal* that supports the verdict rather than replacing it, and its §6.1 cheap decisive
  experiment is what the later plan `.junie/plans/optical-flow-probe-first-step.md` implemented — one
  global low-resolution translation estimate per frame, drawn on the diagnostics overlay, behind the
  fourth structural switch `AutoMaskOpticalFlow`, additive and wired into no verdict. The experiment was
  then answered in a real game and came out negative (`docs/optical-flow.md` §6.2): the sky's slow drift
  sits below the search's whole-ring-pixel floor, a global vector cannot separate still HUD from
  barely-moving sky anyway, and the verdict never changed. The probe and its switch have been removed
  from the shader, so this entry stands as originally written — block matching / optical flow is out of
  scope, and the burden of proof is on a proposal that answers the loop failure §3 names before anything
  is built on a vector. `docs/optical-flow.md` carries the whole decision.
- D3D9/D3D10 support for the compute path (inherent; documented as a limit).

### User Stories

- As a player in a game with a slowly panning skybox, I want the backdrop to stay out of the mask while my HUD stays in, so my effects don't grade the sky as interface.
- As a user on D3D9 or with a GPU without compute, I want the shader to behave exactly as today when `AutoMaskCompute` is off, with no VRAM or frame-time cost.
- As a user who hates hand-tuning noise thresholds, I want an opt-in auto-deadband that measures the scene's noise floor and sets the RGB step for me.
- As a tuning user, I want the overlay and corner marker to keep their current meanings so my existing tuning habits carry over.

### Functional Requirements

- `AutoMaskCompute=0` (default): the file compiles to the current behaviour byte-for-byte (checked via the verifier's bytecode hashes); no new targets allocated; no compute passes in the technique.
- `AutoMaskCompute=1`: the accum, motion-reduction pair, and their pass entries are replaced by the compute equivalents; all other passes (`PS_Copy`, dilation, `PS_Store`, `PS_StoreFrame`, anti-bloom, diagnostics, restore) unchanged.
- The world-drawn gate reads an exact share of changing pixels from the previous frame (same one-frame-behind semantics as today, same `> AutoMaskMotion` strictness, same magenta/yellow marker).
- The drift channel marks a pixel moving when **either** the frame-to-frame diff or the EMA-lag diff crosses the deadband; the graded overlay shows the max, so red remains the reading the verdict comes from.
- The deadband override is per frame, per shader invocation, and never writes back into the slider's value.
- New uniforms follow the annotation/type and widget-family conventions (`__UNIFORM_DRAG_FLOAT1` for the horizon, `__UNIFORM_SLIDER_BOOL1` for the toggle, slider for the noise floor).

### Non-Functional Requirements

- **Cost when on:** ~1 full-res compute pass replacing two sub-res passes + one 1-thread pass; `groupshared` reduction keeps global atomics at ~group count (thousands, not millions) per frame; histogram adds a 256-bin `r32u` (1 KB). Drift targets: two RGBA16F full-res ping-pong targets (~28 MB at 1440p) — identical cost to the pixel-shader EMA variant, since the EMA is a float read-modify-write either way.
- **Cost when off:** none beyond parse time; verified by target-declaration audit and the unchanged bytecode hashes.
- **Platform:** compute path requires D3D11+/Vulkan (SM5+; atomics are empty code below SM5 and rgba16f typed UAV load is unavailable below D3D11.1). README states this plainly, as the pack documents its constraints.
- Toggling the switch costs one effect recompile (as with the existing switches).


# Technical Design

### Current Implementation

- `Shaders/AutoMask.fx`: `PS_Accum` (state machine, lines 199–278), `PS_Motion`→16×16 `texMotionCoarse`, `PS_MotionAvg`→1×1 RGBA8 `texMotionStat` (lines 281–305), ping-pong `PS_Copy`, two-technique wiring (lines 442–507). The accumulator reads the statistic one frame behind (`live = tex2D(MotionStat,...).r * 100.0 > AutoMaskMotion`).
- `tools/verify_shaders.py`: compiles every entry point at a profile chosen from its shape (`ps_5_0`/`cs_5_0`, `entry_points`), parses passes via `PixelShader`/`ComputeShader`/`RenderTarget`/`DispatchSize` (`technique_bindings`), eight variants (`VARIANTS`), and translates ReShade's compute dialect into HLSL (`strip_for_fxc`) so fxc can compile it at all. Loud-failure properties now cover five cases (empty shader set, pass-count cross-check, missing binding, broken syntax, compute pass missing a dispatch size); no-bytecode is an error.

### Key Decisions

1. **Opt-in via preprocessor definition** (`AutoMaskCompute`), per the agreed shape and the repo's elision convention. One guard owns: the `CS_*` functions, the technique's pass entries, and every compute-only texture/storage. Values tuned by watching stay live sliders (the horizon, auto-step toggle, noise floor) — only the structural switch is a definition.
2. **Replacement, not addition:** when on, `PS_Accum`, `PS_Motion`, `PS_MotionAvg`, `texMotionCoarse`, and the 1×1 RGBA8 stat are compiled out; their compute equivalents take the same slots in the pass order. Keeps the cost claim honest and the diff reviewable.
3. **Coverage via `groupshared` reduction + single global counter.** `[numthreads(64,4,1)]` blocks of 256 threads cover 64×4 px; per-thread flag → `atomicAdd` into a `groupshared` counter → `barrier()` (lowers to `GroupMemoryBarrierWithGroupSync`, verified in reshade-fx) → thread 0 `atomicAdd` into a 1×1 `r32u` target. ~14k group atomics/frame at 1440p.
4. **`CS_Finish` keeps cross-backend readability.** The counter is `r32u` (atomics need integer formats), but the pixel passes (`PS_Accum`'s gate read, `PS_DebugMap`, corner marker) sample through float samplers. `CS_Finish` (1×1 dispatch, right after `CS_Accum`) reads the count, writes the share into a 1×1 `r32f` float target, and zeroes the counters/histogram for the next frame. Pass order within a technique is serialized, so the handoff is safe; the stat keeps today's one-frame-behind semantics exactly.
5. **EMA drift channel with a fixed horizon.** `drift' = lerp(now, drift, 1 - 1/K)`, `K = AutoMaskDrift × AutoMaskTargetFPS`; motion = `max(shortDiff, driftDiff)` through the same deadband ramp. Two new full-res RGBA16F ping-pong targets + a guarded copy pass (`PS_CopyDrift`); the existing `PS_Copy` cannot carry it (only one spare accumulator channel, and the EMA needs float3). Reuses `AutoMaskEps` for the drift comparison rather than adding a second deadband — random TAA jitter averages out in the EMA while sustained drift accumulates; the TAA risk is documented, and the failure direction is mild (HUD left out, not sky captured).
6. **Auto-deadband from the histogram's tail.** 256 bins of per-frame max-diff (levels 0–255). `CS_Finish` derives the smallest level whose above-share falls below `AutoMaskNoiseFloor` (percent of screen), clamped to [1, `ceil(AutoMaskEps)`-slider-max... i.e. [1,8]]; `AutoMaskAutoStep` on → `CS_Accum` uses it in place of `max(ceil(AutoMaskEps),1)`. The exact tail policy is finalized with the overlay as the instrument during stage 4.
7. **Post-cut recovery mechanism, stated up front.** After a scene cut the EMA lags by the whole colour distance, which would unmark the screen for ~K frames. `CS_Accum` snaps the drift EMA toward `now` at an accelerated rate on clean-still frames (short diff reads exactly still), so recovery is a handful of frames; during real drift (still/changing oscillation) the trailing behaviour that catches the skybox is preserved. This is the main risk to watch in the manual scenarios.

### Proposed Changes

**Stage 1 — `tools/verify_shaders.py` compute support.** ✅ *Done, committed as `teach verify_shaders.py compute passes`.*
- `ENTRY_POINT` split into `PIXEL_ENTRY_POINT` (`: SV_Target`) and two compute patterns (`[numthreads]`-attributed and thread-addressed), all unanchored; `entry_points` returns a name→kind map.
- Per-entry target profile: `PROFILES` picks `ps_5_0` for pixel, `cs_5_0` for compute; hash and histogram cross-checks apply to both.
- `technique_bindings`: parses `ComputeShader` and `DispatchSizeX/Y/Z`; `Pass` rows carry kind, shader, target and dispatch; a compute pass with fewer than two dispatch sizes is a loud failure (mirror of parser error 3012); keyword cross-checks extended to `ComputeShader` and `DispatchSize`; absent `RenderTarget` on a compute pass is expected.
- `VARIANTS`: `BASE_VARIANTS` (four combos) × `AutoMaskCompute` 0/1 = eight, with the prelude-override mechanism unchanged.
- **Unplanned but load-bearing: `strip_for_fxc` now translates ReShade's compute dialect into HLSL.** `storage1D/2D/3D<T>` → `RWTexture*<T>`, `barrier()`/`groupMemoryBarrier()`/`memoryBarrier()` → the HLSL barrier names, and the `atomic*` family → `Interlocked*` with storage+index folded into `Obj[idx]` (paren-balanced argument reading; `atomicCompareExchange` refused loudly, as it has no HLSL expression form). ReShade's own codegen does this before calling a shader compiler, and fxc cannot read the dialect directly — without it no compute entry point compiles at all, so Stage 1 is unreachable otherwise.
- Added `--hashes` (per-entry bytecode sha256) because the plan's off-path regression check needs it and the tool never printed hashes before.
- Kept the deliberate properties: loud empty/missing failures, histogram-vs-instruction-count cross-check (works unchanged on `cs_5_0` asm).

**Stage 1 verification evidence.**
- All eight variants pass: `uv run tools/verify_shaders.py check --pass-list --opcodes`.
- Off-path regression **proven identical**: the 40 entry points of the four `AutoMaskCompute=0` variants hash byte-for-byte the same as the pre-change tool's output (captured by importing the pre-change module from a scratch copy before editing).
- Five loud-failure cases each exit non-zero (empty `Shaders/`, unparsable passes, missing binding, broken syntax, compute pass missing a dispatch size), plus 15 direct parser-guard and translation assertions.
- A synthetic compute probe (`CS_Count` + `CS_Finish` with `groupshared` reduction + atomics) compiled clean end to end under the new tool, confirming the compute path is genuinely reachable, not just parseable.
- **New constraint for Stage 2, discovered here:** a `barrier()` must sit in uniform flow control, so a compute shader's ceil-div bounds guard must be a *predicate* (`bool live = tid.x < BUFFER_WIDTH && ...`) and not an early `return` — fxc rejects the latter outright (X4026). Stage 2's `CS_Accum` must be written that way.

**Stage 2 — `AutoMaskCompute` switch + `CS_Accum` + exact gate.**
- Switch block after the existing two (same annotation comments).
- `#if AutoMaskCompute == 1`: `CS_Accum` (state machine mirrored from `PS_Accum`, plus a `SV_DispatchThreadID` bounds **predicate** `bool live = tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT;` for ceil-div dispatch sizes — a predicate rather than an early `return`, which fxc rejects in front of a `barrier()`, X4026), `texAutoMotionCount` 1×1 `r32u` + storage, `texAutoStat` 1×1 `r32f` + sampler, `CS_Finish`; technique passes swapped (`CS_Accum` for `PS_Accum`, `CS_Finish` for the motion pair); `PS_Motion`/`PS_MotionAvg`/`texMotionCoarse`/`texMotionStat` compiled out; `PS_Accum`'s gate read in `PS_DebugMap`/corner-marker paths redirected to the float stat via a guarded sampler line.
- `#else`: the file remains as today.

**Stage 3 — EMA drift channel.**
- `texAutoDriftA/B` RGBA16F full-res + samplers + storages; `PS_CopyDrift` copy pass; `AutoMaskDrift` uniform (drag widget, seconds × `AutoMaskTargetFPS` cap convention).
- `CS_Accum`: drift sample, EMA update written to the drift target, `motion = max(short, drift)` before the existing flag use (deadband, cost, banking untouched); clip-rail exclusion applied symmetrically to the drift comparison; accelerated snap on clean-still frames.
- Overlay unchanged in meaning (red is still the graded max); README rows + a "slow backdrops" paragraph replacing part of the tuning guidance.

**Stage 4 — Histogram + auto-deadband.**
- `texAutoMotionHist` 256×1 `r32u` + storage; `CS_Accum` adds one `atomicAdd(hist[min(maxDiff,255)], 1)`.
- `CS_Finish`: derive the deadband from the tail share vs `AutoMaskNoiseFloor`; write the derived level into the stat texture's second channel (or a sibling 1×1); `AutoMaskAutoStep` toggle selects the effective deadband in `CS_Accum`.
- README: the toggle, the noise-floor slider, and when to prefer manual.

### Data Models / Contracts

```hlsl
// Switch
#ifndef AutoMaskCompute
	#define AutoMaskCompute		0		// [0 or 1] 1 runs the accumulator and the
#endif										// motion gate as compute passes (D3D11+/Vulkan)

// New uniforms (annotations per AGENTS.md conventions)
uniform float AutoMaskDrift  < __UNIFORM_DRAG_FLOAT1  "Drift horizon (seconds)"; ui_min 0, ui_max 10.0*AutoMaskTargetFPS, step 0.25 > = 0.5 * AutoMaskTargetFPS;
uniform bool  AutoMaskAutoStep < __UNIFORM_SLIDER_BOOL1 "Auto-detect RGB step"; > = false;
uniform float AutoMaskNoiseFloor < __UNIFORM_SLIDER_FLOAT1 "Noise floor (percent)"; ui_min 0.0, ui_max 5.0, step 0.05 > = 0.5;

// Compute-only targets
#if AutoMaskCompute == 1
	texture texAutoMotionCount { Width = 1; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionCount { Texture = texAutoMotionCount; };
	texture texAutoStat { Width = 1; Height = 1; Format = r32f; };   // float share, sampled by pixel passes
	texture texAutoMotionHist { Width = 256; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionHist { Texture = texAutoMotionHist; };
	texture texAutoDriftA/B { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };  // ping-pong
#endif

// Pass wiring (technique AutoMask), compute variant:
// CS_Accum -> PS_Copy -> PS_CopyDrift -> CS_Finish -> PS_DilateH -> PS_DilateV
//          -> PS_Store -> PS_StoreFrame -> [PS_AntiBloom] -> [PS_DebugMap]
```

Dispatch shape: `DispatchSizeX = (BUFFER_WIDTH + 63) / 64; DispatchSizeY = (BUFFER_HEIGHT + 3) / 4;` with `[numthreads(64,4,1)]` on `CS_Accum` and an in-shader bounds **predicate** (not an early `return` — see Stage 1 evidence), so odd resolutions keep full coverage (the AGENTS.md `BUFFER_*` rule).

### File Structure

- `Shaders/AutoMask.fx` — all shader changes (guarded blocks; no new files; the no-`.fxh` rule stands).
- `tools/verify_shaders.py` — compute support + variant matrix (stage 1).
- `README.md` — settings table rows, preprocessor-switch section, platform limit, slow-backdrop guidance (stages 2–4).

### Architecture Diagram

```mermaid
graph TD
    subgraph frameN["frame N — technique AutoMask"]
        CS_Accum["CS_Accum (compute, full-res)\nstate machine + drift EMA\n+ atomic flag/histogram"]
        PS_Copy["PS_Copy (pixel)\naccumulator ping-pong back-edge"]
        CopyDrift["PS_CopyDrift (pixel, guarded)\ndrift ping-pong back-edge"]
        CS_Finish["CS_Finish (compute, 1×1)\ncount → share (r32f)\nclear counters + histogram\nderive deadband"]
        Dilate["PS_DilateH/V + PS_Store + PS_StoreFrame (pixel, unchanged)"]
    end
    Hist["texAutoMotionHist 256×1 r32u"] --> CS_Finish
    Count["texAutoMotionCount 1×1 r32u"] --> CS_Finish
    CS_Finish --> Stat["texAutoStat 1×1 r32f"]
    Stat -- "gate: live > AutoMaskMotion (one frame behind)" --> CS_Accum
    CS_Accum --> Count
    CS_Accum --> Hist
    CS_Accum --> PS_Copy
    CS_Accum --> CopyDrift
    PS_Copy --> Dilate
    CopyDrift --> CS_Accum
```

### Risks

- **Post-cut mask blanking** (EMA lag after a scene cut) — mitigated by the accelerated snap; the manual scenario list includes "cut between two scenes, mask must reform promptly".
- **TAA-noisy HUDs vs the drift channel** — the EMA may flag a static-but-dithering HUD; failure direction is mild (element left out) and tunable via horizon/noise floor; documented in README.
- **D3D9/D3D10 users flipping the switch** — compute pipeline creation fails in ReShade; README states the requirement plainly; the technique still loads for the *other* techniques... (single technique file: state it in the switch tooltip).
- **Integer-format sampler traps** — pixel passes never sample `r32u` targets directly; only `CS_Finish` touches them (as storage), float handoff via `texAutoStat`.
- **Silent verifier blind spots** — closed by stage 1 landing before any shader change; pass-count cross-check extended to `DispatchSize` so a dropped compute pass is loud.


# Testing

### Validation Approach

Per AGENTS.md: verification is the offline compile check plus a review pass; real end-to-end behaviour needs eyes in ReShade, which is stated, not claimed.

**Automated (agent-runnable)**
- `uv run tools/verify_shaders.py init && uv run tools/verify_shaders.py check --pass-list --opcodes` after every stage; all eight variants must pass.
- **Off-path regression:** bytecode sha256 of every entry point in the four `AutoMaskCompute=0` variants must be **identical** to the pre-change hashes (the tool prints them with `--hashes`) — the strongest available proof the default behaviour is untouched. *Stage 1 baseline captured:* the 40 off-path entry points of `94710ad`, the commit before the Stage 1 one (`add plan for the compute gate and drift channel`); see Stage 1 evidence.
- **On-path wiring:** `--pass-list` must show the compute pass order (`CS_Accum`, `PS_Copy`, `PS_CopyDrift`, `CS_Finish`, …) at `AutoMaskCompute=1` and the current order at 0; a compute pass missing `DispatchSizeX/Y` must fail loudly (new tool guard).
- Cost reporting: instruction counts for `CS_Accum`/`CS_Finish` vs the removed `PS_Motion`/`PS_MotionAvg` pair, recorded in the stage summary.
- The tool's loud-failure behaviours re-exercised by hand after any parser change: empty `Shaders/`, pass-pattern miss, missing binding, broken syntax, and a compute pass with one dispatch size — each must exit non-zero.

**Manual (needs eyes in ReShade — listed, not claimed)**
- Walking with HUD up; menu open/close; quiet room (mask must stay empty); fire/water in view.
- **Slow skybox pan over a live scene:** sky must stay out of the mask while HUD stays in (the drift channel's reason to exist).
- **Scene cut:** mask must reform promptly (snap mechanism), not stay blanked for the drift horizon.
- **TAA-heavy static HUD:** element must not be evicted by the drift channel at default horizon.
- **Auto-deadband on/off:** same scene, toggled — the effective deadband should sit above visible dithering noise without missing real motion; off must match manual behaviour exactly.
- **D3D9/D3D10 or compute-less GPU:** switch stays off, behaviour unchanged.
- Corner marker must remain magenta/yellow exactly as today in both variants (it is the canary for pass-order damage).


# Delivery Steps

### ✓ Step 1: Teach verify_shaders.py compute passes
`tools/verify_shaders.py` compiles compute entry points and reports their wiring, so later stages are verifiable at all.

**Status: done, committed as `teach verify_shaders.py compute passes`.** All eight variants pass; the 40 off-path entry points hash identically to their pre-change values; five loud-failure cases and 15 direct parser/translation assertions hold; a synthetic compute probe compiled clean end to end. Delivered beyond the plan as written: a ReShade-dialect→HLSL translation in `strip_for_fxc` (without which no compute entry point compiles) and a `--hashes` flag for the off-path regression. Constraint handed to Step 2: the ceil-div bounds guard must be a predicate, not an early `return` (fxc X4026 in front of a `barrier()`).

- Extend `ENTRY_POINT` to also match compute signatures (`void ... : SV_DispatchThreadID` style, not line-anchored), keeping the existing pixel pattern intact.
- Pick the fxc target per entry: `ps_5_0` for `SV_Target` shaders, `cs_5_0` for compute; keep the bytecode-hash and histogram cross-checks for both.
- Extend `technique_bindings` to parse `ComputeShader = name` and `DispatchSizeX/Y/Z`, carry the shader kind in bindings, fail loudly on a compute pass missing dispatch sizes, and treat a missing `RenderTarget` on a compute pass as expected.
- Extend `VARIANTS` to the four existing combos × `AutoMaskCompute` 0/1 (eight variants), with the prelude-override mechanism the tool already uses.
- Re-exercise the four loud-failure behaviours by hand after the parse changes; confirm the current file passes all eight variants with unchanged off-path hashes.

### ✓ Step 2: Add AutoMaskCompute switch with CS_Accum and atomic gate
With `AutoMaskCompute=1` the gate counts every pixel via a groupshared atomic reduction and the 16×16 tap approximation is compiled out; with 0 the file compiles byte-for-byte as today.

**Status: done.** `Shaders/AutoMask.fx` carries the switch, `CS_Accum`/`CS_Finish`, the exact gate, the swapped pass entries, and the guarded target declarations; `README.md` and `AGENTS.md` are updated. All eight variants pass; the 40 off-path entry points still hash identically; the parity check shows the two accumulators share 47 statements and differ only in the bounds predicate, thread addressing, group reduction and store-vs-return. Cost: `CS_Accum` 107 slots + `CS_Finish` 6 replacing `PS_Accum` 87 + `PS_Motion` 25 + `PS_MotionAvg` 23 and the whole 16×16 pass.

Four implementation notes worth carrying forward:
- **`tex2D` cannot be compiled at `cs_5_0`** (X4532, no implicit derivatives). `CS_Accum` samples through `tex2Dlod` with an explicit level; the pixel passes are untouched.
- **The bounds guard must be a predicate, not an early `return`** (X4026): `bool live = (tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT)`, with the sample and the store gated on it.
- **`groupshared` is file-scope**, and the per-group thread is selected with `SV_GroupIndex` — `SV_DispatchThreadID` is global, so `tid.x == 0` would only fire in one group.
- **The read sites need no guarded line.** Both variants declare the sampler under the same name `MotionStat` (an `r32f` target on the compute side, the old RGBA8 one on the pixel side), so `PS_DebugMap` and the marker keep reading `tex2D(MotionStat, ...)` unchanged. This is a simplification of the plan's "guarded sampler line".

- Add the `AutoMaskCompute` switch block after the existing two, same `#ifndef` + `// [0 or 1]` convention, guarding everything the feature owns.
- Write `CS_Accum` mirroring `PS_Accum`'s state machine exactly (quantize, clip rails, deadband ramp, confidence/hold/move-memory), adding `SV_DispatchThreadID` addressing with ceil-div bounds **predicates** (not early returns — barriers must sit in uniform flow control, X4026) and `[numthreads(64,4,1)]`.
- Add the 1×1 `r32u` motion counter (+storage) and `texAutoStat` 1×1 `r32f` handoff target; implement the `groupshared` per-group reduction and per-thread `atomicAdd`.
- Write `CS_Finish` (1×1 dispatch, right after `CS_Accum`): count → share, clear the counter for next frame, keeping the statistic's one-frame-behind semantics.
- Guard the technique: compute pass entries replace `PS_Accum` and the `PS_Motion`/`PS_MotionAvg` pair when on; compile out `PS_Motion`, `PS_MotionAvg`, `texMotionCoarse`, `texMotionStat` when on; redirect `PS_DebugMap`/corner-marker stat reads to `texAutoStat` via a guarded sampler line.
- README: document the switch, the D3D11+/Vulkan requirement, and what changes when it is on; also update `AGENTS.md`'s switch inventory (it currently says "two structural switches") once `AutoMaskCompute` exists.
- Verify: eight variants pass; off-path bytecode hashes unchanged; on-path pass list shows the compute wiring; record instruction counts.

### ✓ Step 3: Implement the EMA drift channel in CS_Accum
Slow backdrops that the frame-to-frame comparison reads as still are caught via the long-baseline channel, with the horizon as one drag slider.

**Status: done.** `Shaders/AutoMask.fx` carries `texAutoDriftA/B`, `AutoDriftStore`, `PS_CopyDrift`, the `AutoMaskDrift` uniform and the drift arithmetic in `CS_Accum`; `README.md` and `AGENTS.md` are updated. All eight variants pass; the 40 off-path entry points still hash identically to the pre-change baseline; the drift targets appear only at `AutoMaskCompute=1` and the pixel path is untouched. Cost: `CS_Accum` 107 → 140 slots and `PS_CopyDrift` 4, i.e. one full-res compute pass plus one full-res copy, and two full-res `RGBA16F` targets — the compute path is no longer a wash on the pixel path, and the README no longer claims it is.

Three implementation notes worth carrying forward:
- **The snap is keyed on the short comparison, not on the clean-still test.** The plan had it "on clean-still frames", but the corrected model shows that test fires on exactly the case the channel exists for: real sub-deadband drift is *precisely* a clean-still frame whose average is a long way behind, so a lag-threshold snap would erase the signal it is meant to protect. Keyed on `maxDiff >= deadband` instead — the short comparison already calling the frame a change — the average follows a cut, a load or a fast pan at once (there it has nothing to add) and only the movement the short comparison is blind to is left to accumulate. Verified numerically: a 160-level cut settles in one frame, a 0.4-level-a-frame drift accumulates to a settled lag of ~12 levels and reads as motion continuously, a static HUD stays at zero lag.
- **The deadband is what makes the channel necessary.** At `AutoMaskEps=1` a one-level step is motion in the short comparison, so the drift channel adds nothing; it earns its keep at the raised settings (`AutoMaskEps=3`, where a one-level step is still and the drift ramp is still climbing at four levels) — which is exactly the tuning case where a slow backdrop would otherwise be banked.
- **The clip-rail exclusion is applied to the average**, not just to `now`/`before`: an average sitting at all 0 or all 255 is a saturated colour on the same reasoning, and it voids the still verdict through the same `clipped` count.

- Add `texAutoDriftA/B` RGBA16F full-res ping-pong targets (+samplers +storages) and the guarded `PS_CopyDrift` copy pass.
- Add `AutoMaskDrift` ("Drift horizon (seconds)") as a `__UNIFORM_DRAG_FLOAT1` duration capped by `AutoMaskTargetFPS`, default 0.5 s.
- In `CS_Accum`: read the previous drift EMA, write the updated EMA (`lerp(now, drift, 1 - 1/K)`) to the drift target, compute the drift diff against the same deadband, take `motion = max(short, drift)`; apply the clip-rail exclusion symmetrically to the drift comparison.
- Implement the accelerated snap of the EMA toward `now` on clean-still frames so a scene cut recovers in a few frames instead of the full horizon.
- Overlay stays semantically unchanged (red = graded max of both channels); README: new settings row plus a slow-backdrop tuning note, replacing part of the manual recipe.
- Verify: eight variants; drift targets only allocated when the switch is on; record cost delta.

The horizon ships as a literal-seconds slider (cap `10.0`, step `0.25`, default `2.0`) rather than a `seconds × AutoMaskTargetFPS` cap: `AutoMaskTargetFPS` multiplies it *inside* the shader to turn it into a frame count, so the panel value stays in the unit the label names. It is declared inside the compute guard rather than with the other uniforms, because the pixel path has no pass that would read it.

**The default was revised after use.** It shipped at `0.5 s`, which turned out to be too short for the channel to do anything: the settled lag the verdict reads is the per-frame shift times the horizon in frames, so at `K = 30` frames a backdrop drifting 0.05 of a level a frame converges to a ~1.5-level lag — under the deadband that judges it — and caught none of it. Numerically modelled: the catch rate at deadband 2 goes 5% → 100% for that pan between 0.5 s and 2.0 s, and the gain shows at every deadband (at deadband 3, 0% → 100%). 2.0 s is roughly the shortest horizon that catches the rates the channel exists for, so that is the default now. The step stays `0.25`: the whole range the setting is useful over spans a second or more, so a quarter second is already a fine enough notch, and a tighter one only made the track longer to sweep. Raising the horizon is close to free for the failure mode it was feared to cost: a static pixel with *independent* per-frame jitter (what TAA produces) settles at a lag that does **not** grow with the horizon — 0.52 levels at 0.5 s, 0.51 at 4 s, for one-level jitter — because independent error does not accumulate. Only a genuine random walk does, and that is a drifting pixel rather than a flickering one.

**The store's precision was revised later, after a review of the channel.** A follow-up pass against the shipped arithmetic (`docs/drift-snap-review.md`) found two coupled defects, and they were landed together because neither is safe alone. First, the short comparison subtracted the quantized *colours*, whose difference carries a float residue — `0.9999999` on 247 of the 255 adjacent pairs — so the deadband forgave most one-level changes at `AutoMaskEps = 1`; it now subtracts the rounded *level counts* (`round(now * 255.0)` against `round(before * 255.0)`, in both accumulators), which makes the most sensitive setting 255 of 255 rather than 8 of 255. Second, the two drift targets were `RGBA16F`, an ulp of 0.1245 levels above level 128, and the creep toward a one-level gap is 0.0083 levels a frame at the 2 s default — under the store's half-ulp above level 31, so the average sat *frozen* rather than following the pixel. A frozen average fails both ways: it cannot accumulate a sub-level shift, so the channel did nothing over the bright half of a sky, and it cannot close on a static pixel either, so a pixel left a level away from it read as moving for as long as it held (measured: 112 of 252 levels never recovered after a single one-level step). They are now `RGBA32F` and point-filtered — point because the average is data rather than a picture, and a linear filter on a 32-bit float target is a combination a driver is free not to support — at ~118 MB for the pair at 1440p, up from ~59 MB. The pair of fixes restores the floor behaviour the tables above describe; it does **not** address the reported symptom (a returning skybox), for which the review's repeat detector is the answer, and it does remove the accidental protection the freeze was providing to the one-level swaying band.

### ✓ Step 4: Add change-size histogram with auto-deadband
The RGB step can be measured from the scene instead of hand-tuned, opt-in via a panel toggle, with the slider path untouched when off.

**Status: done.** `Shaders/AutoMask.fx` carries `texAutoMotionHist` (256×1 `r32u`) and `texAutoStep` (1×1 `r32f`), the per-pixel `atomicAdd` in `CS_Accum`, the tail walk in `CS_Finish`, the `AutoMaskAutoStep`/`AutoMaskNoiseFloor` uniforms and the measured deadband in `CS_Accum`; `README.md` and `AGENTS.md` are updated. All eight variants pass; the 40 off-path entry points still hash identically to the pre-change baseline and the histogram/step targets appear only at `AutoMaskCompute=1`; the loud-failure properties still hold 5/5. Cost: `CS_Accum` 140 → 154 slots, `CS_Finish` 6 → 41 (a 1×1 pass, so the walk is one thread's work), plus 1 KB for the bins and the step.

Five implementation notes worth carrying forward:
- **The bin index truncates, matching the verdict's own boundary.** `int(maxDiff)` puts bin `b` exactly at the differences the verdict calls motion at `deadband = b` (its test is `maxDiff < deadband`), so the above-share read off the histogram at a level *is* the share that level would call moving — same units, same comparison, no second convention to keep in step. `round` would have put the boundary half a level off it. Verified numerically across 2,000 random distributions: the walk's answer always equals an independent "smallest level whose above-share falls at or under the floor" reading.
- **Running out of the range falls back to the slider, not to 8.** The plan had the clamp be the *end* of the range; the corrected reading is that a frame where no level from 1 to 8 separates (every level still changing across the screen — a fully live frame, which is exactly when the measurement has no floor to read) must not hand the accumulator a step picked from noise. Falling back to `max(ceil(AutoMaskEps), 1.0)` means a fast camera movement can never talk the shader into forgiving real motion.
- **The deadband read is clamped on both sides.** `clamp(tex2Dlod(AutoStep, ...).r, 1.0, 8.0)` guards the first frame after the toggle goes on, when the target is still unwritten and would otherwise read 0 and take the deadband off the slider's own scale.
- **The bins are filled only while the toggle is on, but cleared unconditionally.** Filling is the per-pixel atomic, so gating it is what keeps "off costs what the path cost before the feature existed" honest; the clear has to run regardless or a toggle flip would leave a frame of counts in the bins and the first measured step after it would be read off stale data.
- **The measurement is not a structural switch.** `AutoMaskAutoStep` is a live toggle and its targets stay allocated while it is off — 1 KB inside a guard the compute path already pays, against a recompile per on/off comparison. It is declared beside the horizon inside the compute guard because the pixel path has no pass that would read it.

The plan's deferred tail policy is settled as: *the smallest level 1–8 whose share of the screen changing above it is at or under `AutoMaskNoiseFloor` percent; if no level in that range qualifies, `max(ceil(AutoMaskEps), 1.0)`* — one frame behind, exactly as the share is, so no frame sets its own threshold. Finalised against synthetic distributions in an offline probe (`tools/.work/`, not committed) rather than the overlay, since the overlay needs eyes in ReShade; the overlay check remains on the manual list.

**Fix after the first real ReShade load.** The compute path failed to compile in the game with X3000 syntax errors on every storage declaration, plus the X3004 errors that followed from them. The cause was carried in from Stage 2, not introduced here: the declarations were written `storage2d`, and ReShade's lexer only registers `storage`, `storage1D`, `storage2D` and `storage3D` — the dimension letter is capital, so a lowercased one lexes as an ordinary identifier and the declaration fails with a bare X3000 that points at the line rather than the case. Every declaration now uses `storage2D`, verified against ReShade v6.8.0's own `effect_lexer.cpp` and the declaration parser in `effect_parser_stmt.cpp` (the `{ Texture = ...; }` property block is valid on a storage, and only `MipLOD`/`MipLevel` are valid inside it, so `Texture` is the one property there and is right).

The reason the offline check missed it is the more important part, and it is fixed too: `strip_for_fxc` translates `storage*<T>` into `RWTexture*` before fxc ever sees the source, so a spelling ReShade rejects compiles here regardless. The tool's `STORAGE` pattern accepted either case, which meant it silently rewrote the invalid keyword into valid HLSL and reported the file clean. The pattern is now pinned to the real spellings, a lowercased one is a loud failure instead of something to translate, and both directions are exercised in the loud-failure probe (7/7 now). The lesson generalises: anything this tool rewrites is unverifiable by compiling it, so the dialect spellings the translation touches have to be pinned to ReShade's source rather than inferred.

**Fix after the second real ReShade load.** With the declarations fixed the compute path compiled further and then failed with X3121 on two lines — `array, matrix, vector, or indexable object type expected in index expression` — on `AutoAccumStore[int2(tid.xy)]` and `AutoMotionCount[int2(0, 0)]`. The cause is a second dialect rule of the same family, carried in from Stage 2: **a storage object cannot be indexed at all**. Its element type is a storage type rather than a vector, matrix or array, and the index-expression rule in ReShade's `effect_parser_exp.cpp` accepts only those three, so every `store[coord]` read or write is rejected against the *use* rather than the declaration. The only legal access is the intrinsic pair `tex2Dfetch(store, coord)` / `tex2Dstore(store, coord, value)`; all nine sites in `CS_Accum`/`CS_Finish` now go through them, and `storage2D<T>` stays the right thing to declare.

This one proved the verifier blind spot from the *other* side, which is the important part. The access intrinsics had to be added to `strip_for_fxc` (ReShade's codegen emits `s[coord]` for them, so fxc cannot see the intrinsic names at all), and the moment that translation existed, the check compiled the bracket form clean — i.e. it would have passed the exact source that failed in the game. So the bracket form is now a loud failure in its own right, keyed on the declared storage names, and it is exercised by hand in the probe (13/13 now, including that case and a texture indexed with brackets as the negative control). The lesson is the sharper version of the earlier one: once a dialect construct is *translated* rather than compiled, the shape the translation produces is exactly the shape the check can no longer judge — so the illegal form has to be refused explicitly, not just the misspelt one.

Reproduced and verified offline rather than by inspection: ReShade v6.8.0's own preprocessor, parser and HLSL codegen (`source/effect_*.cpp`) were built into a scratch harness under `/tmp` and run over the shader, reproducing the in-game X3121 at the same two lines and columns, then confirming all eight variants parse and assemble clean once fixed. That is the tool to reach for whenever a failure is dialect-level rather than HLSL-level — `fxc` cannot answer these questions, but ReShade's parser can, offline.

- Add `texAutoMotionHist` 256×1 `r32u` (+storage); `CS_Accum` adds one `atomicAdd(hist[min(maxDiff,255)], 1)` per pixel.
- In `CS_Finish`: read the histogram, derive the smallest level whose above-share falls below `AutoMaskNoiseFloor` (clamped 1–8), write it to the stat texture for next frame's `CS_Accum`.
- Add `AutoMaskAutoStep` (`__UNIFORM_SLIDER_BOOL1`, default off) selecting the effective deadband in `CS_Accum`, and `AutoMaskNoiseFloor` slider (default 0.5%); finalise the tail policy with the overlay as the instrument.
- README: the toggle and noise-floor slider, when to prefer manual, and the known TAA interaction.
- Verify: eight variants; histogram and deadband targets elided when the switch is off; full manual-scenario checklist appended to the stage summary as the list that needs eyes in ReShade.