# Verification

How this project is verified and how the offline check is exercised. Read this when a change touches
`tools/verify_shaders.py`, adds a shader entry point or dialect spelling, or when you need the
failure-mode list before committing a change to the check.

Nothing here is automatically testable, so verification is a review pass plus an offline compile check:

- `uv run tools/verify_shaders.py init` fetches the pinned ReShade headers, then
  `uv run tools/verify_shaders.py check` preprocesses and compiles every shader with `fxc` and reports
  instruction counts and opcode histograms. Keep the `tools/.work/` output out of commits.
- The check compiles sixteen variants — `AutoMaskAntiBloom` and `AutoMaskDiagnostics` each at 0 and 1,
  crossed with `AutoMaskCompute` and `AutoMaskDepthMotion` at 0 and 1, set from the prelude exactly as a
  ReShade-level definition would be — because a `#if` guard can drop a pass from a technique body, and
  only compiling every combination shows that it did. The compute switch is crossed rather than added
  beside the others because it swaps a pass for one of another type, and the depth switch adds a render
  target on the closing pass, so a guard that drops or misbinds a pass has to show at every setting.
  `--pass-list` prints the wiring, `--opcodes` the histogram per shader, `--hashes` the bytecode sha256
  of each entry point.
- An entry point is compiled at the profile its shape calls for: `ps_5_0` for a `SV_Target` function,
  `cs_5_0` for a compute one, so a compute pass cannot slip through unread or be compiled as a pixel
  shader. A pass is read for `ComputeShader` as well as `PixelShader`, and a compute pass declaring fewer
  than two `DispatchSize`s exits non-zero the way ReShade rejects it (its error 3012).
- **A warning is a failure, not a note.** ReShade prints every warning its compile emits into the log
  the user reads at load, so shipping one is shipping an unreadable log. `check` therefore reports a
  warning entry as `WARN` and exits non-zero on it. The one exception is `X3579` (`ps_5_0 does not
  support groupshared, groupshared ignored`), which is the harness's own artefact: the whole preprocessed
  file is compiled once per entry point, so fxc sees the compute path's file-scope `groupshared` tally
  while compiling a *pixel* entry point, where ReShade — emitting one pass's shader from that pass's
  reachable code — does not. The game's log carrying no such warning is what says the cause is the
  harness, so it is filtered on the reported code (this `fxc` rejects `/wd`) and nothing else is.
  Exercise the gate by hand before committing a change to it: put the construct below back and it must
  exit non-zero naming the code.
- The shader is written so that `check` is silent, and the rewrite below is the *only* thing that
  silences its code — do not "tidy" it back into the warning shape. A `clipped` accumulator declared
  `float3` makes `clipped == 0.0` a three-wide test whose `&&` truncation is X3206, so it is a scalar (the
  `all()` answer is one value, not one per channel) — `AutoMaskClipped` returns `int` so the four `all()`
  terms stay one integer sum, and a `float` return reorders `iadd`/`itof` against `and`/`add` in the
  compute accumulator and moves its hash. It is a bug in the log rather than a cosmetic preference.
- **The full identity check is the strongest evidence this tool offers, and it is how a behaviour-neutral
  change is verified.** `check --hashes --opcodes` is run before and after, and every one of the 82 entry
  points' bytecode sha256 and instruction count must come out identical — stronger than "the off path is
  unchanged", because it covers the compute path too. `docs/refactor-candidates.md` §1 holds the rules a
  fold has to clear.
- **It must fail loudly on missing data.** The tool's contract is that missing data exits non-zero rather
  than reporting a clean pass, because a missing hash compares equal to another missing hash. Ten cases
  must keep exiting non-zero, each exercised by hand before committing a change here: an empty
  `Shaders/`; a technique whose passes the parser cannot find (cross-checked against the `pass` keyword
  count, so a pattern miss cannot look like a technique with fewer passes); a technique binding a shader
  that does not exist; a shader whose syntax is broken; a compute pass missing one of its dispatch sizes;
  a variant list carrying two entries under one name, which would show the same combination twice and
  leave the other uncompiled; a call to an intrinsic `fxc` implements but ReShade does not; an identifier
  that is a reserved word in ReShade's lexer though not in HLSL; `AutoMask.fxh` deleted from `Shaders/`,
  which must fail because the workspace is emptied of stale copies before each run (with last run's copy
  left in `tools/.work/` the include would resolve and the check would report a clean pass for a shader
  that cannot load); and a render target a pass declares that the pass reading does not carry, where
  `PS_DilateH` writing `texAutoAccumA` makes the `RenderTarget[0-9]*` keyword count matter — a target it
  misses, or an index ReShade does not accept (`RenderTarget8`, past the `0`–`7`), exits non-zero naming
  the count rather than silently dropping what the pass writes.
