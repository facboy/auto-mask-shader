# AutoMask

Builds a UI mask for ReShade by watching what holds still.

Nothing to install, nothing to paint, no coordinates to pick. Drop the shader in, place it twice, and
it works out where your HUD is by itself.

## What it does

Somewhere in your effect chain you want to protect the interface — the health bar, the inventory, the
map, the dialogue box — from whatever your other effects are doing to the picture. Usually that means
painting a mask image by hand: which pixels are UI, which are the world.

This does it the other way round. A pixel the game keeps drawing in the same place, frame after frame,
is something that isn't moving, and almost everything that isn't moving is interface. A pixel the
world is animating is not. So the shader compares each frame against the one before it and builds the
mask from that: hold still, and you accumulate; keep changing, and you fall away again.

Motion is the stronger of the two readings, so the shader trusts it further. A brief movement — a bar
that drains, a list that scrolls — is covered by the grace period and never counts against the
element. A movement that lasts, though, is remembered: it is what the game re-rendering from a new
viewpoint looks like, and no panel is drawn that way. So a pixel seen moving stays out of the mask and
has to hold still for a while before it can be taken for interface. That is what keeps the shader from
grabbing a wall the moment you stop walking past it.

Open a menu and its whole region holds still, so it lands in the mask. Close it and the world starts
moving there again, so it drops back out.

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
| **Motion needed for a live frame (percent)** | Below this much of the screen moving, the shader decides the world isn't being drawn and holds the mask as it is rather than guessing from a still picture. See the honest limits below. `0` turns this off. |
| **Still frames before the map is held** | How long that has to go on before the holding starts. It exists so a menu that opens into an already-paused scene still gets looked at before the shader stops looking. |

There are two more switches that are not sliders — **anti-bloom** (on by default) and the
**diagnostics overlay** (off). Both are compile-time switches rather than sliders, which is why
turning one on or off causes a short recompile rather than taking effect instantly. The trade is worth
it: with a switch off, the work it would have done is not just skipped, it isn't in the shader at all.

## Seeing what it decided

Turn the diagnostics overlay on and the mask is drawn over the picture: **green where the shader
thinks a pixel is interface, blue where it thinks it's the world**. Compare it against the game
underneath. This is the only way to tell a genuine mistake from something the shader can never get
right, so it is worth turning on the first time you use this.

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
  there is nothing animating in view, so the wall looks exactly like a HUD. The motion setting above
  is the defence: once it notices almost nothing is moving it holds the mask instead of extending it.
  The cost is that a menu opened in a scene the game has already paused gets a limited window to be
  noticed, which is what the settle setting is for. Both are visible in the diagnostics overlay, which
  is why that ships with it.

  This is the one case where remembering movement cannot help, and it is worth being clear why. The
  shader only knows what the last two frames looked like. A wall you walked past was moving in the
  picture, so it is remembered and cannot be grabbed when you stop. A wall you have been standing in
  front of the whole time never moved, so there is nothing to remember — and it is genuinely
  indistinguishable from a HUD, because on the evidence available it is the same thing.

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
