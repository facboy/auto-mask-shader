//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
//
// AutoMask
// License: MIT (see LICENSE)
// Concept, store/restore pattern and anti-bloom from UIDetectMulti by Kaiser,
// which builds on work by Brussels1. https://github.com/Kaiser-R/Reshade-Shaders
//
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

//Requirements
#include "ReShadeUI.fxh"
#include "ReShade.fxh"

//Switches. Both are preprocessor definitions rather than sliders, so their
//passes and targets can be elided from the bytecode entirely. `#ifndef` lets a
//ReShade-level definition or a preset override them without editing this file.
#ifndef UIMaskDiagnostics
	#define UIMaskDiagnostics	0		// [0 or 1] 1 draws the generated map over the frame
#endif

#ifndef UIMaskAntiBloom
	#define UIMaskAntiBloom		1		// [0 or 1] 1 blacks the masked pixels in the frame the other effects see
#endif

//Uniforms
uniform float UIMaskEps <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "RGB step counted as a change";
	ui_tooltip = "How far a pixel's colour may move between frames and still count as holding still";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 32.0;
	ui_step = 0.1;
> = 4.0;

uniform float UIMaskRise <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Confidence gained per still frame";
	ui_tooltip = "Lower takes more frames of stillness before a pixel is treated as HUD";
	ui_category = "AutoMask";
	ui_min = 0.005; ui_max = 0.5;
	ui_step = 0.005;
> = 0.07;

uniform float UIMaskFall <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Confidence lost per changing frame";
	ui_tooltip = "Higher clears a region faster once the world starts moving over it again";
	ui_category = "AutoMask";
	ui_min = 0.005; ui_max = 0.5;
	ui_step = 0.005;
> = 0.2;

uniform float UIMaskForget <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames of absence before decay starts";
	ui_tooltip = "Bridges brief animation. A draining bar or a scrolling grid needs this long enough to cover the movement";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 15.0;

//Dilate radius in pixels. The loop is unrolled to a fixed maximum because a
//uniform bound cannot be unrolled, so keep the slider and the constant in step.
#define UIMASK_DILATE_MAX 3
uniform float UIMaskDilate <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Closing radius in pixels";
	ui_tooltip = "Grows the mask to close anti-aliased edges and text. 0 is a pass-through";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 3.0;
	ui_step = 1.0;
> = 1.0;

uniform float UIMaskEdge <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Luma step counted as a boundary";
	ui_tooltip = "Stops the closing radius at a real HUD contour instead of growing it out into the scenery";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 255.0;
	ui_step = 1.0;
> = 40.0;

//The stillness gate. The world normally carries motion, so a frame with almost
//none means the world view is not being drawn and anything that looks stable is
//stable for the wrong reason.
uniform float UIMaskMotion <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Motion needed for a live frame (percent)";
	ui_tooltip = "Below this much of the screen moving, the map is held instead of advanced. 0 turns the gate off";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 2.0;

uniform float UIMaskSettle <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Still frames before the map is held";
	ui_tooltip = "Lets a panel that opens into an already-paused scene be scanned before the gate locks";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 10.0;

