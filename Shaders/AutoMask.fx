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
#ifndef AutoMaskDiagnostics
	#define AutoMaskDiagnostics	0		// [0 or 1] 1 draws the generated map over the frame
#endif

#ifndef AutoMaskAntiBloom
	#define AutoMaskAntiBloom		1		// [0 or 1] 1 blacks the masked pixels in the frame the other effects see
#endif

//Uniforms
//RGB change deadband in whole levels out of 255: the smallest change counted as motion, so the
//smallest setting catches every change there is and is the most sensitive the detection goes.
//Raise it if the overlay shows red over genuinely still pixels -- capture noise or dithering -- at
//the price of the smallest movements; lower it to 1 if anything visibly moving reads without red.
//Decides only whether a pixel moved -- what moving then costs is set by the two sliders below
uniform float AutoMaskEps <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "RGB step counted as a change";
	ui_tooltip = "The smallest change in levels out of 255 that counts as motion.\n1 is the most sensitive: any change at all is motion; 2 forgives a one-level difference, and so on.";
	ui_category = "AutoMask";
	ui_min = 1.0; ui_max = 8.0;
	ui_step = 1.0;
> = 1.0;

//Still frames a pixel needs before it is taken for interface. Raised when a backdrop that stops
//when you do keeps getting caught; lowered when a HUD that only briefly holds still fails to appear.
//A pixel seen moving repays its move memory first, one frame per still frame, so that countdown has to pass before
//this one starts
uniform float AutoMaskRise <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames still before marked as interface";
	ui_tooltip = "Frames of stillness a pixel needs before it is added to the mask.\nRaise it if scenery is getting caught, lower it if a HUD that briefly holds still fails to appear.";
	ui_category = "AutoMask";
	ui_min = 1.0; ui_max = 100.0;
	ui_step = 1.0;
> = 2.0;

//Changing frames a pixel needs before it is dropped from the interface. Keep it short enough that
//the world takes the mask back promptly, long enough that one stray changing frame cannot punch
//holes in a protected element. Frames the RGB step calls still cost nothing.
uniform float AutoMaskFall <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames moving before unmarked as interface";
	ui_tooltip = "Frames of change before a pixel is dropped from the mask.\nLower takes regions back faster, higher makes the mask linger.";
	ui_category = "AutoMask";
	ui_min = 1.0; ui_max = 100.0;
	ui_step = 1.0;
> = 2.0;

//Bridges brief animation. Also covers the one full-screen change after a load or a resize, when
//the previous frame is still blank.
uniform float AutoMaskForget <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames of absence before decay starts";
	ui_tooltip = "Frames of animation absorbed before decay starts, so a draining health bar or scrolling list keeps its mask.\nOnly applies while the world is being drawn";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 15.0;

//Frames a moving pixel remains penalized before earning protection again. A frame the RGB step
//calls moving costs one frame of the unmarking countdown, however small the change was, and a
//still frame pays one back -- at 60fps, 90 frames is a second and a half.
//The repayment runs even while the world is stopped, so this is also how long a screen-wide move takes to clear.
uniform float AutoMaskMoveMemory <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames a move is remembered";
	ui_tooltip = "Still frames after a move before the pixel can be claimed as interface again.\n0 forgets a move the frame after it happens";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 600.0;
	ui_step = 5.0;
> = 90.0;

#define AUTOMASK_DILATE_MAX 3
uniform float AutoMaskDilate <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Closing radius in pixels";
	ui_tooltip = "Grows the mask to close anti-aliased edges and text. 0 is a pass-through";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 3.0;
	ui_step = 1.0;
> = 1.0;

uniform float AutoMaskEdge <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Luma step counted as a boundary";
	ui_tooltip = "Stops the closing radius at a real HUD contour instead of growing it out into the scenery";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 255.0;
	ui_step = 1.0;
> = 40.0;

