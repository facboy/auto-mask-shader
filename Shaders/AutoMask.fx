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

//Lets the depth buffer help decide when the world is being drawn. The overlay writes no depth, so a
//panel cannot hide the drawing behind it the way it hides it in the picture. Needs depth buffer access
//(ReShade's Depth Buffer settings), which online games often block; with no depth bound the picture's
//own reading is used exactly.
#ifndef AutoMaskDepthMotion
	#define AutoMaskDepthMotion		0	// [0 or 1] 1 lets the depth buffer help measure the world being drawn
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
//The isolation gate's counts ride in texAutoDilate's 8-bit channels, so a whole number is scaled by
//this on the way in and back out, landing it on the same byte at either end.
#define AUTOMASK_COUNT_SCALE 255.0
//The isolation gate's line test: a line through a pixel must hold more than half its length, and the
//smallest window is 3 across, so 3 is its whole length and a two-pixel cluster still reads as a speck.
#define AUTOMASK_AXIS_MIN 3.0
//Admission's seed rate: a pixel with no claimed neighbour earns this share of the usual rise, so a
//region starts only from a pixel that holds still twice as long. Named so both accumulators halve alike.
#define AUTOMASK_SEED_SHARE 0.5
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

#if AutoMaskDepthMotion == 1
	//The step as a share of its own distance: how much of the distance to a surface it must move in one
	//frame to count as the world being redrawn. Depth is a distance, not an 8-bit channel, so a share of
	//it is independent of the game's far plane -- and translation moves a near surface by more of its
	//distance than a far one, so one step covers a metre at arm's length and misses a distant backdrop.
	uniform float AutoMaskDepthEps <
		__UNIFORM_INPUT_FLOAT1
		ui_label = "Depth step counted as a change (percent)";
		ui_tooltip = "How much of its own distance a surface must move in one frame to count as the world being redrawn, as a percentage of that distance.\nDepth is a distance, so a share of it is the same in every game; lower is more sensitive, and the screen-wide share the setting above reads is what keeps depth noise from counting.\nRaise it if depth noise holds the world as drawn over a stopped scene, lower it if walking fails to.";
		ui_category = "AutoMask";
		ui_min = 1.0; ui_max = 100.0;
		ui_step = 1.0;
	> = 10.0;

	//An experiment rather than a tuning value: takes the world-drawn reading from depth alone, so a scene
	//whose only motion is texture -- water, fire, a scrolling backdrop -- reads as stopped instead of
	//drawn. Off, depth is added to the picture's reading and can only raise it. It needs a bound depth
	//buffer: with none the premise never fires and the corner marker stays yellow.
	uniform bool AutoMaskDepthOnly <
		__UNIFORM_SLIDER_BOOL1
		ui_label = "Depth only (experiment)";
		ui_tooltip = "On, the world-drawn reading comes from the depth buffer alone, so animating textures no longer count as the world moving.\nOff, depth is added to the picture's own reading.\nNeeds the depth buffer: with none bound, the world never reads as drawn";
		ui_category = "AutoMask";
	> = false;
#endif

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

//Admission, the second spatial term and the one upstream of the verdict. A pixel no claimed neighbour
//touches earns at half rate, so a region starts from whichever pixel holds still for twice the rise
//and a lone still pixel cannot seed one. It reaches a genuinely new element, only later.
uniform bool AutoMaskNeighbour <
	__UNIFORM_SLIDER_BOOL1
	ui_label = "Stop specks entering the mask";
	ui_tooltip = "On, a still pixel with no mask beside it takes twice as long to be added.\nA lone speck of noise is not protected; a solid element still appears normally.\nOff, every still pixel is added at the same pace";
	ui_category = "AutoMask";
> = false;

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
//Accumulator ping-pong: .r=confidence/debt, .g=hold, .b=motion, .a=whether the verdict could speak
//(the pixel was not pinned), which the motion reduce divides the changed share by on the pixel path
//and which the compute path's own tally carries instead.
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