- **A spelling the tool rewrites cannot be checked by compiling.** Storage declarations are translated to
  `RWTexture*` before fxc sees them, so a keyword ReShade would reject compiles in the check regardless:
  a lowercase `storage2d` passed every variant and failed in ReShade with a bare X3000 pointing at the
  line rather than the case, and because the bad declaration dropped its target, two further X3004 errors
  followed from it. The dialect keywords are therefore pinned to ReShade's own lexer — `storage`,
  `storage1D`, `storage2D`, `storage3D` with a **capital** dimension letter, and those four only — and a
  near-miss is a loud failure rather than something to rewrite.
- **The same rule covers the access intrinsics**, which are translated to bracket form before fxc sees
  them: their spellings are pinned the same way, and so is a wrong argument count, which cannot be
  translated and must not be dropped. The sharper case is the *inverse*: because the translation produces
  the bracket form, that form compiles here even though ReShade rejects it, so a storage object indexed
  directly is a loud failure in its own right, alongside the spelling and arity guards. Exercise all three
  by hand before committing a change to the translation, plus a texture indexed with brackets as the
  negative control, which must stay untouched.
- **The same caveat has a third form.** `fmod` is genuine HLSL that `fxc` implements and ReShade's parser
  does not carry, so a clean compile here is guaranteed and the effect still fails at load with X3004
  (`undeclared identifier or no matching intrinsic overload`). It reached a game once — written into a
  wrap around an integer, it passed every variant here and then failed to load — so the names `fxc` has
  and ReShade's own table does not are refused outright, that set being read from
  `source/effect_symbol_table_intrinsics.inl` rather than guessed: it is a deny set, so an ordinary
  identifier is never mistaken for a missed intrinsic, and a shader that defines its own function of one
  of those names is still allowed to call it. ReShade does provide `frac`, `floor`, `round`, `saturate`,
  `lerp`, `smoothstep`, `step`, `mad` and the `tex2D*` family — the whole vocabulary this shader uses — so
  a wrap around an integer is `%` rather than `fmod`.
- **The fourth form is a word, not a call.** ReShade's lexer emits some spellings as a reserved token
  where HLSL has no such thing, so `float sample = ...` is well-formed HLSL: `fxc` compiles it and ReShade
  fails the *load* with X3000, pointing at the column rather than naming the word. That reached the game,
  so the set is pinned to ReShade's own lexer rather than guessed — the `(name, tokenid::reserved)` table
  of `source/effect_lexer.cpp`, which is where `sample`, `new`, `this` and the `half`/`double`/`Texture2D`
  spellings sit. It is a deny set, and the guard reads the source with comments and string literals
  dropped first, because those words are ordinary English and this file's own tooltips use them. Exercise
  it by hand with `sample` put back: the check must exit non-zero naming the word.
- `pyproject.toml` lives in `tools/`, not at the repo root: this is a shader project, and `uv run`
  discovers the project by searching upward from the script, so the root-level command above works.

## The prose budget, which the same tool refuses

`uv run tools/verify_shaders.py check-docs` reads `README.md`, `AGENTS.md`, `docs/*.md`, the shader sources
and `tools/verify_shaders.py` itself, and exits non-zero on two things the budget bans. The first is
framing that describes the writing rather than its subject, or restates the sentence before it; the second
is the stale form of a design's history, because a comment or a doc states what the code does now, not how
it changed. `--list` prints every phrase with its reason, and `docs/editing-conventions.md` holds the
reasoning and the exception for a record of an investigation.

- It is the only rule here whose absence was silent: the compile check never opens a `.md`, so nothing
  caught the framing until a review pass did. A pass means only "no phrase from the list", and judgement
  stays with the review.
- The framing is matched by its verb, not by a noun alone: `this section explains X` is refused while
  `this section calls the pair the cheap half` is an internal cross-reference and is left alone. A phrase
  that is genuinely the subject of a line carries `prose-ok` to skip it. Naming a retired design to weigh
  the shipped one against it is a real claim and is left alone; only `has since been` and its like are
  refused, and a line whose subject *is* such a phrase quotes it in backticks, which the scan blanks
  before matching — a span opened and closed across a line break included.
- It needs no `fxc`, so a docs-only run works without the Windows SDK.
- Exercise it by hand before committing a change to the list: add a refused phrase to a doc and it must
  exit non-zero naming the phrase, then add `prose-ok` on that line and it must pass. Both the framing
  and the stale-form lists are exercised the same way.
