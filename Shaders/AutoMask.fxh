//Shared arithmetic: the verdict is one state machine run by both accumulators, so the parts that sample
//nothing live here rather than twice. Each takes what it needs already sampled, since the pixel path
//reads with tex2D and the compute path with tex2Dlod, and a helper that sampled would move one path's
//form onto the other's. The drift terms stay behind AutoMaskCompute in the shader that includes this.

//The deadzone's normalized offset from its centre, shared so the test below and the restore's ring
//cannot drift apart.
float2 AutoMaskDeadzoneOffset(float2 texcoord)
{
	float rx = AutoMaskDeadzoneWidth * 0.005;
	float ry = AutoMaskDeadzoneHeight * 0.005;
	return float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01) / float2(rx, ry);
}

//The elliptical centre deadzone, active only while the world is drawn when the setting says so.
bool AutoMaskInDeadzone(float2 texcoord, bool drawn)
{
	bool inside = false;
	if (AutoMaskDeadzone && AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
		float2 offset = AutoMaskDeadzoneOffset(texcoord);
		if (dot(offset, offset) <= 1.0){
			inside = !AutoMaskDeadzoneMotionOnly || drawn;
		}
	}
	return inside;
}

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

//The sliders speak in frames; the accumulator is confidence against the 0.5 verdict step, so a frame
//of credit is that step over the frame count, a hair above the exact share for half precision.
float AutoMaskRate(float frames)
{
	return 0.504 / max(frames, 1.0);
}

//One frame of the accumulator: the hold pays half a frame back while the pixel is still, the drawn
//world turns stillness into interface, a bridge absorbs brief animation, and past that the debt is
//banked. Returns the new confidence and hold.
float2 AutoMaskDecay(float conf, float held, bool stable, bool drawn, bool inDeadzone,
	float earn, float cost)
{
	if (stable && !inDeadzone){
		held = max(held - 0.5, 0.0);
		if (drawn){
			if (conf < 0.0){
				conf = min(0.0, conf + cost);
			} else {
				conf = min(1.0, conf + earn);
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
	return float2(conf, held);
}

//The published mask, read by the three passes that consume it.
float AutoMaskPublished(float2 uv)
{
	return step(0.5, tex2D(AutoMap, uv).r);
}
