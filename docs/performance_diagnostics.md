# Performance: the diagnostics build

What `AutoMaskDiagnostics=1` costs when it is on, read off the compiled bytecode. The switch ships at
`0`, but the on-build is a shipped variant rather than a retired one: ReShade exposes the definition in
the UI, so anyone can compile the overlay in, and that build pays for the readings every frame it runs.
`docs/performance.md` measures the default path, `docs/performance_compute.md` the compute and depth
paths, and neither tabulates the overlay.

Companions: `docs/performance.md` and `docs/performance_compute.md` (the other paths, and the bytecode
method), `docs/core-model.md` (the readings the views draw), `docs/verification.md` (the check, and the
scenarios that need a game).

## 1. Where the cost sits

`uv run tools/verify_shaders.py check --opcodes`, static slots and back-buffer taps per entry point, at
2560×1440. The overlay adds nothing to `AutoMask` — no pass and no target — and grows `PS_Restore`
alone:

| variant | entry point | slots | samples |
| --- | --- | ---: | ---: |
| `diagnostics` | `PS_Restore` | 40 (8 without) | 4 (2 without) |
| `diagnostics-compute` | `PS_Restore` | 114 (8 without) | 5 (2 without) |
| `diagnostics-depth` | `PS_Restore` | 89 (8 without) | 7 (2 without) |
| `diagnostics-compute-depth` | `PS_Restore` | 162 (8 without) | 8 (2 without) |

Two facts, both read from the report and the `.asm`:

- **The overlay owns no pass and no target.** It reads the accumulator and the 1×1 `MotionStat` inside
  `PS_Restore`'s `#if AutoMaskDiagnostics` block, so the tint is drawn in the pass that already writes
  the frame. On the pixel path that is two extra taps — `AutoAccumB` and the 1×1 `MotionStat`. The
  depth normals probe is the largest block: 89 slots and seven taps with the depth switch on, rising to
  162 where the compute path's step readout (§5) is compiled in beside it.
- **The overlay adds one full-resolution tap to `PS_Restore`.** `PS_Restore` is 8 slots and two taps
  (`BackBuffer`, `AutoHistory`) without the overlay, and 40 and four with it: the per-pixel tint's fetch
  of `texAutoAccumB` and the corner marker's read of `MotionStat`, which is one texel. The compute paths
  are the same shape, plus the step readout's one-texel fetch of `AutoStep` (§5): the digit is guarded, so
  it costs its slots only where the auto-detect toggle can be on.

The overlay's own frame, on the pixel path, is therefore ~29.5 MB of traffic the default path does not
move: the restore's read of `texAutoAccumB`, one full-resolution fetch a frame. The corner marker's read
is one texel. Against a default path of five full-resolution passes and four targets, the overlay is no
pass and no target.

## 2. The map pass, folded into the restore

`texAutoAccumB` is written by the accumulator, the first pass of the frame, and never rewritten — the
closing writes `texAutoAccumA`, the history, the drift pair, the depth and `texAutoDilate`, never `B`.
`MotionStat` is written by `CS_Finish` or `PS_MotionAvg`, both before the closing. And the depth buffer
is available to any pass. Every source the overlay reads is therefore still valid when `AutoMask_Restore`
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
read for the tint and for the marker.

Two behaviour deltas came with the fold and need eyes on a game rather than the check:

- **The readings stop passing through `RGBA8`.** `changed` and `confidence` were quantized to eight bits
  between the map and the restore, and inlined they are full precision. `changed` feeds a `0.7` blend, so
  the difference is sub-visible, but it is a real output change.
- **The override order had to survive the move.** The normals probe replaces the picture rather than
  tinting it, so it stays last; the inline keeps that order, which is why the diagnostics block was
  rewritten rather than copied. (The tile view that once sat above the confidence grade was removed with
  the map — §3.)

## 3. The tile map, removed

The overlay had a third, compute-only view: `CS_Tile` read the picture as a fixed 16×16 grid and reduced
it to region readings — the mask's component count and largest share, the enclosed share, and the count
and area of contiguous wide-change patches — which the tile view drew as a per-cell class with five bars.
It was built as the instrument for `docs/ui-isolation-options.md` §5.2's fill, §5.4's arrivals and §5.8's
ratio, all three since closed as measured out, and it was kept afterwards as the tuning instrument for
the two spatial rules that shipped.

