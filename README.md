# AutoMask

Builds a UI mask for ReShade by watching what holds still.

Nothing to install, nothing to paint, no coordinates to pick. Drop the shader in, place it twice, and
it works out where your HUD is by itself.

## What it does

Somewhere in your effect chain you want to protect the interface — the health bar, the inventory, the
map, the dialogue box — from whatever your other effects are doing to the picture. Usually that means
painting a mask image by hand: which pixels are UI, which are the world.

This does it the other way round, with one thing held above the rest: **most of the screen is the world.** A
pixel the game keeps drawing in the same place, frame after frame, is something that isn't moving — and
that only means interface while the world around it is being drawn. When the view is moving, anything
that holds still is almost certainly yours. When the whole screen has gone still, the thing holding
still is the backdrop, and the shader stops deciding rather than guessing: it holds the mask it already
has and adds nothing. It compares each frame against the one before it as the evidence for that: hold
still while the world moves for a couple of frames, and you are taken for interface; keep changing for
a couple of frames, and you fall away again.

Motion is the stronger of the two readings, so the shader trusts it further. A brief movement — a bar
that drains, a list that scrolls — is covered by the grace period and never counts against the
element. A movement that lasts, though, is remembered: it is what the game re-rendering from a new
viewpoint looks like, and no panel is drawn that way. So a pixel seen moving stays out of the mask and
has to hold still for a while before it can be taken for interface. That is what keeps the shader from
grabbing a wall the moment you stop walking past it.

Open a menu and its whole region holds still while the world carries on behind it, so it lands in the
mask. Close it and the world starts moving there again, so it drops back out.

