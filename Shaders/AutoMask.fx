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

//The finished HUD map: .r is the HUD/non-HUD value, and everything else reads it.
texture texAutoMap { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoMap { Texture = texAutoMap; };

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
//then decays. Nothing else gates this. Read A, write B.
float4 PS_Accum(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 now = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 before = tex2D(AutoHistory, texcoord).rgb;
	float3 diff = abs(now - before) * 255.0;
	float stable = max(diff.r, max(diff.g, diff.b)) < UIMaskEps ? 1.0 : 0.0;

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;

	if (stable > 0.5){
		conf = min(1.0, conf + UIMaskRise);
		held = 0.0;
	} else if (held < UIMaskForget){
		held += 1.0;
	} else {
		conf = max(0.0, conf - UIMaskFall);
	}

	//.b is the raw still flag, recorded here because this pass is the only one
	//that can measure it. The stillness gate averages it in a later step.
	return float4(conf, held, stable, 0.0);
}

//The ping-pong back-edge: B has to come back to A, because the next frame reads A.
float4 PS_Copy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(AutoAccumB, texcoord);
}

//Publishes the accumulated confidence as the map everything else reads.
float4 PS_Map(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return float4(tex2D(AutoAccumA, texcoord).r.xxx, 1.0);
}

//Stores the untouched frame for the next frame's comparison. This has to run
//after PS_Accum, which compares against the *previous* frame: storing first would
//compare the frame against itself and every pixel would read as still.
float4 PS_StoreFrame(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
}

float4 PS_PassThrough(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
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
		PixelShader = PS_Map;
		RenderTarget = texAutoMap;
	}
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_StoreFrame;
		RenderTarget = texAutoHistory;
	}

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
		PixelShader = PS_PassThrough;
	}
}
