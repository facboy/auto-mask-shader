//Shared arithmetic: the verdict is one state machine run by both accumulators, so the parts that sample
//nothing live here rather than twice. Each takes what it needs already sampled, since the pixel path
//reads with tex2D and the compute path with tex2Dlod, and a helper that sampled would move one path's
//form onto the other's. The drift terms stay behind AutoMaskCompute in the shader that includes this.

//The elliptical centre deadzone, active only while the world is drawn when the setting says so.
bool AutoMaskInDeadzone(float2 texcoord, bool drawn)
{
	bool inside = false;
	if (AutoMaskDeadzone && AutoMaskDeadzoneWidth > 0.0 && AutoMaskDeadzoneHeight > 0.0){
		float rx = AutoMaskDeadzoneWidth * 0.005;
		float ry = AutoMaskDeadzoneHeight * 0.005;
		float2 offset = float2(texcoord.x - 0.5, texcoord.y - AutoMaskDeadzoneY * 0.01);
		if (dot(offset / float2(rx, ry), offset / float2(rx, ry)) <= 1.0){
			inside = !AutoMaskDeadzoneMotionOnly || drawn;
		}
	}
	return inside;
}

//The premise: whether the share last frame's reduce published clears the setting.
bool AutoMaskDrawn(float share)
{
	return share * 100.0 > AutoMaskMotion;
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