//Targets
//The accumulator ping-pongs because a target cannot be read while it is written,
//and there are no atomics or compute shaders in this dialect.
//.r confidence, .g frames of absence (the hold), .b still flag (the gate reads it)
texture texAutoAccumA { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture texAutoAccumB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler AutoAccumA { Texture = texAutoAccumA; };
sampler AutoAccumB { Texture = texAutoAccumB; };

//The frame the stability test compares against, one frame behind the live one.
texture texAutoHistory { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoHistory { Texture = texAutoHistory; };

//The masked pixels as they were, kept so the restore pass can put them back after
//the user's other effects have run. This has to be the *stored* result, not the
//frame: by the time the restore pass runs, the frame has the black from the
//anti-bloom pass in it, and it has been through every other effect too.
texture texAutoFrame { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoFrame { Texture = texAutoFrame; };

//The dilate runs in two passes, horizontal then vertical, so this holds the
//half-finished result between them.
texture texAutoDilate { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoDilate { Texture = texAutoDilate; };

//The finished HUD map: .r is the HUD/non-HUD value, and everything else reads it.
texture texAutoMap { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoMap { Texture = texAutoMap; };

//The gate's two readings: a block average of the still flag, then a 1x1 number --
//the fraction of the screen that moved. Both are sub-resolution, so they are
//cheap, and the 1x1 is read by the next frame's accumulate.
texture texMotionCoarse { Width = BUFFER_WIDTH / 16; Height = BUFFER_HEIGHT / 16; Format = RGBA8; };
sampler MotionCoarse { Texture = texMotionCoarse; };
texture texMotionStat { Width = 1; Height = 1; Format = RGBA8; };
sampler MotionStat { Texture = texMotionStat; };

#if UIMaskDiagnostics == 1
	//The map is painted into its own target rather than straight onto the back
//buffer, which still has to be copied into the history before anything paints
//over it.
	texture texAutoDebug { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
	sampler AutoDebug { Texture = texAutoDebug; };
#endif

//Pixel shaders
//The whole activation signal: a pixel whose colour has barely moved since the
//last frame accumulates confidence, holds for a grace period once it does move,
//then decays. The one thing above it is the frame-wide stillness gate: below
//UIMaskMotion percent of the screen moving, the accumulator carries its state
//over unchanged rather than judging pixels on a frame the world is not drawing.
//Read A, write B.
float4 PS_Accum(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 now = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 before = tex2D(AutoHistory, texcoord).rgb;
	float3 diff = abs(now - before) * 255.0;
	float stable = max(diff.r, max(diff.g, diff.b)) < UIMaskEps ? 1.0 : 0.0;

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;
	float still = prev.a;

	//The statistic is the previous frame's, so the gate acts one frame after the
	//motion actually stopped. That latency is what lets every pass read only
	//targets it is not writing.
	float live = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0;
	if (live < UIMaskMotion){
		still = min(255.0, still + 1.0);
	} else {
		still = 0.0;
	}

	if (still >= UIMaskSettle){
		//Held: no rise, no hold, no decay. The pixel's verdict is not touched --
		//the accumulator simply stops advancing.
	} else if (stable > 0.5){
		conf = min(1.0, conf + UIMaskRise);
		held = 0.0;
	} else if (held < UIMaskForget){
		held += 1.0;
	} else {
		conf = max(0.0, conf - UIMaskFall);
	}

	//.b is the raw still flag, recorded here because this pass is the only one
	//that can measure it. The two passes below average it into a 1x1 number.
	return float4(conf, held, stable, still);
}

//First half of the gate's measurement: block average the still flag down to a
//sixteenth of the resolution. It runs after the accumulate, whose flag is its
//only input, and its output is what the *next* frame reads.
float4 PS_Motion(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	//One texel here covers a 16x16 block, so the taps span the block's interior
	//rather than its edge.
	float step = 1.0 / 16.0;
	float sum = 0.0;
	for (int y = 0; y < 2; y++){
		for (int x = 0; x < 2; x++){
			float2 uv = texcoord + (float2(x, y) - 0.5) * step * 0.5;
			sum += tex2D(AutoAccumB, uv).b;
		}
	}
	return float4((sum * 0.25).xxx, 1.0);
}

//Second half: reduce that to one number, the fraction of the screen that moved.
//A grid of coarse blocks is sampled evenly rather than all of them, because at
//this size the extra taps would not change the answer.
float4 PS_MotionAvg(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float sum = 0.0;
	for (int y = 0; y < 16; y++){
		for (int x = 0; x < 16; x++){
			float2 uv = (float2(x, y) + 0.5) / 16.0;
			sum += tex2D(MotionCoarse, uv).r;
		}
	}
	//Sampled blocks that held still contribute 1.0 each, so the moving fraction is
	//what is left.
	return float4(1.0 - sum / 256.0, 0.0, 0.0, 1.0);
}

//The ping-pong back-edge: B has to come back to A, because the next frame reads A.
float4 PS_Copy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(AutoAccumB, texcoord);
}

//Publishes the map everything else reads: the accumulated confidence, closed by
//a dilate stopped where the luma step in the frame exceeds UIMaskEdge, so it
//snaps to a real contour instead of growing a fixed radius into the scenery.
//Split horizontally then vertically: a max over a rectangle equals a max of two
//1D passes, and two 7-tap passes are far cheaper than one 49-tap pass.
//No loop in this file is forced with [unroll]. ReShade's compiler rejected a
//forced unroll here outright (X3511, "unrolled loop is too large"), while this
//repository's offline check did not reproduce that on any installed fxc -- so
//the offline check does not model ReShade's limit, and the safe course is not to
//force an unroll at all. The companion pack, which is known to load in-game,
//contains none.
//The sliders limit the taps arithmetically rather than with `continue`, so the
//loop body has no data-dependent control flow.
float4 PS_DilateH(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(UIMaskDilate + 0.5);
	float mask = tex2D(AutoAccumA, texcoord).r;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));

	for (int i = -UIMASK_DILATE_MAX; i <= UIMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(i * texel.x, 0.0);
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (abs(float(i)) <= r && edge <= UIMaskEdge) ? 1.0 : 0.0;
		mask = max(mask, tex2D(AutoAccumA, uv).r * keep);
	}
	return float4(mask.xxx, 1.0);
}

float4 PS_DilateV(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(UIMaskDilate + 0.5);
	float mask = tex2D(AutoDilate, texcoord).r;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));

	for (int i = -UIMASK_DILATE_MAX; i <= UIMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(0.0, i * texel.y);
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (abs(float(i)) <= r && edge <= UIMaskEdge) ? 1.0 : 0.0;
		mask = max(mask, tex2D(AutoDilate, uv).r * keep);
	}
	return float4(mask.xxx, 1.0);
}

//Keeps the frame where the map says HUD, into its own target, so the restore pass
//has the real pixels to put back once the anti-bloom pass has blacked them and the
//user's other effects have run.
float4 PS_Store(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float mask = step(0.5, tex2D(AutoMap, texcoord).r);
	return float4(tex2D(ReShade::BackBuffer, texcoord).rgb * mask, 1.0);
}

//Stores the untouched frame for the next frame's comparison. This has to run
//after PS_Accum, which compares against the *previous* frame: storing first would
//compare the frame against itself and every pixel would read as still.
float4 PS_StoreFrame(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
}

#if UIMaskAntiBloom == 1
	//Blacks the masked pixels in the frame the rest of the chain sees, so a bloom
	//pass downstream finds no HUD brightness to bleed over the scene. Unmasked
	//pixels pass through untouched. The HUD is not lost: what is stored above is
	//the real thing, and the restore pass puts it back.
	float4 PS_AntiBloom(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 frame = tex2D(ReShade::BackBuffer, texcoord).rgb;
		float mask = step(0.5, tex2D(AutoMap, texcoord).r);
		return float4(frame * (1.0 - mask), 1.0);
	}
#endif

//Puts the stored HUD pixels back on top after the user's other effects have run,
//leaving everything else as the live frame.
float4 PS_Restore(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 live = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 stored = tex2D(AutoFrame, texcoord).rgb;
	float mask = step(0.5, tex2D(AutoMap, texcoord).r);
	return float4(lerp(live, stored, mask), 1.0);
}

#if UIMaskDiagnostics == 1
	//Paints the map on its own: blue where the pixel is world, green where it is
	//HUD. Nothing has been stored yet, so the map is the confidence field at this
	//point and green comes in gradually.
	float4 PS_DebugMap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float mask = tex2D(AutoMap, texcoord).r;
		return float4(lerp(float3(0.0, 0.0, 0.35), float3(0.1, 1.0, 0.1), mask), 1.0);
	}

	//Blends that over the frame so the game underneath is still recognisable.
	float4 PS_DebugOverlay(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		return lerp(tex2D(ReShade::BackBuffer, texcoord), float4(tex2D(AutoDebug, texcoord).rgb, 1.0), 0.7);
	}
#endif

//Techniques
technique AutoMask
{
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Accum;
		RenderTarget = texAutoAccumB;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Copy;
		RenderTarget = texAutoAccumA;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Motion;
		RenderTarget = texMotionCoarse;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_MotionAvg;
		RenderTarget = texMotionStat;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_DilateH;
		RenderTarget = texAutoDilate;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_DilateV;
		RenderTarget = texAutoMap;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Store;
		RenderTarget = texAutoFrame;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_StoreFrame;
		RenderTarget = texAutoHistory;
	}

	#if UIMaskAntiBloom == 1
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_AntiBloom;
		}
	#endif

	#if UIMaskDiagnostics == 1
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_DebugMap;
			RenderTarget = texAutoDebug;
		}
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_DebugOverlay;
		}
	#endif
}

technique AutoMask_Restore
{
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Restore;
	}
}
