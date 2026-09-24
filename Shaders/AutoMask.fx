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

//Runs the accumulator and gate as compute, so the gate counts every pixel rather than sampling a
//16x16 grid with four taps. Needs D3D11 or newer, or Vulkan.
#ifndef AutoMaskCompute
	#define AutoMaskCompute		0		// [0 or 1] 1 runs the accumulator and the motion gate as compute passes
#endif

//Frame rate the frame-count caps are sized for: each cap is a duration in seconds times this.
#ifndef AutoMaskTargetFPS
	#define AutoMaskTargetFPS		60	// [30 to 240] frame rate the frame-count caps are sized for
#endif

//Uniforms
//One of the four frame-count durations, kept together in the "Frame timing" section: still frames a
//pixel needs before it is taken for interface. A pixel seen moving repays its move memory first, so
//that countdown passes before this one starts.
uniform float AutoMaskRise <
	__UNIFORM_DRAG_FLOAT1
	ui_label = "Frames still before marked as interface";
	ui_tooltip = "Frames of stillness a pixel needs before it is added to the mask.\nRaise it if scenery is getting caught, lower it if a HUD that briefly holds still fails to appear.";
	ui_category = "Frame timing";
	ui_min = 1.0; ui_max = 10.0 * AutoMaskTargetFPS;
	ui_step = 1.0;
> = 0.5 * AutoMaskTargetFPS;

//Changing frames a pixel needs before it is dropped from the interface. Keep it at or under the
//rise, or the mask lingers over moving scenery; frames the RGB step calls still cost nothing.
uniform float AutoMaskFall <
	__UNIFORM_DRAG_FLOAT1
	ui_label = "Frames moving before unmarked as interface";
	ui_tooltip = "Frames of change before a pixel is dropped from the mask.\nLower takes regions back faster, higher makes the mask linger.";
	ui_category = "Frame timing";
	ui_min = 1.0; ui_max = AutoMaskTargetFPS;
	ui_step = 1.0;
> = 2.0;

//Frames of change absorbed as a running balance before decay starts: a changing frame adds one, a
//still frame pays half of one back. Also absorbs the one full-screen change after a load.
uniform float AutoMaskForget <
	__UNIFORM_DRAG_FLOAT1
	ui_label = "Frames of absence before decay starts";
	ui_tooltip = "Frames of change absorbed before decay starts, so a draining health bar or scrolling list keeps its mask.\nA still frame pays half a frame of the balance back; only applies while the world is being drawn";
	ui_category = "Frame timing";
	ui_min = 0.0; ui_max = 5.0 * AutoMaskTargetFPS;
	ui_step = 1.0;
> = 0.25 * AutoMaskTargetFPS;

//Frames a moving pixel stays penalized before it can earn protection again: one frame of countdown
//per changing frame, one paid back per still frame, repaid even while the world is stopped.
uniform float AutoMaskMoveMemory <
	__UNIFORM_DRAG_FLOAT1
	ui_label = "Frames a move is remembered";
	ui_tooltip = "Still frames after a move before the pixel can be claimed as interface again.\n0 forgets a move the frame after it happens";
	ui_category = "Frame timing";
	ui_min = 0.0; ui_max = 10.0 * AutoMaskTargetFPS;
	ui_step = 5.0;
> = 2.0 * AutoMaskTargetFPS;

#define AUTOMASK_DILATE_MAX 3
//The isolation gate's row count rides in texAutoDilate's 8-bit .g, so the whole number is scaled by
//this on the way in and back out, landing it on the same byte at either end.
#define AUTOMASK_COUNT_SCALE 255.0
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

//Minimum screen motion coverage to credit stillness as interface. Below it the mask is held --
//nothing added and only what moves lost; above it the mask advances.
uniform float AutoMaskMotion <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Motion needed to trust stillness (percent)";
	ui_tooltip = "How much of the screen must be changing before the world counts as being drawn and stillness can be taken for interface.";
	ui_category = "AutoMask";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 1.0;
> = 50.0;