**That claim did not hold, so the pass and its targets are gone.** The isolation gate works at a radius
of 1–3 px — a 7×7 box — while a grid cell is 160×90 px at 1440p, so a view 20× coarser than the rule
cannot show what the rule does. Its own view was mostly duplicated per pixel and better: a green cell is
the verdict view at cell resolution, a red one is the motion view at cell resolution *minus* the premise
gate, and a black one is the plain picture. Its one unique contribution was region shape — the published
mask's components and its holes — for a gate that ships off, and that is available exactly from a
per-pixel read of the history alpha if it is ever wanted. What went with the pass:

| item | cost removed |
| --- | --- |
| `CS_Tile` pass | one thread group, 236 slots, ~768 taps a cell group |
| three relaxations | `G²` = 256 rounds each, two barriers a round |
| `texAutoTileKind` | 16×16 `RGBA8`, 1 KB |
| `texAutoTileStat` | 2×1 `RGBA32F`, 32 B |
| six `groupshared` arrays | 6 KB of workgroup state |
| `UIDebugTile` | one uniform, and the class/bar branches in `PS_Restore` |

It was free in the eight variants that do not cross compute with diagnostics, since the pass and its
targets were behind both guards — this is a saving to the four on-builds that ran it, not to the default
path. `docs/ui-isolation-options.md` §6 records the removal with the reasoning.

## 4. Smaller items

- **`changed` is computed under every view.** `saturate(accum.b * UIDebugGain)` fills the motion view's
  red at every pixel, but red is read only by that view; the verdict, confidence and normals views
  ignore it. One `mul_sat` a pixel, and a `[branch]` on the view uniform would cost more than it saves.
  Left.
- **The normals probe.** Three depth fetches and three position reconstructions, already behind
  `if (UIDebugDepthNormal)`, a uniform branch that is false in the shipped view. It costs nothing until
  the checkbox is ticked and then reads the surface it names. Left.

## 5. The step readout

The auto-deadband settles on a level the rest of the overlay cannot show — `docs/verification.md` records
that the step's own value was drawn nowhere, so the only witness was the red it produces. It is now drawn:
the bottom-right corner shows the committed step as a **digit**, 1–8, read from the 1×1
`texAutoStep.r` `CS_Finish` already commits for the next frame's `CS_Accum`. A digit rather than a bar
because it names a number, and it leads the mask by one frame exactly as the corner marker leads the
premise.

It is guarded twice over, so the pixel path and the toggle-off build pay nothing: `texAutoStep` and its
sampler exist only under `AutoMaskCompute`, and the draw is behind `AutoMaskAutoStep` — the value is only
read when auto-detect is on. The glyph is a seven-segment numeral in the calculator layout, drawn from
UV-space segments, not a font; a seven-segment box that is not square smears every bar together, which is
why the readout's box is aspect-corrected. It is drawn bright red on a darkened box. What it costs is the
compute paths' `PS_Restore`: 40 → 114 slots and 4 → 5 taps, the extra texel being that one fetch, with a
further 89/162 on the depth variants where the normals probe is also compiled in. The arithmetic sits
inside the corner branch, so a pixel outside the corner pays only the predicate.

## 6. How to verify a change here

`uv run tools/verify_shaders.py check --hashes --opcodes`, before and after, exactly as on the other
paths:

- A change under the diagnostics guard moves only the diagnostics variants' `PS_Restore`; every
  non-diagnostics variant — the eight with the overlay off — must stay byte-identical.
- The quantization delta and the moved read change **what the views look like**, not what the mask
  decides: neither reads anything the verdict reads, so the mask and the final picture must be identical
  with the overlay on and off. That is the property to check, and it needs the overlay on a game —
  `docs/verification.md` lists the views' scenarios, and an agent cannot run one.
- A change that reaches outside the guard is a change to another path and needs that path's own entry;
  the eight non-diagnostics variants in the report are the evidence it did not.
