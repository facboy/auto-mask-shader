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

//Switches
#ifndef UIMaskDiagnostics
	#define UIMaskDiagnostics	0		// [0 or 1] 1 draws the generated map over the frame
#endif

#ifndef UIMaskAntiBloom
	#define UIMaskAntiBloom		1		// [0 or 1] 1 blacks the masked pixels in the frame the other effects see
#endif

//Uniforms
//RGB change deadband tolerating capture noise and jitter (1/255 units). 0 disables the shader.
uniform float UIMaskEps <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "RGB step counted as a change";
	ui_tooltip = "How far a pixel may move between frames and still count as holding still, in units of 1/255 of the colour range. Raise it if a static HUD will not form a mask; lower it if moving scenery still accumulates. 0 disables the shader";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 8.0;
	ui_step = 0.1;
> = 1.0;

//Confidence gained per still frame.
uniform float UIMaskRise <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Confidence gained per still frame";
	ui_tooltip = "How quickly a pixel earns protection once it stops moving. At 0.25 two still frames are enough; lower it to demand a longer run of stillness";
	ui_category = "AutoMask";
	ui_min = 0.005; ui_max = 1.0;
	ui_step = 0.005;
> = 0.25;

uniform float UIMaskFall <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Confidence lost per changing frame";
	ui_tooltip = "Higher clears a region faster once the world starts moving over it again. Keep it above 'Confidence gained' or the mask will linger over moving scenery. A change smaller than the deadband costs proportionally less";
	ui_category = "AutoMask";
	ui_min = 0.005; ui_max = 1.0;
	ui_step = 0.005;
> = 0.5;

uniform float UIMaskForget <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames of absence before decay starts";
	ui_tooltip = "Bridges brief animation. A draining bar or a scrolling grid needs this long enough to cover the movement. It absorbs the first frames of movement before any of it is remembered, so it also covers the one full-screen change after a load or a resize, when the previous frame is still blank. It only applies while the world is being drawn";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 15.0;

//Frames a moving pixel remains penalized before earning protection again.
uniform float UIMaskMoveMemory <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames a move is remembered";
	ui_tooltip = "How long a pixel the frame shows as moving stays out of the mask. A full-magnitude move costs one 'Confidence lost' of confidence and a still frame pays back a single frame's worth of it, so this is roughly how many still frames pass before the pixel can begin earning protection again -- at 60fps, 90 frames is a second and a half. The repayment happens whether or not the world is being drawn, so this is also how long a screen-wide move takes to clear once it stops. Below 1 it is off, and only the per-frame fall remains";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 600.0;
	ui_step = 5.0;
> = 90.0;

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

//Minimum screen motion coverage required to credit stillness as interface.
uniform float UIMaskMotion <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Motion needed to trust stillness (percent)";
	ui_tooltip = "How much of the screen has to be changing before the world counts as being drawn and a pixel that is not moving can be taken for interface. Above it the mask advances; below it the scene is static, nothing is drawn in place, and there is no verdict to make, so the mask is held instead -- a pixel that holds still keeps what it has and one that is moving still falls. Raise it if scenery is still getting caught while the view is quiet, lower it if a HUD fails to appear";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 20.0;

//Elliptical center deadzone suppressing accumulation on camera-tethered characters.
uniform float UIMaskDeadzoneWidth <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone width (percent)";
	ui_tooltip = "Width of an elliptical center region where stillness is not accumulated. Set above 0 to prevent a third-person player character from being captured as interface. 0 disables the deadzone";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float UIMaskDeadzoneHeight <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone height (percent)";
	ui_tooltip = "Height of the elliptical center deadzone. 0 disables the deadzone";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float UIMaskDeadzoneY <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone vertical position (percent)";
	ui_tooltip = "Vertical center of the deadzone (50 is screen center, higher moves it down toward the character's feet, lower moves it up)";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 55.0;

uniform bool UIMaskDeadzoneMotionOnly <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Only suppress deadzone while world moves";
	ui_tooltip = "When enabled, the deadzone only suppresses accumulation while the world is being drawn. When the scene is still, full-screen menus can accumulate even inside the deadzone. When disabled, the deadzone is suppressed at all times";
	ui_category = "AutoMask";
