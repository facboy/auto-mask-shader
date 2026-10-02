# Performance: the diagnostics build

What `AutoMaskDiagnostics=1` costs when it is on, read off the compiled bytecode. The switch ships at
`0`, but the on-build is a shipped variant rather than a retired one: ReShade exposes the definition in
the UI, so anyone can compile the overlay in, and that build pays for the readings every frame it runs.
`docs/performance.md` measures the default path, `docs/performance_compute.md` the compute and depth
paths, and neither tabulates the overlay.

Companions: `docs/performance.md` and `docs/performance_compute.md` (the other paths, and the bytecode
method), `docs/compute-path.md` (the tile map's design and why it rides the compute guard),
`docs/core-model.md` (the readings the views draw), `docs/verification.md` (the check, and the scenarios
that need a game).

## 1. Where the cost sits

`uv run tools/verify_shaders.py check --opcodes`, static slots and back-buffer taps per entry point, at
2560×1440. The overlay adds nothing to `AutoMask` — no pass and no target — and grows `PS_Restore`,
plus `CS_Tile` where the compute path is on too:

| variant | entry point | slots | samples |
| --- | --- | ---: | ---: |
| `diagnostics` | `PS_Restore` | 40 (8 without) | 4 (2 without) |
| `diagnostics-compute` | `PS_Restore` | 78 (8 without) | 7 (2 without) |
| | `CS_Tile` | 236 | 3 |
| `diagnostics-depth` | `PS_Restore` | 89 (8 without) | 7 (2 without) |
| `diagnostics-compute-depth` | `PS_Restore` | 126 (8 without) | 10 (2 without) |
| | `CS_Tile` | 236 | 3 |

Three facts, all read from the report and the `.asm`:

- **The overlay owns no pass and no target.** It reads the accumulator and the 1×1 `MotionStat` inside
  `PS_Restore`'s `#if AutoMaskDiagnostics` block, so the tint is drawn in the pass that already writes
  the frame. On the pixel path that is two extra taps — `AutoAccumB` and the 1×1 `MotionStat` — and on
  the compute path three, the third being `texAutoTileKind` for the tile view. The depth normals probe
  is the largest block: 89 slots and seven taps with the depth switch on, 126 and ten with compute as
  well.
- **The overlay adds one full-resolution tap to `PS_Restore`.** `PS_Restore` is 8 slots and two taps
  (`BackBuffer`, `AutoHistory`) without the overlay, and 40 and four with it: the per-pixel tint's fetch
  of `texAutoAccumB` and the corner marker's read of `MotionStat`, which is one texel. On the compute
  path it is 78 and seven, the two extra being the tile class fetch and the bar readings from the 2×1
  `texAutoTileStat`, behind `UIDebugTile`'s uniform branch.
- **`CS_Tile` is a fixed cost, not a per-pixel one.** 236 slots, but a single `AUTOMASK_TILE_GRID`²
  thread group with a 1×1 dispatch and three taps a cell. Against a full-resolution pass it is small, and
  it exists only where the compute and diagnostics switches cross.

The overlay's own frame, on the pixel path, is therefore ~29.5 MB of traffic the default path does not
move: the restore's read of `texAutoAccumB`, one full-resolution fetch a frame. The corner marker's read
is one texel. Against a default path of five full-resolution passes and four targets, the overlay is no
pass and no target.

## 2. The map pass, folded into the restore

`texAutoAccumB` is written by the accumulator, the first pass of the frame, and never rewritten — the
closing writes `texAutoAccumA`, the history, the drift pair, the depth and `texAutoDilate`, never `B`.
`MotionStat` is written by `CS_Finish` or `PS_MotionAvg`, both before the closing. `texAutoTileKind` and
`texAutoTileStat` are written by `CS_Tile`, which is itself before the restore. And the depth buffer is
available to any pass. Every source the overlay reads is therefore still valid when `AutoMask_Restore`
runs, and `PS_Restore` binds no render target — it writes the back buffer — so it samples none of them
while writing.

That is what the inline uses. The readings are built in the restore's `#if AutoMaskDiagnostics` block
rather than packed into a target by a pass of its own, so for every diagnostics-on frame the map pass and
its target are gone:

| pixel-path build | before | after |
| --- | --- | --- |
| full-resolution passes | `PS_DebugMap` | none |
| `texAutoDebug` | allocated, 14.7 MB, written and read | gone |
| traffic | ~59 MB/frame | ~29.5 MB |
| taps across map + restore | 6 | 4 |

The restore's tap count does not rise above what the map plus restore took: the map's two fetches of its
own target are replaced by one fetch of `texAutoAccumB` and one of `MotionStat`, which is what the map
read for the tint and for the marker. The compute path holds the same way: the map's three taps join the
restore's six, nine in all, and land as seven on one pass.

Two behaviour deltas come with the fold and need eyes on a game rather than the check:

- **The readings stop passing through `RGBA8`.** `changed` and `confidence` were quantized to eight bits
  between the map and the restore, and inlined they are full precision. `verdict` and `screen` are
  `step`/boolean and unaffected. `changed` feeds a `0.7` blend, so the difference is sub-visible, but it
  is a real output change.
- **The override order has to survive the move.** The tile class is mapped to a colour in the map and the
  tile view's blend is decided in the restore; the normals probe replaces the picture. The inline keeps
  tile over confidence and normals over everything, which is why the diagnostics block was rewritten
  rather than copied.

## 3. The screen-state read is broadcast to one texel

The map sampled the 1×1 `MotionStat` at every pixel, applied `AutoMaskDrawn`, and wrote the 0/1 result
into the map's alpha for the corner marker to fetch at `(0.5, 0.5)`. Inlined, the marker reads
`MotionStat` itself and applies `AutoMaskDrawn` with the strictness `docs/compute-path.md` requires at
the threshold — `> AutoMaskMotion`, not `step`, which is true at the threshold itself and would disagree
on exactly the boundary frame — inside `if (texcoord.x < 0.02 && texcoord.y > 0.98)`, so the fetch is one
texel in the corner rather than a screen-constant value decided once per pixel.

## 4. Smaller items

- **`changed` is computed under every view.** `saturate(accum.b * UIDebugGain)` fills the motion view's
  red at every pixel, but red is read only by that view; the verdict, confidence, tile and normals views
  ignore it. One `mul_sat` a pixel, and a `[branch]` on the view uniform would cost more than it saves.
  Left.
- **The tile coverage channels are dead.** `texAutoTileKind`'s green, blue and alpha are written from the
  cell's mask share, wide share and a constant, and nothing reads them: the tile view draws only red.
  Either the drawing uses the channels or the comment beside the store is corrected.
- **`CS_Tile`'s three relaxations.** `tileLabel`, `tileWide` and `tileHole` each run a full
  `AUTOMASK_TILE_ROUNDS` = `G²` = 256 rounds. That bound is exact for a serpentine region of the longest
  path, so a cheaper scheme would change what each reading means, and the pass is one thread group of
  256, so the two barriers a round cost nothing against any full-resolution pass. Left.
- **The normals probe.** Three depth fetches and three position reconstructions, already behind
  `if (UIDebugDepthNormal)`, a uniform branch that is false in the shipped view. It costs nothing until
  the checkbox is ticked and then reads the surface it names. Left.

## 5. How to verify a change here

`uv run tools/verify_shaders.py check --hashes --opcodes`, before and after, exactly as on the other
paths:

- A change under the diagnostics guard must move only the diagnostics variants' entry points. The overlay
  now leaves `PS_Restore` as the only entry point it moves, with `CS_Tile` where the compute path crosses;
  every non-diagnostics variant — the eight with the overlay off — must stay byte-identical.
- The quantization delta and the moved read change **what the views look like**, not what the mask
  decides: neither reads anything the verdict reads, so the mask and the final picture must be identical
  with the overlay on and off. That is the property to check, and it needs the overlay on a game —
  `docs/verification.md` lists the views' scenarios, and an agent cannot run one.
- A change that reaches outside the guard is a change to another path and needs that path's own entry;
  the eight non-diagnostics variants in the report are the evidence it did not.
