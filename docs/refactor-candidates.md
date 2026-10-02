# Refactor candidates

Where `Shaders/AutoMask.fx` and `tools/verify_shaders.py` said the same thing twice, the fold each took,
and what is deliberately not a candidate. **None of it changes what the shader or the check does.**

## 1. What a candidate has to clear

- **Identity is the evidence, not an opinion.** `uv run tools/verify_shaders.py check --hashes
  --opcodes` is run before and after each fold, and every entry point's bytecode sha256 and instruction
  count must come out **identical**. There is no committed baseline, so the before-run is the baseline.
- **An instruction count may not rise.** HLSL inlines a function by default, so a helper is not expected
  to cost a call — but register allocation and scheduling can still move, and the full-res accumulator is
  the pass where it would matter. `--opcodes` on `CS_Accum` and `PS_Accum` is where that shows.
- **A construct the check cannot judge is not free.** `strip_for_fxc` rewrites the compute dialect before
  `fxc` sees it, so a clean compile says nothing about a `groupshared` array passed to a function, or a
  macro that hides a `barrier()`. `docs/verification.md` names the blind spot; anything in it has to be
  read against ReShade's own parser rather than inferred from a passing check.
- **Comment budget.** Any comment touched counts against `COMMENT_BLOCK_MAX` (4 lines), so a block
  already at the limit cannot be wrapped further.

## 2. Landed — the two accumulators, and the reads around them

`CS_Accum` and `PS_Accum` were the same state machine written twice, differing only in how a sample is
spelled (`tex2Dlod` with an explicit level against `tex2D`) and in the drift channel the compute path
alone has. The duplicated parts now live as functions in `Shaders/AutoMask.fxh` (more joined them
below):

| helper | folds |
| --- | --- |
| `AutoMaskDrawn(share)` | the premise, previously stated five times in two spellings |
| `AutoMaskDecay(conf, held, stable, drawn, earn, cost)` | the hold, the credit, the bridge and the banked debt |

Each takes what it needs **already sampled**, so neither path's sampling form moved onto the other's. The
drift terms stay behind `#if AutoMaskCompute == 1` in the `.fx`, because its ramp and the two extra rail
comparisons are the compute path's alone and the pixel path is documented as having no drift pass.

`AutoMaskPublished(uv)` was folded here too, but has since been moved back into `AutoMask.fx` beside
`PS_AntiBloom`, its only remaining caller: it samples (`tex2D(AutoHistory, uv)`), which the header's
helpers do not, and `PS_Restore` and `CS_Tile` now read the history alpha inline from a fetch they
already make. It is the same test the drift terms fail — a helper with one consumer is naming rather than
a fold — so it belongs in the `.fx`.

A second reading, of the shader against its header and its two closing passes against each other,
folds the values each site was deriving for itself:

| helper | folds |
| --- | --- |
| `AutoMaskDeadband()` | `max(ceil(AutoMaskEps), 1.0)` at the verdict, the walk's fallback and the walk's floor |
| `AutoMaskClipped(now, before)` | the pinned-colour count, with the compute path's two drift terms added at its call site |
| `AutoMaskRate(frames)` | the `0.504 / max(slider, 1.0)` pair, one copy for `AutoMaskRise` and `AutoMaskFall` |

`AutoMaskClipped` returns `int`, not `float`: as a float the helper's `all()` terms summed in integer and
the total was converted, which reordered `iadd`/`itof` against `and`/`add` in `CS_Accum` and moved its
hash — returning `int` restores the assembly exactly.

The closing passes' luma and edge test is a fold of the same kind but **not** verdict arithmetic, so its
helpers sit at file scope in `AutoMask.fx` beside the two passes: `AutoMaskLuma` holds the one copy of the
`float3(0.299, 0.587, 0.114)` literal, and `AutoMaskEdgeKeep(luma, lumaCentre, inRange)` the one copy of
the luma bound. It takes the luma and the range already computed rather than the sampled colour: a helper
taking the colour left the tap's sample and the index comparison free to swap in fxc's schedule, so
`PS_DilateH` and `PS_DilateV` hashes moved with their instruction counts unchanged. Passing both keeps the
assembly byte-identical.

The header is a deliberate exception to "one self-contained file", and a narrow one: it holds **code** and
nothing else — no uniform, `texture`, `sampler` or technique — so it changes nothing about the panel, the
targets or the bytecode. The ban that remains is on **authored data** in a file, which is what would be a
usability regression. Three things follow, and none is optional: the include sits **after** the uniforms
and targets its helpers read, because the dialect has no forward declaration; the check copies the `.fxh`
into `tools/.work/` and holds it to the comment budget alongside the shader; and `README.md` says both
files are installed together. `AGENTS.md` carries the rule and `docs/verification.md` the check side.

Left in place on purpose: the accumulator's other arithmetic, because folding it would need a helper to
sample or to take four more arguments, and the two paths' opcode counts are the point. The accumulator's
`stable` is a float used in arithmetic later in `CS_Accum`; the helper only ever tests it, so the
conversion is at the call site and the accumulator's own uses are untouched.

## 3. Considered and left

- **The three grid relaxations in `CS_Tile`.** `tileLabel`, `tileWide` and `tileHole` are one relaxation
  written three times, differing only in the combine op (`min` against `max`) and the sentinel guard.
  Folding it means passing a `groupshared` array to a function or hiding a `barrier()` in a macro, and
  both are exactly the dialect constructs §1 says this check cannot judge. The round count and the
  barrier placement are what keeps each reading exact, so a mis-translation is a wrong reading rather
  than a compile error. The histogram's dynamically indexed `groupshared` array is the precedent: that
  was settled against ReShade's parser, not against a passing `check`.
