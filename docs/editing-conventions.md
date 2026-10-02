# Editing conventions, in full

The reasoning behind the rules condensed in `AGENTS.md`. Read this when a change touches a uniform's
annotation, the frame-count sliders' conversion, the prose budget, or the drift channel's reset step.

- **Say it and stop.** The prose budget is the one the HLSL comments keep, and it covers the README, the
  docs and this file alike. It buys words for what a reader cannot work out — a value, a cause, a
  consequence — not framing that describes the writing instead of the subject, nor a clause restating the
  sentence before it. Reasoning earns a sentence only where it changes what an editor would do — a cap
  that would cross another threshold, a widget family that must match a declared type.
- **A doc describes what ships now, not how it changed.** The reader's question is what the shader does,
  not what it did, so a fact framed by the design it replaced makes them work out which design is current
  — and once one landed change is narrated, the next seems to belong there too. Weighing a shipped design
  against a retired one is a real claim and stays: `RGBA16F` *where* the whole-value form could not resolve
  the creep. So does language that is not history at all — `no longer`, `the old behaviour`, a first
  *pass* of the frame. `check-docs` refuses only the stale forms, and `--list` prints them.
  **A record of an investigation is the exception**, because its argument is the thing being kept:
  `docs/review.md`, `docs/drift-snap-review.md`, `docs/optical-flow.md` and
  `docs/ui-isolation-options.md` are read to know what a design answered, so they may name the design and
  what it was measured against — but even there, a superseded claim is folded into the corrected one
  rather than left beside it for the reader to reconcile.
