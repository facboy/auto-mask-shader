# Editing conventions, in full

The reasoning behind the rules condensed in `AGENTS.md`. Read this when a change touches a uniform's
annotation, the frame-count sliders' conversion, or the drift channel's reset step.

- The uniform widget is chosen by the annotation macro's family, and the family by what the value means:
  the duration settings (`AutoMaskRise`, `AutoMaskFall`, `AutoMaskForget`, `AutoMaskMoveMemory`, and the
  compute path's `AutoMaskDrift`) use `__UNIFORM_DRAG_FLOAT1`, a drag widget over free values rather
  than a stepped track; everything else is a slider. A mismatch between annotation family and declared
  type is a silent ReShade UI bug.
- `AutoMaskTargetFPS` is the one further definition, a setup number rather than a tuning one. The
  frame-count settings are durations, so their `ui_max` caps are seconds × `AutoMaskTargetFPS` (rise
  10 s, fall 1 s, grace 5 s, move memory 10 s) and grow with the frame rate a user plays at, which
  no literal could. It is not watched and not elided — a runtime `frametime` uniform cannot appear in an
  annotation, which is why it is a definition at all. The drift horizon is a duration of the other kind:
  its slider is already in seconds (cap a literal 10, step 0.25, default 2) and the frame count its
  average remembers is derived from it, so `AutoMaskTargetFPS` multiplies it inside the shader. Its
  default is the one value chosen from the mechanism rather than from the frame sliders' convention:
  the settled lag is the per-frame shift times the horizon in frames, so the shortest horizon that can
  clear the deadband out of a sub-level shift is what makes the channel do anything at all — a default
  of a few frames reads as no drift whatsoever. It is declared inside the compute guard beside the other
  uniforms, because the pixel path has no pass that would read it and a setting that does nothing is
  worse than an absent one. `AutoMaskAutoStep` and `AutoMaskNoiseFloor` sit there with it for the same
  reason.
- The reset's step is expressed as `max(deadband, 8.0)` rather than a bare literal, which at the shipped
  caps is a flat 8 levels at every position — the `AutoMaskEps` slider ends at 8 and the auto-step walk
  clamps to the same 8 — but which cannot cross the verdict deadband if either cap is ever raised. That
  is the whole point of the `max`: the reset must stay at or above the deadband so the two thresholds
  never collapse back into one, and 8 is the number the shader already treats as its top-of-range level,
  so there is no second constant to keep in step. It is deliberately *not* a slider — nobody watches the
  reset's threshold, and `AutoMaskDrift` has to remain the setting being read.
- The 8 that literal names stays a literal, and the walk's own top level is now a named constant
  (`AUTOMASK_STEP_MAX`) instead. The two are deliberately not tied together: they answer different
  questions — "is this a new picture?" against "where does the scene's noise end?" — so raising the
  walk's range to catch a coarser noise floor must not quietly raise the threshold that decides a scene
  cut is not drift. Within the histogram the constant *is* worth having, because the same number sizes
  the target, the `groupshared` tally, the clear loop, the bin clamp and the walk's range, and those
  cannot be allowed to drift apart. `AUTOMASK_DILATE_MAX` is the existing precedent for a definition
  that bounds a fixed loop rather than holding data or eliding a pass.
- The credit lives in both `LICENSE` and the header block on purpose: someone copying just the `.fx`
  into their ReShade folder takes the attribution with it.
