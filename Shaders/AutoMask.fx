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
//The deadband. It exists only to tolerate capture noise -- temporal
//anti-aliasing, dithering, an engine's own jitter -- which makes a pixel that is
//visually static still differ between frames. Nothing about the signal requires
//it: comparing two textures that hold the same pixels gives exactly 0, and 0 is
//already under any threshold here.
//The units are 1/255 of the colour range, but do NOT assume one level is the
//smallest possible change: that holds only on an 8-bit frame, and it was measured
//false here -- lowering this below 1 visibly reduces how many pixels test as
//stable, so sub-level differences exist in practice. Treat it as a continuous
//tolerance. 0 disables the shader, because `diff < 0` is never true.
uniform float UIMaskEps <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "RGB step counted as a change";
	ui_tooltip = "How far a pixel may move between frames and still count as holding still, in units of 1/255 of the colour range. Raise it if a static HUD will not form a mask; lower it if moving scenery still accumulates. 0 disables the shader";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 8.0;
	ui_step = 0.1;
> = 1.0;

//Confidence gained per still frame. With the default of 0.25, two consecutive
//still frames put a pixel over the 0.5 protection threshold -- a HUD is protected
//almost as soon as it stops moving, which is the behaviour the whole idea rests
//on. It was 0.07, needing eight frames, and combined with a fall nearly three
//times as fast as the rise that meant a pixel had to be still nearly every single
//frame or never accumulate at all. That is why nothing ever reached the threshold.
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
	ui_tooltip = "Bridges brief animation. A draining bar or a scrolling grid needs this long enough to cover the movement. It absorbs the first frames of movement before any of it is remembered, so it also covers the one full-screen change after a load or a resize, when the previous frame is still blank";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 15.0;

//Stillness is only a hint -- a wall holds still too. Motion is proof: it is drawn
//by something the game re-renders from a new viewpoint or a new pose, never by a
//panel painted into the same pixels every frame. So movement does not merely miss
//the rise, it is remembered, and the memory outlives the movement itself. A pixel
//just seen moving cannot be claimed as interface the instant the camera stops over
//it, which is the commonest false positive there is: pan past a wall, stop, and
//without this the wall is protected two frames later.
//The memory lives in the sign of the confidence, where there was room for it. A
//negative value is a pixel that is not interface and is not about to be, and
//everything downstream reads the map at 0.5, so a negative is simply unmasked with
//no extra term in any pass. The depth is proportional to how far the pixel moved,
//so one drifting at the deadband owes a fraction of a frame's worth and one the
//camera swung past owes the lot.
//It is measured in frames, and heals at its own rate, because the two ends of the
//same number run on different timescales. Protection has to take two frames or the
//shader is useless on a HUD; staying out of the mask has to outlast a camera
//movement, which is seconds. A still frame gives back one frame's worth of the
//debt and not the next rise, so this is how long the move is remembered for.
//A value that is too large is the one mistake that hides itself: a region held out
//of the mask looks exactly like a region nothing was ever drawn in.
uniform float UIMaskMoveMemory <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Frames a move is remembered";
	ui_tooltip = "How long a pixel the frame shows as moving stays out of the mask. A full-magnitude move costs one 'Confidence lost' of confidence and a still frame pays back a single frame's worth of it, so this is roughly how many still frames pass before the pixel can begin earning protection again -- at 60fps, 90 frames is a second and a half. It is the cost of walking past scenery and then standing still. Below 1 it is off, and only the per-frame fall remains";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 600.0;
	ui_step = 5.0;
> = 90.0;

//Dilate radius in pixels. The loop is bounded by a fixed maximum because a
//uniform bound cannot bound a loop that the compiler may unroll, so keep the
//slider and the constant in step.
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

//The stillness gate. Off by default, and that is deliberate: standing still is
//exactly when a HUD should be detected, so freezing the accumulator on a still
//frame stops the mask forming in the most common case. It exists only for the
//one scene it was written for -- an interior with no ambient animation at all --
//and it should stay off unless that is what you are looking at.
uniform float UIMaskMotion <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Motion needed for a live frame (percent)";
	ui_tooltip = "Below this much of the screen moving, the map is held instead of advanced. Read from the mean motion across the screen, so a few pixels in full flight count for less than a large area in modest motion. Off at 0, which is the default; turn it on only if a scene with nothing animating in it fills the mask with scenery";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float UIMaskSettle <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Still frames tolerated before the hold starts";
	ui_tooltip = "How long a scene that has stopped keeps being looked at before the map locks. Must be long enough for a panel to form, so it needs to exceed 0.5 divided by 'Confidence gained'";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 120.0;
	ui_step = 1.0;
