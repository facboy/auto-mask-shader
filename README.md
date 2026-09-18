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
still is the backdrop, and the shader stops deciding rather than guessing. It compares each frame
against the one before it as the evidence for that: hold still while the world moves, and you
accumulate; keep changing, and you fall away again.

Motion is the stronger of the two readings, so the shader trusts it further. A brief movement — a bar
that drains, a list that scrolls — is covered by the grace period and never counts against the
element. A movement that lasts, though, is remembered: it is what the game re-rendering from a new
viewpoint looks like, and no panel is drawn that way. So a pixel seen moving stays out of the mask and
has to hold still for a while before it can be taken for interface. That is what keeps the shader from
grabbing a wall the moment you stop walking past it.

Open a menu and its whole region holds still while the world carries on behind it, so it lands in the
mask. Close it and the world starts moving there again, so it drops back out.

The awkward case is a menu that pops open over a world that has already stopped — a pause screen, say.
Nothing is being redrawn, so stillness proves nothing, and the panel's own brief opening is all the
evidence there is. Two settings cover the stop, and they answer different questions about it: for the
first stretch after the world stops, stillness is still believed, which is long enough for a panel that
has just appeared to be found; for a while after that, a pixel that holds still earns nothing more,
while something that moves is still noticed and still drops out; and past both, the shader stops
reading the screen altogether and simply holds the mask as it is.

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
they aren't.

| Setting | What it does |
| --- | --- |
| **RGB step counted as a change** | How far a pixel's colour can move between two frames and still count as "holding still". Raise it if the mask is full of holes over a HUD that has slight shimmer; lower it if scenery is getting caught. |
| **Confidence gained per still frame** | How quickly a pixel earns its place in the mask. Lower means an element has to hold still for longer before it counts. |
| **Confidence lost per changing frame** | How quickly a region drops back out once the world starts moving over it. Higher clears faster. |
| **Frames of absence before decay starts** | The grace period before that decay begins. This is the one that matters most: it is what keeps an element covered while it animates a little — a draining bar, a scrolling list, a blinking cursor. Too short and you get holes over exactly the parts that move. |
| **Frames a move is remembered** | How long something stays out of the mask after the frame shows it moving. Holding still is only a hint — a wall holds still too — but movement is proof: the game re-renders moving things from a new viewpoint, and nothing paints a panel that way. So a move is remembered, and a pixel seen moving has to hold still for this many frames before it can be claimed as interface. This is what stops a wall you just walked past being grabbed the moment you stop. At `0` a move is forgotten the frame after it happens, which is the old behaviour. |
| **Closing radius in pixels** | Grows the mask slightly to close anti-aliased edges and thin text. `0` turns it off. |
| **Luma step counted as a boundary** | Stops that growth at a real edge in the picture, so the mask snaps to the HUD's outline instead of spilling out into the scenery. |
| **Motion needed to trust stillness (percent)** | How much of the screen has to be changing before the shader believes the world is being drawn. Above it, a pixel that holds still is taken for interface; below it, stillness stops earning anything, because what holds still in a still scene is the scenery. Raise it if scenery is still getting caught, lower it if a HUD fails to appear. Unlike the other settings this one is the premise rather than a refinement, which is why its default is not zero. |
| **Still frames trusted after the world stops** | The window a panel gets when it opens into a scene that has just stopped. For this long after the world last moved, stillness is still believed — long enough for a menu that has just appeared to be found. This is the inner window, so keep the freeze below at least this long. |
| **Still frames before the accumulator freezes** | How long the scene has to stay quiet before the shader stops reading it altogether and holds the mask as it is. Before this but past the trust window, a pixel that holds still no longer earns anything while something that moves is still noticed and still drops out. |

There are two more switches that are not sliders — **anti-bloom** (on by default) and the
**diagnostics overlay** (off). Both are compile-time switches rather than sliders, which is why
turning one on or off causes a short recompile rather than taking effect instantly. The trade is worth
it: with a switch off, the work it would have done is not just skipped, it isn't in the shader at all.

