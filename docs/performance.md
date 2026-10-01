# Performance

Where the frame's cost actually sits, measured off the compiled bytecode rather than the source, and
the one change that measurement has justified. The pass count and the target count are fixed by
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

## 3. Openings left unmeasured

- **The two ping-pong back-edges.** `PS_Copy` and `PS_CopyDrift` are full-resolution passes whose only
  job is one sample. A consumer could read the `B` target directly rather than the `A` side the copy
  writes, eliding a full-resolution read and write — but the accumulator ping-pong is a hard dialect
  constraint (`docs/core-model.md`), and any fold has to leave every pass reading a target no pass
  writes in the same frame.
- **`PS_Store` and `PS_StoreFrame` both re-read the back buffer.** Two full-resolution passes reading
  the same texture; one multi-target pass would take a single read. `AutoMask.fx` has never used a
  second render target and `tools/verify_shaders.py` does not parse `RenderTarget1`, so this is a
  check change before it is a shader change.
- **The isolation gate's four taps a loop step.** Its row, column and two diagonal counts ride the
  taps the closing already takes, which is the no-extra-tap design (`docs/core-model.md`); a flat 3×3
  gathering would cost less per tap but is only worth it beside the bound above.
- **The accumulator's static footprint.** `CS_Accum` (254) and `PS_Accum` (151) carry the pinned-colour
  count's sixteen `eq`/`and` pairs. `AutoMaskClipped` returning `int` rather than `float` is a recorded
  decision (`docs/refactor-candidates.md`) that keeps the bytecode hash stable, so this is not a tidy.