- **The same run covers the source half of the budget**, which the phrase list alone cannot: a comment
  block longer than `COMMENT_BLOCK_MAX` (4 lines) is refused in any `Shaders/*.fx` or `*.fxh`, in
  `tools/verify_shaders.py`'s comments and docstrings, and in a doc — the shader's `//` runs, the Python
  file's comment and docstring blocks alike. Adjacent `//` lines are one block, so wrapping a comment
  lengthens it rather than spreading it; the credit block at the head of the shader is exempt by its
  `////...` fence, and `prose-ok` inside a block skips it.
- The four blocks that predate the rule carry `prose-ok` rather than being cut, and are exercised by hand
  as the rule's own tests — 5 lines must fail naming the range, 4 must pass, and `prose-ok` must clear it
  — before any change to the limit.

## The toolchain, which is not obvious

The compile check needs `fxc.exe`, which is a Windows binary run under WSL:

- It is looked up as `$FXC`, then `shutil.which("fxc.exe")`, then the newest
  `/mnt/c/Program Files (x86)/Windows Kits/10/bin/*/x64/fxc.exe`.
- Paths are translated with `wslpath -w` before being handed to `fxc`.
- The source must be preprocessed with these defined, because ReShade injects them and `fxc` will not
  compile without them. `Shaders/AutoMask.fxh` and the shader are both copied into `tools/.work/` first,
  since the include resolves against the including file's own directory, and any stale `.fx`/`.fxh` this
  repository does not have is removed, so a deleted header cannot resolve against last run's copy:

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
  too, because that is the same text ReShade puts in the log it shows at load.
- ReShade's compute dialect is not HLSL: `storage2D`/`storage1D`/`storage3D` objects, the group and
  memory barriers, and the `atomic*` family are its own surface vocabulary, and ReShade's own codegen
  translates them (`RWTexture*`, `GroupMemoryBarrierWithGroupSync()`, `Interlocked*`) before handing the
  result to a shader compiler. The check compiles the source itself, so it writes the same translation
  out in `strip_for_fxc`; without it no compute entry point could be compiled at all.
- The access intrinsics are part of the same translation: `tex2Dfetch(s, coord)` and
  `tex2Dstore(s, coord, value)` become `s[coord]` before fxc sees them, because a storage object cannot
  be indexed in the dialect at all and those calls are the only legal access. So the same
  unverifiable-by-compiling caveat applies in both directions — the spelling and argument count are
  pinned, and the bracket form the translation produces, which ReShade would reject, is refused rather
  than passed.
- The dialect's own constraints on a compute pass here — derivatives, barrier placement, `groupshared`
  and storage indexing — are in `docs/compute-path.md`.

## End-to-end scenarios that need a game

**Real end-to-end testing means loading both techniques in ReShade in a game**, which an agent cannot
do. State that instead of claiming a change is verified, and name the scenarios that need eyes on them.
Reviewing a screen capture is the next best thing. The overlay's motion view is the cheap way to see
movement the deadband is still admitting, and the corner marker tells you whether the reading you are
looking at is current.

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
  the world stopped it must *stay* out rather than clearing itself `AutoMaskMoveMemory` frames later,
  which is the screen-wide fill the one-sided hold prevents; then the same with an animating element on
  screen throughout — a draining bar or a scrolling list moving longer than `AutoMaskForget` — which
  should lose its protection to the memory and get it back once the animation stops and the world is
  drawn again.
- **Retention, `AutoMaskEstablished`, on both paths and off by default.** The case it exists for is a
  bar whose parts animate while the rest of the element holds still: a stamina or health bar refilling
  during combat, a spinner, a scrolling list. It is a live checkbox rather than a definition, so the
  branch is compiled in either way and the hashes move with it; what must be identical is the **output** —
  with the box off the branch is skipped and the mask is exactly the pre-change one, which is the
  property to re-read off-GPU as the mask, not as the bytecode. On: the animating part must stay in the
  mask while the still part of the element surrounds it, forming on without the two-second blank the move
  memory would otherwise leave. The negative control is the
  whole point of the rule and the one to watch hardest: close a menu, or reveal world behind any element,
  and the region must clear at the **fall** timing exactly as it did before — if it lingers for
  `AutoMaskMoveMemory` instead, the retention is reading a still neighbour where it should not, and the
  reach or the neighbour test is what to look at. Two properties to read on the overlay: the confidence
  view must show the animating part held at or above the verdict while the still part is cyan, and the
  motion view must show the same part red, which is the reading retention is overriding. Its bound is the
  reach: a changed part wider than about `2 × AutoMaskEstablishReach` pixels has no still neighbour to
  rest on and falls back to the memory, so a full-width moving band is the expected non-fix. The reach is
  a live slider in its own `Retention` category, so a bar that still drops out is widened rather than
  recompiled.
