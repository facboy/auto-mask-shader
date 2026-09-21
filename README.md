# AutoMask

Builds a UI mask for ReShade by watching what holds still.

Nothing to install, nothing to paint, no coordinates to pick. Drop the shader in, place it twice, and
it works out where your HUD is by itself.

## What it does

Somewhere in your effect chain you want to protect the interface — the health bar, the inventory, the
map, the dialogue box — from whatever your other effects are doing to the picture. Usually that means
painting a mask image by hand: which pixels are UI, which are the world. This does it the other way
round, from one assumption: **most of the screen is the world.**

A pixel the game keeps drawing in the same place, frame after frame, is something that isn't moving —
and that only means interface while the world around it is being drawn. So the shader compares each
frame against the one before it: hold still for a couple of frames while the view moves, and you are
taken for interface; keep changing for a couple of frames, and you fall away again. Open a menu and its
whole region holds still while the world carries on behind it, so it lands in the mask; close it and the
world starts moving there again, so it drops back out.

Motion is the stronger of the two readings, so the shader trusts it further. A brief movement — a bar
that drains, a list that scrolls — is covered by the grace period and never counts against the element.
A movement that lasts, though, is remembered: it is what the game re-rendering from a new viewpoint
looks like, and no panel is drawn that way. So a pixel seen moving stays out of the mask and has to hold
still for a while before it can be taken for interface — which is what keeps the shader from grabbing a
wall the moment you stop walking past it.

The awkward case is a menu that pops open over a world that has already stopped — a pause screen, say.
Nothing is being redrawn, so stillness proves nothing about what is on screen, and the shader will not
add anything on that evidence alone. What it does instead is hold: for as long as the world is not being
drawn, a pixel that is holding still keeps whatever it had, and a pixel that is moving still falls out.
So a stopped scene can only ever lose mask, never gain it — a quiet room cannot fill in, and nothing
that is animating can be sitting in the mask while the world is stopped. The cost is the panel that
opens by itself into a world that has already stopped: it is caught only if its arrival lifts the
screen-wide reading over the motion setting, and a small or slow one may not.

## Placing it

Two pieces, and both positions matter:

1. **AutoMask** — put it **first** in the effect list, above everything else. It has to see the game's
   untouched picture for the comparison to mean anything.
2. **AutoMask_Restore** — put it **last**, below everything else. It puts the interface back on top
   once your other effects have finished with the frame.

Neither position is a preference. If `AutoMask` runs after another effect, it is comparing processed
frames and the mask will be wrong.

**Do not load this alongside Kaiser's `UIDetectMulti`.** They want the same two slots, so one of them
ends up reading a frame the other has already written into. They are alternatives, not companions —
pick one.

## The settings

All of them live in the ReShade panel. The defaults are meant to be usable as-is; these are for when
they aren't. The tooltips in the panel give each setting in brief — this table is where the detail
lives.

