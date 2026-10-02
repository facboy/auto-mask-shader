# Performance: the diagnostics build

What `AutoMaskDiagnostics=1` costs when it is on, read off the compiled bytecode. The switch ships at `0`,
but the on-build is a shipped variant rather than a retired one: ReShade exposes the definition in the UI,
so anyone can compile the overlay in, and that build pays for the overlay's pass, target and extra
full-resolution tap every frame it runs. This is the account for that configuration.
`docs/performance.md` measures the default path, `docs/performance_compute.md` the compute and depth
paths, and neither tabulates the overlay.

Companions: `docs/performance.md` and `docs/performance_compute.md` (the other paths, and the bytecode
method), `docs/compute-path.md` (the tile map's design and why it rides the compute guard), `docs/core-model.md`
(the readings the views draw), `docs/verification.md` (the check, and the scenarios that need a game).

## 1. Where the cost sits

`uv run tools/verify_shaders.py check --opcodes`, static slots and back-buffer taps per entry point, at
2560×1440. The overlay adds `PS_DebugMap` to every variant, and `CS_Tile` where the compute path is on too:

| variant | entry point | slots | samples |
| --- | --- | ---: | ---: |
| `diagnostics` | `PS_DebugMap` | 10 | 2 |
| | `PS_Restore` | 35 (8 without) | 4 (2 without) |
| `diagnostics-compute` | `PS_DebugMap` | 35 | 3 |
| | `CS_Tile` | 236 | 3 |
| | `PS_Restore` | 67 (8 without) | 6 (2 without) |
| `diagnostics-depth` | `PS_DebugMap` | 60 | 5 |
| | `PS_Restore` | 36 | 4 |
| `diagnostics-compute-depth` | `PS_DebugMap` | 84 | 6 |
| | `PS_Restore` | 68 | 6 |

Three facts, all read from the report and the `.asm`:

- **`PS_DebugMap` is one full-resolution pass and one full-resolution target.** On the pixel path it is 10
  slots and two taps — `AutoAccumB` and the 1×1 `MotionStat` — and on the compute path 35 and three, the
  third being `texAutoTileKind` for the tile view. The depth normals probe is the largest block: 60 slots
  and five taps with the depth switch on, 84 and six with compute as well. It writes `texAutoDebug`, an
  `RGBA8` buffer at full resolution — 14.7 MB at 1440p.
- **The overlay adds a full-resolution tap to `PS_Restore`, plus a point one.** `PS_Restore` is 8 slots
  and two taps (`BackBuffer`, `AutoHistory`) without the overlay, and 35 and four with it: one fetch of the
  map for the per-pixel tint, and a second at `(0.5, 0.5)` for the corner marker, which reads one texel. On
  the compute path it is 67 and six, the two extra being the bar readings from the 2×1 `texAutoTileStat`,
  behind `UIDebugTile`'s uniform branch.
- **`CS_Tile` is a fixed cost, not a per-pixel one.** 236 slots, but a single `AUTOMASK_TILE_GRID`² thread
  group with a 1×1 dispatch and three taps a cell. Against a full-resolution pass it is small, and it
  exists only where the compute and diagnostics switches cross.

The overlay's own frame, on the pixel path, is therefore ~59 MB of traffic the default path does not move:
the map's read of `texAutoAccumB` (29.5 MB), its write of `texAutoDebug` (14.7 MB) and the restore's
full-resolution read of that target (14.7 MB). The corner marker's read is one texel. Against a default
path of five full-resolution passes and four targets, the overlay is a sixth pass and a fifth target.

## 2. The map pass and its target

`PS_DebugMap` reads its sources, packs the selected view into `texAutoDebug`'s four channels — red the
graded motion, green the verdict, blue the confidence, alpha the screen state — and its only readers are
two sites in `PS_Restore`: the per-pixel tint and the corner marker. Nothing else in the effect, and
nothing outside it, samples `texAutoDebug`.

That pair is a leftover of the shader's first shape, where a `PS_DebugMap` pass painted the map and a
`PS_DebugOverlay` pass blended it over the frame. The overlay is folded into `PS_Restore` now, so the map
is an intermediate whose consumer runs in the same effect and can read the same sources directly.

## 3. The pass-and-target fold the map leaves open

Every source `PS_DebugMap` reads is still valid when `AutoMask_Restore` runs, which makes the map pass and
its target redundant rather than the price of the reading:

- `texAutoAccumB` is written by the accumulator, the first pass of the frame, and never rewritten — the
  closing writes `texAutoAccumA`, the history, the drift pair, the depth and `texAutoDilate`, never `B`.
- `MotionStat` is written by `CS_Finish` or `PS_MotionAvg`, both before the closing.
- `texAutoTileKind` and `texAutoTileStat` are written by `CS_Tile`, which is itself before the restore.
- The depth buffer is available to any pass.

`PS_Restore` binds no render target — it writes the back buffer — so there is no read-write conflict, and it
already reads `texAutoHistory` from the earlier technique, which is the same cross-technique pattern.

Inlining the map body into the `#if AutoMaskDiagnostics` block of `PS_Restore` removes, for every
diagnostics-on frame:

| pixel-path build | before | after |
| --- | --- | --- |
| full-resolution passes | `PS_DebugMap` | none |
| `texAutoDebug` | allocated, 14.7 MB, written and read | gone |
| traffic | ~59 MB/frame | none |
| taps across map + restore | 6 | 4 |

The restore's tap count does not rise: the map's two fetches of `texAutoDebug` are replaced by one fetch of
`texAutoAccumB` and one of `MotionStat`, which is what the map read for the tint and for the marker. The
compute path holds the same way: the map's three taps join the restore's six, nine in all, and land as seven
on one pass.

Two behaviour deltas come with the fold and need eyes on a game rather than the check:

- **The readings stop passing through `RGBA8`.** `changed` and `confidence` are quantized to eight bits
  between the map and the restore today, and inlined they are full precision. `verdict` and `screen` are
  `step`/boolean and unaffected. `changed` feeds a `0.7` blend, so the difference is sub-visible, but it is
  a real output change.
- **The override order has to survive the move.** The tile class is mapped to a colour in the map and the
  tile view's blend is decided in the restore; the normals probe replaces the picture. The inline has to
  keep tile over confidence and normals over everything, which is a rewrite of the diagnostics block rather
  than a copy.

The fold is not built. It is the same shape as the store and depth-store folds, and the same test applies:
the check confirms it compiles and leaves every non-diagnostics entry point hash-identical, and a game
confirms the views still read as they did.

## 4. The screen-state read is broadcast to one texel

Even without the fold, one tap in `PS_DebugMap` is avoidable on its own. The pass samples the 1×1
`MotionStat` at every pixel, applies `AutoMaskDrawn`, and writes the 0/1 result into the map's alpha. The
only reader of that alpha is the corner marker, which fetches the map at `(0.5, 0.5)`. The `.asm` shows the
sample and its `mul`/`lt` running unconditionally, before the normals and tile branches, so a screen-constant
value is fetched and decided once per pixel to be broadcast to a single corner texel.

The marker can read `MotionStat` itself and apply `AutoMaskDrawn` with the strictness `docs/compute-path.md`
requires at the threshold — the corner marker's own read is a fixed cost. Doing so frees the tap, the
arithmetic and the map's alpha channel; the fold in §3 absorbs the whole pass, so this is the fallback when
the fold is not taken. The alpha channel is then free for the tile coverage the map's comment already claims
to draw (§5).

## 5. Smaller items

- **`changed` is computed under every view.** `saturate(accum.b * UIDebugGain)` fills the map's red at
  every pixel, but red is read only by the motion view; the verdict, confidence, tile and normals views
  ignore it. One `mul_sat` a pixel, and a `[branch]` on the view uniform would cost more than it saves.
  Left.
- **The tile coverage channels are dead.** `texAutoTileKind`'s green, blue and alpha are written from the
  cell's mask share, wide share and a constant, and nothing reads them: the map draws only red. The
  comment beside the store claims the coverage is what lets the map show how much of a cell each reading
  found, which the drawing code does not do. A comment that overstates, not a cost — the store is 16×16.
  Either the drawing uses the channels (with §4's freed alpha) or the comment is corrected.
- **`CS_Tile`'s three relaxations.** `tileLabel`, `tileWide` and `tileHole` each run a full
  `AUTOMASK_TILE_ROUNDS` = `G²` = 256 rounds. That bound is exact for a serpentine region of the longest
  path, so a cheaper scheme would change what each reading means, and the pass is one thread group of 256,
  so the two barriers a round cost nothing against any full-resolution pass. Left.
- **The normals probe.** Three depth fetches and three position reconstructions, already behind
  `if (UIDebugDepthNormal)`, a uniform branch that is false in the shipped view. It costs nothing until the
  checkbox is ticked and then reads the surface it names. Left.

## 6. How to verify a change here

`uv run tools/verify_shaders.py check --hashes --opcodes`, before and after, exactly as on the other paths:

- A change under the diagnostics guard must move only the diagnostics variants' entry points. With §3 or §4
  landed, `PS_Restore` is expected to move, `PS_DebugMap` and `texAutoDebug` to be gone, and every
  non-diagnostics variant — the eight with the overlay off — byte-identical.
- §3's quantization delta and §4's moved read change **what the views look like**, not what the mask
  decides: neither reads anything the verdict reads, so the mask and the final picture must be identical
  with the overlay on and off. That is the property to check, and it needs the overlay on a game —
  `docs/verification.md` lists the views' scenarios, and an agent cannot run one.
- A change that reaches outside the guard is a change to another path and needs that path's own entry; the
  eight non-diagnostics variants in the report are the evidence it did not.