#if AutoMaskCompute == 1
	//How long a colour lingers in the average the drift comparison reads, catching a shift too small
	//to cross a level between two frames. 0 turns it off.
	uniform float AutoMaskDrift <
		__UNIFORM_DRAG_FLOAT1
		ui_label = "Drift horizon (seconds)";
		ui_tooltip = "How long the slow colour average the drift comparison reads remembers.\nCatches scenery that shifts by less than a level a frame -- a skybox panning slowly -- which the frame-to-frame comparison cannot see.\n0 turns it off.";
		ui_category = "AutoMask";
		ui_min = 0.0; ui_max = 10.0;
		ui_step = 0.25;
	> = 2.0;
#endif

//RGB change deadband in whole levels out of 255, the smallest change counted as motion. It decides
//only whether a pixel moved; what moving then costs is AutoMaskRise and AutoMaskFall's business. Last
//row of "AutoMask", so it sits directly above the section that measures it.
uniform float AutoMaskEps <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "RGB step counted as a change";
	ui_tooltip = "The smallest change in levels out of 255 that counts as motion.\n1 is the most sensitive: any change at all is motion; 2 forgives a one-level difference, and so on.";
	ui_category = "AutoMask";
	ui_min = 1.0; ui_max = 8.0;
	ui_step = 1.0;
> = 1.0;

#if AutoMaskCompute == 1
	//Gates the floor below, so it must open its own category -- ReShade reads ui_category_toggle off
	//the variable that opens one, and unticking it would hide the rest of "AutoMask" if it lived there.
	//The step measured rather than tuned: on, it is the level the last frame's histogram found the
	//scene's noise floor at. Off, AutoMaskEps applies as on the pixel path.
	uniform bool AutoMaskAutoStep <
		__UNIFORM_SLIDER_BOOL1
		ui_label = "Auto-detect RGB step";
		ui_tooltip = "On, the RGB step is measured from the scene each frame rather than read from the slider.\nThe step is set where only a sliver of the screen still changes above it.";
		ui_category = "RGB step detection";
		ui_category_toggle = true;
	> = false;

	//The measured step is the smallest change size 1-8 at which no more than this share of the screen is
	//still changing by that much or more. Shown only while the toggle above is on, because nothing
	//reads it otherwise.
	uniform float AutoMaskNoiseFloor <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Noise floor (percent)";
		ui_tooltip = "The measured step is the smallest change size 1-8 at which no more than this much of the screen is still changing by that much or more.\nLower forgives more: the step settles higher, so more small movement passes as still.\nHigher keeps the smaller movements, at the cost of admitting more noise as motion.";
		ui_category = "RGB step detection";
		ui_min = 0.0; ui_max = 5.0;
		ui_step = 0.05;
	> = 0.5;
#endif

//Elliptical center deadzone suppressing accumulation on camera-tethered characters, active only
//while the world is drawn when AutoMaskDeadzoneMotionOnly is set. Its own category, gated by the
//checkbox first in it; one block at the end, since a category is a contiguous run.
uniform bool AutoMaskDeadzone <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Enable center deadzone";
	ui_tooltip = "On, the elliptical region below stops accumulating stillness, so a camera-tethered character is not captured as interface.\nOff, a configured deadzone is parked rather than zeroed";
	ui_category = "Center deadzone";
	ui_category_toggle = true;
> = false;

uniform float AutoMaskDeadzoneWidth <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone width (percent)";
	ui_tooltip = "Width of the elliptical center region where stillness is not accumulated.\nSet above 0 to keep a third-person character from being captured as interface";
	ui_category = "Center deadzone";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float AutoMaskDeadzoneHeight <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone height (percent)";
	ui_tooltip = "Height of the elliptical center deadzone";
	ui_category = "Center deadzone";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 0.0;

uniform float AutoMaskDeadzoneY <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Center deadzone vertical position (percent)";
	ui_tooltip = "Vertical center of the deadzone (50 is screen center, higher moves it down toward the character's feet, lower moves it up)";
	ui_category = "Center deadzone";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 0.5;
> = 55.0;

uniform bool AutoMaskDeadzoneMotionOnly <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Only suppress deadzone while world moves";
	ui_tooltip = "On, the deadzone suppresses accumulation only while the world is being drawn,\nso full-screen menus can still build a mask over a stopped scene.\nOff, it suppresses at all times";
	ui_category = "Center deadzone";
> = false;

