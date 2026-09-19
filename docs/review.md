# Shader Code Review: AutoMask.fx

## 1. Overview & Scope

This review examines `Shaders/AutoMask.fx`, evaluating:
- Unused, dead, or redundant variables, parameters, constants, and render targets.
- Algorithmic and memory efficiency across all passes (specifically the motion reduction pipeline).
- Adherence to project conventions defined in `AGENTS.md`, with particular attention to comment verbosity.
- Integration and correctness of the Center Deadzone logic for third-person games.

---

## 2. Dead, Unused, and Redundant Code

### 2.1 Critical Requirement: `SV_Position` in Pixel Shader Signatures
Every pixel shader in the pipeline declares `float4 pos : SV_Position` as its first parameter:
- `PS_Accum`
- `PS_Motion`
- `PS_MotionAvg`
- `PS_Copy`
- `PS_DilateH`
- `PS_DilateV`
- `PS_Store`
- `PS_StoreFrame`
- `PS_AntiBloom`
- `PS_Restore`
- `PS_DebugMap`
- `PS_DebugOverlay`

**Observation & Critical Finding**: While `pos` is not explicitly read inside the pixel shader bodies, **it must not be removed**. ReShade's vertex shader (`PostProcessVS`, from `ReShade.fxh`) is:
```hlsl
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
```
Under the D3D10/11/12 register rule, a pixel shader's inputs bind by hardware register, and its `TEXCOORD` inputs are numbered from `v0` in the order it declares them. `PostProcessVS` puts the position at `v0` and the UV at `v1`, so the position parameter is load-bearing: it occupies `v0` and pushes the UV up to `v1`. Removing it slides the UV down into the position's register; declaring it last makes the UV fall back to `v0` while the position claims `v1`, producing *two* mismatched-register errors rather than one. Only "first" links correctly.

The failure is not a value reinterpretation. The driver either reports a mismatched or absent input (debug layer) or leaves the input undefined; measured on a live D3D11 device with the debug layer attached, hardware supplied zero, so every pixel sampled one texel — the per-pixel difference collapses to zero everywhere, the mask fills uniformly, and the screen shows a single flashing colour. **The debug layer reports the error but does not stop the draw**, and without the debug layer the misbehaviour is silent, which is why the signature is pinned by reflection rather than by eye.

The parameter is required even when the body never reads the input, and `PS_MotionAvg` is the case in this file: it samples at constant UVs and its body has **no `dcl_input_ps` at all**, yet its compiled signature still lists both inputs with an empty `Used` column (see `tools/.work/PS_MotionAvg.asm`). Linkage is decided on the declared signature, and `fxc` preserves declared inputs whether or not the body reads them.

**Conclusion**: Keep `float4 pos : SV_Position, float2 texcoord : TEXCOORD` on all pixel shaders.

---

### 2.2 Redundant Mask Multiplication in `PS_Store`
In `PS_Store`:
```hlsl
float4 PS_Store(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float mask = step(0.5, tex2D(AutoMap, texcoord).r);
    return float4(tex2D(ReShade::BackBuffer, texcoord).rgb * mask, 1.0);
}
```
And subsequently in `PS_Restore`:
```hlsl
float3 live = tex2D(ReShade::BackBuffer, texcoord).rgb;
float3 stored = tex2D(AutoFrame, texcoord).rgb;
float mask = step(0.5, tex2D(AutoMap, texcoord).r);
float3 color = lerp(live, stored, mask);
```
**Observation**: `PS_Restore` performs a linear interpolation between `live` and `stored` based on `mask`. When `mask == 0`, `PS_Restore` selects `live`. Pre-multiplying by `mask` in `PS_Store` zeros out unmasked pixels in `texAutoFrame`, which is safe and isolates UI contents in debug inspections, but mathematically redundant for the composite pass.

---