- The drift channel's pair, both on the compute path: pan slowly across otherwise still scenery — a
  sky, a distant backdrop — and the backdrop must stay out of the mask while a HUD in the same frame
  stays in, which the overlay's motion view is where to watch, since the short comparison alone shows
  the sky as clean; then cut between two scenes, or load one, and the mask must reform within a handful
  of frames rather than staying blank for the horizon. The same pan at `AutoMaskEps = 1` is the direct
  check on the decoupled reset: a horizon that now changes what the motion view shows is the channel
  working. The third is a HUD that does not move but does flicker — a static element with temporal
  anti-aliasing on it — which must not be evicted by the channel at the default horizon; if it is, the
  horizon is what to shorten, and a step of a couple of levels is the shape of flicker that needs that
  rather than a raised RGB step.
- **The move's tail, which is what the bounded reach is for.** Pan — hold a turn, or walk forward — then
  stop dead, and the corner marker must go yellow (the world no longer being drawn) promptly rather than
  seconds later, and the motion view's red must clear at the same moment instead of covering the screen
  and fading. The fall is still proportional to the horizon, so a shorter one is still the lever on it,
  and at `AutoMaskDrift = 0` there must be no tail at all. This is one of the two scenarios a user
  reported from playing, so it is the first to re-check after a change to the drift arithmetic.
- The auto-deadband's pair, both on the compute path: the same scene with the toggle on and off, and
  the step the measurement settles on should sit above the dithering the overlay shows as red without
  losing movement you can see — with the toggle off it must match the manual slider exactly. The third
  is a fully live frame — pan across detailed scenery with auto-detect on — where there is no quiet
  majority to measure and the slider's own value is what must govern, so the mask cannot start forgiving
  real motion just because the camera is moving.
  **The measured step must not flap with the share that set it.** This is the second thing a user
  reported: the motion view's red went off over scenery that could be seen moving, across the whole
  screen at once and for a fraction of a second at a time, because a step following the share up
  forgives the very motion that raised it. Watch the motion view over a steady mover — grass in wind, a
  waterfall — for a minute: the red must stay on it, and a red that blinks off and back across
  everything at once is the step moving rather than the scene. The step's own value is now drawn as a
  digit in the bottom-right corner (compute path, auto-detect on), so the failure to look for is that
  digit changing — a red that blinks with the digit steady is the scene, one that blinks with the digit
  moving is the step; a digit that never settles is the measurement flapping.
  Two of this feature's properties are checkable off-GPU and should be re-checked that way after any
  change to the histogram, rather than looked for on screen. **The reading must be unchanged by how the
  bins are counted**: the walk's answer for the reduced 8-bin groupshared tally must be identical to the
  256-bin per-pixel one for every distribution a frame can produce, which a scratch probe
  (`tools/.work/`, not committed) confirms by mirroring both readings statement for statement over
  20,000 synthetic frames — 0 mismatches. **The dialect must accept the tally**: a clean compile says
  nothing about a dynamically indexed `groupshared` array or an `atomicAdd` on one, so that was checked
  against ReShade v6.8.0's own parser and codegen instead, which emits
  `groupshared uint V__groupHist[8];` and `InterlockedAdd(V__groupHist[bin], 1u, _res)`. A construct this
  check cannot judge has to be verified against ReShade's source, not inferred from a passing compile.
- **The step readout, in the bottom-right corner and on the compute path only.** It draws the committed
  auto-detected step, 1–8, as a seven-segment numeral read from the 1×1 `texAutoStep.r`, in bright red on a
  dark box, and only while **Auto-detect RGB step** is on. Off-GPU the guard is the check: the draw is behind
  `AutoMaskCompute` *and* the toggle, so the pixel path and the toggle-off build must be **byte-identical** to the
  pre-change build, and only the four compute variants' `PS_Restore` may move. On screen: with the toggle
  off there must be no digit at all; on, the digit must agree with the level the red implies — a clean
  scene settles low, a noisy one high — and it must change only when the auto-deadband commits, i.e. after
  `AUTOMASK_STEP_DWELL` frames, not every frame the histogram wobbles. Because it leads the mask by one
  frame, a single-frame disagreement with the red is expected and is not a fault. The box is sized so the
  seven-segment glyph stays square in pixels (the corner inset is aspect-corrected), so check the bars are
  even rather than smeared, and that the digit stays in the corner and legible at a low resolution.
