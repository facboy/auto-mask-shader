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

**Observation & Critical Finding**: While `pos` is not explicitly read inside the pixel shader bodies, **it must not be removed**. ReShade vertex shaders (specifically `PostProcessVS` from `ReShade.fxh`) output:
```hlsl
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
```
In ReShade's shader linkage and backend code generation (HLSL, GLSL, SPIR-V), pixel shader input parameters bind to vertex shader outputs in order. If `float4 pos : SV_Position` is omitted from the pixel shader, the pixel shader's `texcoord` parameter receives the vertex shader's first output (`position : SV_Position`), which contains unnormalized screen pixel coordinates (e.g. `[0..2560] x [0..1440]`) rather than normalized `[0.0..1.0]` UVs. This causes every sampler across all passes to sample out-of-bounds/clamped coordinates, breaking the entire pipeline and flashing the screen with a solid color.

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

## 3. Architecture & Performance: The Motion Reduction Mismatch

A significant computational inefficiency exists between `texMotionCoarse`, `PS_Motion`, and `PS_MotionAvg`.

### 3.1 The Mismatch Breakdown
1. **Target Declaration**:
   ```hlsl
   texture texMotionCoarse { Width = BUFFER_WIDTH / 16; Height = BUFFER_HEIGHT / 16; Format = RGBA8; };
   ```
   At 2560x1440, `texMotionCoarse` is $160 \times 90 = 14,400$ pixels.
   At 3840x2160 (4K), it is $240 \times 135 = 32,400$ pixels.

2. **Per-Texel Workload in `PS_Motion`**:
   `PS_Motion` executes once per coarse texel. Each invocation samples 4 taps from `AutoAccumB`:
   $$14,400 \times 4 = 57,600 \text{ texture fetches (1440p)}$$
   $$32,400 \times 4 = 129,600 \text{ texture fetches (4K)}$$

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
   `PS_MotionAvg` samples an evenly spaced $16 \times 16$ grid across normalized UV coordinates `[0, 1]`—**exactly 256 samples**.

### 3.2 The Design Rationale
The original architecture declares `texMotionCoarse` as `BUFFER_WIDTH / 16` by `BUFFER_HEIGHT / 16` so that every coarse block texel represents an aspect-ratio-correct 16x16 pixel region of the render buffer. `PS_MotionAvg` then performs a sparse 16x16 point sampling grid across that buffer to compute a lightweight screen-wide statistic. Keeping `texMotionCoarse` buffer-relative preserves the game's aspect ratio and ensures predictable behavior across varied resolutions (1080p, 1440p, 4K, ultrawide).

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
2. **Preserve `SV_Position` Signatures**: Retain `float4 pos : SV_Position` on all pixel shaders to prevent ReShade parameter binding failure and UV corruption.
3. **Retain Aspect-Correct Coarse Motion Target**: Keep `texMotionCoarse` sized to `BUFFER_WIDTH / 16` and `BUFFER_HEIGHT / 16` to preserve screen aspect ratio and sampling alignment across resolutions.
