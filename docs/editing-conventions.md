# Editing conventions, in full

The reasoning behind the rules condensed in `AGENTS.md`. Read this when a change touches a uniform's
annotation, the frame-count sliders' conversion, the prose budget, or the drift channel's reset step.

- **Say it and stop.** The prose budget is the one the HLSL comments keep, and it covers the README, the
  docs and this file alike. It buys words for what a reader cannot work out — a value, a cause, a
  consequence — not framing that describes the writing instead of the subject, nor a clause restating the
  sentence before it. Both phrases cut from `docs/definitions.md` were the first kind: "It is a lookup
  rather than an argument" and "the ambiguity is what sends a reader looking" say what the paragraph is
  doing, and neither is missed. This file is where the budget is hardest to keep, since every rule in it
  *is* reasoning; reasoning earns a sentence only where it changes what an editor would do — a cap that
  would cross another threshold, a widget family that must match a declared type. What a value used to be
  belongs in the review docs.
- The uniform widget is chosen by the annotation macro's family, and the family by what the value means:
  the duration settings (`AutoMaskRise`, `AutoMaskFall`, `AutoMaskForget`, `AutoMaskMoveMemory`, and the
  compute path's `AutoMaskDrift`) use `__UNIFORM_DRAG_FLOAT1`, a drag widget over free values rather
  than a stepped track; everything else is a slider. A mismatch between annotation family and declared
  type is a silent ReShade UI bug.
- **The panel has no per-uniform visibility annotation, only a per-category one**, and it is worth
  knowing exactly what it can do before reaching for it. ReShade reads `ui_category_toggle` off a
  boolean uniform and hides every *other* member of that category while the value is false — the value
  comes from the uniform itself, so it is a live toggle and not a compile-time `#if`. Two consequences
  follow, and both are traps:
  - **The gated variable is never hidden itself.** It is what turns the rest of the category back on,
    so the checkbox always stays drawn. That is why `AutoMaskAutoStep` carries the annotation and
    `AutoMaskNoiseFloor` is the one hidden behind it, rather than the other way round.
  - **The gate only works if the gated variable opens the category.** ReShade takes the value off the
    variable at whose index the category *changes*, so the annotation has to sit on the first uniform
    of the group. Put it on a later one and it is silently ignored — the category renders as an
    ordinary always-open one, with nothing in the log to say so.
  This is also why the step settings are their own category rather than more rows under `AutoMask`:
  unticking the gate hides the rest of *its* category, so a gate placed among the main settings would
  hide every slider in the shader. The two categories are therefore `AutoMask` (everything always
  shown) and `Step detection` (the toggle, then the floor it gates). `ui_category` is not a way to
  hide one setting conditionally on another in general — there is no annotation that does that, so a
  value that must stay visible whatever its neighbours are set to stays in `AutoMask`.
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
