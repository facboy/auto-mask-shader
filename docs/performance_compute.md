# Performance: the compute and depth paths

What the two configurations that ship off cost when they are on. Both default to `0` because they need
a device or a depth buffer, not because they are worse: `AutoMaskCompute=1` is the more accurate mask
and `AutoMaskDepthMotion=1` is the better witness where depth is available, so a player who can run them
runs them. `docs/performance.md` measures the shipped pixel default; this is what differs off the same
compiled bytecode, and the openings that measurement leaves. §2's depth-only branch and §3's narrowing
are both built.

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

## 3. `texAutoAccumA` narrowed to `RG16F` under compute

With `AutoMaskCompute=1` and `AutoMaskDiagnostics=0`, the pair is wider than anything reads. `texAutoAccumB`'s
four channels:

| channel | written as | readers |
| --- | --- | --- |
| `.r` | confidence | `PS_DilateH` centre and tap, the accumulator next frame |
| `.g` | hold | the accumulator next frame (through `PS_DilateH`'s carry to A) |
| `.b` | motion | `CS_Tile` and `PS_DebugMap` — diagnostics only |
| `.a` | 1.0 | **none** — the eligible flag is `PS_Motion`'s, which does not exist under compute |

`.b` is written for `PS_Motion`, which the switch removes, and its only readers are the two diagnostics
passes, both compiled out unless the overlay is on. `.a` is `PS_Accum`'s eligible flag, read only by
`PS_Motion`; `CS_Accum` stores a constant `1.0` there and nothing reads it — the count that flag exists
to divide is carried in the atomics instead. `texAutoAccumA` is the same picture without the diagnostics
qualifier: it is written only as render targets (`PS_DilateH`'s verbatim `carry = centre`), and every
reader wants `.r`/`.g` alone — `prev.r`/`prev.g` and the four admission taps, which test `.r`. That holds
with the overlay on as well, since the tile map and the debug map read `B`, never `A`.

**`B` cannot be narrowed, and the reason is the dialect rather than the arithmetic.** ReShade's
`tex2Dstore` is declared for exactly six storage element types — `int`, `int4`, `uint`, `uint4`, `float`,
`float4` — and there is **no two-component form**. `B` is written only through that intrinsic
(`AutoAccumStore`, a `storage2D`), so a `float2` store cannot be expressed at all; the first attempt at
this change declared `storage2D<float2>` and ReShade rejected the effect at load with X3004,
`undeclared identifier or no matching intrinsic overload for 'tex2Dstore'`. **This is a case the offline
check cannot catch**: `strip_for_fxc` rewrites `tex2Dstore` into `s[coord] = value` before fxc sees it
(`docs/verification.md`), so the store's element type is never validated against ReShade's overload set
and every variant compiles clean either way.

**`A` is a different case, and it is narrowed.** A store overload only constrains what is written through
a `storage2D`, and nothing writes `A` that way, so `RG16F` is expressible for it: declared under
`AutoMaskCompute == 1` and `RGBA16F` on the pixel path. The guard is the compute switch rather than the
pair's channel arithmetic because it is also the portability line: compute means D3D11 or Vulkan, where
`R16G16_FLOAT` is a hardware-required render target, while the pixel path is what a D3D9 or D3D10 device
runs and is left exactly as it was. That is half the pair: ~14.7 MB against ~29.5 MB for the one target,
and ~59 MB a frame against ~118 MB at 1440p, since each target is read and written twice a frame. The
remaining ~29.5 MB sits in `B`, held wide by the missing `float2` store.

Two facts the check cannot see either, read from the vendor tables instead: `R16G16_FLOAT` supports
`RenderTarget`, `Typed UAV` and `UAV Typed Store` as **hardware-required** at D3D11.0 — the same class as
`R16G16B16A16_FLOAT`, which `A` already used — and it is a storage-image format on Vulkan, where the
shader also runs. Nothing reads `A` as a typed UAV (it is sampled through its SRV), so the D3D11.1
typed-load floor the compute path documents is untouched.

The check's own limit is the point of the entry: a target's `Format` is an annotation, `strip_for_fxc`
drops annotations before fxc sees the source, and a `Format = BOGUSFORMAT` was measured to pass the whole
suite — **no hash moves at all** for this change and the bytecode cannot testify to it. The vendor tables
above and a game are the evidence instead.

## 4. Not openings

- **The pinned-colour count.** `AutoMaskClipped` is four `eq` groups of three `and`s each, twelve
  operations at most, and it is tempting on the compute path because `.a` is a channel nothing reads
  there (§3). It is not removable: the count feeds `stable` and the changed/active tally on both paths,
  so it is recomputed either way — republishing it would store a value nothing reads, which is the dead
  store §3 describes rather than a saving.
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
- §3's landed narrowing is the one the check cannot see **at all**: `A`'s `Format` is an annotation,
  `strip_for_fxc` drops annotations before fxc sees the source, so its `RG16F` declaration is invisible
  to the bytecode and **every hash stays identical** — unlike §2, this change is not pinned by the check
  in either direction. The format's support was read from the vendor tables instead (§3), and the check
  cannot refuse a bad storage element type either, since it rewrites `tex2Dstore` before compiling; that
  is how the `storage2D<float2>` attempt reached a game. A game is the only confirmation of the swap.

Neither is observable offline beyond the hashes. Whether a depth-only branch reads the same scene the same
way, or whether a narrower accumulator leaves the compute gate and the tile map intact, needs the overlay
on a game — `docs/verification.md` lists the scenarios, and an agent cannot run one.
