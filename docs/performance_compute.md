# Performance: the compute and depth paths

What the two configurations that ship off cost when they are on. Both default to `0` because they need
a device or a depth buffer, not because they are worse: `AutoMaskCompute=1` is the more accurate mask
and `AutoMaskDepthMotion=1` is the better witness where depth is available, so a player who can run them
runs them. `docs/performance.md` measures the shipped pixel default; this is what differs off the same
compiled bytecode, and the openings that measurement leaves. Only §2's depth-only branch is built.

Companions: `docs/performance.md` (the default path's measured cost, and the bytecode method),
`docs/compute-path.md` (what the switch swaps in), `docs/core-model.md` (the depth witness),
`docs/verification.md` (the check, and what an offline compile cannot see).

## 1. Where the cost sits

`uv run tools/verify_shaders.py check --opcodes` at 2560×1440, static slots per entry point:

| entry point | variant | slots |
| --- | --- | ---: |
| `CS_Accum` | compute | 196 |
| `CS_Accum` | compute + depth | 257 |
| `PS_Accum` | pixel | 93 |
| `PS_Accum` | pixel + depth | 152 |
| `PS_DilateH` | compute | 56 |
| `PS_DilateV` | compute + depth | 72 |
| `CS_Finish` | compute | 66 |

Three facts follow, and none is in `docs/performance.md`:

- **The depth switch adds 61 slots to `CS_Accum` and 59 to `PS_Accum`.** The block is the size of the
  rest of `PS_Accum` put together. `docs/performance.md` §1 records that the accumulator's static count
  moves under a switch (152 against 93) but not what the block does; §2 is that.
- **On the compute path the accumulator is the heaviest full-resolution pass, not the closing.** `CS_Accum`
  196 against `PS_DilateH` 56 and `PS_DilateV` 72. The closing is the heaviest pass on the pixel default
  (`docs/performance.md` §1), and the switch moves that title to the accumulator.
- **The compute path has no reduce passes at all.** `PS_Motion` (27) and `PS_MotionAvg` (24) are replaced
  by `CS_Accum`'s in-pass tally and `CS_Finish` (66); the technique is `CS_Accum`, `CS_Finish`, the two
  closings, and the optional tile and overlay passes.

## 2. The depth witness is per-pixel reconstruction, its picture ramp now skipped

With `AutoMaskDepthMotion` on, both accumulators run the same block: `ReShade::GetLinearizedDepth` at the
pixel and at each of its right and lower neighbours (three buffer fetches), `tex2Dlod(AutoDepth, …)` for
the previous frame's depth, three `AutoMaskCamPos` calls — each building a ray and dividing the depth by
that ray's length — a `cross`/`normalize`/`abs` for the surface normal, and `AutoMaskDepthMoved` on the
centre pair. That is the 59–61 slots. It runs at full resolution, in the pass that is already the
heaviest on the compute path, and `docs/performance.md` never measures it — its §1 table covers the
closing's loop and the accumulator's static count only.

Three things in the block are worth arguing, and one of them is now built:

- **`AutoMaskDepthOnly` used to override the colour grading rather than skip it — now it skips.** `motion`
  was written as `AutoMaskDepthOnly ? AutoMaskDepthMoved(...) : max(motion, AutoMaskDepthMoved(...))`, so
  the picture's own ramp and the drift comparison's were computed either way and the `max` discarded them
  when the tick was on; fxc flattens that small a body to a `movc`, so a plain `if` did not help. Both
  accumulators now build the ramp inside `[branch] if (!AutoMaskDepthOnly)`, which is the one directive
  fxc honours as real flow control, and the tick skips it. The rest of the block is not skippable —
  `maxDiff` still feeds `stable` and next frame's average, `maxDrift` still feeds `stable`, and both
  still feed the histogram — so the saving is the ramp, not the block. `docs/performance.md` §11 is the
  landed account.
- **The orientation is inherent, not folded.** `AutoMaskDepthInvariant` decides up-facing from the two
  neighbour depths, and `AutoMaskCamPos`' ray direction is `texcoord`, so both the direction and its
  length vary per pixel — there is no read of the centre alone that answers it and nothing to hoist.
- **The ray lengths vary with the pixel.** A `sqrt` and a `div` per `AutoMaskCamPos` call look hoistable
  and are not: `offset` is `texcoord`, so the three ray lengths differ per pixel. The only constants are
  `halfAngle` and the two buffer offsets.

The honest reading of the depth block is therefore that it is ~60 slots doing a real per-pixel job. The
depth-only branch is the one saving with a clear shape, and it is landed: it costs one static slot on
each depth accumulator and skips 7 instructions a pixel on the pixel path and 14 on the compute path,
but only while the tick is on. Everything else in the block is a real per-pixel job.

## 3. Two accumulator channels are dead under compute without diagnostics

With `AutoMaskCompute=1` and `AutoMaskDiagnostics=0`, `texAutoAccumB`'s four channels are read by:

| channel | written as | readers under compute, diagnostics off |
| --- | --- | --- |
| `.r` | confidence | `PS_DilateH` centre and tap, the accumulator next frame |
| `.g` | hold | the accumulator next frame (through `PS_DilateH`'s carry to A) |
| `.b` | motion | **none** — `CS_Tile` and `PS_DebugMap`, both diagnostics-only |
| `.a` | 1.0 | **none** — the eligible flag is `PS_Motion`'s, which does not exist under compute |

`.b` is written for `PS_Motion`, which the switch removes, and its only readers are the two diagnostics
passes (the tile map's `wide` reading and the debug map's `changed`), both compiled out unless the
overlay is on. `.a` is `PS_Accum`'s eligible flag, read only by `PS_Motion`; `CS_Accum` stores a constant
`1.0` there and nothing on the compute path reads it — the count that flag exists to divide is carried in
the atomics instead. So on the configuration a compute player actually runs, half the accumulator's
channels are written every frame and read by no one.

That makes the accumulator pair **narrower than `RGBA16F` where nothing reads the two dead channels**: an
`RG16F` pair would carry `.r` and `.g` and halve the pair from ~59 MB to ~29.5 MB at 1440p, with its
per-frame traffic halved with it — the same size saving as the drift store's re-centring
(`docs/performance.md` §10), on the pair that is four full-resolution touches a frame.

The catch is the guard, and it is why this is written as a question rather than a change. The target is
declared once and shared by both paths, and the pixel path needs all four channels (`.b` for `PS_Motion`'s
changed reading, `.a` for its eligible one); the compute path needs `.b` back whenever
`AutoMaskDiagnostics` is on. So the narrower declaration applies to `AutoMaskCompute == 1 &&
AutoMaskDiagnostics == 0` alone, which is a third state the two existing guards do not describe, and the
check's variant matrix would have to cover it. That is a definition-shaped decision — a target's format
is not a live setting — and it belongs with the tile map's own guard, since the tile map is the only
thing that reads `.b` on the compute path.

## 4. Not openings

- **The pinned-colour count.** `AutoMaskClipped` is four `eq` groups of three `and`s each, twelve
  operations at most, and it is tempting on the compute path because `.a` is a free channel (§3). It is
  not removable: the count feeds `stable` and the changed/active tally on both paths, so it is recomputed
  either way — republishing it into `.a` would store a value nothing reads, which is the dead store §3
  describes rather than a saving.
- **The atomics.** `CS_Accum`'s `atomic_iadd` calls are per group, not per pixel, and the histogram's are
  gated on the toggle. `docs/compute-path.md` argues the histogram's few-dozen-byte targets against the
  1 KB they replaced; nothing there is worth revisiting.
- **`CS_Finish`.** 66 slots, one thread, 1×1 — a fixed cost the frame pays once. It is the replacement for
  two reduce passes and is not a candidate for folding.
- **The drift pair.** Re-centred into half precision (`docs/performance.md` §10); the remaining cost is
  the two full-resolution targets and their four touches, which is the price of the channel, not a fold.
- **Reaching across the guards.** Every item in §2–§3 sits behind the depth or the compute guard, so the
  shipped pixel default is untouched. A change that reached past that line would be a change to the
  default path in its own right and would need its own justification — not because the bytecode would
  move, but because the default's behaviour would.

## 5. How to verify a change here

`uv run tools/verify_shaders.py check --hashes --opcodes`, before and after. The evidence wanted is
narrower than on the default path:

- §2's landed branch must move only the eight `*-depth` variants' `CS_Accum` and `PS_Accum`, and leave
  `PS_DilateH`, `PS_DilateV` and every non-depth entry point hash-identical. It does: the two accumulators
  gain one static slot each and nothing else's hash moves.
- §3's edit is the one the check cannot fully see. `strip_for_fxc` rewrites the compute dialect before
  `fxc` sees it (`docs/verification.md`), and the accumulator's store is a `tex2Dstore`; a narrowed
  target would have to be checked against ReShade's own parser and the variant matrix extended to cover
  the compute-diagnostics-off state, not inferred from a passing compile.

Neither is observable offline beyond the hashes. Whether a depth-only branch reads the same scene the same
way, or whether a narrower accumulator leaves the compute gate and the tile map intact, needs the overlay
on a game — `docs/verification.md` lists the scenarios, and an agent cannot run one.