> = 12.0;

//Targets
//The accumulator ping-pongs because a target cannot be read while it is written,
//and there are no atomics or compute shaders in this dialect.
//.r confidence, and the sign carries the memory: a pixel the frame has called
//moving sits below zero, owing frames, until stillness pays them back. .g frames
//of absence (the hold), .b this frame's motion magnitude (the gate reads it),
//.a still frames (the gate's counter).
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

//The gate's two readings: a block average of the per-pixel motion, then the 1x1
//number that reduces it -- how much of the screen is in motion. Both are
//sub-resolution, so they are cheap, and the 1x1 is read by the next frame's
//accumulate.
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
//then decays. Motion is the stronger evidence and reaches further: once it has
//outlasted the hold it is banked, and the pixel is kept below the threshold until
//that debt is paid off by holding still. So a brief movement is bridged and a
//sustained one is a verdict.
//The one thing above all of it is the frame-wide stillness gate: below
//UIMaskMotion percent of the screen moving, the accumulator carries its state
//over unchanged rather than judging pixels on a frame the world is not drawing.
//Read A, write B.
float4 PS_Accum(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 now = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 before = tex2D(AutoHistory, texcoord).rgb;
	float3 diff = abs(now - before) * 255.0;
	float maxDiff = max(diff.r, max(diff.g, diff.b));
	//Graded rather than a step, and on a curve rather than a ramp, so how far a pixel
	//moved decides both what it pays and how long it is kept out. The curve is what
	//lets the same number serve both: linear in the change would hand the whole
	//memory to a pixel one step over the deadband, which is exactly where capture
	//noise lives, and a HUD pixel that keeps nudging the deadband would then be kept
	//out of the mask for good. Smoothed, a marginal twitch owes almost nothing and a
	//real move still owes the lot. The low edge is floored so the expression
	//survives UIMaskEps = 0, which is documented as off.
	float edge = max(UIMaskEps, 0.001);
	float motion = smoothstep(edge, edge * 4.0, maxDiff);
	float stable = maxDiff < UIMaskEps ? 1.0 : 0.0;

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;
	float still = prev.a;

	//The gate's statistic is the previous frame's, so the gate acts one frame after
	//the motion actually stopped. That latency is what lets every pass read only
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
		//A still frame pays back one frame's worth of the debt and nothing more, so
		//the debt -- which is a whole number of frames of UIMaskFall -- takes exactly
		//that many still frames to clear, and protection is earned again only once it
		//is clear. That is what holds a pixel the frame has just called moving out of
		//the mask for the memory's duration rather than for the two frames a rise
		//would take.
		conf = conf < 0.0 ? min(0.0, conf + UIMaskFall) : min(1.0, conf + UIMaskRise);
		held = 0.0;
	} else if (held < UIMaskForget){
		//The hold comes first, so briefly animating interface is bridged rather
		//than remembered, and the single full-screen change after a load or a
		//resize -- when the stored frame is still blank -- is absorbed here too.
		held += 1.0;
	} else {
		//What the change costs, and then what it is remembered for, with the memory as
		//a lower bound rather than a second subtraction: taking the lower of the two
		//is what makes it impossible for any arrangement of the sliders to let a move
		//raise a pixel or a still frame deepen a hole. The depth is graded, so a pixel
		//drifting at the deadband owes a fraction of a frame while one the camera
		//swung past owes the lot. At the default memory it is the hold that pays for
		//it -- fifteen frames of it are spent before any is banked -- which is what
		//keeps briefly animating interface protected.
		conf = conf - UIMaskFall * motion;
		if (UIMaskMoveMemory > 0.0){
			//The memory is switched off by setting it to zero, and then the bound is
			//lifted rather than applied: a bound of zero is a stricter verdict than
			//any memory asks for, where the intent is only the per-frame fall.
			conf = min(conf, -UIMaskFall * UIMaskMoveMemory * motion);
		}
	}

	//Clamped here because the memory is what the sign of this channel is carrying,
	//so it has to be bounded to be payable: the floor is the deepest a single move
	//can reach, which is what makes the heal take 'Frames a move is remembered' and
	//not arbitrarily longer. It bounds a value the map never reads -- everything
	//downstream reads the map at 0.5, and this stays below it -- so nothing else has
	//to know about it.
	//.b is the raw motion magnitude, recorded here because this pass is the only
	//one that can measure it. The two passes below average it into a 1x1 number.
	return float4(clamp(conf, -UIMaskFall * UIMaskMoveMemory, 1.0), held, motion, still);
}

