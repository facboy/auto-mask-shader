//Shared arithmetic: the verdict is one state machine run by both accumulators, so the parts that sample
//nothing live here rather than twice. Each takes what it needs already sampled, since the pixel path
//reads with tex2D and the compute path with tex2Dlod, and a helper that sampled would move one path's
//form onto the other's. The drift terms stay behind AutoMaskCompute in the shader that includes this.

//The RGB step in whole levels: the deadband the verdict reads, and the floor the auto-step walks from.
float AutoMaskDeadband()
{
	return max(ceil(AutoMaskEps), 1.0);
}

//The premise: whether the share last frame's reduce published clears the setting.
bool AutoMaskDrawn(float share)
{
	return share * 100.0 > AutoMaskMotion;
}

//Pinned-colour count over the sampled pair: a colour held at all 0 or all 255 shows no difference
//while it stays there, but that is saturation, not stillness, so it voids the still verdict. `all`
//makes each term a scalar, avoiding the X3206 truncation warning fxc emits for a vector form.
int AutoMaskClipped(float3 now, float3 before)
{
	return all(now == 0.0.xxx) + all(now == 1.0.xxx)
	     + all(before == 0.0.xxx) + all(before == 1.0.xxx);
}

#if AutoMaskDepthMotion == 1
//The premise's other witness: whether the surface behind a pixel moved toward or away from the view.
//The linearized depth is a distance divided by the far plane, so multiplying the change by that plane --
//which ReShade supplies, off the user's own depth settings -- gives metres: the same at any range, where
//a share of the distance falls off and vanishes behind the far field's quantisation. Footed at half.
float AutoMaskDepthMoved(float now, float before, float metres)
{
	float moved = abs(now - before) * RESHADE_DEPTH_LINEARIZATION_FAR_PLANE;
	return smoothstep(metres * 0.5, metres, moved);
}

//Reconstructs the camera-space position of a pixel from its depth and its place on the screen, so the
//surface's orientation can be read. Depth is a distance along the view axis, not along the ray, so the
//ray's own z is the cosine of its angle to that axis: with the screen half-angle from the field of view,
//that is one over the length of the unit ray the two screen offsets and the 1 make.
float3 AutoMaskCamPos(float2 offset, float2 halfAngle, float depth)
{
	float3 ray = float3(offset * halfAngle, 1.0);
	return depth * ray / length(ray);
}

//Whether the surface here can never show a depth change to a camera that walks: `n . t` is zero for it,
//so its stillness is not evidence the world stopped and it is left out of the depth share. A normal
//across the walk covers the floor, the ceiling and a wall walked alongside, while the wall ahead points
//down the walk and stays in; a vertical normal holds that even when the camera is pitched.
bool AutoMaskDepthInvariant(float3 p, float3 px, float3 py)
{
	float3 n = abs(normalize(cross(px - p, py - p)));
	return n.z < AUTOMASK_DEPTH_ALIGNED || n.y > AUTOMASK_DEPTH_UPRIGHT;
}
#endif

//The sliders speak in frames; the accumulator is confidence against the 0.5 verdict step, so a frame
//of credit is that step over the frame count, a hair above the exact share for half precision.
float AutoMaskRate(float frames)
{
	return 0.504 / max(frames, 1.0);
}

//One frame of the accumulator: the hold pays half a frame back while the pixel is still, the drawn
//world turns stillness into interface, a bridge absorbs brief animation, and past that the debt is
//banked. Returns the new confidence and hold.
float2 AutoMaskDecay(float conf, float held, bool stable, bool drawn, float earn, float cost)
{
	if (stable){
		held = max(held - 0.5, 0.0);
		if (drawn){
			if (conf < 0.0){
				conf = min(0.0, conf + cost);
			} else {
				conf = min(1.0, conf + earn);
			}
		}
	} else if (drawn && held < AutoMaskForget){
		held += 1.0;
	} else {
		conf = conf - cost * (1.0 - stable);
		if (AutoMaskMoveMemory > 0.0){
			conf = min(conf, -cost * AutoMaskMoveMemory * (1.0 - stable));
		}
	}
	return float2(conf, held);
}

//The published mask, read by the three passes that consume it.
float AutoMaskPublished(float2 uv)
{
	return step(0.5, tex2D(AutoMap, uv).r);
}