//Keeps a masked pixel only while enough still pixels are around it, so a lone speck the comparison
//cannot tell from a HUD is not protected. Its own category, gated by the checkbox first in it.
uniform bool AutoMaskIsolated <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Enable isolated pixel removal";
	ui_tooltip = "On, a pixel in the mask is kept only while enough of its neighbourhood is still too, itself counted, so a lone speck of noise or scenery is not protected as interface.\nThe neighbourhood is the isolation radius below, measured as the density below";
	ui_category = "Isolated pixels";
	ui_category_toggle = true;
> = false;

//Share of the neighbourhood that must be still, itself counted, for the gate above. A share rather
//than a count, so it means one thing at every isolation radius: a count would have to be capped at the
//smallest box's area.
uniform float AutoMaskDensity <
	__UNIFORM_DRAG_FLOAT1
	ui_label = "Still neighbourhood density (percent)";
	ui_tooltip = "What share of a masked pixel's neighbourhood must be still, itself counted, for the pixel to stay in the mask.\n0 keeps every pixel, 100 keeps only a fully solid neighbourhood.\nMeasured in steps of 1";
	ui_category = "Isolated pixels";
	ui_min = 0.0; ui_max = 100.0;
	ui_step = 1.0;
> = 33.0;

//How far the neighbourhood reaches, independent of the closing radius: shape and evidence are different
//questions, and tying this to AutoMaskDilate would move the gate's meaning whenever the closing is
//retuned. Shares the closing's fixed loop, so it costs no extra tap.
uniform float AutoMaskIsolation <
	__UNIFORM_SLIDER_FLOAT1
	ui_label = "Isolation radius in pixels";
	ui_tooltip = "How far the density above is measured, as a square 2 x this + 1 across.\nIndependent of the closing radius: the closing is how far the mask is grown, this is how much corroboration a pixel needs";
	ui_category = "Isolated pixels";
	ui_min = 0.0; ui_max = 3.0;
	ui_step = 1.0;
> = 1.0;

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

