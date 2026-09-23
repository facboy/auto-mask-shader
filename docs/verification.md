# Verification

How this project is verified and how the offline check is exercised. Extracted from `AGENTS.md`; read
this when a change touches `tools/verify_shaders.py`, adds a shader entry point or dialect spelling, or
when you need the detailed failure-mode list before committing a change to the check.

Nothing here is automatically testable, so verification is a review pass plus an offline compile
check:

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
- **A warning is a failure, not a note.** ReShade prints every warning its compile emits into the log the
  user reads at load, so shipping one is shipping an unreadable log — which is how a real warning gets
  missed. `check` therefore reports a warning entry as `WARN` and exits non-zero on it. The one exception
  is `X3579` (`ps_5_0 does not support groupshared, groupshared ignored`), which is the harness's own
  artefact rather than the shader's: the whole preprocessed file is compiled once per entry point, so fxc
  sees the compute path's file-scope `groupshared` tally while compiling a *pixel* entry point, where
  ReShade — emitting one pass's shader from that pass's reachable code — does not. The game's log carrying
  no such warning is what says the cause is the harness, so it is filtered on the reported code (this
  `fxc` rejects `/wd`: `Unknown or invalid option`) and nothing else is. Exercise the gate by hand before
  committing a change to it: put the construct below back and it must exit non-zero naming the code.
- The shader is written so that `check` is silent, and the rewrite below is the *only* thing that silences
  its code — do not "tidy" it back into the warning shape. A `clipped` accumulator declared `float3` makes
  `clipped == 0.0` a three-wide test whose `&&` truncation is X3206, so it is a `float` (the `all()` answer
  is one value, not one per channel). It is an outright bug in the log rather than a cosmetic preference.
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
  `RWTexture*` before fxc sees them, so a keyword ReShade would reject compiles in the check regardless.
  That already bit: a lowercase `storage2d` passed every variant and failed in ReShade with a bare X3000
  pointing at the line rather than the case, and because the bad declaration dropped its target, two
  further X3004 errors followed from it. The dialect keywords are therefore pinned to ReShade's own lexer
  — `storage`, `storage1D`, `storage2D`, `storage3D` with a **capital** dimension letter, and those four
  only — and a near-miss is a loud failure rather than something to rewrite. Exercise it by hand with the
  file changed back to the lowercase spelling before committing any change to the translation.
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
  overload`). It reached a game once — written into a wrap around an integer, it passed every variant
  here and then failed to load — so the names `fxc` has and ReShade's own table does not are refused
  outright, that set being read from `source/effect_symbol_table_intrinsics.inl` rather than guessed: it
  is a deny set, so an ordinary identifier is never mistaken for a missed intrinsic, and a shader that
  defines its own function of one of those names is still allowed to call it. ReShade does provide
  `frac`, `floor`, `round`, `saturate`, `lerp`, `smoothstep`, `step`, `mad` and the `tex2D*` family — the
  whole vocabulary this shader uses — so a wrap around an integer is `%` rather than `fmod`. Exercise it
  by hand with `fmod` put back before committing a change to that guard.
- `pyproject.toml` lives in `tools/`, not at the repo root: this is a shader project, and `uv run`
  discovers the project by searching upward from the script, so the root-level command above works.

## The toolchain, which is not obvious

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

## End-to-end scenarios that need a game

**Real end-to-end testing means loading both techniques in ReShade in a game**, which an agent cannot
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
  of frames rather than staying blank for the horizon. The same pan at `AutoMaskEps = 1` is the direct
  check on the decoupled reset: before the fix the motion view showed the sky clean at *every* horizon
  position, so a horizon that now changes what the motion view shows is the channel working and one
  that changes nothing is it having stopped again. The third is a HUD that does not move but does
  flicker — a static element with temporal anti-aliasing on it — which must not be evicted by the
  channel at the default horizon; if it is, the horizon is what to shorten, and a step of a couple of
  levels is the shape of flicker that needs the horizon shortened rather than the RGB step raised.
- The auto-deadband's pair, both on the compute path: the same scene with the toggle on and off, and
  the step the measurement settles on should sit above the dithering the overlay shows as red without
  losing movement you can see — with the toggle off it must match the manual slider exactly, slider
  value and all. The third is a fully live frame — pan across detailed scenery with auto-detect on —
  where there is no quiet majority to measure and the slider's own value is what must govern, so the
  mask cannot start forgiving real motion just because the camera is moving.
  Two of this feature's properties are checkable off-GPU and should be re-checked that way after any
  change to the histogram, rather than looked for on screen. **The reading must be unchanged by how the
  bins are counted**: the walk's answer for the reduced 8-bin groupshared tally must be identical to the
  256-bin per-pixel one for every distribution a frame can produce, which a scratch probe
  (`tools/.work/`, not committed) confirms by mirroring both readings statement for statement over
  20,000 synthetic frames — 0 mismatches. **The dialect must accept the tally**: because
  `strip_for_fxc` rewrites the dialect before fxc sees it, a clean compile says nothing about whether
  ReShade takes a dynamically indexed `groupshared` array or an `atomicAdd` on one, so that was checked
  against ReShade v6.8.0's own parser and codegen instead, which emits
  `groupshared uint V__groupHist[8];` and `InterlockedAdd(V__groupHist[bin], 1u, _res)`. Both are the
  same probes the storage-keyword failures needed, and the same rule applies: a construct this check
  cannot judge has to be verified against ReShade's source, not inferred from a passing compile.
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