//First half of the gate's measurement: block average the per-pixel motion down to
//a sixteenth of the resolution. It runs after the accumulate, whose magnitude is
//its only input, and its output is what the *next* frame reads.
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
	//The mean motion of the block, which the 1x1 pass reduces again. It used to be
	//a mean of a 0/1 still flag, where a block one pixel over the deadband counted
	//exactly as much as a block in full motion; the magnitude makes the screen-wide
	//reading a measure of movement rather than of how many pixels twitched.
	return float4((sum * 0.25).xxx, 1.0);
}

//Second half: reduce that to the screen's mean motion. A grid of coarse blocks is
//sampled evenly rather than all of them, because at this size the extra taps would
//not change the answer.
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
//Confidence is what is published, not the verdict, and the memory in its sign is
//consumed here for free: both targets on this path are RGBA8, so a negative is
//flattened to zero on the way through, and everything downstream reads the map at
//0.5. A pixel kept out of the mask by its memory and a pixel nothing was drawn in
//therefore arrive as the same zero, which is the whole reason the memory can ride
//in an existing channel rather than needing a target of its own.
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
	//Diagnostics gain: multiplies the frame's motion so the noise floor is visible.
	//Not a tuning knob -- it changes nothing but this view.
	uniform float UIDebugGain <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Diagnostics: motion gain";
		ui_tooltip = "Brightens the per-pixel motion in the overlay, so a change too small to see but large enough to stop a pixel accumulating becomes visible";
		ui_category = "AutoMask";
		ui_min = 1.0; ui_max = 64.0;
		ui_step = 1.0;
	> = 8.0;

	//Reads the state out of the accumulator instead of recomputing it. That is the
	//whole point of drawing it: an independent recomputation could disagree with
	//what the accumulate actually saw, and then this view would be reporting on
	//itself rather than on the shader. .b is the frame's motion magnitude, so red is
	//the changed-ness the verdict was derived from, and the gain is what makes a
	//change at the deadband visible at all.
	//
	//Blue is confidence, drawn at twice scale so that 0.5 -- the value the green
	//and the map threshold sit at -- is full-strength blue. Half-strength blue is
	//therefore the point where a pixel is one still frame from being protected.
	//
	//Green needs both things to be true: confidence at 0.5 (blue full) *and* the
	//pixel's confidence over the map threshold. If blue goes full-strength and
	//green still does not appear, the fault is past the accumulator -- in the map
	//pass, or in which target PS_Accum is bound to. That distinction is the whole
	//reason this instrument exists; green alone cannot show it.
	//
	//Alpha is how much of a remembered move the pixel still owes, as a fraction of
	//the deepest debt. It is the one reading that explains a pixel showing no
	//motion, no blue and no green -- held out by its memory, which is otherwise
	//indistinguishable from a pixel nothing was ever drawn in.
	float4 PS_DebugMap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 state = tex2D(AutoAccumA, texcoord);
		float mask = step(0.5, tex2D(AutoMap, texcoord).r);
		float changed = saturate(state.b * UIDebugGain);
		float conf = saturate(state.r * 2.0);
		float owed = saturate(-state.r / max(UIMaskFall * UIMaskMoveMemory, 0.001));
		return float4(changed, mask, conf, owed);
	}

	//Blends that over the frame so the game underneath is still recognisable.
	//
	//It reads texAutoHistory for the frame, not the back buffer. The back buffer has
	//been through the anti-bloom pass by this point, which has blacked every masked
	//pixel, so compositing over it made the overlay's colours depend on whether
	//anti-bloom was compiled in -- which is not something a diagnostics view should
	//ever do.
	//
	//The magenta block in the bottom-left corner is deliberate: it is always drawn,
	//regardless of what the mask or the motion come out as. Without a fixed
	//marker, "the overlay is not running" and "the overlay is running and showing
	//nothing" look identical on screen, and they need completely different fixes.
	float4 PS_DebugOverlay(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		if (texcoord.x < 0.02 && texcoord.y > 0.98){
			return float4(1.0, 0.0, 1.0, 1.0);
		}
		return lerp(tex2D(AutoHistory, texcoord), float4(tex2D(AutoDebug, texcoord).rgb, 1.0), 0.7);
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
