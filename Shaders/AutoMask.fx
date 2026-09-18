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

//Targets. texAutoMap holds the mask: .r is the HUD/non-HUD value, and everything
//else reads it.
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
//Placeholder for the map, replaced by the accumulator in the next step: seeds
//every pixel as HUD so the overlay and the restore pass are wired to a real
//target rather than an uninitialised one.
float4 PS_MapSeed(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return float4(1.0, 0.0, 0.0, 1.0);
}

float4 PS_PassThrough(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
}

#if UIMaskDiagnostics == 1
	//Paints the map on its own: blue where the pixel is world, green where it is
	//HUD. Everything green means the map is still the placeholder above.
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
		PixelShader = PS_MapSeed;
		RenderTarget = texAutoMap;
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