> = false;

//Targets
//Accumulator ping-pong: .r=confidence/debt, .g=hold, .b=motion
texture texAutoAccumA { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
texture texAutoAccumB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler AutoAccumA { Texture = texAutoAccumA; };
sampler AutoAccumB { Texture = texAutoAccumB; };

//Previous untouched frame for stability comparison.
texture texAutoHistory { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoHistory { Texture = texAutoHistory; };

//Stored UI pixels to restore after downstream effects.
texture texAutoFrame { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoFrame { Texture = texAutoFrame; };

//Intermediate target for separable dilation.
texture texAutoDilate { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoDilate { Texture = texAutoDilate; };

//Published HUD map (.r is HUD mask).
texture texAutoMap { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoMap { Texture = texAutoMap; };

//Motion reduction targets: coarse downscale and 1x1 global coverage statistic.
texture texMotionCoarse { Width = 16; Height = 16; Format = RGBA8; };
sampler MotionCoarse { Texture = texMotionCoarse; };
texture texMotionStat { Width = 1; Height = 1; Format = RGBA8; };
sampler MotionStat { Texture = texMotionStat; };

#if UIMaskDiagnostics == 1
	texture texAutoDebug { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
	sampler AutoDebug { Texture = texAutoDebug; };
#endif

//Pixel shaders
//Accumulates confidence from stillness while the world is drawn; a stopped world can only lose it.
float4 PS_Accum(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 now = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 before = tex2D(AutoHistory, texcoord).rgb;
	float3 diff = abs(now - before) * 255.0;
	float maxDiff = max(diff.r, max(diff.g, diff.b));
	float edge = max(UIMaskEps, 0.001);
	float motion = smoothstep(edge, edge * 4.0, maxDiff);
	float stable = maxDiff < UIMaskEps ? 1.0 : 0.0;

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;

	//Whether the world is being drawn, measured on the previous frame.
	float live = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0;
	bool drawn = live > UIMaskMotion;

	bool inDeadzone = false;
	if (UIMaskDeadzoneWidth > 0.0 && UIMaskDeadzoneHeight > 0.0){
		float rx = UIMaskDeadzoneWidth * 0.005;
		float ry = UIMaskDeadzoneHeight * 0.005;
		float2 offset = float2(texcoord.x - 0.5, texcoord.y - UIMaskDeadzoneY * 0.01);
		if (dot(offset / float2(rx, ry), offset / float2(rx, ry)) <= 1.0){
			inDeadzone = !UIMaskDeadzoneMotionOnly || drawn;
		}
	}

	if (stable > 0.5 && !inDeadzone){
		//Still, so nothing is animating here: end any bridge that was running.
		held = 0.0;
		//A drawn world turns stillness into interface: repay debt, then earn. A stopped
		//one cannot tell a held HUD from its own backdrop, so it changes nothing else.
		if (drawn){
			if (conf < 0.0){
				conf = min(0.0, conf + UIMaskFall);
			} else {
				conf = min(1.0, conf + UIMaskRise);
			}
		}
	} else if (drawn && held < UIMaskForget && !inDeadzone){
		//Bridge brief animation before decay starts.
		held += 1.0;
	} else {
		//Decay confidence and bank move debt: the fall never waits on the world being drawn.
		conf = conf - UIMaskFall * motion;
		if (UIMaskMoveMemory > 0.0){
			conf = min(conf, -UIMaskFall * UIMaskMoveMemory * motion);
		}
	}

	if (inDeadzone){
		conf = min(conf, 0.0);
		held = 0.0;
	}

	return float4(clamp(conf, -UIMaskFall * UIMaskMoveMemory, 1.0), held, motion, 1.0);
}

//Downsamples motion flags into coarse block coverage.
float4 PS_Motion(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float blockStep = 1.0 / 16.0;
	float sum = 0.0;
	for (int y = 0; y < 2; y++){
		for (int x = 0; x < 2; x++){
			float2 uv = texcoord + (float2(x, y) - 0.5) * blockStep * 0.5;
			sum += step(0.001, tex2D(AutoAccumB, uv).b);
		}
	}
	return float4((sum * 0.25).xxx, 1.0);
}

//Reduces coarse blocks to global screen motion coverage (1x1).
float4 PS_MotionAvg(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float sum = 0.0;
	for (int y = 0; y < 16; y++){
		for (int x = 0; x < 16; x++){
			float2 uv = (float2(x, y) + 0.5) / 16.0;
			sum += tex2D(MotionCoarse, uv).r;
		}
	}
	return float4((sum / 256.0).xxx, 1.0);
}

//Ping-pong back-edge (copy B to A).
float4 PS_Copy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(AutoAccumB, texcoord);
}

//Horizontal dilation bounded by luma edge threshold.
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

//Stores masked UI pixels before downstream processing.
float4 PS_Store(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float mask = step(0.5, tex2D(AutoMap, texcoord).r);
	return float4(tex2D(ReShade::BackBuffer, texcoord).rgb * mask, 1.0);
}

//Stores untouched frame for next frame's comparison.
float4 PS_StoreFrame(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
}

#if UIMaskAntiBloom == 1
	//Blacks masked UI pixels in back buffer to suppress bloom bleeding.
	float4 PS_AntiBloom(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 frame = tex2D(ReShade::BackBuffer, texcoord).rgb;
		float mask = step(0.5, tex2D(AutoMap, texcoord).r);
		return float4(frame * (1.0 - mask), 1.0);
	}
#endif

//Restores stored UI pixels over processed frame.
float4 PS_Restore(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 live = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 stored = tex2D(AutoFrame, texcoord).rgb;
	float mask = step(0.5, tex2D(AutoMap, texcoord).r);
	float3 color = lerp(live, stored, mask);

	#if UIMaskDiagnostics == 1
		//Bottom-left diagnostic state marker: magenta=live, yellow=stopped.
		if (texcoord.x < 0.02 && texcoord.y > 0.98){
			float state = tex2D(AutoDebug, float2(0.5, 0.5)).a;
			if (state > 0.75){
				return float4(1.0, 0.0, 1.0, 1.0);
			}
			return float4(1.0, 1.0, 0.0, 1.0);
		}
	#endif

	return float4(color, 1.0);
}

#if UIMaskDiagnostics == 1
	//Motion visualization gain for diagnostics overlay.
	uniform float UIDebugGain <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Diagnostics: motion gain";
		ui_tooltip = "Brightens the per-pixel motion in the overlay, so a change too small to see but large enough to stop a pixel accumulating becomes visible";
		ui_category = "AutoMask";
		ui_min = 1.0; ui_max = 64.0;
		ui_step = 1.0;
	> = 8.0;

	//Packs diagnostic channels: .r=motion, .g=mask, .b=confidence/debt, .a=screen state.
	float4 PS_DebugMap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 accum = tex2D(AutoAccumA, texcoord);
		float mask = step(0.5, tex2D(AutoMap, texcoord).r);
		float changed = saturate(accum.b * UIDebugGain);
		float depth = max(UIMaskFall * UIMaskMoveMemory, 0.001);
		float conf = clamp(0.5 + 0.5 * (accum.r < 0.0 ? accum.r / depth : accum.r), 0.0, 1.0);
		float drawn = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0 > UIMaskMotion;
		float screen = drawn ? 1.0 : 0.0;
		return float4(changed, mask, conf, screen);
	}

	//Blends diagnostics map over history frame and draws deadzone guide ring.
	float4 PS_DebugOverlay(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 color = lerp(tex2D(AutoHistory, texcoord), float4(tex2D(AutoDebug, texcoord).rgb, 1.0), 0.7);
		if (UIMaskDeadzoneWidth > 0.0 && UIMaskDeadzoneHeight > 0.0){
			float rx = UIMaskDeadzoneWidth * 0.005;
			float ry = UIMaskDeadzoneHeight * 0.005;
			float2 offset = float2(texcoord.x - 0.5, texcoord.y - UIMaskDeadzoneY * 0.01);
			float dist = length(offset / float2(rx, ry));
			float ring = 1.0 - saturate(abs(dist - 1.0) / max(fwidth(dist) * 1.5, 0.001));
			color.rgb = lerp(color.rgb, float3(1.0, 1.0, 0.0), ring * 0.85);
		}
		return color;
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