- **The premise's denominator, which a large dark region defeats.** The share is
  `changed / pixels that could change` rather than `changed / every pixel`, so a frame with a big
  black or letterboxed region has no ceiling below what movement can reach — were the share over every
  pixel, a high **Motion needed to trust
  stillness** would read the world as stopped while it was plainly moving, giving the corner marker yellow
  during a walk and the whole screen red wherever the wide grading caught the drawing. Watch the corner
  marker over a scene with a large permanent black area: it must be magenta
  while moving, at any setting the movement can actually reach. Two properties are checkable off-GPU and
  were: the corrected share agrees with a direct `changed / active` count over 300 random frames on
  *both* paths (0 mismatches), and a fully inert frame divides by a floor of one rather than zero. The
  limit of the fix: it excludes pixels pinned at a rail, not merely dark ones, since a static black
  backdrop is indistinguishable from a wall — a very dark view can still put a high setting out of
  reach, and that is a slider question rather than a bug.
- **The depth check, `AutoMaskDepthMotion`, on both paths.** It ships off as a definition, so the first
  check is that the mask with it at `0` is **byte-identical** to the pre-change mask — the hashes cover
  that off-GPU. With it at `1`: open a *large* opaque menu over a moving world and the corner marker
  must stay magenta while it is open and the mask must go on forming, which is the case the switch
  exists for. Then the negative control: in a game with no depth bound (or a game whose depth ReShade
  has not found) the mask must be exactly the `AutoMaskDepthMotion = 0` mask, since the unbound texture
  reads as a constant and the depth term is zero. The panel over an already-stopped world is *not* fixed
  and must not appear to be: with the world paused the depth stops too. **Depth step counted as a change
  (metres)** is a real distance, uniform across the screen where a share of the depth fell off with
  range: **walking forward over plain scenery with a HUD up must keep the corner marker magenta**, and
  the same step should register near, mid and far scenery alike. Past the distance where a walk's change
  is smaller than the buffer's own quantisation those pixels can register either way, which is the
  flicker to expect out there. Panning fires the term easily (rotation swings the sampled distance at
  every silhouette), so a marker that responds to a pan but not to a walk is a far-plane mismatch, not a
  threshold. Raise the step if depth noise holds a stopped scene as drawn, shown as magenta when it
  should be yellow. Expect the view and the marker to disagree for a moment on settling: the marker
  reads the screen-wide share and goes yellow as soon as the camera is effectively still, while the
  per-pixel red twitches over close geometry for a second or two longer, because deceleration and
  head-bob are real movement of a few centimetres. The two off-GPU properties the design rests on: a
  buffer sampled where nothing is bound returns one constant on both sides of the comparison, so the
  term is exactly zero, and the term is only ever added to the changed count, never the verdict. One
  side effect to expect: the depth change is folded into the same graded channel the motion view draws,
  so with the switch on a **depth**-only change shows there as red — the motion view can no longer be read
  as picture-only while the switch is on. The auto-deadband
  *measurement* is unaffected, since it bins the picture's own `maxDiff`.
- **The depth normals probe, `UIDebugDepthNormal`, and the surface exclusion it decides.** It exists only
  with `AutoMaskDepthMotion` and `AutoMaskDiagnostics` both on, and draws a field rather than a mark:
  white where the surface faces up or down, black where it faces the direction of travel. Point it at a
  scene with a clear floor and an oblique wall and the floor must read white and the wall black, which
  is the signature the exclusion keys on. The reading is a reconstruction — camera-space position from
  depth and the screen ray, crossed between neighbours — so its *shading* is right while its absolute
  tilt moves with **Camera field of view (degrees)**: sweep that and the reading should tilt, not change
  which surfaces are bright. Two limits: the sign of the normal is arbitrary (only its magnitude is
  drawn), and where the depth is clamped the reconstruction has no gradient and reads black regardless.
  What it decides: `AutoMaskDepthInvariant` drops the surfaces a walk cannot move from the depth changed
  count and its denominator — a normal lying across the walk (`n.z` under `AUTOMASK_DEPTH_ALIGNED`), and
  a vertical normal (`n.y` over `AUTOMASK_DEPTH_UPRIGHT`), which holds for the floor even when the
  camera is pitched. The wall ahead points down the walk and stays counted, as does a slope.