//Intermediate target for separable dilation. .g carries the isolation gate's row count and .b the
//centre verdict, the channels the closing radius leaves unused, so the vertical pass can count a
//column and a diagonal out of taps it already takes.
texture texAutoDilate { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoDilate { Texture = texAutoDilate; };

//Published HUD map (.r is HUD mask).
texture texAutoMap { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler AutoMap { Texture = texAutoMap; };

#if AutoMaskDepthMotion == 1
	//Last frame's linearized depth, for the change the depth premise counts. One target, not a pair: the
	//accumulator reads it in its own pass and the store below writes it in a later one, so nothing reads
	//what is being written. Full precision, since a level of 255 is well under a half-precision ulp here.
	texture texAutoDepth { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32F; };
	sampler AutoDepth { Texture = texAutoDepth; };
#endif

//The screen-motion gate as compute: a 1x1 integer counter every moved pixel adds to, handed to the
//1x1 float share the pixel passes sample. The accumulator writes as storage, read and written only
//through tex2Dfetch/tex2Dstore -- a bracket fails in ReShade with X3121.
#if AutoMaskCompute == 1
	//The last level the walk measures in, and the end of the AutoMaskEps slider with it.
	#define AUTOMASK_STEP_MAX 8
	texture texAutoMotionCount { Width = 1; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionCount { Texture = texAutoMotionCount; };
	//The pixels that could show a change at all. The share is taken over these rather than over the whole
	//buffer, because a black or clipped region can never move and every pixel of it lowers the ceiling:
	//at 44% of the screen inert, no camera movement can read above 56%.
	texture texAutoMotionActive { Width = 1; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionActive { Texture = texAutoMotionActive; };
	//The change-size histogram: one bin per level the walk speaks in, so the scene itself says where
	//its noise floor is. A pixel that did not change takes no bin at all.
	texture texAutoMotionHist { Width = AUTOMASK_STEP_MAX; Height = 1; Format = r32u; };
	storage2D<uint> AutoMotionHist { Texture = texAutoMotionHist; };
	texture texAutoStat { Width = 1; Height = 1; Format = r32f; };
	storage2D<float> AutoStatStore { Texture = texAutoStat; };
	sampler MotionStat { Texture = texAutoStat; };
	//The step measured off that histogram, one frame behind exactly as the share is: .r the committed
	//step, .g the answer it is being compared against and .b the frames that answer has stood for.
	texture texAutoStep { Width = 1; Height = 1; Format = RGBA32F; };
	storage2D<float4> AutoStepStore { Texture = texAutoStep; };
	sampler AutoStep { Texture = texAutoStep; };
	storage2D<float4> AutoAccumStore { Texture = texAutoAccumB; };
	//How far the average sits from the frame, in deadbands: the drift ramp's top and the bound the
	//average is held inside, so a lag the ramp cannot read is never stored.
	#define AUTOMASK_DRIFT_LAG 2.0
	//Frames a measured step must stand before it is committed. Named, not a slider: it bounds how long
	//a held reading lasts rather than naming a value anyone tunes.
	#define AUTOMASK_STEP_DWELL (1.0 * AutoMaskTargetFPS)
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
	//Motion reduction targets: coarse downscale and 1x1 global coverage statistic. The coarse target is
	//two readings, .r the share of the block that changed and .g the share that could have, so the
	//reduce below divides the sums rather than averaging a ratio of them.
	texture texMotionCoarse { Width = 16; Height = 16; Format = RGBA8; };
	sampler MotionCoarse { Texture = texMotionCoarse; };
	texture texMotionStat { Width = 1; Height = 1; Format = RGBA8; };
	sampler MotionStat { Texture = texMotionStat; };
#endif

#if AutoMaskDiagnostics == 1
	texture texAutoDebug { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
	sampler AutoDebug { Texture = texAutoDebug; };
#endif

//The tile map: the picture as a coarse grid of squares, each cell a share of itself rather than a
//count of its pixels. The grid is fixed at AUTOMASK_TILE_GRID across, so a reading means the same
//thing at every screen size, and the cells are sampled rather than tallied, so the map costs no
//target per screen and no atomic per pixel. It exists as an instrument only: nothing reads it.
#if AutoMaskCompute == 1 && AutoMaskDiagnostics == 1
	//Cells across the grid, and one relaxation round per cell of its longest path: a connected region of
	//a fixed GxG grid can be at most G^2 cells long, so that many sweeps settle any region exactly. It
	//is a property of the grid's size and not of the picture -- which is the whole reason the region
	//readings are taken here rather than at full resolution, where the same test has no bound to name.
	#define AUTOMASK_TILE_GRID 16
	#define AUTOMASK_TILE_ROUNDS (AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID)
	//Taps per axis inside one cell, so the coverage a cell reports is what this many points see.
	#define AUTOMASK_TILE_TAPS 8
	//Samples that must be masked for a cell to count as interface. One: this is a footprint view, so the
	//question is whether the mask covers the cell at all, not whether it fills it -- most interface is
	//thin against a 160x90 cell, and a health bar ten pixels tall is under a fifth of one. Asking for a
	//share instead made every partial UI cell read black, which is the unshaded UI in the screenshots.
	#define AUTOMASK_TILE_HITS 1.0
	//The count the two count bars are drawn against. Both are counts of regions over a 256-cell grid, so
	//their own scale is 0..256 and a reading of a few -- the interesting range -- would move a bar by one
	//percent of its length. Against this, a reading of 16 or more fills the bar, which is the point past
	//which "how many pieces" has stopped being the question.
	#define AUTOMASK_TILE_COUNT_MAX 16

	//How far up the accumulator's own graded motion a cell's pixels must sit to count as an arrival
	//candidate. A channel the mask computed, not a raw difference measured here: measuring its own is how
	//the map came to call a held UI edge red, a sub-pixel shift of a hard contour being tens of levels.
	#define AUTOMASK_TILE_WIDE 0.75
	//.r the cell's class over 4 (0 world, 1 mask, 2 hole, 3 arrival candidate), .g the coverage the mask
	//gave it and .b the coverage the accumulator's graded motion did. Point filtered: a cell is a
	//reading, not a picture to interpolate.
	texture texAutoTileKind { Width = AUTOMASK_TILE_GRID; Height = AUTOMASK_TILE_GRID; Format = RGBA8; };
	storage2D<float4> AutoTileKindStore { Texture = texAutoTileKind; };
	sampler AutoTileKind { Texture = texAutoTileKind; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
	//The readings, one bar each: (0) component count against `AUTOMASK_TILE_COUNT_MAX`, the largest
	//component's share of the mask, hole share of the grid and masked share of the grid; (1) arrival
	//patch count against the same bound and the share of the grid those patches cover. Point filtered,
	//since a texel is read by name rather than as a picture.
	texture texAutoTileStat { Width = 2; Height = 1; Format = RGBA32F; };
	storage2D<float4> AutoTileStatStore { Texture = texAutoTileStat; };
	sampler AutoTileStat { Texture = texAutoTileStat; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
	//One cell per thread: the class each cell landed in, the grid a relaxation works on, the second grid
	//holding a round's answer, one region's size per label, and the two results kept past the last
	//relaxation -- the wide patches and the cells the contour closes around.
	groupshared uint tileState[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
	groupshared uint tileLabel[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
	groupshared uint tileScratch[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
	groupshared uint tileArea[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
	groupshared uint tileWide[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
	groupshared uint tileHole[AUTOMASK_TILE_GRID * AUTOMASK_TILE_GRID];
#endif

//The shared verdict arithmetic, in its own header. It holds no coordinate, colour or table, only the
//functions both accumulators call. Included here because the dialect has no forward declaration, so a
//call may only name what is already declared. Both files go into the ReShade folder together.
#include "AutoMask.fxh"

//Pixel shaders
#if AutoMaskCompute == 1
	//Per-group tallies, so the counter and the histogram take a handful of adds per group rather
	//than one per pixel. Every group zeroes them before any of them counts.
	groupshared uint groupChanged;
	groupshared uint groupActive;
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
		#if AutoMaskDepthMotion == 1
			//The depth the world's drawing is read from, against the frame the store pass left. Both
			//sides are the depth buffer's own constant when none is bound, so the difference is zero and
			//this reading contributes nothing to the premise.
			float depthNow = ReShade::GetLinearizedDepth(texcoord);
			float depthBefore = tex2Dlod(AutoDepth, float4(texcoord, 0.0, 0.0)).r;
		#endif
		//The comparison subtracts the level counts, not the quantized colours: those differ by a float
		//residue -- 0.9999999 for most of the 255 adjacent pairs -- which the deadband would forgive.
		float3 nowLevels = round(now * 255.0);
		float3 beforeLevels = round(before * 255.0);
		now = nowLevels / 255.0;
		//A pinned colour voids stillness on either side of the pair: saturation, not stillness, plus the
		//drift average's own two rails.
		float clipped = AutoMaskClipped(now, before)
		              + all(drift == 0.0.xxx) + all(drift == 1.0.xxx);
		float3 diff = abs(nowLevels - beforeLevels);
		//The long-baseline reading against the same deadband: how far the frame has got from where
		//its colour has been. Either comparison calling it motion is motion. Its ramp is footed at the
		//deadband and tops out at AUTOMASK_DRIFT_LAG deadbands, the bound the average is held in below.
		float3 driftDiff = abs(now - drift) * 255.0;
		float maxDiff = max(diff.r, max(diff.g, diff.b));
		float maxDrift = max(driftDiff.r, max(driftDiff.g, driftDiff.b));
		//The step is tuned (AutoMaskEps) or measured (last frame's histogram); the clamp keeps an
		//unwritten target off the slider's own scale.
		float deadband = AutoMaskAutoStep
			? clamp(tex2Dlod(AutoStep, float4(0.5, 0.5, 0.0, 0.0)).r, 1.0, 8.0)
			: AutoMaskDeadband();
		float motion = max(smoothstep(deadband - 1.0, deadband + 2.0, maxDiff),
		                   smoothstep(deadband, deadband * AUTOMASK_DRIFT_LAG, maxDrift));
		#if AutoMaskDepthMotion == 1
			//The world being drawn, measured on depth: the overlay writes no depth, so a panel cannot
			//hide the drawing as it hides it in the picture. The step is a share of the surface's own
			//distance, which keeps it independent of the game's far plane. Off, it only raises the
			//graded reading the reduce counts; the depth-only experiment makes it the whole of it.
			motion = AutoMaskDepthOnly
				? AutoMaskDepthMoved(depthNow, depthBefore, AutoMaskDepthEps)
				: max(motion, AutoMaskDepthMoved(depthNow, depthBefore, AutoMaskDepthEps));
		#endif
		float stable = (maxDiff < deadband && maxDrift < deadband && clipped == 0.0) ? 1.0 : 0.0;

		//The average follows the frame a horizon's worth a frame, and snaps to it where the frame is a
		//new picture. The reset is keyed to a wide change rather than the deadband, so the max keeps
		//the two thresholds from collapsing into one.
		float horizon = max(AutoMaskDrift * AutoMaskTargetFPS, 1.0);
		float3 next = (maxDiff < max(deadband, 8.0)) ? lerp(now, drift, 1.0 - 1.0 / horizon) : now;
		//Held inside that reach: a sustained move otherwise leaves the average a rate x horizon levels
		//behind, and the screen goes on reading as drawn for a horizon after the view stops. The reach
		//is in level counts and `now` is normalized, so it is divided back onto that scale: left in
		//levels it is 255 times the reach it names, and holds nothing.
		float3 reach = deadband * AUTOMASK_DRIFT_LAG / 255.0;
		next = max(now - reach, min(now + reach, next));

		float gain = AutoMaskRate(AutoMaskRise);
		float cost = AutoMaskRate(AutoMaskFall);

		float4 prev = tex2Dlod(AutoAccumA, float4(texcoord, 0.0, 0.0));
		float conf = prev.r;
		float held = prev.g;

		//Admission: a pixel no claimed neighbour touches earns at half rate, so a region starts only
		//from a pixel that holds still for twice the rise. The cross is the same channel the isolation
		//gate counts on, read a frame behind like the centre tap.
		float earn = gain;
		if (AutoMaskNeighbour){
			float2 texel = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
			float support = step(0.5, tex2Dlod(AutoAccumA, float4(texcoord + float2(texel.x, 0.0), 0.0, 0.0)).r)
			              + step(0.5, tex2Dlod(AutoAccumA, float4(texcoord - float2(texel.x, 0.0), 0.0, 0.0)).r)
			              + step(0.5, tex2Dlod(AutoAccumA, float4(texcoord + float2(0.0, texel.y), 0.0, 0.0)).r)
			              + step(0.5, tex2Dlod(AutoAccumA, float4(texcoord - float2(0.0, texel.y), 0.0, 0.0)).r);
			if (support < 0.5)
				earn = gain * AUTOMASK_SEED_SHARE;
		}

		float live_share = tex2Dlod(MotionStat, float4(0.5, 0.5, 0.0, 0.0)).r;
		bool drawn = AutoMaskDrawn(live_share);

		float2 state = AutoMaskDecay(conf, held, stable > 0.5, drawn, earn, cost);
		conf = state.x;
		held = state.y;

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
		//only read when there is a bin, so a still pixel cannot reach the array off its low end. prose-ok
		bool binned = live && AutoMaskAutoStep && maxDiff >= 1.0;
		int bin = min(int(maxDiff), AUTOMASK_STEP_MAX) - 1;
		if (gi == 0){
			groupChanged = 0u;
			groupActive = 0u;
		}
		if (gi < AUTOMASK_STEP_MAX)
			groupHist[gi] = 0u;
		barrier();
		if (changed)
			atomicAdd(groupChanged, 1u);
		//`live` gates this one too: the dispatch rounds up, and an out-of-frame thread's samples are
		//undefined, so counting them as active would dilute the share.
		if (live && (clipped == 0.0 || changed))
			atomicAdd(groupActive, 1u);
		if (binned)
			atomicAdd(groupHist[bin], 1u);
		barrier();
		//One thread hands both tallies over. The bins are read with constant indices, so the reads
		//are in bounds whatever the group size; a bin no pixel reached is skipped, which is what
		//makes a still frame's histogram cost almost nothing, and the whole flush is gated on the
		//toggle so the off path does no histogram work at all -- the clear above is the shared
		//memory the group is about to discard, not the bins the next frame reads. prose-ok
		if (gi == 0){
			atomicAdd(AutoMotionCount, int2(0, 0), groupChanged);
			atomicAdd(AutoMotionActive, int2(0, 0), groupActive);
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
		//Over the pixels that can move, not the whole buffer. A black or clipped region is evidence
		//neither way, and counting it holds the share below the threshold on a screen with enough of it,
		//so the premise never sees the world drawn however hard the camera moves.
		uint changedCount = tex2Dfetch(AutoMotionCount, int2(0, 0));
		uint activeCount = tex2Dfetch(AutoMotionActive, int2(0, 0));
		tex2Dstore(AutoMotionCount, int2(0, 0), 0u);
		tex2Dstore(AutoMotionActive, int2(0, 0), 0u);
		float share = float(changedCount) / max(float(activeCount), 1.0);
		tex2Dstore(AutoStatStore, int2(0, 0), share);

		//A pixel that did not change has no bin, so the bins sum to the count changing at the first
		//level, and each level's own bin is what the level below it subtracts -- at the test for level
		//L, `above` is exactly the count the verdict calls motion at deadband L. The step is therefore
		//the smallest level 1-8 leaving no more than AutoMaskNoiseFloor percent above it; running out
		//of the range means no level separates this frame's noise from its content, so the slider's own
		//value stands. prose-ok
		//The floor is read against the pixels that could move, as the premise is: an inert region cannot
		//change and would otherwise tighten the rule in proportion to how much of the screen it covers.
		if (AutoMaskAutoStep){
			float floorCount = AutoMaskNoiseFloor * 0.01 * max(float(activeCount), 1.0);
			float step = AutoMaskDeadband();
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
			//A step is committed only once AUTOMASK_STEP_DWELL frames have answered the same level: the
			//walk is fed by motion measured against the step it sets, so a mover covering more than the
			//floor holds it above that mover's own size and the red goes off screen-wide. A scene change
			//answers one level and holds it; movement in and out of the floor's tail does not.
			float4 prevStep = tex2Dfetch(AutoStepStore, int2(0, 0));
			float committed = prevStep.r;
			float candidate = prevStep.g;
			float held = prevStep.b;
			if (committed < 1.0){
				committed = step; candidate = step; held = 0.0;
			} else if (step == committed){
				candidate = step; held = 0.0;
			} else if (step == candidate){
				held += 1.0;
				if (held >= AUTOMASK_STEP_DWELL){ committed = step; held = 0.0; }
			} else {
				candidate = step; held = 1.0;
			}
			tex2Dstore(AutoStepStore, int2(0, 0), float4(committed, candidate, held, 1.0));
		}

		//Cleared whether or not the step is being measured, so the bins start every frame empty and
		//the toggle can be flipped without stale counts.
		for (int i = 0; i < AUTOMASK_STEP_MAX; i++)
			tex2Dstore(AutoMotionHist, int2(i, 0), 0u);
	}

#if AutoMaskDiagnostics == 1
	//Reads the picture as a coarse grid of cells and reduces it to the region readings the instrument is
	//for: how many pieces the mask is in, how much of it sits inside a contour, and how the widely-changed
	//cells clump. A cell is a share of itself, sampled at a few points, so the reading is of a region and
	//not of its every pixel. Each read is a relaxation over the grid, a full `AUTOMASK_TILE_ROUNDS`.
	[numthreads(AUTOMASK_TILE_GRID, AUTOMASK_TILE_GRID, 1)]
	void CS_Tile(uint3 tid : SV_DispatchThreadID)
	{
		uint G = AUTOMASK_TILE_GRID;
		uint cells = G * G;
		uint cell = tid.y * G + tid.x;
		float2 span = float2(BUFFER_WIDTH, BUFFER_HEIGHT) / float(G);
		float2 tapStep = span / float(AUTOMASK_TILE_TAPS);
		float2 origin = float2(tid.xy) * span;

		float masked = 0.0;
		float wide = 0.0;
		for (int ty = 0; ty < AUTOMASK_TILE_TAPS; ty++){
			for (int tx = 0; tx < AUTOMASK_TILE_TAPS; tx++){
				float2 uv = (origin + (float2(tx, ty) + 0.5) * tapStep) * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
				masked += step(0.5, tex2Dlod(AutoMap, float4(uv, 0.0, 0.0)).r);
				//The accumulator's own graded motion, read rather than recomputed: a panel appearing over
				//a stopped scene is a contiguous patch of pixels the mask calls strongly moving with no
				//mask on them, which is the case the screen-wide premise cannot see.
				wide += step(AUTOMASK_TILE_WIDE, tex2Dlod(AutoAccumA, float4(uv, 0.0, 0.0)).b);
			}
		}
		float taps = float(AUTOMASK_TILE_TAPS * AUTOMASK_TILE_TAPS);
		//The premise, read from the share `CS_Finish` has just published: an arrival is a panel appearing
		//over a *stopped* world, so while the world is being drawn every moving cell is that drawing and
		//none of it is an arrival. Without this the class is simply "what moved", which on a camera pan is
		//the whole screen -- the screen-wide orange wash in the screenshots.
		bool stopped = !AutoMaskDrawn(tex2Dlod(MotionStat, float4(0.5, 0.5, 0.0, 0.0)).r);
		//A cell is mask before it is an arrival candidate: a wide change inside a region the mask
		//already covers is that region being redrawn, not a panel appearing over it.
		tileState[cell] = masked >= AUTOMASK_TILE_HITS ? 1u
		              : ((stopped && wide / taps >= AUTOMASK_TILE_WIDE) ? 3u : 0u);
		//Written for the map pass to draw, so the tile view shows the region the readings were taken
		//over rather than a reconstruction of it. The coverage goes in .g and the wide share in .b, so
		//the map can show how much of a cell each reading found rather than only which class it landed
		//in -- a cell the mask touches at 5% and one it fills both read as interface.
		tex2Dstore(AutoTileKindStore, int2(tid.xy), float4(float(tileState[cell]) * 0.25,
			masked / taps, wide / taps, 1.0));

		//The mask's components: a label only ever decreases and only toward the least index in its own
		//region, so the full round count leaves every cell holding its region's least index. `cells` is
		//the sentinel -- one past every index -- so a cell that is not mask spreads no label.
		tileLabel[cell] = tileState[cell] == 1u ? cell : cells;
		barrier();
		for (uint sr = 0u; sr < AUTOMASK_TILE_ROUNDS; sr++){
			//A cell that is not mask keeps its sentinel: a label spreads only among mask cells, or a
			//world cell would absorb its neighbour's label and carry it across the grid, collapsing
			//every region into one.
			uint best = tileLabel[cell];
			if (best != cells){
				if (tid.x > 0u)     best = min(best, tileLabel[cell - 1u]);
				if (tid.x < G - 1u) best = min(best, tileLabel[cell + 1u]);
				if (tid.y > 0u)     best = min(best, tileLabel[cell - G]);
				if (tid.y < G - 1u) best = min(best, tileLabel[cell + G]);
			}
			tileScratch[cell] = best;
			barrier();
			tileLabel[cell] = tileScratch[cell];
			barrier();
		}
		//Each region's size, scattered onto the label its cells settled on: the label is the least index
		//in the region and unique to it, so one array indexed by label counts them all.
		tileArea[cell] = 0u;
		barrier();
		if (tileLabel[cell] != cells)
			atomicAdd(tileArea[tileLabel[cell]], 1u);
		barrier();

		//The same relaxation over the widely-changed cells, so the arrival reading is a count of
		//contiguous patches rather than of cells. A patch of one counts: a panel the grid barely
		//resolved is a reading, not a failure.
		tileWide[cell] = tileState[cell] == 3u ? cell : cells;
		barrier();
		for (uint pr = 0u; pr < AUTOMASK_TILE_ROUNDS; pr++){
			uint best = tileWide[cell];
			if (best != cells){
				if (tid.x > 0u)     best = min(best, tileWide[cell - 1u]);
				if (tid.x < G - 1u) best = min(best, tileWide[cell + 1u]);
				if (tid.y > 0u)     best = min(best, tileWide[cell - G]);
				if (tid.y < G - 1u) best = min(best, tileWide[cell + G]);
			}
			tileScratch[cell] = best;
			barrier();
			tileWide[cell] = tileScratch[cell];
			barrier();
		}

		//A cell is outside the contour if a chain of outside cells reaches the border, so the growth starts
		//there and spreads through every cell but the mask: the mask is the wall, and whatever the growth
		//never reaches is enclosed. Only world cells are *counted*; a wide-change cell still *conducts* it,
		//or a pan's own wide cells would wall off the world and the screen would read as enclosed.
		tileHole[cell] = (tileState[cell] != 1u
		              && (tid.x == 0u || tid.y == 0u || tid.x == G - 1u || tid.y == G - 1u)) ? 1u : 0u;
		barrier();
		for (uint hr = 0u; hr < AUTOMASK_TILE_ROUNDS; hr++){
			uint outer = 0u;
			if (tileState[cell] != 1u){
				outer = tileHole[cell];
				if (tid.x > 0u)     outer = max(outer, tileHole[cell - 1u]);
				if (tid.x < G - 1u) outer = max(outer, tileHole[cell + 1u]);
				if (tid.y > 0u)     outer = max(outer, tileHole[cell - G]);
				if (tid.y < G - 1u) outer = max(outer, tileHole[cell + G]);
			}
			tileScratch[cell] = outer;
			barrier();
			tileHole[cell] = tileScratch[cell];
			barrier();
		}
		//Class 2 is an enclosed cell, so the map draws the region this reading counted. The cell's own
		//class was written once above; this is a second write of one cell, not a second pass.
		if (tileState[cell] == 0u && tileHole[cell] == 0u)
			tex2Dstore(AutoTileKindStore, int2(tid.xy), float4(0.5, 0.0, 0.0, 1.0));

		//One thread reduces the grid: a cell whose label is its own index is its region's least, so it
		//is the one that counts the region, and `tileArea` holds that region's size.
		barrier();
		if (cell == 0u){
			uint maskCells = 0u;
			uint components = 0u;
			uint largest = 0u;
			uint arrivalCells = 0u;
			uint arrivals = 0u;
			uint holes = 0u;
			for (uint ci = 0u; ci < cells; ci++){
				if (tileState[ci] == 1u){
					maskCells++;
					if (tileLabel[ci] == ci){
						components++;
						largest = max(largest, tileArea[ci]);
					}
				} else if (tileState[ci] == 3u){
					arrivalCells++;
					if (tileWide[ci] == ci)
						arrivals++;
				} else if (tileHole[ci] == 0u){
					holes++;
				}
			}
			//Each reading stored on the scale its own bar is drawn against, so a bar means the same thing
			//at any resolution: the two counts against `AUTOMASK_TILE_COUNT_MAX` -- the count that fills
			//their bar -- and the three shares as the shares they are. The largest component is a share
			//of the mask, which is what says whether the mask is one region or a long tail of specks.
			float countScale = 1.0 / float(AUTOMASK_TILE_COUNT_MAX);
			float perCell = 1.0 / float(cells);
			float perMask = maskCells > 0u ? 1.0 / float(maskCells) : 0.0;
			tex2Dstore(AutoTileStatStore, int2(0, 0), float4(float(components) * countScale,
				float(largest) * perMask, float(holes) * perCell, float(maskCells) * perCell));
			tex2Dstore(AutoTileStatStore, int2(1, 0), float4(float(arrivals) * countScale,
				float(arrivalCells) * perCell, 0.0, 1.0));
		}
	}
#endif

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
	//saturation, not stillness, so a wholly clipped colour voids the still verdict.
	float clipped = AutoMaskClipped(now, before);
	float3 diff = abs(nowLevels - beforeLevels);
	float maxDiff = max(diff.r, max(diff.g, diff.b));
	//The deadband is a level count: a change of that many levels or more is motion, anything less is
	//still. The ramp spans a fixed three levels, footed one under, so its own level reads a quarter.
	float deadband = AutoMaskDeadband();
	float motion = smoothstep(deadband - 1.0, deadband + 2.0, maxDiff);
	float stable = (maxDiff < deadband && clipped == 0.0) ? 1.0 : 0.0;
	#if AutoMaskDepthMotion == 1
		//The depth reading joins the motion the reduce below counts, not the verdict above: a change in
		//depth is the world being redrawn, which the overlay cannot have written, so it can only raise
		//the share. The step is a share of the surface's own distance, so it is the same in every game.
		//With no depth bound the difference is zero and the count is the picture's own.
		float depthNow = ReShade::GetLinearizedDepth(texcoord);
		float depthBefore = tex2D(AutoDepth, texcoord).r;
		motion = AutoMaskDepthOnly
			? AutoMaskDepthMoved(depthNow, depthBefore, AutoMaskDepthEps)
			: max(motion, AutoMaskDepthMoved(depthNow, depthBefore, AutoMaskDepthEps));
	#endif

	float gain = AutoMaskRate(AutoMaskRise);
	float cost = AutoMaskRate(AutoMaskFall);

	float4 prev = tex2D(AutoAccumA, texcoord);
	float conf = prev.r;
	float held = prev.g;

	//Admission, the same test as the compute path's: a pixel no claimed neighbour touches earns at the
	//seed rate, so a region starts only from a pixel that holds still for twice the rise.
	float earn = gain;
	if (AutoMaskNeighbour){
		float2 texel = BUFFER_PIXEL_SIZE;
		float support = step(0.5, tex2D(AutoAccumA, texcoord + float2(texel.x, 0.0)).r)
		              + step(0.5, tex2D(AutoAccumA, texcoord - float2(texel.x, 0.0)).r)
		              + step(0.5, tex2D(AutoAccumA, texcoord + float2(0.0, texel.y)).r)
		              + step(0.5, tex2D(AutoAccumA, texcoord - float2(0.0, texel.y)).r);
		if (support < 0.5)
			earn = gain * AUTOMASK_SEED_SHARE;
	}

	//Whether the world is being drawn, measured on the previous frame.
	float live = tex2D(MotionStat, float2(0.5, 0.5)).r;
	bool drawn = AutoMaskDrawn(live);

	float2 state = AutoMaskDecay(conf, held, stable > 0.5, drawn, earn, cost);
	conf = state.x;
	held = state.y;

	//.a carries whether the verdict could speak at all, which the two reduce passes below read: the
	//share is taken over the pixels that flag, so a black or clipped region cannot dilute it.
	return float4(clamp(conf, -cost * AutoMaskMoveMemory, 1.0), held, motion, clipped == 0.0 ? 1.0 : 0.0);
}

//Downsamples motion flags into coarse block coverage: .r the changed share, .g the share that could
//change, which the reduce below divides.
float4 PS_Motion(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float blockStep = 1.0 / 16.0;
	float sum = 0.0;
	float eligible = 0.0;
	for (int y = 0; y < 2; y++){
		for (int x = 0; x < 2; x++){
			float2 uv = texcoord + (float2(x, y) - 0.5) * blockStep * 0.5;
			float4 accum = tex2D(AutoAccumB, uv);
			float changed = step(0.001, accum.b);
			sum += changed;
			eligible += max(accum.a, changed);
		}
	}
	return float4(sum * 0.25, eligible * 0.25, 0.0, 1.0);
}

//Reduces coarse blocks to global screen motion coverage (1x1): the changed share over the share that
//could change, the sums taken first so the ratio is of the screen rather than of an average of ratios.
float4 PS_MotionAvg(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float sum = 0.0;
	float eligible = 0.0;
	for (int y = 0; y < 16; y++){
		for (int x = 0; x < 16; x++){
			float2 uv = (float2(x, y) + 0.5) / 16.0;
			float2 block = tex2D(MotionCoarse, uv).rg;
			sum += block.r;
			eligible += block.g;
		}
	}
	return float4((sum / max(eligible, 1e-5)).xxx, 1.0);
}
#endif

//Ping-pong back-edge (copy B to A).
float4 PS_Copy(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(AutoAccumB, texcoord);
}

//The closing's luma, one copy for both passes, and the luma bound on a tap. `inRange` is passed to the
//test rather than computed in it, so the loop index stays at the call site where it was.
float AutoMaskLuma(float3 rgb)
{
	return dot(rgb, float3(0.299, 0.587, 0.114));
}

float AutoMaskEdgeKeep(float luma, float lumaCentre, bool inRange)
{
	float edge = abs(luma - lumaCentre) * 255.0;
	return (inRange && edge <= AutoMaskEdge) ? 1.0 : 0.0;
}

//Horizontal closing bounded by luma edge, plus the row's still count for the isolation gate and the
//centre verdict the vertical pass reads the column and the diagonals off.
float4 PS_DilateH(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(AutoMaskDilate + 0.5);
	//The box has its own radius, one pixel wide at least so the gate always has a share to read.
	float reach = max(floor(AutoMaskIsolation + 0.5), 1.0);
	float centre = tex2D(AutoAccumA, texcoord).r;
	float mask = centre;
	float lumaCentre = AutoMaskLuma(tex2D(ReShade::BackBuffer, texcoord).rgb);
	float nearby = 0.0;

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(i * texel.x, 0.0);
		bool inRange = abs(float(i)) <= r;
		float luma = AutoMaskLuma(tex2D(ReShade::BackBuffer, uv).rgb);
		float keep = AutoMaskEdgeKeep(luma, lumaCentre, inRange);
		float neighbour = tex2D(AutoAccumA, uv).r;
		//The count is the verdict, unbounded by luma: a contour inside a HUD must not cost it support.
		nearby += abs(float(i)) <= reach ? step(0.5, neighbour) : 0.0;
		mask = max(mask, neighbour * keep);
	}
	//.b is the centre's own verdict, which the vertical pass needs to count a column or a diagonal:
	//those runs cross this pass rather than lying along it, so a row count cannot supply them.
	float still = step(0.5, centre);
	return float4(mask, nearby / AUTOMASK_COUNT_SCALE, still, 1.0);
}

//Vertical closing bounded by luma edge, plus the box's still count and the isolation gate's line test.
float4 PS_DilateV(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 texel = BUFFER_PIXEL_SIZE;
	float r = floor(AutoMaskDilate + 0.5);
	float reach = max(floor(AutoMaskIsolation + 0.5), 1.0);
	float4 centre = tex2D(AutoDilate, texcoord);
	float mask = centre.r;
	float lumaCentre = AutoMaskLuma(tex2D(ReShade::BackBuffer, texcoord).rgb);
	float nearby = 0.0;
	//The four runs through this pixel: its column, and its two diagonals. Its row is the centre's own
	//count, already in .g, and the diagonals read the centre verdict .b so a contour inside a HUD
	//cannot cost them, exactly as the row count is unbounded by luma.
	float column = 0.0;
	float diagDown = 0.0;
	float diagUp = 0.0;

	for (int i = -AUTOMASK_DILATE_MAX; i <= AUTOMASK_DILATE_MAX; i++){
		float2 uv = texcoord + float2(0.0, i * texel.y);
		bool inRange = abs(float(i)) <= r;
		float luma = AutoMaskLuma(tex2D(ReShade::BackBuffer, uv).rgb);
		float keep = AutoMaskEdgeKeep(luma, lumaCentre, inRange);
		float4 row = tex2D(AutoDilate, uv);
		//The gate's extra taps sit behind its own checkbox, which ships off, so the default path does
		//not take them: the column and the diagonals cost nothing while nothing reads them.
		if (AutoMaskIsolated && abs(float(i)) <= reach){
			nearby += row.g * AUTOMASK_COUNT_SCALE;
			column += row.b;
			//A diagonal leaves the column by i: the tap one column over at that row offset is its
			//pixel. An off-frame tap clamps, and reads the same verdict a pixel on the edge would.
			diagDown += tex2D(AutoDilate, uv + float2(i * texel.x, 0.0)).b;
			diagUp += tex2D(AutoDilate, uv - float2(i * texel.x, 0.0)).b;
		}
		mask = max(mask, row.r * keep);
	}

	//The row count came from the horizontal pass, at the centre, and is in .g.
	float rowCount = centre.g * AUTOMASK_COUNT_SCALE;

	//Every masked pixel is tested, not only the ones the verdict claimed: what the closing radius grew
	//around a speck has that speck's thin neighbourhood and goes with it. The box is the isolation
	//radius, so the share is the same test at every position of it. A line through the pixel is the
	//second door: a stroke holds more than half of its own length along one axis, where the box share
	//asks it to fill a share of a box it is too thin to fill. Both doors keep -- the box was there
	//first, so nothing it kept is lost, and the line only ever rescues what the box dropped. prose-ok
	float side = 2.0 * reach + 1.0;
	float floorLine = max(reach + 1.0, AUTOMASK_AXIS_MIN);
	float best = max(rowCount, max(column, max(diagDown, diagUp)));
	if (AutoMaskIsolated && nearby < AutoMaskDensity * 0.01 * side * side && best < floorLine)
		mask = 0.0;

	return float4(mask.xxx, 1.0);
}

//Stores masked UI pixels before downstream processing.
float4 PS_Store(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float mask = AutoMaskPublished(texcoord);
	return float4(tex2D(ReShade::BackBuffer, texcoord).rgb * mask, 1.0);
}

//Stores untouched frame for next frame's comparison.
float4 PS_StoreFrame(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return tex2D(ReShade::BackBuffer, texcoord);
}

#if AutoMaskDepthMotion == 1
	//Stores this frame's linearized depth for next frame's comparison, in its own pass: the accumulator
	//reads the target earlier in the frame and a pass cannot read what it writes. A frame with no depth
	//stores the depth buffer's own constant, so next frame's comparison of it against itself is no change.
	float4 PS_StoreDepth(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		return ReShade::GetLinearizedDepth(texcoord).xxxx;
	}
#endif

#if AutoMaskAntiBloom == 1
	//Blacks masked UI pixels in back buffer to suppress bloom bleeding.
	float4 PS_AntiBloom(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float3 frame = tex2D(ReShade::BackBuffer, texcoord).rgb;
		float mask = AutoMaskPublished(texcoord);
		return float4(frame * (1.0 - mask), 1.0);
	}
#endif

#if AutoMaskDiagnostics == 1
	//Diagnostics view toggle. Both readings tint only the pixels they name.
	uniform bool UIDebugMotion <
		__UNIFORM_SLIDER_BOOL1
		ui_label = "Diagnostics: motion view";
		ui_tooltip = "On, the overlay shows red where the frame sees a change.\nOff, it shows green where a pixel has earned protection, without the closing radius.\nThe corner marker shows in both";
		ui_category = "Diagnostics";
	> = true;

	//Confidence view, the reading ui-isolation-options.md 5.5 asks for: the accumulator's confidence
	//drawn as a grade rather than decided, so the pixels sitting just under the protection line -- the
	//mass a count of crossings throws away -- can be seen. Both accumulators carry it, so unlike the
	//tile view it needs no compute path.
	uniform bool UIDebugConfidence <
		__UNIFORM_SLIDER_BOOL1
		ui_label = "Diagnostics: confidence view";
		ui_tooltip = "On, the overlay draws each pixel in one of two flat colours instead of grading it: cyan where the mask already claims it, magenta where it is still earning and has not crossed -- the band just under the protection line.\nNothing at all below zero, so a pixel still recovering from a move shows as the plain picture.\nOverridden by the tile view where that exists";
		ui_category = "Diagnostics";
	> = false;

	#if AutoMaskCompute == 1
		//The one view that is compute-only, because the tile map the region readings are taken over
		//exists only there. It replaces the other views while it is on, rather than tinting with them,
		//because what it draws is a whole-cell class rather than a per-pixel reading.
		uniform bool UIDebugTile <
			__UNIFORM_SLIDER_BOOL1
			ui_label = "Diagnostics: tile view";
			ui_tooltip = "On, the overlay draws the screen as a 16 x 16 grid of squares, each square one colour for what the mask is doing in it: green mostly masked interface, black not masked, red changed widely with no mask on it while the world is quiet (a panel the shader has not caught), orange a hole the mask closes around.\nFive bars along the top are the region counts that grid produced: how many pieces the mask is in, the largest piece's share of it, the share of the screen inside a contour, how many wide-change patches there are, and the share of the screen they cover.\nOff, the overlay shows the motion or verdict view as usual";
			ui_category = "Diagnostics";
		> = false;
	#endif

	//Motion visualization gain for diagnostics overlay.
	uniform float UIDebugGain <
		__UNIFORM_SLIDER_FLOAT1
		ui_label = "Diagnostics: motion gain";
		ui_tooltip = "Brightens the red motion reading in the overlay,\nso a change too small to see becomes visible";
		ui_category = "Diagnostics";
		ui_min = 1.0; ui_max = 64.0;
		ui_step = 1.0;
	> = 8.0;

	//Packs the view's own channels, one map pass for every view: the motion view in .r, the verdict in
	//.g, the accumulator's charge in .b, the tile view's own colour in .rgb, and the screen state always
	//in .a. The view selector decides nothing here; it only decides what `PS_Restore` draws from this map.
	float4 PS_DebugMap(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
	{
		float4 accum = tex2D(AutoAccumA, texcoord);
		float verdict = step(0.5, accum.r);
		//The accumulator's charge, clamped: the restore below splits it at the 0.5 verdict step into the
		//two flat colours it draws, and below zero draws nothing. Stored raw rather than pre-classed so
		//the threshold and the verdict stay the same number.
		float confidence = saturate(accum.r);
		float changed = saturate(accum.b * UIDebugGain);
		float drawn = AutoMaskDrawn(tex2D(MotionStat, float2(0.5, 0.5)).r);
		float screen = drawn ? 1.0 : 0.0;

		//The compute path packs the tile view's own colour in .rgb and the screen state in .a, so one map
		//pass serves every view; the pixel path has no tile view and shares the .b below.
		#if AutoMaskCompute == 1
			//The tile view draws the region the readings are taken over: each cell in the class it landed
			//in, so a wide change with no mask under it -- the arrival candidate, the case the premise
			//cannot see -- is visible as the region it is rather than as a number. The class is sampled
			//point-wise from a 16x16 target, so a pixel shows the cell it falls in.
			if (UIDebugTile){
				float4 tile = tex2D(AutoTileKind, texcoord);
				float cls = tile.r * 4.0;
				if (cls > 2.5)
					return float4(1.0, 0.0, 0.0, screen);      //wide change, no mask: an arrival candidate
				if (cls > 1.5)
					return float4(1.0, 0.6, 0.0, screen);      //enclosed by the contour: orange
				if (cls > 0.5)
					return float4(0.0, 1.0, 0.0, screen);      //mask: green
				return float4(0.0, 0.0, 0.0, screen);          //world: black
			}
		#endif
		return float4(changed, verdict, confidence, screen);
	}
#endif

//Restores stored UI pixels over processed frame.
float4 PS_Restore(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 live = tex2D(ReShade::BackBuffer, texcoord).rgb;
	float3 stored = tex2D(AutoFrame, texcoord).rgb;
	float mask = AutoMaskPublished(texcoord);
	float3 color = lerp(live, stored, mask);

	#if AutoMaskDiagnostics == 1
		//Tint over the restore, drawn after it so it sits on top of the stored UI: red where the
		//motion view sees a change, green where the verdict view sees protection, a cyan grade where the
		//confidence view reads, and the tile view's own colours where the grid reading is being watched.
		float4 debug = tex2D(AutoDebug, texcoord);
		float tint = UIDebugMotion ? debug.r : debug.g;
		float3 mark = UIDebugMotion ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
		//The confidence view draws two flat colours rather than a brightness ramp, so no shade has to be
		//judged: cyan where the verdict would already claim the pixel, magenta where it is earning but
		//has not crossed -- the band a weighted count would weigh -- and nothing at all below zero. It is
		//read from the channel the tile view overrides below.
		if (!UIDebugMotion && UIDebugConfidence){
			mark = debug.b >= 0.5 ? float3(0.0, 1.0, 1.0) : float3(1.0, 0.0, 1.0);
			tint = debug.b > 0.0 ? 1.0 : 0.0;
		}
		#if AutoMaskCompute == 1
			//The tile view's own colour, packed by the map above, rather than a per-pixel mark: the
			//blend is how strong that colour is, and the class is the mark. It overrides the
			//confidence grade, which shares its blue channel.
			if (UIDebugTile){
				mark = saturate(debug.rgb);
				tint = max(mark.r, max(mark.g, mark.b));
			}
		#endif
		color = lerp(color, mark, tint * 0.7);

		//The five region readings as bars across the top, in their documented order and colour, each
		//filled left to right to its own value. Read from the target the region pass filled, so a bar is
		//the frame's own number rather than a constant.
		#if AutoMaskCompute == 1
			if (UIDebugTile && texcoord.y < 0.02){
				float4 a = tex2D(AutoTileStat, float2(0.25, 0.0));
				float4 b = tex2D(AutoTileStat, float2(0.75, 0.0));
				float u = texcoord.x / 0.2;
				int slot = int(u);
				float within = frac(u);
				float value = 0.0;
				float3 bar = float3(0.0, 0.0, 0.0);
				//1 white: how many separate pieces the mask is in.
				if (slot == 0){ value = a.r; bar = float3(1.0, 1.0, 1.0); }
				//2 green: the largest piece's share of the mask.
				else if (slot == 1){ value = a.g; bar = float3(0.0, 1.0, 0.0); }
				//3 orange: the share of the screen sitting inside a contour.
				else if (slot == 2){ value = a.b; bar = float3(1.0, 0.6, 0.0); }
				//4 red: how many contiguous wide-change patches there are.
				else if (slot == 3){ value = b.r; bar = float3(1.0, 0.0, 0.0); }
				//5 magenta: the share of the screen those patches cover.
				else if (slot == 4){ value = b.g; bar = float3(1.0, 0.0, 1.0); }
				if (within < saturate(value))
					color = lerp(color, bar, 0.9);
			}
		#endif

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
	#if AutoMaskCompute == 1 && AutoMaskDiagnostics == 1
		//The tile map and its readings. After the closing, so a cell is the mask the shader published
		//rather than the verdict under it, and before the history store, since the wide-change reading
		//compares against the frame that pass is about to overwrite.
		pass {
			ComputeShader = CS_Tile;
			DispatchSizeX = 1;
			DispatchSizeY = 1;
		}
	#endif
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
	#if AutoMaskDepthMotion == 1
		//After the accumulator's read and the history's store, so this frame's depth is left for the
		//next frame's comparison rather than the one just made.
		pass {
			VertexShader = PostProcessVS;
			PixelShader = PS_StoreDepth;
			RenderTarget = texAutoDepth;
		}
	#endif

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
