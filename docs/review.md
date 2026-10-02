# Shader Code Review: AutoMask.fx

## 1. Overview & Scope

`Shaders/AutoMask.fx`, reviewed for unused or redundant code, the motion reduction pipeline's efficiency,
and adherence to the project conventions in `AGENTS.md`. The Center Deadzone reviewed in §5 has since
been removed.

## 2. Dead, Unused, and Redundant Code

### 2.1 Critical Requirement: `SV_Position` in Pixel Shader Signatures

Every pixel shader declares `float4 pos : SV_Position` as its **first** parameter, and no body reads it.
It must not be removed. ReShade's vertex shader (`PostProcessVS`, from `ReShade.fxh`) is:

```hlsl
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
```

Under the D3D10/11/12 register rule, a pixel shader's inputs bind by hardware register, and its `TEXCOORD`
inputs are numbered from `v0` in the order it declares them. `PostProcessVS` puts the position at `v0` and
the UV at `v1`, so the position parameter is load-bearing: it occupies `v0` and pushes the UV up to `v1`.
Removing it slides the UV down into the position's register; declaring it last makes the UV fall back to
`v0` while the position claims `v1`, producing *two* mismatched-register errors rather than one.

The failure is not a value reinterpretation. The driver either reports a mismatched or absent input (debug
layer) or leaves the input undefined; measured on a live D3D11 device with the debug layer attached,
hardware supplied zero, so every pixel sampled one texel — the per-pixel difference collapses to zero
everywhere, the mask fills uniformly, and the screen shows a single flashing colour. **The debug layer
reports the error but does not stop the draw**, and without it the misbehaviour is silent.

The parameter is required even when the body never reads the input, and `PS_MotionAvg` is the case in this
file: it samples at constant UVs and its body has **no `dcl_input_ps` at all**, yet its compiled signature
still lists both inputs with an empty `Used` column. Linkage follows the declared signature, and `fxc`
preserves declared inputs whether or not the body reads them.

### 2.2 Redundant Mask Multiplication in `PS_Store`

`PS_Store` pre-multiplied the frame by the mask before writing `texAutoFrame`, while `PS_Restore` selected
between the live and stored frames with `lerp(live, stored, mask)`. The multiply's only value was that the
target isolated UI contents for a debug inspection; it was mathematically redundant for the composite, and
the target and the store pass are now gone (`docs/performance-openings.md` §2–§3).

### 2.3 Self-Sampling in Dilation Loops (`PS_DilateH` & `PS_DilateV`)

Both 1D dilation loops ran an `i == 0` step, where `uv == texcoord`: it re-sampled the frame and the
accumulator, computed `edge = 0.0` and set `keep = 1.0`, all of which the centre tap already holds. The
step is skipped and its contributions are seeded from the centre tap (`docs/performance.md` §5).

## 3. Architecture & Performance: The Motion Reduction Path

The pixel path's reduction runs `PS_Motion` into a fixed 16×16 `texMotionCoarse`, then `PS_MotionAvg`
into the 1×1 `texMotionStat`. The target is 256 texels at 4 bytes each — 1,024 bytes, identically at
every resolution — and `PS_Motion` takes four taps a texel, so 1,024 taps stand in for every pixel. The
compute path replaces the pair with `CS_Accum`'s tally (`docs/compute-path.md`).

### 3.1 What the Two Passes Actually Do

`PS_Motion` executes once per coarse texel and samples four taps from `AutoAccumB`, so 256 × 4 = 1,024
texture fetches. `PS_MotionAvg` runs on the 1×1 target and samples an evenly spaced 16×16 grid across
normalized UVs — exactly 256 samples, every texel of the coarse target, at each texel's centre.

### 3.2 Resolution and the Tap Geometry

The two passes are written entirely in UV, so their relationship is resolution-independent either way:

- `PS_Motion` takes four taps at `±0.015625` UV horizontally and `±0.01171875` UV vertically
  (`(i - 0.5) * blockStep * 0.5`, with `blockStep = 1.0 / 16.0` applied to x and y as *UV*, so the pair
  is not the same number of pixels on a 16:9 screen). The taps span 80×45 px at 1440p and 120×67.5 px at
  4K — exactly half a coarse texel in each axis, covering 25% of its area. Neither declaration averages
  the 16×16-pixel block its texel nominally represents.
- The fixed 16×16 size is the one that aligns: `PS_Motion` writes texel centres at `(m + 0.5) / 16` and
  `PS_MotionAvg` samples at `(n + 0.5) / 16`, so every sample sits exactly on a texel centre. A
  buffer-relative size lands on texel boundaries or arbitrary offsets — at 1440p the horizontal sample is
  `10n + 5` — and where the buffer does not divide by 16 it truncates the target (1080p is 67.5 texels
  tall, so it gets 67).
- The aspect-ratio property a buffer-relative size would preserve is unused: nothing reads the coarse map
  *as a spatial map*. `PS_MotionAvg` is the sole reader and collapses it to one number with 256 sparse
  taps, and a dense per-region reduction inside a single 1×1 invocation would be far slower.

The fixed size therefore matches the declaration to its only consumer, and drops the target from 57,600
bytes to 1,024 bytes at 1440p.

## 4. Comment Verbosity Audit

The audit found essay-style commentary accounting for over 250 lines, much of it tutorial narration and
history already documented in `AGENTS.md` and `docs/`. The offending blocks were compressed to short
technical statements in commit `1df5530`, and `COMMENT_BLOCK_MAX` and the prose budget now hold the
line (`docs/editing-conventions.md`).

## 5. Review of the Center Deadzone Implementation (since removed)

The Center Deadzone carved a camera-tethered region out of the mask with an elliptical inclusion test,
`dot(offset / radii, offset / radii) <= 1.0`, avoiding a square root in `PS_Accum`, and forced
`conf = min(conf, 0.0)` so any confidence already in the region dissolved at once. It was cleanly
separated and removed as unused; §5 is kept as the record of the review that landed it.

## 6. Summary of Action Items

1. **Prune comments** to 1–2 line technical statements (completed in `1df5530`).
2. **Preserve `SV_Position` signatures** on all pixel shaders: the position occupies `v0` so the UV binds
   to `v1`, and without it the linkage fails and every pass samples a single texel.
3. **Size the coarse motion target to 16×16** rather than buffer-relative: nothing reads the coarse map
   spatially, and the fixed size matches the declaration to its only consumer (256 texels, 1,024 bytes,
   at every resolution).
