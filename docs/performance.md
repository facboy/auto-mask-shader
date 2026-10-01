# Performance

Where the frame's cost actually sits, measured off the compiled bytecode rather than the source, and
the changes that measurement has justified. The pass count and the target count are fixed by
`docs/core-model.md` and `docs/compute-path.md`: every pass is a full-resolution read and write, so
what the frame pays is the bytes moved more than the instructions run.

## 1. What the assembly shows

`uv run tools/verify_shaders.py check --opcodes` reports a static slot count per entry point, which
is a compile-time figure. The two closing passes compile to runtime loops, and a slot count hides the
trip count inside them. Read off `tools/.work/PS_Dilate*.asm` at the shipped defaults:

| pass | samples at the centre | samples per loop tap | loop taps |
| --- | --- | --- | --- |
| `PS_DilateH` | 2 | 2 | 7 (`2 × AUTOMASK_DILATE_MAX + 1`) |
| `PS_DilateV` | 2 | 4 | 7 |

The closing therefore costs `PS_DilateH` 16 and `PS_DilateV` 30 samples a pixel, about 46 against the
accumulator's 8 and the other full-resolution passes at 1–3 each. That is the heaviest part of the
full-resolution chain, and the one place a static count (41 and 61) reads well under what the frame
pays.

## 2. The taps neither radius wants

Both loops run `AUTOMASK_DILATE_MAX` either side whatever the sliders say. A tap past both radii
feeds neither term: `inRange` is false, so the closing term is zero, and the isolation count is gated
on `abs(i) <= reach`, so that term is zero too. At the default **Closing radius 1** and **Isolation
radius 1** the loop takes seven taps where three carry either term.

Bounding each loop by `min(max(r, reach), AUTOMASK_DILATE_MAX)` drops the closing to 8 + 14 samples a
pixel, a little over half, with identical output — a tap outside both radii already contributed
nothing. The bound costs three instructions (`PS_DilateH` 41 → 45, `PS_DilateV` 61 → 68 statically)
for 3 taps at the defaults against 7. The explicit `AUTOMASK_DILATE_MAX` term is not redundant: both
sliders cap at 3, so it never tightens the bound, and it is what keeps the loop tied to the constant
rather than to the sliders alone.

## 3. The store's second render target

`PS_Store` and `PS_StoreFrame` were two full-resolution passes reading the same `BackBuffer`, one
multiplying by the mask and one copying to the history target. They are one pass now: `PS_Store`
returns the masked pixels and writes the untouched frame to `texAutoHistory` through a second
`SV_Target1`, so the pass count drops by one and a full-resolution back-buffer read goes with it. This
is the one merge a static count could not hide — `PS_StoreFrame` was a whole pass — and the only
change here a readback consumer could be sensitive to, since the accumulator's history read expects
the bytes the merge writes. The offline check parses `RenderTarget1` for it, so a second target a
later edit adds cannot hide from the wiring cross-check.

## 4. Both back-edges, folded into the closing

`PS_Copy` carried `texAutoAccumB` back to `texAutoAccumA` so next frame's accumulator reads the state
this frame produced, and `PS_CopyDrift` did the same for the drift pair. Neither can be **deleted** — the
accumulator must read one side while writing the other, and ReShade runs one fixed pass list per frame,
so the read/write sides cannot alternate — but both can be **merged** into `PS_DilateH`, which is the
only full-resolution pass that already reads the accumulator: it takes the centre tap of
`texAutoAccumB` anyway, so writing that same value to `texAutoAccumA` as `SV_Target1` is the copy, at no
extra sample; and its read of `texAutoDriftB` for `SV_Target2` is the drift copy, which does cost one
read (no other pass reads the drift channel) but no longer a pass or a dispatch. Two full-resolution
passes go with them.

The two other readers of the live side, `PS_DebugMap` and `CS_Tile`, moved from `A` to `B` with the
accumulator's fold. The drift writer stays `AutoDriftStore` → `texAutoDriftB` and the reader stays
`AutoDriftA`, so the pair keeps its `A`-reads/`B`-writes convention.

The merge is only legal because the host samples a *different* texture than it writes: ReShade errors
`3020` on a pass that samples a texture it also uses as a render target, which is why the copies had to
be passes of their own and why they cannot fold into `PS_Store` (that pass already reads what the copies
write). The drift fold is behind `#if AutoMaskCompute == 1`, since the pixel path has no drift channel:
the shader has two `PS_DilateH` signatures under the guard, differing only by `SV_Target2`.

**Why the merge is trusted to bind.** Multi-target passes are first-class in ReShade, read from its own
source rather than inferred: `effect_parser_stmt.cpp` accepts `RenderTarget0`..`RenderTarget7`
(`state_name` starting `RenderTarget` with a `0`..`7` suffix), stores them by index in an 8-slot
`render_target_names`, and `runtime.cpp` binds each to an RTV and appends its format to the pipeline. So
`RenderTarget1` and `RenderTarget2` are honoured, not ignored. Two constraints come with it: every target
in a pass must share its dimensions, which holds (`BUFFER_WIDTH × BUFFER_HEIGHT` throughout), and
`SRGBWriteEnable` would require *every* target to be `RGBA8` — so it must stay **off** on this pass,
because it writes `RGBA16F` (`texAutoAccumA`) and `RGBA32F` (`texAutoDriftA`). ReShade defaults it to
false and the shader never sets it.

## 5. Openings left unmeasured

- **The isolation gate's four taps a loop step.** Its row, column and two diagonal counts ride the
  taps the closing already takes, which is the no-extra-tap design (`docs/core-model.md`); a flat 3×3
  gathering would cost less per tap but is only worth it beside the bound above.
- **The accumulator's static footprint.** `CS_Accum` (254) and `PS_Accum` (151) carry the pinned-colour
  count's sixteen `eq`/`and` pairs. `AutoMaskClipped` returning `int` rather than `float` is a recorded
  decision (`docs/refactor-candidates.md`) that keeps the bytecode hash stable, so this is not a tidy.