| Setting | What it does |
| --- | --- |
| **RGB step counted as a change** | How far a pixel's colour may move between two frames before the frame counts it as motion, counted in whole levels out of 255. The frame is quantized onto that grid before the comparison, so a change smaller than half a level reads as no change at all. It answers one question only — "did this pixel move?" — and it is the most sensitive at `1`, where any change of a level is motion; `2` forgives a one-level difference, `3` forgives two, and so on. There is nothing below `1`, because a level is the smallest change a channel can make. Raise it only if you see red in the overlay over things that are genuinely not moving — noise, dithering or temporal anti-aliasing makes a static pixel differ by a level or two — at the cost of no longer seeing the smallest movements; lower it to `1` if anything you can see moving is shown without red. What a moving pixel then *costs* the mask is a separate setting (**Frames moving before unmarked as interface**, and the move memory): every frame this step calls changing costs one frame of the unmarking countdown, however small the change was, so it decides *whether* the frame sees a change and nothing else. |
| **Frames still before marked as interface** | How many frames a pixel has to hold still — while the world is being drawn — before it is added to the mask. Raise it if a backdrop that stops when you do keeps getting caught; lower it if a HUD that only briefly holds still fails to appear. A pixel seen moving has to repay its move memory first, so that countdown has to pass before this one starts. A frame whose colour is fully black or fully white — every channel at 0, or every channel at 255 — does not count as still, because a colour pressed against the top or bottom of its range may be saturated rather than motionless and the comparison cannot tell the difference; the moves onto and off full black or full white are ordinary changes and are judged as usual. |
| **Frames moving before unmarked as interface** | How many frames a pixel has to keep changing — counting from when it was last marked, and past the grace period below — before it is dropped from the mask. Lower clears a region faster once the world starts moving over it again; higher makes the mask linger. The count runs whether or not the world is being drawn, and frames the RGB step calls still cost nothing. Keep it short enough that the world takes the mask back promptly, long enough that one stray changing frame cannot punch holes in a protected element. |
| **Frames of absence before decay starts** | The grace period before that decay begins, and the one that matters most: it is what keeps an element covered while it animates a little — a draining bar, a scrolling list, a blinking cursor. It runs as a balance, a changing frame adding one and a still frame paying half of one back, so animation that outweighs its pauses banks toward the limit while brief bursts do not. Too short and you get holes over exactly the parts that move; it only applies while the world is being drawn. |
| **Frames a move is remembered** | How long something stays out of the mask after the frame shows it moving. Holding still is only a hint — a wall holds still too — but movement is proof: the game re-renders moving things from a new viewpoint, and nothing paints a panel that way. So a pixel seen moving has to hold still for this many frames before it can be claimed as interface, which is what stops a wall you just walked past being grabbed the moment you stop. The repayment does not wait on the world being drawn, so this is also how long a screen-wide move takes to clear once the view stops. At `0` a move is forgotten the frame after it happens. |
| **Drift horizon (seconds)** *(compute path only)* | How long the shader remembers where a pixel's colour has been, as a running average. It is the second reading a pixel is judged on, and it exists for one case: scenery that shifts by *less than a level a frame* — a skybox panning slowly, a distant backdrop drifting past — which the frame-to-frame comparison can't see, because half a level rounds to no change at all. Over a horizon that shift adds up, and a pixel that has been creeping away from where it was is not something the game paints in place. Longer catches slower movement; shorter lets the mask come back sooner after an abrupt change. A scene cut or a load drags the average straight to the new scene, so the mask is never held off waiting for a stale average to catch up. `0` turns the comparison off. It is the one setting here sized in seconds rather than frames, and the difference is the point: this reading has to build up a difference you can measure out of a change too small to see between two frames, and that takes time rather than a handful of frames. |
| **Auto-detect RGB step** *(compute path only)* | When this is checked, the shader stops asking *you* what counts as a change and works it out from the scene instead. Every frame it tallies how far each pixel moved — one tally per size of change — and then reads off the smallest change that only a sliver of the screen is still making. Everything below that is the picture's own noise: dithering, temporal anti-aliasing, the little shimmer that makes a static pixel differ by a level or two. The shader forgives all of it and takes everything above it as real movement. If no change size separates the two — a frame where the whole screen is genuinely moving — there is nothing to measure, so it keeps whatever the slider above says rather than guessing from a scene that has no floor. When this is off, the **RGB step counted as a change** slider rules exactly as it always has. Start here if you have ever found yourself nudging that slider, and only go back to setting it by hand if the measurement leaves you with a step you don't like: the two are alternatives, not companions. The motion view of the overlay is how you watch the measurement work, since the red it draws is graded against the step that was measured — a scene where something you can see moving shows no red is a scene the shader has read correctly. |
| **Noise floor (percent)** *(compute path only)* | The share of the screen the measured step is allowed to leave changing above it, and the whole of how strict the measurement is. Lower it and the shader forgives more — the step it chooses sits higher, so more of the picture's small movement passes as still; raise it and the step sits lower, keeping the smallest movements at the cost of counting more of the noise as motion. It does nothing while **Auto-detect RGB step** is off. |
| **Closing radius in pixels** | Grows the mask slightly to close anti-aliased edges and thin text. `0` turns it off. |
| **Luma step counted as a boundary** | Stops that growth at a real edge in the picture, so the mask snaps to the HUD's outline instead of spilling out into the scenery. |
| **Motion needed to trust stillness (percent)** | How much of the screen has to be changing before the shader believes the world is being drawn. Above it, a pixel that holds still is taken for interface and the mask builds; below it, stillness earns nothing, because what holds still in a still scene is the scenery. This is the line that decides whether the screen is being drawn at all — the premise rather than a refinement, which is why its default is not zero. Raise it if scenery is still getting caught, lower it if a HUD fails to appear. |
| **Center deadzone width (percent)** | Width of an elliptical center region where stillness does not accumulate into the mask. Keeps a third-person player character tethered to the camera from being captured as interface. `0` turns it off. |
| **Center deadzone height (percent)** | Height of the elliptical center deadzone. `0` turns it off. |
| **Center deadzone vertical position (percent)** | Vertical center of the deadzone (`50` is screen center; raise it to move down toward the character's feet). |
| **Only suppress deadzone while world moves** | When checked, the deadzone only suppresses accumulation while the world is being drawn. When the scene is still, full-screen menus can accumulate even inside the deadzone. When unchecked, the deadzone is suppressed at all times. |
| **Diagnostics: motion view** | Which reading the overlay draws when it is switched on. On, it is the motion view: red where the frame sees a change, nothing where it does not. Off, it is the verdict view: green where a pixel has earned its place in the mask — the shader's own verdict, without the closing radius — nothing where it has not. Both tint only the pixels they name and leave the rest of the picture exactly as the game drew it; the deadzone ring and the bottom-left corner marker show in both. |

There are four more switches that are not sliders — **anti-bloom** (on by default), the
**diagnostics overlay** (off), the **compute path** (off), and the **motion estimate** (off). All four
are compile-time switches rather than sliders, which is why turning one on or off causes a short
recompile rather than taking effect instantly. The trade is worth it: with a switch off, the work it
would have done is not just skipped, it isn't in the shader at all.

**The motion estimate** is the one that measures rather than protects: it works out, from the picture
alone, roughly how far the whole image moved since a moment ago. **It changes nothing about which pixels
are protected**, with the switch on or off — it exists on its own because whether a panning sky reads as
one steady movement is worth knowing before anything is built on top of it. It needs the compute path
below, and so a Direct3D 11 or newer device, or Vulkan: with the compute path off there is nothing for it
to run on and it is simply the pixel path. It allocates about 7 MB of buffers while it is on, and none
while it is off.

**The compute path** changes *how* the mask is worked out, not what it means, and everything in the
table above still applies. On the pixel path the screen-wide reading the mask depends on is an
approximation: the picture is reduced to a 16×16 grid with four samples per block, so about a thousand
samples stand in for every pixel on screen, and a small panel arriving — or a region falling between
the samples — can move that reading without the sampler seeing why. With the compute path on, the
accumulator itself counts every pixel it calls changed, collapsed per block of 256 before it is added
up, so the reading is exact and the two coarse-grid passes disappear. What it buys is not a faster
shader — it costs a little more than the pixel path and allocates two more full-screen buffers — but a
reading you can trust, the drift horizon below, and a step measured from the scene rather than guessed.
If you are happy with the pixel path, there is no reason to move.

It needs a Direct3D 11 or newer device, or Vulkan. On Direct3D 9 or 10, or any device without compute
support, leave it off — the shader cannot fall back to the pixel path on its own, and the technique
will fail to build. On anything modern it is safe to switch on, and worth doing if you have ever seen
the screen-wide reading behave oddly — a mask that forms or refuses to form for no visible reason, or
scenery that creeps in slowly while nothing appears to be moving.

The compute path also carries the **Drift horizon** setting above: a second, long-baseline reading of
each pixel, for the slow drift the frame-to-frame comparison is blind to. Raise it to catch slower
drift, lower it to get the mask back sooner. It is the one setting here sized in seconds rather than
frames, and it has to be: it builds a measurable difference out of a change too small to see between
two frames, so a horizon of a handful of frames would still be level with the scene and let the drift
through unread. If you have watched a slow backdrop creep into the mask, this is the setting that
stops it, and raising it further is what catches slower movement still.

It is also the most memory-hungry part of the shader, and deliberately so: the average it keeps has to
creep toward the picture by a fraction of a level a frame, which is finer than half precision can
resolve over the brighter half of the range, so it is the one buffer here kept in full precision
instead of half. The pair of them come to about 120 MB at 1440p. What that buys is the channel
working across the whole brightness range instead of only in the dark: the same slow drift used to be
caught over a dark sky and missed over a bright one, and a still element could be kept out of the mask
for as long as it sat a level away from its own average.

It carries **Auto-detect RGB step** and its **Noise floor** as well, the other settings that come and
go with this switch. On the pixel path the step has to be a number you chose; here the shader can count
up exactly how many pixels changed by each amount — one tally per size of change, over every pixel on
screen — and put the step where the scene's own noise stops and the movement starts. The two are
alternatives: with auto-detect on the slider is ignored rather than blended with the measurement, so
you can turn it on and off to compare the two without either interfering with the other.

## Seeing what it decided

Turn the diagnostics overlay on and it draws one of two readings over the picture, whichever
**Diagnostics: motion view** picks. Both tint *only* the pixels they name and leave every other pixel
exactly the game drew it, with no global wash — it is either red where the frame sees a change or green
where the shader has decided a pixel is interface, and nothing at all where neither applies:

- **Red** — the motion view: how much this pixel changed this frame, with nothing the frame forgave
  drawn at all. From there it is graded over a fixed three-level span: a change one step under the
  RGB-step setting is the first to show, one the size of the setting is a faint red — about a quarter
  of full strength, one a step larger about three-quarters, and one two steps above it is full red —
  the same span at every position of that slider. It fades out as a region settles, and it keeps
  updating even while the world is stopped, so a red patch in a held frame is something still moving
  on screen. This is the view to watch while setting that slider: no red over something you can see
  moving means the setting is above it. A pixel that is red while the verdict view would call it yours
  is an element being left behind as the world starts moving over it — the normal way a menu leaving
  looks.
- **Green** — the verdict view: the shader's judgement right now, this pixel has earned its place in
  the mask. It is on or off, never a shade, because it is a decision — and it is the shader's verdict
  *without* the closing radius, so an element shows exactly its own area and nothing grown around it.
  This is the view for asking what the shader thinks it is protecting: a menu should light up while it
  is open and go dark as the world takes it back. A stopped world adds nothing, so in a held frame
  (the marker below is yellow) the green you see is the last state that was decided, and may only
  shrink, never grow.

If you have configured a center deadzone (`Center deadzone width` and `height` above zero), a thin yellow ring is drawn around the boundary of the ellipse so you can see exactly where it frames your character while adjusting the sliders.

The small block in the bottom-left corner is always drawn, and its colour tells you what the whole
screen is doing — which matters, because that is what decides whether the reading you can see is a
current judgement or a held one:

- **Magenta** — the world is being drawn. The reading on screen is live: the verdict view's greens are
  being earned, the motion view's reds are clearing.
- **Yellow** — the world has stopped being drawn. The mask is now held: anything still keeps exactly
  the state it was in, and anything the frame shows moving is still falling out. So in a yellow frame
  the green view is the last state that was decided and will not change on a still pixel, while red
  and the falling of a moving pixel are still live.

The block is drawn flat, with no blending, by the very last thing in the chain, so nothing can paint
over it — it stays its own colour whatever the game or your other effects are doing underneath,
including behind your own interface. It is a colour to read, like a traffic light, not part of the
picture, which also means it is only there while both techniques are enabled, since the second one
draws it.

The marker reflects the state about to be used, one frame ahead of the decision the mask has just made,
so do not be surprised if it changes a frame before the mask visibly does.

Compare it against the game underneath. This is the only way to tell a genuine mistake from something
the shader can never get right, so it is worth turning on the first time you use this.

## Anti-bloom

If you run a bloom or glare effect, it will find the bright edges of your HUD and smear them out over
the scene behind. Anti-bloom stops that. While it's on, the interface pixels are blacked out in the
frame your other effects see, so there is nothing bright there for bloom to pick up — and the real
interface is put back by `AutoMask_Restore` at the end, so you never see the black.

That means the final picture is unchanged by this switch: it only changes what the effects in between
are allowed to see.

## What it can't do

These aren't settings you haven't found yet. They're limits of the idea, and knowing about them saves
time:

- **Semi-transparent interface is never protected.** If the world shows through an element — a faded
  health bar, a translucent map overlay — those pixels are constantly changing, so they never look
  still and never get protected. This is the one case where a hand-painted mask genuinely does better.
- **Standing still somewhere with nothing moving.** Face a wall or a closed door in a quiet room and
  there is nothing animating in view, so a wall that never moves is never distinguished from a HUD by
  the comparison alone. This is what the motion setting above is for, and it is why that setting is the
  premise rather than a refinement: while the world is not being drawn the shader does not take
  stillness for interface at all, so a stopped scene cannot fill the mask in — it can only hold what it
  already had, or lose it.

  Remembering movement cannot help here, and it is worth being clear why. The shader only knows what
  the last two frames looked like. A wall you walked past was moving in the picture, so it is
  remembered and cannot be grabbed when you stop. A wall you have been standing in front of the whole
  time never moved, so there is nothing to remember — and it is genuinely indistinguishable from a
  HUD, because on the evidence available it is the same thing.
- **A frame that is fully black or fully white never counts as still.** A colour pressed against the top
  or bottom of its range may be saturated rather than motionless, so a letterbox bar, a hard fade or a
  clipped sky earns nothing while it holds, and a screenful of it converges toward no mask rather than
  filling one — the right side to be wrong on. Moves onto and off full black or white are ordinary
  changes and are judged as usual.
- **A panel that opens over a scene that has already stopped.** The cost of the same premise: a menu
  that pops open over a paused world is caught only because its opening is itself movement, and that
  movement has to lift the screen-wide reading over the motion threshold. A large panel fades in, so it
  usually registers; a small one, or a slow one, may not, and then the shader has no evidence to work
  with. Lower the motion threshold for that, and accept that scenery will be caught more readily while
  the view is quiet.
- **Something that moves while the world is stopped falls out of the mask.** A spinner, a flashing
  icon, a video-style background loop — with the world stopped, those pixels keep changing, so they are
  treated as moving and drop out even though they are not really interface. This is the deliberate
  trade that keeps a stopped scene from filling in: the shader would rather lose a genuinely animating
  element in a paused scene than protect something it cannot identify. It also means the mask can
  shrink but never grow while the world is stopped, so a stopped scene converges rather than drifting.
- **Interface that animates for longer than the grace period loses its protection.** The other side of
  the same trade as the wall. The grace runs as a balance, so an element keeps its mask while its
  animation outweighs its pauses and loses it once the changing frames predominate — correct by the
  shader's own reasoning, since something mostly in motion is not something the game paints in place.
  If you have an element like that, raise the grace period until its animation outweighs its pauses.
- **A player character tethered to the camera in third-person games.** When running forward in a
  third-person game, the camera moves with your character, so the background streams past while your
  character's back or torso stays locked at the exact same screen position. To the comparison that
  looks identical to a HUD element. Use the **Center deadzone** settings to carve out an elliptical
  exclusion zone around your character model.
- **A HUD that flickers without moving, on the compute path.** Dithering and temporal anti-aliasing
  make a pixel that is standing still differ by a level or two from frame to frame — usually forgiven
  by the RGB step above, but not by the drift horizon, because a pixel that keeps wandering does end up
  away from its own average. The direction it fails in is the mild one: the element is left out of the
  mask rather than the scenery being taken in. If you see a static element being dropped when the
  compute path is on, shorten the horizon.
- **The measured RGB step has nothing to measure in a fully live frame, on the compute path.**
  Auto-detect works by finding where the picture's noise stops, and that only exists while most of the
  screen is holding still. Pan across a detailed scene, or stand in a crowd of moving things, and every
  change size is being made by something somewhere across the whole screen — there is no quiet majority
  for the floor to be read off. The shader notices and keeps the slider's own value for those frames
  rather than guessing a step from a scene that has no floor, so a fast camera movement cannot talk it
  into forgiving real motion. It only means the measurement is a reading of calm scenes, which is
  exactly where the slider is hardest to set by hand. If it settles on a step you don't like in a
  particular game, turn it off and use the slider — the two are alternatives, and the slider is
  untouched while auto-detect is on.
- **A wrong mask is worse than a wrong verdict.** Where a mask image toggles effects at the wrong
  moment, this one is continuously visible if it's wrong. If in doubt, tune toward a longer grace
  period and a tighter closing radius rather than an eager mask.
- **It is expensive.** The mask costs several full-screen passes every frame, and it allocates several
  full-resolution buffers while it's loaded. This is the price of not needing a mask image, and it is
  the most expensive thing in the pack next to `UIDetectMulti` itself. If your frame rate is tight,
  this is not the shader to add.

## Credit

The idea of building a UI mask from what holds still, the store-the-pixels-first /
restore-them-last arrangement, and the anti-bloom trick all come from Kaiser's `UIDetectMulti`, which
builds on work by Brussels1. This shader shares no code with that project — see `LICENSE`.

Licensed MIT.