- **A still patch of world beside a large animating one, which is the premise's own false witness.** The
  share is a single screen-wide number, so it says the world is drawn whenever *enough* of it moves —
  and stillness is then credited over still world too. Watch the verdict view (or the mask) over a scene
  with a river, a waterfall or fire covering a good part of the frame while the camera is still and a
  wall or a menu backdrop sits in view: green appearing over the wall is this failure. It is the
  animated-neighbour form of the large-dark-region case above — that one capped the share so the world
  read stopped while it was moving, this one lets the world read drawn over a patch that never moved —
  and it is the option `docs/ui-isolation-options.md` §5.10 records. Raising **Motion needed to trust
  stillness** is the only shipped lever and it only helps while the animating region is small. **A played
  game puts the answer at rare**: these views exist but are very few,
  so `AutoMaskDepthOnly` in a per-game preset covers them. A pan that shows large picture motion with a
  flat depth term is not this case — a rotation swings the sampled distance at every silhouette — so
  the flat term there is a far-plane or depth-settings fault, recognised by the opposite symptom: a
  genuine element failing to be captured while the view moves.
- **The witness experiment, `AutoMaskDepthOnly`, inside the depth guard and on both paths.** `motion`
  becomes the depth term alone rather than `max(depth, picture)`, so the premise reads viewpoint change
  rather than picture change. The panel's three states are the switch off (picture alone), the switch on
  with this off (both) and both on (depth alone), so the check covers the labelling as well as the
  arithmetic. Off-GPU it must be **absent** with `AutoMaskDepthMotion = 0`, and the additive path must
  be unchanged with it false — a false switch that changed an entry-point hash would mean the branch was
  not free. In a game, with the depth buffer missing or mis-configured the **corner marker is stuck
  yellow**, because the depth term is zero and the premise never fires: that is the switch being on with
  no usable depth, not a broken mask. Then, in a scene whose only movement is texture with the camera
  still: with the switch off the marker is magenta and still world is claimed (the case above), with it
  on the marker goes yellow and the mask holds.
- The exact comparison, at `AutoMaskEps = 1`, where it is a visible change rather than an arithmetic
  one: the motion view over a large smooth gradient — a sky, a wall lit by a lamp — must show a red rim
  wherever the ramp crosses a level, since every one-level change trips the verdict where only the
  binade edges used to. The mask must not start eating scenery on that account: a backdrop that *stops*
  against a bright scene should still earn its mask once the world is drawn over it. Raising
  `AutoMaskEps` is the remedy if the extra red is noise.
- The drift store's precision, on the compute path: pan slowly across a *bright* sky or backdrop — the
  upper half of the brightness range — and it must stay out of the mask, which the dark half already
  did. The reverse case is the one to watch with the verdict view: put the overlay in its verdict view
  on a still HUD element and confirm the green is there and stays there over the horizon, which the
  frozen whole-value store could not deliver.
- The panel's grouping, which the compile check cannot see at all: each heading must appear once, with
  **Frame timing** holding the four frame-count durations, **Is the scene in motion?** next holding the
  motion threshold and the depth readings, the compute path's group reading **RGB step detection** rather
  than the old **Step detection**, and the RGB step slider drawn as the last row of **AutoMask** so it
  sits directly above that group. A category named twice draws two headings of the same name, so a
  second **AutoMask** block, or **Is the scene in motion?** drawn in the midst of **AutoMask** with a
  second **AutoMask** heading under it, is the failure to look for after any move of a uniform. Inside
  **Diagnostics** the order is the guide first: **motion view** with **motion gain** directly under it,
  then the two development readings — **confidence view** and **depth normals**.
- The isolation gate, in the panel and in the mask: the checkbox ships off, so on first load **Isolated
  pixels** must show the gate alone with the count and radius hidden under it, and it must be a *second*
  gated category beside **RGB step detection**. With it on, a still speck with no still neighbourhood —
  a stuck pixel, a flat patch in a noisy gradient — must vanish from the mask while a solid element
  keeps its. **Still neighbourhood density** is a typed field, not a slider, and must show its value as
  entered (a `ui_type = "input"` mismatch would draw a track instead); **Isolation radius** must be
  independent of **Mask grow radius**, so moving the growth alone must not change which specks are
  dropped, and the gate must work with the closing at `0`. Both are checkable off-GPU, and the probe
  does exactly that: it sweeps the two radii and the density, and holds every pixel of the two passes to
  the closed-form rule — keep what the closing grew, unless the still share of the box (itself counted)
  is under the density *and* no line through the pixel clears the line door. The count is of the
  shader's own still/moving reading, so the check that it is not a colour test is a still element with a
  hard internal edge — a boxed health bar, text on a plate — which must survive. Clearing the checkbox
  must give back exactly the mask the closing radius alone produces, which the probe's second check
  covers. The line door's own two properties are off-GPU too: **it can only rescue**, because the box
  share is still a first door, so over random screens every pixel the old gate kept is kept; and **no
  speck clears it**, since the floor never drops under 3, so a lone pixel, an adjacent pair and an L of
  three are dropped at every radius while a straight run of three is rescued where the floor is still 3.
  Its reach by stroke orientation is measured rather than assumed, because the README makes a claim
  about it: a one-pixel stroke along a row, a column or either diagonal is rescued at every radius, and
  the slopes between them only at the radii where the pixels they lay in an axis clear the rising floor.