//Intermediate target for separable dilation. .g carries the isolation gate's row count, the channel
//the closing radius leaves unused.
texture texAutoDilate { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoDilate { Texture = texAutoDilate; };

//Published HUD map (.r is HUD mask).
texture texAutoMap { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoMap { Texture = texAutoMap; };

//The screen-motion gate as compute: a 1x1 integer counter every moved pixel adds to, handed to the
//1x1 float share the pixel passes sample. The accumulator writes as storage, read and written only
//through tex2Dfetch/tex2Dstore -- a bracket fails in ReShade with X3121.
#if AutoMaskCompute == 1
	//The last level the walk measures in, and the end of the AutoMaskEps slider with it.
	#define AUTOMASK_STEP_MAX 8
	texture texAutoMotionCount { Width = 1; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionCount { Texture = texAutoMotionCount; };
	//The change-size histogram: one bin per level the walk speaks in, so the scene itself says where
	//its noise floor is. A pixel that did not change takes no bin at all.
	texture texAutoMotionHist { Width = AUTOMASK_STEP_MAX; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionHist { Texture = texAutoMotionHist; };
	texture texAutoStat { Width = 1; Height = 1; Format = r32f; };
	storage2D<float> AutoStatStore { Texture = texAutoStat; };
	sampler MotionStat { Texture = texAutoStat; };
	//The step measured off that histogram, one frame behind exactly as the share is.
	texture texAutoStep { Width = 1; Height = 1; Format = r32f; };
	storage2D<float> AutoStepStore { Texture = texAutoStep; };
	sampler AutoStep { Texture = texAutoStep; };
	storage2D<float4> AutoAccumStore { Texture = texAutoAccumB; };
	//The drift ping-pong: the long-baseline average needs its own pair -- the accumulator has one
	//spare channel, the average three -- and cannot be half precision, or the creep toward a
	//one-level gap would sit frozen under an RGBA16F ulp.
	texture texAutoDriftA { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F; };
	texture texAutoDriftB { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA32F; };
	//Point filtered: the average is data rather than a picture, so interpolating it would blend one
	//pixel's history into its neighbour's.
	sampler AutoDriftA { Texture = texAutoDriftA; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
	sampler AutoDriftB { Texture = texAutoDriftB; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
	storage2D<float4> AutoDriftStore { Texture = texAutoDriftB; };
#else
	//Motion reduction targets: coarse downscale and 1x1 global coverage statistic.
	texture texMotionCoarse { Width = 16; Height = 16; Format = RGBA8; };
	sampler MotionCoarse { Texture = texMotionCoarse; };
	texture texMotionStat { Width = 1; Height = 1; Format = RGBA8; };
	sampler MotionStat { Texture = texMotionStat; };
#endif

#if AutoMaskDiagnostics == 1
	texture texAutoDebug { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
	sampler AutoDebug { Texture = texAutoDebug; };
#endif

//Pixel shaders
#if AutoMaskCompute == 1
	//Per-group tallies, so the counter and the histogram take a handful of adds per group rather
	//than one per pixel. Every group zeroes them before any of them counts.
	groupshared uint groupChanged;
	groupshared uint groupHist[AUTOMASK_STEP_MAX];

	//The accumulator as compute, plus the moved-pixel count the gate reads. The bounds guard is a
	//predicate, not an early return, because a barrier has to sit in uniform flow control; and
	//compute has no implicit derivatives, so every sample names its level.
	[numthreads(64, 4, 1)]
	void CS_Accum(uint3 tid : SV_DispatchThreadID, uint gi : SV_GroupIndex)
	{
		//The dispatch rounds up, so the last group can cover pixels outside the frame.
		bool live = (tid.x < BUFFER_WIDTH && tid.y < BUFFER_HEIGHT);
		float2 texcoord = (float2(tid.xy) + 0.5) * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

		float3 now = tex2Dlod(ReShade::BackBuffer, float4(texcoord, 0.0, 0.0)).rgb;
		float3 before = tex2Dlod(AutoHistory, float4(texcoord, 0.0, 0.0)).rgb;
		float3 drift = tex2Dlod(AutoDriftA, float4(texcoord, 0.0, 0.0)).rgb;
		//The comparison subtracts the level counts, not the quantized colours: those differ by a float
		//residue -- 0.9999999 for most of the 255 adjacent pairs -- which the deadband would forgive.
		float3 nowLevels = round(now * 255.0);
		float3 beforeLevels = round(before * 255.0);
		now = nowLevels / 255.0;
		//A pinned colour voids stillness on either side of the pair: saturation, not stillness. `all`
		//makes the count a scalar, avoiding the X3206 truncation warning fxc emits for a vector form.
		float clipped = all(now == 0.0.xxx) + all(now == 1.0.xxx)
		              + all(before == 0.0.xxx) + all(before == 1.0.xxx)
		              + all(drift == 0.0.xxx) + all(drift == 1.0.xxx);
		float3 diff = abs(nowLevels - beforeLevels);
		//The long-baseline reading against the same deadband: how far the frame has got from where
		//its colour has been. Either comparison calling it motion is motion.
		float3 driftDiff = abs(now - drift) * 255.0;
		float maxDiff = max(diff.r, max(diff.g, diff.b));
		float maxDrift = max(driftDiff.r, max(driftDiff.g, driftDiff.b));
		//The step is tuned (AutoMaskEps) or measured (last frame's histogram); the clamp keeps an
		//unwritten target off the slider's own scale.
		float deadband = AutoMaskAutoStep
			? clamp(tex2Dlod(AutoStep, float4(0.5, 0.5, 0.0, 0.0)).r, 1.0, 8.0)
			: max(ceil(AutoMaskEps), 1.0);
		float motion = max(smoothstep(deadband - 1.0, deadband + 2.0, maxDiff),
		                   smoothstep(deadband - 1.0, deadband + 2.0, maxDrift));
		float stable = (maxDiff < deadband && maxDrift < deadband && clipped == 0.0) ? 1.0 : 0.0;

		//The average follows the frame a horizon's worth a frame, and snaps to it where the frame is a
		//new picture. The reset is keyed to a wide change rather than the deadband, so the max keeps
		//the two thresholds from collapsing into one.
		float horizon = max(AutoMaskDrift * AutoMaskTargetFPS, 1.0);
		float3 next = (maxDiff < max(deadband, 8.0)) ? lerp(now, drift, 1.0 - 1.0 / horizon) : now;

		float gain = 0.504 / max(AutoMaskRise, 1.0);
		float cost = 0.504 / max(AutoMaskFall, 1.0);

		float4 prev = tex2Dlod(AutoAccumA, float4(texcoord, 0.0, 0.0));
		float conf = prev.r;
		float held = prev.g;

		float live_share = tex2Dlod(MotionStat, float4(0.5, 0.5, 0.0, 0.0)).r * 100.0;
		bool drawn = live_share > AutoMaskMotion;

		bool inDeadzone = false;
		if (AutoMaskDeadzone && AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
			float rx = AutoMaskDeadzoneWidth * 0.005;
			float ry = AutoMaskDeadzoneHeight * 0.005;
			float2 offset = float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01);
			if (dot(offset / float2(rx, ry), offset / float2(rx, ry)) <= 1.0){
				inDeadzone = !AutoMaskDeadzoneMotionOnly || drawn;
			}
		}

		if (stable > 0.5 && !inDeadzone){
			held = max(held - 0.5, 0.0);
			if (drawn){
				if (conf < 0.0){
					conf = min(0.0, conf + cost);
				} else {
					conf = min(1.0, conf + gain);
				}
			}
		} else if (drawn && held < AutoMaskForget && !inDeadzone){
			held += 1.0;
		} else {
			conf = conf - cost * (1.0 - stable);
			if (AutoMaskMoveMemory > 0.0){
				conf = min(conf, -cost * AutoMaskMoveMemory * (1.0 - stable));
			}
		}

		if (inDeadzone){
			conf = min(conf, 0.0);
			held = 0.0;
		}

		//Count first, then reduce, so a group agrees on the tallies once every thread has added to
		//them. Both are tallied in groupshared, so the screen costs a handful of adds per group
		//rather than one per pixel: a global bin would take an add from every pixel, and on a still
		//screen nearly all of them land on the same bin.
		bool changed = live && step(0.001, motion) > 0.5;
		//One bin per whole level of frame-to-frame difference, so the next frame can be told where
		//this scene's noise ends. The index truncates, so bin level-1 is exactly the difference the
		//verdict calls motion at deadband level, and the levels above the walk's own share the top
		//bin. A pixel that did not change takes no bin at all: the walk sums the bins, so the quiet
		//majority is counted by its absence rather than by an add onto one bin apiece. The index is
		//only read when there is a bin, so a still pixel cannot reach the array off its low end.
		bool binned = live && AutoMaskAutoStep && maxDiff >= 1.0;
		int bin = min(int(maxDiff), AUTOMASK_STEP_MAX) - 1;
		if (gi == 0)
			groupChanged = 0u;
		if (gi < AUTOMASK_STEP_MAX)
			groupHist[gi] = 0u;
		barrier();
		if (changed)
			atomicAdd(groupChanged, 1u);
		if (binned)
			atomicAdd(groupHist[bin], 1u);
		barrier();
		//One thread hands both tallies over. The bins are read with constant indices, so the reads
		//are in bounds whatever the group size; a bin no pixel reached is skipped, which is what
		//makes a still frame's histogram cost almost nothing, and the whole flush is gated on the
		//toggle so the off path does no histogram work at all -- the clear above is the shared
		//memory the group is about to discard, not the bins the next frame reads.
		if (gi == 0){
			atomicAdd(AutoMotionCount, int2(0, 0), groupChanged);
			if (AutoMaskAutoStep)
				for (int i = 0; i < AUTOMASK_STEP_MAX; i++)
					if (groupHist[i] > 0u)
						atomicAdd(AutoMotionHist, int2(i, 0), groupHist[i]);
		}

		if (live){
			tex2Dstore(AutoAccumStore, int2(tid.xy), float4(clamp(conf, -cost * AutoMaskMoveMemory, 1.0), held, motion, 1.0));
			tex2Dstore(AutoDriftStore, int2(tid.xy), float4(next, 1.0));
		}
	}

	//Turns the frame's count into the share the next frame's gate reads, measures the step off the
	//histogram, and clears both for the next frame.
	[numthreads(1, 1, 1)]
	void CS_Finish(uint3 tid : SV_DispatchThreadID)
	{
		float share = float(tex2Dfetch(AutoMotionCount, int2(0, 0))) / (BUFFER_WIDTH * BUFFER_HEIGHT);
		tex2Dstore(AutoMotionCount, int2(0, 0), 0u);
		tex2Dstore(AutoStatStore, int2(0, 0), share);

		//A pixel that did not change has no bin, so the bins sum to the count changing at the first
		//level, and each level's own bin is what the level below it subtracts -- at the test for level
		//L, `above` is exactly the count the verdict calls motion at deadband L. The step is therefore
		//the smallest level 1-8 leaving no more than AutoMaskNoiseFloor percent above it; running out
		//of the range means no level separates this frame's noise from its content, so the slider's own
		//value stands.
		if (AutoMaskAutoStep){
			float floorCount = AutoMaskNoiseFloor * 0.01 * float(BUFFER_WIDTH * BUFFER_HEIGHT);
			float step = max(ceil(AutoMaskEps), 1.0);
			uint above = 0u;
			for (int i = 0; i < AUTOMASK_STEP_MAX; i++)
				above += tex2Dfetch(AutoMotionHist, int2(i, 0));
			for (int level = 1; level <= AUTOMASK_STEP_MAX; level++){
				if (float(above) <= floorCount){
					step = float(level);
					break;
				}
				above -= tex2Dfetch(AutoMotionHist, int2(level - 1, 0));
			}
			tex2Dstore(AutoStepStore, int2(0, 0), step);
		}

		//Cleared whether or not the step is being measured, so the bins start every frame empty and
		//the toggle can be flipped without stale counts.
		for (int i = 0; i < AUTOMASK_STEP_MAX; i++)
			tex2Dstore(AutoMotionHist, int2(i, 0), 0u);
	}

	//Drift ping-pong back-edge (copy B to A).
	float4 PS_CopyDrift(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		return float4(tex2D(AutoDriftB, texcoord).rgb, 1.0);
	}
#else
//Accumulates confidence from stillness while the world is drawn; a stopped world can only lose it.
float4 PS_Accum(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 now = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 before = tex2D(AutoHistory, texcoord).rgb;
	//The history is stored on the 8-bit grid, so on a higher-precision back buffer the live sample is
	//quantized onto it first: a sub-half-level change reads as exactly zero instead of a fraction.
	float3 nowLevels = round(now * 255.0);
	float3 beforeLevels = round(before * 255.0);
	now = nowLevels / 255.0;
	//A pixel pinned at all 0 or all 255 shows no difference while it stays there, but that is
	//saturation, not stillness, so a wholly clipped colour voids the still verdict. `all` makes the
	//count a scalar, avoiding the X3206 truncation warning fxc emits for a vector form.
	float clipped = all(now == 0.0.xxx) + all(now == 1.0.xxx)
	              + all(before == 0.0.xxx) + all(before == 1.0.xxx);
	float3 diff = abs(nowLevels - beforeLevels);
	float maxDiff = max(diff.r, max(diff.g, diff.b));
	//The deadband is a level count: a change of that many levels or more is motion, anything less is
	//still. The ramp spans a fixed three levels, footed one under, so its own level reads a quarter.
	float deadband = max(ceil(AutoMaskEps), 1.0);
	float motion = smoothstep(deadband - 1.0, deadband + 2.0, maxDiff);
	float stable = (maxDiff < deadband && clipped == 0.0) ? 1.0 : 0.0;

	//The sliders speak in frames; the accumulator is confidence against the 0.5 verdict step, so a
	//frame of credit is that step over the slider, a hair above the exact share for half precision.
	float gain = 0.504 / max(AutoMaskRise, 1.0);
	float cost = 0.504 / max(AutoMaskFall, 1.0);

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;

	//Whether the world is being drawn, measured on the previous frame.
	float live = tex2D(MotionStat, float2(0.5, 0.5)).r * 100.0;
	bool drawn = live > AutoMaskMotion;

	bool inDeadzone = false;
	if (AutoMaskDeadzone && AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
		float rx = AutoMaskDeadzoneWidth * 0.005;
		float ry = AutoMaskDeadzoneHeight * 0.005;
		float2 offset = float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01);
		if (dot(offset / float2(rx, ry), offset / float2(rx, ry)) <= 1.0){
			inDeadzone = !AutoMaskDeadzoneMotionOnly || drawn;
		}
	}

	if (stable > 0.5 && !inDeadzone){
		//Still, so pay half a frame of the bridge back rather than ending it.
		held = max(held - 0.5, 0.0);
		//A drawn world turns stillness into interface: repay debt, then earn.
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
		//Decay confidence and bank move debt: the fall never waits on the world being drawn.
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
#endif

//Ping-pong back-edge (copy B to A).
float4 PS_Copy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(AutoAccumB, texcoord);
}

//Horizontal closing bounded by luma edge, plus the row's still count for the isolation gate.
float4 PS_DilateH(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(AutoMaskDilate + 0.5);
	//The box has its own radius, one pixel wide at least so the gate always has a share to read.
	float reach = max(floor(AutoMaskIsolation + 0.5), 1.0);
	float centre = tex2D(AutoAccumA, texcoord).r;
	float mask = centre;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));
	float nearby = 0.0;

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(i * texel.x, 0.0);
		bool inRange = abs(float(i)) <= r;
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (inRange && edge <= AutoMaskEdge) ? 1.0 : 0.0;
		float neighbour = tex2D(AutoAccumA, uv).r;
		//The count is the verdict, unbounded by luma: a contour inside a HUD must not cost it support.
		nearby += abs(float(i)) <= reach ? step(0.5, neighbour) : 0.0;
		mask = max(mask, neighbour * keep);
	}
	return float4(mask, nearby / AUTOMASK_COUNT_SCALE, mask, 1.0);
}

//Vertical closing bounded by luma edge, plus the box's still count and the isolation gate.
float4 PS_DilateV(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(AutoMaskDilate + 0.5);
	float reach = max(floor(AutoMaskIsolation + 0.5), 1.0);
	float4 centre = tex2D(AutoDilate, texcoord);
	float mask = centre.r;
	float lumaCentre = dot(tex2D(ReShade::BackBuffer, texcoord).rgb, float3(0.299, 0.587, 0.114));
	float nearby = 0.0;

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(0.0, i * texel.y);
		bool inRange = abs(float(i)) <= r;
		float luma = dot(tex2D(ReShade::BackBuffer, uv).rgb, float3(0.299, 0.587, 0.114));
		float edge = abs(luma - lumaCentre) * 255.0;
		float keep = (inRange && edge <= AutoMaskEdge) ? 1.0 : 0.0;
		float4 row = tex2D(AutoDilate, uv);
		nearby += abs(float(i)) <= reach ? row.g * AUTOMASK_COUNT_SCALE : 0.0;
		mask = max(mask, row.r * keep);
	}

	//Every masked pixel is tested, not only the ones the verdict claimed: what the closing radius grew
	//around a speck has that speck's thin neighbourhood and goes with it. The box is the isolation
	//radius, so the share is the same test at every position of it.
	float side = 2.0 * reach + 1.0;
	if (AutoMaskIsolated && nearby < AutoMaskDensity * 0.01 * side * side)
		mask = 0.0;

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
		ui_category = "Diagnostics";
	> = true;

	//Motion visualization gain for diagnostics overlay.
	uniform float UIDebugGain <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Diagnostics: motion gain";
		ui_tooltip = "Brightens the red motion reading in the overlay,\nso a change too small to see becomes visible";
		ui_category = "Diagnostics";
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
		//Tint over the restore, drawn after it so it sits on top of the stored UI: red where the
		//motion view sees a change, green where the verdict view sees protection.
		float4 debug = tex2D(AutoDebug, texcoord);
		float tint = UIDebugMotion ? debug.r : debug.g;
		float3 mark = UIDebugMotion ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
		color = lerp(color, mark, tint * 0.7);

		if (AutoMaskDeadzone && AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
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
	#if AutoMaskCompute == 1
		//Counts every moved pixel, and does the accumulator's own work in the same dispatch.
		pass {
			ComputeShader = CS_Accum;
			DispatchSizeX = (BUFFER_WIDTH + 63) / 64;
			DispatchSizeY = (BUFFER_HEIGHT + 3) / 4;
		}
	#else
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_Accum;
			RenderTarget = texAutoAccumB;
		}
	#endif
	pass {
		VertexShader = PostProcessVS;
		PixelShader = PS_Copy;
		RenderTarget = texAutoAccumA;
	}
	#if AutoMaskCompute == 1
		//Brings the drift average back to the side the accumulator reads next frame.
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_CopyDrift;
			RenderTarget = texAutoDriftA;
		}
		//Hands the count over as the share the next frame's gate reads, and clears it.
		pass {
			ComputeShader = CS_Finish;
			DispatchSizeX = 1;
			DispatchSizeY = 1;
		}
	#else
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
	#endif
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