### 2.3 Self-Sampling in Dilation Loops (`PS_DilateH` & `PS_DilateV`)
In both 1D dilation passes:
```hlsl
float mask = tex2D(AutoAccumA, texcoord).r;
float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));

for (int i = -UIMASK_DILATE_MAX; i <= UIMASK_DILATE_MAX; i++){
    float2 uv = texcoord + float2(i * texel.x, 0.0);
    float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
    float edge = abs(luma - lumaCentre) * 255.0;
    float keep = (abs(float(i)) <= r && edge <= UIMaskEdge) ? 1.0 : 0.0;
    mask = max(mask, tex2D(AutoAccumA, uv).r * keep);
}
```
**Observation**: When `i == 0`, `uv == texcoord`. The loop computes `edge = 0.0`, sets `keep = 1.0`, and re-samples `tex2D(AutoAccumA, texcoord)` and `ReShade::BackBuffer`. While the HLSL compiler (`fxc`) may optimize redundant texture fetches at `i == 0`, starting with `mask` and checking neighbors for `i != 0` avoids redundant calculation.

---

## 3. Architecture & Performance: The Motion Reduction Path

The motion reduction runs `PS_Motion` into `texMotionCoarse`, then `PS_MotionAvg` into the 1×1 `texMotionStat`.

### 3.1 What the Two Passes Actually Do
1. **Target Declaration**:
   ```hlsl
   texture texMotionCoarse { Width = 16; Height = 16; Format = RGBA8; };
   ```
   A fixed $16 \times 16 = 256$ texels, at 4 bytes each: 1,024 bytes, identically at every resolution.

2. **Per-Texel Workload in `PS_Motion`**:
   `PS_Motion` executes once per coarse texel. Each invocation samples 4 taps from `AutoAccumB`:
   $$256 \times 4 = 1,024 \text{ texture fetches}$$

3. **Sampling in `PS_MotionAvg`**:
   `PS_MotionAvg` runs on a 1x1 render target (`texMotionStat`), evaluating:
   ```hlsl
   float sum = 0.0;
   for (int y = 0; y < 16; y++){
       for (int x = 0; x < 16; x++){
           float2 uv = (float2(x, y) + 0.5) / 16.0;
           sum += tex2D(MotionCoarse, uv).r;
       }
   }
   return float4((sum / 256.0).xxx, 1.0);
   ```
   `PS_MotionAvg` samples an evenly spaced $16 \times 16$ grid across normalized UV coordinates `[0, 1]`—**exactly 256 samples**, every texel of the coarse target, at each texel's centre.

### 3.2 Resolution and the Tap Geometry
The two passes are written entirely in UV, so their relationship is resolution-independent either way:

- `PS_Motion` takes 4 taps at `±0.015625` UV horizontally and `±0.01171875` UV vertically (`(i - 0.5) * blockStep * 0.5`, with `blockStep = 1.0 / 16.0` applied to x and y as *UV*, so the pair is not the same number of pixels on a 16:9 screen). The taps therefore span 80×45 px at 1440p and 120×67.5 px at 4K — **exactly half a coarse texel in each axis in both versions**, covering 25% of its area. In neither declaration does the pass average the 16×16-pixel block its texel nominally represents; it samples the accumulator across a sub-region of that block.

- The declaration does change where the reduction lands, and the 16×16 target is the one that aligns. `PS_Motion` writes texel centres at `(m + 0.5) / 16`, and `PS_MotionAvg` samples at `(n + 0.5) / 16`, so at 16×16 every sample sits exactly on a texel centre — the reduction reads each coarse block once and skips none. With `BUFFER_WIDTH / 16` the sample position in texel units is `(n + 0.5) * (BUFFER_WIDTH / 16) / 16`, which is a texel centre only by coincidence: at 1440p (160 texels across) it lands on `10n + 5`, a texel *boundary*, and in the vertical at 90 texels it lands on `5.625n + 2.8125`, an arbitrary offset. So the buffer-relative version both samples between coarse texels and, where the buffer does not divide by 16 at all, truncates the target — 1080p is 67.5 texels tall, so it gets 67. The fixed size removes a resolution-dependent misalignment rather than adding one.

- The aspect-ratio argument that the buffer-relative size would preserve is real but unused: it has value only if something reads the coarse map *as a spatial map*, per region. Nothing does. `PS_MotionAvg` is the sole reader and collapses the map to one number with 256 sparse taps. A dense per-region reduction inside a single 1×1 invocation would be far slower than the current sparse read, so the sparse read is the right call and this is not the direction to revisit.