- **The isolation filter's sliders interact with the closing, which a test run has to account for:** the
  gate judges the mask *after* the closing, and the luma bound stops the closing growing across a
  contour but not along it, so a one-pixel hairline is thickened along its own length into a band the
  closing's width. A test that wants to see the line door work therefore has to put **Mask grow radius**
  at `0` — at the default it changes nothing on a hairline, and the visible difference is a 2-px bar or
  a block's interior at a wide **Isolation radius** instead. Run the scenarios above at both closing
  settings, and the checkbox cleared at each must give back exactly the pre-change mask.
- **The closing's two passes share one luma plane.** `PS_DilateH` stores its centre luma in
  `texAutoDilate`'s `.a` and `PS_DilateV` bounds its taps by it, so the vertical pass no longer re-reads
  the back buffer for it. The consequence needs eyes: `texAutoDilate` is `RGBA8`, so a tap whose edge
  lands within a level of `AutoMaskEdge` can fall on the other side of it, and the vertical pass's growth
  can differ from the horizontal's by at most that. Sweep **Mask grow radius** `0`–`3` over anti-aliased
  text and one-pixel strokes: the boundary must still close the same glyphs, with no one-pixel gap
  opening at a contour that was closed before. At `0` there is no growth to compare, and the pass-through
  must be exactly as it was. The off-GPU half is the hash set: every entry point but `PS_DilateH` and
  `PS_DilateV` must be byte-identical.
- **The closing skips the frame taps its own radius excludes.** `PS_DilateH` samples the frame for a
  tap's luma only while that tap is within the grow radius; past it `keep` is zero by the same bound, so
  the sample would buy nothing. The mask is therefore **identical at every setting** — this is the
  property to check rather than the saving — and at **Mask grow radius 0** the loop still reads every
  accumulator tap for the isolation count, so the closing must produce exactly the mask the unguarded
  form did. Sweep grow `0`–`3` against **Isolation radius** 1–3 and confirm the mask does not change
  shape where the two radii differ. Only `PS_DilateH`'s hash may move.
- **The confidence view, the reading §5.5 asked for, and the answer it produced.** It is a per-pixel
  read of the accumulator, so it exists on the pixel path too: it must be
  selectable with the compute switch either way, and absent only with the diagnostics overlay compiled
  out. With the motion toggle off it must **draw two flat colours, not a ramp** — cyan where the verdict
  would already claim the pixel and magenta where it is earning but has not crossed — since a grade asks
  for shades to be compared. Its split must be the same line the verdict view greens at. **Nothing at or
  below zero may be tinted**, since the range a move's debt covers is wide and shading it made healing
  world read as a halo. It reads nothing in the mask, so toggling it must leave the mask and the final
  image identical. **Run in a game it showed a thin band over UI interiors and a much larger one over
  plain scenery with no interface in it**, in the dim, smoothly shaded parts. It is not the
  forgiving-deadband explanation this repo recorded first: at the `AutoMaskEps` default of `1` there is
  no band, and the scenery is **drifting below the comparison's resolution** — a whole level a frame is
  the comparison's unit and one frame is its baseline, so scenery sliding at a fraction of a level a
  frame reads as perfectly still and is credited. The checks that read it out, all of them existing
  settings: the motion view shows those pixels **black** (unchanged this frame); the corner marker stays
  solid magenta, so the premise is not flickering; sweeping **Frames a move is remembered** from `120`
  to `600` shrinks and then removes the band, because each level the drift does cross floors the whole
  patch; and the band's width tracks **Frames still before marked as interface**. A **longer Drift
  horizon makes it worse**, which is the channel feeding the world-drawn count rather than acting per
  pixel — the one reading here that points the other way, and the one to re-run first if the mechanism
  is ever reopened. Neither the premise, the move memory in its ordinary form, the clip exclusion nor
  either spatial rule addresses it: the clip voids a colour pinned at all 0 or 255, not one that is
  bit-still at some level in shadow, and the spatial rules test *shape*, which a band several pixels
  across passes.