The awkward case is a menu that pops open over a world that has already stopped — a pause screen, say.
Nothing is being redrawn, so stillness proves nothing about what is on screen, and the shader will not
add anything on that evidence alone. What it does instead is hold: for as long as the world is not being
drawn, a pixel that is holding still keeps whatever it had, and a pixel that is moving still falls out.
So a stopped scene can only ever lose mask, never gain it — a quiet room cannot fill in, and nothing
that is animating can be sitting in the mask while the world is stopped. The cost is that a panel which
opens by itself into a world that has already stopped is caught only if its arrival is itself movement
big enough to lift the reading on the line below; a small or slow one may not register at all.

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
| **RGB step counted as a change** | How far a pixel's colour may move between two frames before the frame counts it as motion, counted in whole levels out of 255 — the steps the channels themselves can take, so the slider moves in whole levels too. It answers one question only, "did this pixel move?", and it is the most sensitive at `1`, where any change at all is motion — shown in the overlay as a change one step below the setting's own size. `2` forgives a one-level difference, `3` forgives two, and so on; there is nothing below `1`, because a level is the smallest change a channel can make. A change the size of the setting itself shows a faint red — a quarter of full strength — and the further a change goes above it the more strongly it reads, reaching full strength four steps above it. Raise it only if you see red in the overlay over things that are genuinely not moving — noise, dithering or temporal anti-aliasing makes a static pixel differ by a level or two — at the cost of no longer seeing the smallest movements; lower it to `1` if anything you can see moving is shown without red. What a moving pixel then *costs* the mask is a separate setting (**Frames moving before unmarked as interface**, and the move memory): every frame the RGB step calls changing costs one frame of the unmarking countdown, however small the change was, so this slider decides *whether* the frame sees it and nothing else. |
| **Frames still before marked as interface** | How many frames a pixel has to hold still — while the world is being drawn — before it is added to the mask. Raise it if a backdrop that stops when you do keeps getting caught; lower it if a HUD that only briefly holds still fails to appear. A pixel seen moving has to repay its move memory first, so that countdown has to pass before this one starts. |
| **Frames moving before unmarked as interface** | How many frames a pixel has to keep changing — counting from when it was last marked, and past the grace period below — before it is dropped from the mask. Lower clears a region faster once the world starts moving over it again; higher makes the mask linger. The count runs whether or not the world is being drawn, and frames the RGB step calls still cost nothing. Keep it short enough that the world takes the mask back promptly, long enough that one stray changing frame cannot punch holes in a protected element. |
| **Frames of absence before decay starts** | The grace period before that decay begins. This is the one that matters most: it is what keeps an element covered while it animates a little — a draining bar, a scrolling list, a blinking cursor. Too short and you get holes over exactly the parts that move. It only applies while the world is being drawn. |
| **Frames a move is remembered** | How long something stays out of the mask after the frame shows it moving. Holding still is only a hint — a wall holds still too — but movement is proof: the game re-renders moving things from a new viewpoint, and nothing paints a panel that way. So a move is remembered, and a pixel seen moving has to hold still for this many frames before it can be claimed as interface. This is what stops a wall you just walked past being grabbed the moment you stop. The repaying of that debt does not wait on the world being drawn, so this is also how long a screen-wide move takes to clear once the view stops — raise it and a pan takes longer to settle. At `0` a move is forgotten the frame after it happens, which is the old behaviour. |
| **Closing radius in pixels** | Grows the mask slightly to close anti-aliased edges and thin text. `0` turns it off. |
| **Luma step counted as a boundary** | Stops that growth at a real edge in the picture, so the mask snaps to the HUD's outline instead of spilling out into the scenery. |
| **Motion needed to trust stillness (percent)** | How much of the screen has to be changing before the shader believes the world is being drawn. Above it, a pixel that holds still is taken for interface and the mask builds; below it, stillness earns nothing, because what holds still in a still scene is the scenery. This is the line that decides whether the screen is being drawn at all — the premise rather than a refinement, which is why its default is not zero. Raise it if scenery is still getting caught, lower it if a HUD fails to appear. |
| **Center deadzone width (percent)** | Width of an elliptical center region where stillness does not accumulate into the mask. Keeps a third-person player character tethered to the camera from being captured as interface. `0` turns it off. |
| **Center deadzone height (percent)** | Height of the elliptical center deadzone. `0` turns it off. |
| **Center deadzone vertical position (percent)** | Vertical center of the deadzone (`50` is screen center; raise it to move down toward the character's feet). |
| **Only suppress deadzone while world moves** | When checked, the deadzone only suppresses accumulation while the world is being drawn. When the scene is still, full-screen menus can accumulate even inside the deadzone. When unchecked, the deadzone is suppressed at all times. |
| **Diagnostics: motion view** | Which reading the overlay draws when it is switched on. On, it is the motion view: red where the frame sees a change, nothing where it does not. Off, it is the verdict view: green where a pixel has earned its place in the mask — the shader's own verdict, without the closing radius — nothing where it has not. Both tint only the pixels they name and leave the rest of the picture exactly as the game drew it; the deadzone ring and the bottom-left corner marker show in both. |

There are two more switches that are not sliders — **anti-bloom** (on by default) and the
**diagnostics overlay** (off). Both are compile-time switches rather than sliders, which is why
turning one on or off causes a short recompile rather than taking effect instantly. The trade is worth
it: with a switch off, the work it would have done is not just skipped, it isn't in the shader at all.

## Seeing what it decided

Turn the diagnostics overlay on and it draws one of two readings over the picture, whichever
**Diagnostics: motion view** picks. Both tint *only* the pixels they name and leave every other pixel
exactly the game drew it, with no global wash — it is either red where the frame sees a change or green
where the shader has decided a pixel is interface, and nothing at all where neither applies:

- **Red** — the motion view: how much this pixel changed this frame. Nothing the frame forgave is drawn
  at all, and from there it is graded: a change one step under the RGB-step setting is the first to
  show, one the size of the setting is a faint red — about a quarter of full strength — and one four
  steps above it is full red. So this is the view to watch while setting that slider: no red over
  something you can see moving means the setting is above it. Red fades out as a region settles down,
  and it keeps updating even while the world is stopped, so a red patch in a held frame is something
  genuinely still moving on screen. A pixel that is red while the mask view would call it yours is an
  element being left behind as the world starts moving over it — the normal way a menu leaving looks.
- **Green** — the verdict view: the shader's judgement right now, this pixel has earned its place in
  the mask. It is on or off, never a shade, because it is a decision, and it is the shader's own
  verdict per pixel — the closing radius is *not* included, so an element shows exactly its own area
  and nothing grown out around it. This is the view for asking what the shader thinks it is protecting:
  a menu should light up while it is open and go dark as the world takes it back. A stopped world adds
  nothing, so in a held frame (the marker below is yellow) the green you see is the last state that was
  decided and may only shrink, never grow.

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

The block is drawn flat — no blending, no tinting — and it is put there by the very last thing in the
chain, so nothing can paint over it. It stays its own colour whatever the game or your other effects
are doing underneath, including behind your own interface. It is a colour to read, like a traffic
light, not part of the picture — which also means it is only there while both techniques are enabled,
since the second one draws it.

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
  the comparison alone. This is what the motion setting above is for, and it is the reason that setting
  is the premise rather than a refinement: while the world is not being drawn the shader does not take
  stillness for interface at all, so a scene that has stopped cannot fill the mask in — it can only hold
  what it already had, or lose it. What that costs is the panel that opens by itself into a world that
  has already stopped: its arrival has to lift the screen-wide reading over the threshold to be noticed,
  and a small panel in a large still scene may not do that.

  This is the one case where remembering movement cannot help, and it is worth being clear why. The
  shader only knows what the last two frames looked like. A wall you walked past was moving in the
  picture, so it is remembered and cannot be grabbed when you stop. A wall you have been standing in
  front of the whole time never moved, so there is nothing to remember — and it is genuinely
  indistinguishable from a HUD, because on the evidence available it is the same thing.

- **A panel that opens over a scene that has already stopped.** Nothing is being redrawn, so stillness
  proves nothing about what is on screen — which is the point of the motion setting, and it is what
  keeps a quiet room from filling the mask. The cost is here: a menu that pops open over a paused world
  is caught only because its opening is itself movement, and that movement has to lift the screen-wide
  reading over the threshold. A large panel fades in, so it usually registers; a small one, or a slow
  one, may not, and then the shader has no evidence to work with. Lower the motion threshold for that,
  and accept that scenery will be caught more readily while the view is quiet.
- **Something that moves while the world is stopped falls out of the mask.** A spinner, a flashing
  icon, a video-style background loop — with the world stopped, those pixels keep changing, so they are
  treated as moving and drop out even though they are not really interface. This is the deliberate
  trade that keeps a stopped scene from filling in: the shader would rather lose a genuinely animating
  element in a paused scene than protect something it cannot identify. It also means the mask can
  shrink but never grow while the world is stopped, so a stopped scene converges rather than drifting.
- **Interface that animates for longer than the grace period loses its protection.** This is the
  deliberate trade in the setting above, and it cuts the other way from the wall. A draining bar or a
  scrolling list is covered only while its movement fits inside "Frames of absence before decay
  starts". Move for longer than that and the shader takes it for the world — correctly, by its own
  reasoning, since something still in motion is not something the game paints in place. If you have an
  element like that, raise the grace period until the whole animation fits inside it. That is the exact
  boundary: grace period short and the element gets holes, grace period long and a wall you stopped in
  front of gets grabbed sooner.
- **A player character tethered to the camera in third-person games.** When running forward in a
  third-person game, the camera moves with your character, so the background streams past while your
  character's back or torso stays locked at the exact same screen position. To the comparison that
  looks identical to a HUD element. Use the **Center deadzone** settings to carve out an elliptical
  exclusion zone around your character model.
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