The fixed size therefore makes the declaration match its only consumer, and drops the target from 57,600 bytes to 1,024 bytes at 1440p.

---

## 4. Comment Verbosity Audit

### 4.1 Project Rule Violation
`AGENTS.md` specifies:
> *"HLSL comments are **short and sparse** (`//UINr 13`). Do not add tutorial narration to the shader. The one exception is the ruled credit block at the top of `Shaders/AutoMask.fx`... which follows the companion pack's style and is the only long comment in the file. Do not add per-function attribution below it."*

### 4.2 Findings
`AutoMask.fx` contains extensive essay-style commentary, accounting for over **250 lines** (~35% of the file). Major instances include:

| Lines | Location | Content / Purpose |
| :--- | :--- | :--- |
| **26–35** | `UIMaskEps` | 10-line discussion on 8-bit precision vs continuous sub-level noise. |
| **45–50** | `UIMaskRise` | 6-line history detailing an older value (0.07) that required 8 frames. |
| **78–97** | `UIMaskMoveMemory` | 20-line narrative on camera motion, debt repayment timescales, and hidden errors. |
| **129–143** | `UIMaskMotion` | 15-line debate about spinning coins, screen share, and quiet rooms. |
| **153–162** | `UIMaskTrust` | 10 lines explaining panel opening grace over static scenes. |
| **172–180** | `UIMaskSettle` | 9 lines on window interaction and state transitions. |
| **278–291** | Before `PS_Accum` | 14-line tutorial narration summarizing the entire activation signal. |
| **298–305** | Inside `PS_Accum` | 8 lines discussing `smoothstep` vs linear ramps. |
| **315–328** | Inside `PS_Accum` | 14 lines explaining why target initial allocation reads 0 vs 255. |
| **409–421** | Before `PS_Motion` | 13 lines repeating the screen-wide premise. |
| **458–477** | Before `PS_DilateH` | 20 lines documenting HLSL compiler bug X3511 and offline test limits. |
| **587–625** | Diagnostics | 39 lines detailing color packing, 3-state alpha, and corner marker rationale. |

### 4.3 Recommendation
All design rationale, architectural history, and compiler quirks are already documented in `AGENTS.md` and `README.md`. Comments in `Shaders/AutoMask.fx` should be condensed into concise, 1–2 line descriptions matching the repository's rules.

---

## 5. Review of the Center Deadzone Implementation

The newly added Center Deadzone operates with clean separation:
- **Parameterization**: Controlled via `UIMaskDeadzoneWidth`, `UIMaskDeadzoneHeight`, `UIMaskDeadzoneY`, and `UIMaskDeadzoneMotionOnly`. Defaults to `0.0` (fully disabled, maintaining 100% backward compatibility).
- **Branchless Math**: Elliptical inclusion check uses `dot(offset / radii, offset / radii) <= 1.0`, avoiding square root operations in `PS_Accum`.
- **Confidence Clamp**: Forcing `conf = min(conf, 0.0)` and `held = 0.0` ensures any preexisting confidence in the region dissolves immediately without waiting for decay cycles.
- **Visual Feedback**: The diagnostics overlay utilizes `fwidth(dist)` to render an anti-aliased 1.5-pixel boundary ring, compiling out completely when `UIMaskDiagnostics == 0`.

---

## 6. Summary of Action Items
 
1. **Prune Comments**: Compress verbose tutorial comments down to 1–2 line technical statements (completed in commit `1df5530`).
2. **Preserve `SV_Position` Signatures**: Retain `float4 pos : SV_Position` on all pixel shaders. It occupies `v0` so the UV binds to `v1`; without it the linkage fails and every pass samples a single texel. Measured on a live D3D11 device, and the generated HLSL is otherwise byte-for-byte identical without it.
3. **Size the Coarse Motion Target to 16×16**: Declare `texMotionCoarse` as `16 × 16` rather than `BUFFER_WIDTH / 16` × `BUFFER_HEIGHT / 16`. Nothing reads the coarse map spatially, so the aspect-ratio property the buffer-relative size preserves is unused, and the fixed size matches the declaration to its only consumer (256 texels, 1,024 bytes, at every resolution).