- **Admission, the speck rule, in the panel and in the mask.** The checkbox ships off, so the mask with
  it clear must be **byte-identical** to the pre-change mask: the branch around the four taps is absent
  while the uniform is false. It lives as a single row of **AutoMask** rather than a gated category — it
  owns no second setting to hide — so after any move of the uniform, the row drawn as **Stop specks
  entering the mask** is what to look for, and a second **AutoMask** heading is the failure to look for.
  With it on: a lone still speck that the verdict would claim must be claimed *later*, not never, and a
  solid element must arrive at nearly its usual time once a couple of its pixels have landed — the
  interior has a neighbour and earns at the full rate. Its two properties are checkable off-GPU and
  were, in `tools/.work/neighbour_probe.py` (not committed), which mirrors the accumulator's arithmetic:
  with the rule clear both a lone and a supported pixel still cross the step at the rise (30 frames at
  the default), and with it set the supported pixel is unchanged while the lone one takes twice that
  (60). The taps are the four-neighbour cross on the verdict channel, so a still element with a hard
  internal edge must be unaffected. The same four taps are written into the pixel and compute
  accumulators, so the two paths must agree.
- **The mask rides the history's alpha, and the closing stores it.** The store pass and the map target
  are gone: `PS_DilateV` writes `float4(frame.rgb, mask)` into `texAutoHistory`, the restore reads the
  frame back off that alpha, and `PS_AntiBloom` takes the mask from the same. The pass list
  is the first check — `AutoMask` must show no `PS_Store` and `texAutoFrame`/`texAutoMap` must appear in
  no pass's targets — and the accumulator's history read must still compare against the frame, not the
  alpha that now neighbours it, so a mask that builds over scenery or fails to build over HUD is the
  `.rgb` read having been dropped. With the mask correct, the picture out of `AutoMask_Restore` has to
  be identical to the pre-change one over both HUD and world, since the restore's
  `lerp(live, stored, mask)` was the same expression before. The off-GPU half is the hash set:
  `PS_DilateV`, `PS_Restore` and `PS_AntiBloom` are expected to move, and `PS_DilateH` and `CS_Accum` are
  the ones that should not.
- **The depth store rides the closing.** With `AutoMaskDepthMotion` on, `PS_DilateV` writes `texAutoDepth`
  as a second target instead of a `PS_StoreDepth` pass: the pass list must show the store gone with the
  depth still bound on the closing, and the depth variants are a pass shorter. The behaviour to check is
  that the world-drawn premise still reads the previous frame's depth — a scene where depth moves has to
  keep the world reading as drawn, and a still one must not — since the store landing in a different pass
  is only correct if the accumulator still reads before the write. The off path must be untouched: the
  `AutoMaskDepthMotion=0` variants are byte-identical, and in the depth variants only `PS_DilateV` moves
  and `PS_StoreDepth` is gone.
- **`texAutoAccumA` narrowed to `RG16F` under compute.** `A` is written only as a render target
  (`PS_DilateH`'s `SV_Target1`) and every reader wants `.r`/`.g`, so it is `RG16F` wherever
  `AutoMaskCompute == 1`. `texAutoAccumB` deliberately does **not** follow, and that is the part to leave
  alone: `B` is written through `tex2Dstore`, whose overload set is only
  `int`/`int4`/`uint`/`uint4`/`float`/`float4`, so `storage2D<float2>` has no matching intrinsic and
  ReShade rejects the effect at load with X3004. The offline check is blind to the whole thing: a
  target's `Format` is an annotation that `strip_for_fxc` drops before fxc sees the source, and
  `tex2Dstore` is rewritten to `s[coord] = value` before compiling, so **no hash moves and no bad store
  is refused** (`docs/performance_compute.md` §3). The in-game check is therefore the only one: with
  compute on, a scene must produce the same mask it did at `RGBA16F` — a mask that differs is `A` having
  dropped a channel a reader wanted — and the pixel path (`AutoMaskCompute=0`) must be unchanged, since
  `A` stays four wide there.
- **The measured step's guarded fetch.** The step is read once per pixel by `CS_Accum`, so the branch is
  a per-pixel saving on the compute path and nothing else. Off-GPU the check pins the blast radius: only
  the four compute variants' `CS_Accum` may move, and the pixel path must be untouched, since the
  measured step does not exist there. In a game the behaviour to watch is the auto-deadband itself:
  **the same scene with `Auto-Detect RGB Step` on must settle on the same step as before the change**,
  and the mask must be identical with the toggle off, which is the path that now takes the `else` branch
  and issues no sample at all. A step that settles differently, or a mask that changes only while the
  toggle is on, is the fetch and the slider having crossed wires.
- **The anti-bloom pass, which ships on.** `PS_AntiBloom` blacks the masked pixels in the live frame for
  a bloom pass downstream, and the restore puts the real pixels back, so the final picture must be
  identical with the pass compiled in or out — the toggle changes what a downstream pass sees, not what
  the user gets. A picture that differs with the switch off is the restore having lost its source.