## Seeing what it decided

Turn the diagnostics overlay on and the mask is drawn over the picture, red and green and blue.
It takes a sentence to read:

- **Green** — the shader's verdict right now: this pixel is in the mask. It is on or off, never a
  shade, because it is a decision. A green pixel that is *not* brightly blue is the closing radius
  rather than the shader's own judgement — the mask is grown over a neighbourhood, so a pixel beside an
  element gets pulled in while its own confidence is nothing.
- **Blue** — how certain the pixel is. Mid-blue is the point where nothing has been decided either way,
  which is where scenery sits. Brighter is confidence earned and climbing towards the mask. Dimmer, and
  all the way to black, is a pixel the frame has just called moving — the further from mid-blue it is,
  the further it has been pushed out. So blue brightening over something is it being recognised as
  yours, and blue going dark over something that has stopped moving is a recent move still being
  remembered, not a mistake.
- **Red** — how much this pixel changed this frame. This is the only one that fades smoothly, so red fading out is a region settling down. Green fading to red is an element being left behind as the world starts moving over it, and it is the normal way a menu leaving looks.

The small block in the bottom-left corner is always drawn, and its colour tells you what the whole
screen is doing — which matters, because that is what decides whether the reds and blues you can see
are a current judgement or an old one:

- **Magenta** — the world is being drawn and everything else on screen is a live verdict.
- **Cyan** — the world has stopped, but stillness is still being believed, so an element that holds
  still is still earning its place. This is the trust window. It is the state a menu that pops open
  over a paused world gets caught in.
- **Yellow** — stillness is no longer believed. A pixel holding still earns nothing more; only
  something that moves is still noticed, and only until the freeze.
- Stale red and blue past the freeze are expected, not a bug: nothing is being read at all by then, so
  what you are seeing is the last thing that was decided, and the marker is what tells you so.

Each of those three colours is drawn flat — no blending, no tinting — and the block is put there by the
very last thing in the chain, so nothing can paint over it. It stays its own colour whatever the game
or your other effects are doing underneath, including behind your own interface. It is a colour to
read, like a traffic light, not part of the picture — which also means it is only there while both
techniques are enabled, since the second one draws it.

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
  stillness for interface at all, so there is nothing to hold and nothing to lock. The one thing it
  buys with that is the trust window, and the thing it costs is a panel that opens over a world that
  has already stopped — the pulse of the menu appearing has to lift the screen-wide reading over the
  threshold to be noticed, and a small panel in a large still scene may not do that.

  This is the one case where remembering movement cannot help, and it is worth being clear why. The
  shader only knows what the last two frames looked like. A wall you walked past was moving in the
  picture, so it is remembered and cannot be grabbed when you stop. A wall you have been standing in
  front of the whole time never moved, so there is nothing to remember — and it is genuinely
  indistinguishable from a HUD, because on the evidence available it is the same thing.

- **A panel that opens over a scene that has already stopped.** Nothing is being redrawn, so stillness
  proves nothing about what is on screen — which is the point of the motion setting, and it is what
  keeps a quiet room from filling the mask. The cost is here: a menu that pops open over a paused world
  is caught only because its opening is itself movement, and only while the trust window is still open.
  A large panel fades in, so it usually registers; a small one, or a slow one, may not, and then the
  shader has no evidence to work with. Raise the trust window for that, and accept that a scene which
  has genuinely stopped will be read for longer before the shader gives up on it.
- **Interface that animates for longer than the grace period loses its protection.** This is the
  deliberate trade in the setting above, and it cuts the other way from the wall. A draining bar or a
  scrolling list is covered only while its movement fits inside "Frames of absence before decay
  starts". Move for longer than that and the shader takes it for the world — correctly, by its own
  reasoning, since something still in motion is not something the game paints in place. If you have an
  element like that, raise the grace period until the whole animation fits inside it. That is the exact
  boundary: grace period short and the element gets holes, grace period long and a wall you stopped in
  front of gets grabbed sooner.
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