//Minimum screen motion coverage required to credit stillness as interface. The premise rather
//than a refinement: below it there is no verdict to make, so nothing changes except what moves.
//Above it the mask advances, below it the mask is held: nothing is added and nothing is lost except what moves.
//Raise it if scenery is getting caught, lower it if a HUD fails to appear
uniform float AutoMaskMotion <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Motion needed to trust stillness (percent)";
	ui_tooltip = "How much of the screen must be changing before the world counts as being drawn and stillness can be taken for interface.";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 20.0;

//Elliptical center deadzone suppressing accumulation on camera-tethered characters. Applies only
//while the world is drawn when AutoMaskDeadzoneMotionOnly is set.
uniform float AutoMaskDeadzoneWidth <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone width (percent)";
	ui_tooltip = "Width of the elliptical center region where stillness is not accumulated.\nSet above 0 to keep a third-person character from being captured as interface.\n0 disables the deadzone";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float AutoMaskDeadzoneHeight <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone height (percent)";
	ui_tooltip = "Height of the elliptical center deadzone. 0 disables the deadzone";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float AutoMaskDeadzoneY <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone vertical position (percent)";
	ui_tooltip = "Vertical center of the deadzone (50 is screen center, higher moves it down toward the character's feet, lower moves it up)";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 55.0;

uniform bool AutoMaskDeadzoneMotionOnly <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Only suppress deadzone while world moves";
	ui_tooltip = "On, the deadzone suppresses accumulation only while the world is being drawn,\nso full-screen menus can still build a mask over a stopped scene.\nOff, it suppresses at all times";
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

#if AutoMaskDiagnostics == 1
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
	//The deadband is a level count, so it is read as whole levels: a change of that many levels or
	//more is motion, anything less is still. The ramp spans a fixed three levels, footed one under
	//-- zero at the smallest setting, so any change at all is caught -- so the setting's own level
	//reads a quarter-strength change at every position.
	float deadband = max(ceil(AutoMaskEps), 1.0);
	float motion = smoothstep(deadband - 1.0, deadband + 2.0, maxDiff);
	float stable = maxDiff < deadband ? 1.0 : 0.0;

	//The two sliders speak in frames; the accumulator is confidence against the 0.5 verdict step, so
	//a frame of credit is that step divided by the slider, kept a hair above the exact share so the
	//half-precision accumulator crosses the step on the frame it should and not one frame either way.
	float gain = 0.504 / max(AutoMaskRise, 1.0);
	float cost = 0.504 / max(AutoMaskFall, 1.0);

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;

	//Whether the world is being drawn, measured on the previous frame.
	float live = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0;
	bool drawn = live > AutoMaskMotion;

	bool inDeadzone = false;
	if (AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
		float rx = AutoMaskDeadzoneWidth * 0.005;
		float ry = AutoMaskDeadzoneHeight * 0.005;
		float2 offset = float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01);
		if (dot(offset / float2(rx, ry), offset / float2(rx, ry)) <= 1.0){
			inDeadzone = !AutoMaskDeadzoneMotionOnly || drawn;
		}
	}

	if (stable > 0.5 && !inDeadzone){
		//Still, so nothing is animating here: end any bridge that was running.
		held = 0.0;
		//A drawn world turns stillness into interface: repay debt, then earn. A stopped
		//one cannot tell a held HUD from its own backdrop, so it changes nothing else.
		if (drawn){
			if (conf < 0.0){
				conf = min(0.0, conf + cost);
			} else {
				conf = min(1.0, conf + gain);
			}
		}
	} else if (drawn && held < AutoMaskForget && !inDeadzone){
		//Bridge brief animation before decay starts.
		held += 1.0;
	} else {
		//Decay confidence and bank move debt: the fall never waits on the world being drawn, and a
		//frame the deadband calls changing costs the same however small the change was.
		conf = conf - cost * (1.0 - stable);
		if (AutoMaskMoveMemory > 0.0){
			conf = min(conf, -cost * AutoMaskMoveMemory * (1.0 - stable));
		}
	}

	if (inDeadzone){
		conf = min(conf, 0.0);
		held = 0.0;
	}

	return float4(clamp(conf, -cost * AutoMaskMoveMemory, 1.0), held, motion, 1.0);
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
	float r = floor(AutoMaskDilate + 0.5);
	float mask = tex2D(AutoAccumA, texcoord).r;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(i * texel.x, 0.0);
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (abs(float(i)) <= r && edge <= AutoMaskEdge) ? 1.0 : 0.0;
		mask = max(mask, tex2D(AutoAccumA, uv).r * keep);
	}
	return float4(mask.xxx, 1.0);
}

