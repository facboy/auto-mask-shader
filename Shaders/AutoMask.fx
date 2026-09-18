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

//Skeleton: both techniques currently just copy the frame through, so the effect
//loads and the pass wiring can be checked before there is a mask to build.
float4 PS_PassThrough(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, uv);
}

//Techniques
technique AutoMask
{
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_PassThrough;
	}
}

technique AutoMask_Restore
{
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_PassThrough;
	}
}