- The uniform widget is chosen by the annotation macro's family, and the family by what the value means:
  the duration settings (`AutoMaskRise`, `AutoMaskFall`, `AutoMaskForget`, `AutoMaskMoveMemory`, and the
  compute path's `AutoMaskDrift`) use `__UNIFORM_DRAG_FLOAT1`, a drag widget over free values rather
  than a stepped track; a value that names a **share** is a typed field, and everything else is a slider.
  `AutoMaskDensity` is an input widget (`__UNIFORM_INPUT_FLOAT1`, `ui_type = "input"`), so a percentage
  can be entered exactly rather than dragged; `ui_min`/`ui_max`/`ui_step` still bound and step it, so
  `ui_step = 1.0` is what keeps it whole. `AutoMaskDepthEps` names a distance in metres, over a range a
  stepped track cannot cover — 0.001 to 2 — so it is a `__UNIFORM_DRAG_FLOAT1` instead. A mismatch between
  annotation family and declared type is a silent ReShade UI bug.
- **The panel has no per-uniform visibility annotation, only a per-category one.** ReShade reads
  `ui_category_toggle` off a boolean uniform and hides every *other* member of that category while the
  value is false — the value comes from the uniform itself, so it is a live toggle and not a
  compile-time `#if`. Two consequences follow, and both are traps:
  - **The gated variable is never hidden itself.** It is what turns the rest of the category back on,
    so the checkbox always stays drawn. That is why `AutoMaskAutoStep` carries the annotation and
    `AutoMaskNoiseFloor` is the one hidden behind it, rather than the other way round.
  - **The gate only works if the gated variable opens the category.** ReShade takes the value off the
    variable at whose index the category *changes*, so the annotation has to sit on the first uniform
    of the group. Put it on a later one and it is silently ignored — the category renders as an
    ordinary always-open one, with nothing in the log to say so.
  This is also why the step settings are their own category rather than more rows under `AutoMask`:
  unticking the gate hides the rest of *its* category, so a gate placed among the main settings would
  hide every slider in the shader. The gated categories are therefore `RGB step detection` (the toggle,
  then the floor it gates) and `Isolated pixels` (the gate, then the count it governs), with the
  ungated `AutoMask`, `Frame timing` and `Is the scene in motion?` staying visible whatever any gate
  says. There is no annotation that hides one setting conditionally on another in general, so a value
  that must stay visible whatever its neighbours are set to stays in an ungated category.
- **An always-shown group can still be named for what it holds.** `Frame timing` splits the four
  frame-count durations — `AutoMaskRise`, `AutoMaskFall`, `AutoMaskForget` and `AutoMaskMoveMemory` —
  out of `AutoMask` purely to name them, with no gate on it: none of the four is ever hidden, and they
  are already one contiguous run at the top of the uniform list, so the split costs nothing but a
  heading. `Is the scene in motion?` does the same just below it for `AutoMaskMotion` and the depth
  readings (`AutoMaskDepthEps`, `AutoMaskDepthOnly`, `AutoMaskDepthFOV`), the two witnesses to one
  question — the settings are named for the question they answer.
- **A feature with a pass of its own is a definition; a branch inside a pass is a gate.** The isolation
  gate is the precedent: it owns no pass, shader or target — it is a count and a branch inside the two
  closing passes — so a `#if` would save a few instructions in one entry point while costing a recompile
  every time someone ticks the box. It is therefore a live `AutoMaskIsolated` bool carrying
  `ui_category_toggle`, and the branch reads it. Its radius is its own slider (`AutoMaskIsolation`)
  rather than the closing's, because a share of still pixels is a different question from how far the
  mask is grown, and sharing one number would mean retuning the closing silently changed what the
  density means. Both radii sit inside the same `AUTOMASK_DILATE_MAX` loop, so the second one adds no
  pass and no target of its own — though its width does set how far that loop runs. The structural
  switches keep their definitions because each elides a whole pass and the `texture`/`sampler` pairs only
  that pass reads, which ReShade would otherwise allocate forever.
- **A category is a contiguous run of uniforms.** ReShade starts a new group where the `ui_category`
  value changes, so the same category named again further down the list renders as a second heading
  with the same name. Nothing else follows from the order — the panel is the only thing that sees it.
- The compute group is named `RGB step detection`, after the `AutoMaskEps` slider it measures rather than
  after the act of measuring, and `AutoMaskEps` is declared as the last uniform of `AutoMask` so its row
  sits directly above that heading. The slider cannot move inside the group: it is read on the pixel path
  with no measurement at all, and with auto-detect on it is still the fallback on a frame where the walk
  finds no floor — both of which a gated, compute-only category would hide or drop.
- `AutoMaskTargetFPS` is the one further definition, a setup number rather than a tuning one. The
  frame-count settings are durations, so their `ui_max` caps are seconds × `AutoMaskTargetFPS` (rise
  10 s, fall 1 s, grace 5 s, move memory 10 s) and grow with the frame rate a user plays at, which
  no literal could. It is not watched and not elided — a runtime `frametime` uniform cannot appear in an
  annotation, which is why it is a definition at all. The drift horizon is a duration of the other kind:
  its slider is already in seconds (cap a literal 10, step 0.25, default 2) and the frame count its
  average remembers is derived from it, so `AutoMaskTargetFPS` multiplies it inside the shader. Its
  default is the one value chosen from the mechanism rather than from the frame sliders' convention:
  the settled lag is the per-frame shift times the horizon in frames, so the shortest horizon that can
  clear the deadband out of a sub-level shift is what makes the channel do anything at all. It is
  declared inside the compute guard beside the other uniforms, because the pixel path has no pass that
  would read it and a setting that does nothing is worse than an absent one. `AutoMaskAutoStep` and
  `AutoMaskNoiseFloor` sit there with it for the same reason.
- The reset's step is expressed as `max(deadband, 8.0)` rather than a bare literal, which at the shipped
  caps is a flat 8 levels at every position — the `AutoMaskEps` slider ends at 8 and the auto-step walk
  clamps to the same 8 — but which cannot cross the verdict deadband if either cap is ever raised. It is
  deliberately *not* a slider: nobody watches the reset's threshold, and `AutoMaskDrift` has to remain
  the setting being read. The 8 stays a literal rather than `AUTOMASK_STEP_MAX`, because the two answer
  different questions — "is this a new picture?" against "where does the scene's noise end?" — so raising
  the walk's range must not quietly raise the threshold that decides a scene cut is not drift.
- The named constants exist where one number sizes several expressions that must not drift apart.
  `AUTOMASK_STEP_MAX` sizes the histogram target, the `groupshared` tally, the clear loop, the bin clamp
  and the walk's range. `AUTOMASK_DRIFT_LAG` is the drift ramp's top and the clamp on the average, and
  the clamp divides it back onto the value's own scale because `now` is normalized and the reach is a
  level count: left in levels it names 255 times what it means. It cannot be `1`, since the ramp is
  `smoothstep(deadband, deadband × LAG, …)`, whose edges collapse there, and being a whole number of
  deadbands is what lets it hold its meaning at every `AutoMaskEps` position. It is not a slider — it is
  the extent of a comparison rather than a duration anyone watches, and exposing it would offer a second
  knob for what `AutoMaskDrift` already sets. `AUTOMASK_STEP_DWELL` and `AUTOMASK_DILATE_MAX` join them
  under the same rule: each bounds a hold or a loop rather than holding data anyone tries, so each is a
  constant and not a slider.
- The credit lives in both `LICENSE` and the header block on purpose: someone copying just the `.fx`
  into their ReShade folder takes the attribution with it.