float4 PS_DilateV(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(AutoMaskDilate + 0.5);
	float mask = tex2D(AutoDilate, texcoord).r;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(0.0, i * texel.y);
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (abs(float(i)) <= r && edge <= AutoMaskEdge) ? 1.0 : 0.0;
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

#if AutoMaskAntiBloom == 1
	//Blacks masked UI pixels in back buffer to suppress bloom bleeding.
	float4 PS_AntiBloom(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 frame = tex2D(ReShade::BackBuffer, texcoord).rgb;
		float mask = step(0.5, tex2D(AutoMap, texcoord).r);
		return float4(frame * (1.0 - mask), 1.0);
	}
#endif

#if AutoMaskDiagnostics == 1
	//Diagnostics view toggle. Both readings tint only the pixels they name.
	uniform bool UIDebugMotion <
		__UNIFORM_SLIDER_BOOL1
		ui_label = "Diagnostics: motion view";
		ui_tooltip = "On, the overlay shows red where the frame sees a change.\nOff, it shows green where a pixel has earned protection, without the closing radius.\nThe deadzone ring and the corner marker show in both";
		ui_category = "AutoMask";
	> = true;

	//Motion visualization gain for diagnostics overlay.
	uniform float UIDebugGain <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Diagnostics: motion gain";
		ui_tooltip = "Brightens the red motion reading in the overlay,\nso a change too small to see becomes visible";
		ui_category = "AutoMask";
		ui_min = 1.0; ui_max = 64.0;
		ui_step = 1.0;
	> = 8.0;

	//Packs diagnostic channels: .r=motion, .g=static-UI verdict, .b=static-UI verdict, .a=screen state.
	float4 PS_DebugMap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 accum = tex2D(AutoAccumA, texcoord);
		float verdict = step(0.5, accum.r);
		float changed = saturate(accum.b * UIDebugGain);
		float drawn = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0 > AutoMaskMotion;
		float screen = drawn ? 1.0 : 0.0;
		return float4(changed, verdict, verdict, screen);
	}
#endif

//Restores stored UI pixels over processed frame.
float4 PS_Restore(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 live = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 stored = tex2D(AutoFrame, texcoord).rgb;
	float mask = step(0.5, tex2D(AutoMap, texcoord).r);
	float3 color = lerp(live, stored, mask);

	#if AutoMaskDiagnostics == 1
		//Tint over the restore, drawn after it so it sits on top of the stored UI rather than being
		//repainted by it: red where the motion view sees a change, green where the verdict view
		//sees protection, nothing at all where it does not.
		float4 debug = tex2D(AutoDebug, texcoord);
		float tint = UIDebugMotion ? debug.r : debug.g;
		float3 mark = UIDebugMotion ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
		color = lerp(color, mark, tint * 0.7);

		if (AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
			float rx = AutoMaskDeadzoneWidth * 0.005;
			float ry = AutoMaskDeadzoneHeight * 0.005;
			float2 offset = float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01);
			float dist = length(offset / float2(rx, ry));
			float ring = 1.0 - saturate(abs(dist - 1.0) / max(fwidth(dist) * 1.5, 0.001));
			color = lerp(color, float3(1.0, 1.0, 0.0), ring * 0.85);
		}

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

	#if AutoMaskAntiBloom == 1
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_AntiBloom;
		}
	#endif

	#if AutoMaskDiagnostics == 1
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_DebugMap;
			RenderTarget = texAutoDebug;
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