- **The five-bar block in `PS_Restore`.** An `if`/`else if` chain mapping a slot to a value and a colour.
  `static const float3 BARS[5]` indexed by the slot would shrink it, but that is a runtime-indexed const
  array, the same class of construct as above.
- **`PS_Motion`/`PS_MotionAvg`.** They look like a candidate against `CS_Accum`'s tally and are not: they
  are the pixel path's replacement for it, one of the two is a 1×1 reduce whose taps are its whole body,
  and the pair is what makes the `AutoMaskCompute = 0` hashes meaningful.

## 4. Landed — `tools/verify_shaders.py`

- **The `fail(why)` fold, completed.** The exit-and-print prefix was written out at ten guard sites when
  the helper landed, and five runtime guards were missed — `technique_bindings`' three parse cross-checks
  and `cmd_check`'s two missing-data guards. All five call `fail(why)` now and print the same text, so the
  prefix is written in one place and the import-time duplicate-variant guard is the only `sys.exit` left
  (it runs before the helper is defined).
- **`report_hits(label, hits, advice)`.** The docs check printed its two hit lists with the same six
  lines twice; both now go through it, and the "a hit is a failure" decision is in one place.
- **`rewrite_calls(text, pattern, render)`.** `translate_atomics` and `translate_storage_access` were the
  same scan — find a call, read its arguments by balancing parens, emit something else — differing only
  in the emitted text. The walk is one function now and each caller supplies a `render(match, args)`.
- **`without_comments(text)`.** `re.sub(r"//[^\n]*", "", text)` stood at seven sites — the include scan,
  the two misspelled-dialect guards, the denied-intrinsic guard, the last line of
  `drop_comments_and_strings`, the storage-index guard and the technique reader — with the "comments
  dropped so prose cannot trip the guard" reason restated at most of them. One helper holds the strip and
  one docstring holds the reason; `drop_comments_and_strings` blanks strings ahead of calling it.
- **The module's prose stays.** The docstring and the per-guard comments are most of the file's lines and
  are the account `docs/verification.md` points at, so a "shrink" of them would be a loss rather than a
  tidy.

## 5. Left alone

The same reading that took the folds above found these, and left each because the body is smaller than
the ceremony around it:

- **The `motion`/`stable` grading.** Only the un-drifted half is shared, and folding it means handing the
  compute call site a partly-built value back to recombine with its ramp — call-site surgery that can
  move instructions, on the full-res accumulator, for one line.
- **The admission cross.** The four taps differ only in how the sample is spelled, so only the
  `support < 0.5` tail folds, and it folds to one line.
- **The two radii and the changed threshold.** `floor(AutoMaskDilate + 0.5)`,
  `max(floor(AutoMaskIsolation + 0.5), 1.0)` and `step(0.001, …)` are real pairs with bodies too small to
  name, so they are worth taking only alongside one of the folds above.
- **Naming the 0.5 verdict step.** It is written as `step(0.5, …)` across `AutoMaskPublished`, both
  accumulators, both closing passes, the tile sampler and the debug map — a documentation gain only, which
  is the constant-merging §6 already refuses.
- **`float2 texel = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)` in `CS_Accum`** where the pixel path
  writes `BUFFER_PIXEL_SIZE`: one value, two spellings, nothing else.

Nothing in that reading reopens §3: the three `CS_Tile` relaxations, the `PS_Restore` bar block and the
`PS_Motion`/`PS_MotionAvg` pair stand as argued.

## 6. What is not a candidate

- **The named constants cannot be merged.** `AUTOMASK_STEP_MAX`, `AUTOMASK_DRIFT_LAG`, `AUTOMASK_AXIS_MIN`
  and the reset's `max(deadband, 8.0)` are each deliberately not tied to the neighbouring constant —
  `docs/editing-conventions.md` argues each case — so unifying two of them is a behaviour change wearing
  a tidy's clothes.
- **No uniform moves between categories, and no two categories merge.** The panel layout is a contract:
  a gated category has to open with its own gate, and a category named twice draws two headings. Order in
  the uniform list is otherwise unobservable and can be left alone.
- **No folding of a guarded pass into a shared function.** A feature with a pass, a shader or a target
  keeps its definition; a branch inside a pass keeps its live checkbox. A shared helper that spanned
  those guards would allocate what the guard exists to elide. The header's helpers span only
  `AutoMaskCompute`'s *drift terms*, which stay in the `.fx` for that reason.

## 7. How a step was, and is, verified

- `uv run tools/verify_shaders.py check --hashes --opcodes`, run before and after against the step's own
  before-run: all 82 entry points' hashes and instruction counts came out identical.
- `uv run tools/verify_shaders.py check-docs`, since every shader comment touched counts against the
  block budget.
- For `tools/verify_shaders.py`, a scratch copy of the tree exercised every loud-failure case
  `docs/verification.md` lists and each still exits non-zero with the same message. With the header
  added, one case more: the `.fxh` deleted from `Shaders/` **after a passing run**, so a copy left in
  `tools/.work/` is there to be resolved against — which is why the workspace is emptied of files this
  repository does not have.
- A review pass over the diff, because the check cannot see whether a helper kept the same meaning, and
  the scenario in `docs/verification.md` that owns the touched code still needs a game.
