# AutoMask

Builds a UI mask for ReShade by watching what holds still.

## What it does

You want to protect the interface — the health bar, the inventory, the map, the dialogue box — from
whatever your other effects are doing to the picture. Normally that means painting a mask image by
hand. This does it from one assumption: **most of the screen is the world.**

A pixel the game keeps drawing in the same place, frame after frame, only means interface while the
world around it is in motion. So the shader compares each frame against the one before it: hold still
for a couple of frames while the view moves and you are taken for interface; keep changing for a couple
of frames and you fall away again. Open a menu and its region holds still while the world carries on
behind it, so it lands in the mask; close it and the world starts moving there again, so it drops out.

Movement is the stronger evidence, so a pixel seen moving has to hold still for a while before it can be
taken for interface, which stops a wall being added to the mask the moment you stop walking past it. The
awkward case is a menu opened over a world that has already stopped, a pause screen say: nothing is being
redrawn, so stillness proves nothing, and the shader will not add anything on that evidence. A stopped
scene can only lose mask, never gain it.

## Installation

Copy both files (`AutoMask.fx` and `AutoMask.fxh`) into your `reshade-shaders\Shaders` folder under the 
game dir. Then you have to enable it in the ReShade UI.

1. **AutoMask** — **first** in the effect list, above everything else, so it compares the game's
   untouched picture.
2. **AutoMask_Restore** — **last**, below everything else, so it puts the interface back on top once
   your other effects have finished with the frame.

## The settings

All of them live in the ReShade panel, and the defaults are meant to be usable as-is. The panel groups
them as **Frame timing**, **Is the scene in motion?**, **AutoMask**, **RGB step detection**,
**Isolated pixels** and **Diagnostics**. The tables below follow that order, and the compile-time
switches that add to it are explained after them.

Four switches are compile-time, so changing one recompiles the shader rather than taking effect
instantly, and each hides the settings only it can read: **anti-bloom** (on by default), the
**diagnostics overlay** (off), **Use Compute Shaders** (off) and the **depth check** (off). Everything
else takes effect live.

### Frame timing

The four durations that decide how quickly a pixel gets added to the mask, drops out of it, and keeps
it through brief animation.

| Setting | What it does |
| --- | --- |
| **Frames still before marked as interface** | How many frames a pixel holds still, while the world is being drawn, before it is added to the mask. Raise it if a backdrop that stops when you do keeps getting caught; lower it if a HUD that only briefly holds still fails to appear. |
| **Frames moving before unmarked as interface** | How many frames a pixel has to keep changing before it is dropped from the mask, on top of the frames **Frames of absence before decay starts** absorbs. Lower clears a region faster once the world moves over it again; higher makes the mask linger. |
| **Frames of absence before decay starts** | Keeps an element covered while it animates a little — a draining bar, a scrolling list, a blinking cursor — by absorbing this many frames of animation before the pixel starts to be dropped. Raise it when you get holes over exactly the parts of a HUD that move. |
| **Frames a move is remembered** | How long a pixel stays out of the mask after the frame shows it moving. Raise it to stop a wall you just walked past being added to the mask the moment you stop; `0` forgets a move the frame after it happens. |

### Is the scene in motion?

How much of the screen must be changing before the world counts as being in motion. It is a single
screen-wide reading, and nothing is marked as interface until it is crossed — because a pixel that
holds still in a scene that has stopped proves nothing.

The depth settings below need the **depth check** switch, explained further down.

| Setting | What it does |
| --- | --- |
| **Motion needed to trust stillness (percent)** | How much of the screen has to be changing before a still pixel is taken for interface. Raise it if scenery keeps getting caught, lower it if a HUD fails to appear. A very dark view can put a high setting out of reach. |
| **Depth step counted as a change (metres)** | How far a surface must move toward or away from you in one frame to count as the world being redrawn, as a real distance in metres. Raise it if depth noise keeps the world reading as drawn over a stopped scene, lower it if walking fails to register. |
| **Depth only, not added to the picture** | On, the world-drawn reading comes from the depth buffer alone, so textures that animate no longer count as the world moving; off, it is depth added to the picture's own. It helps in the rare views where the picture is busy but the viewpoint is not, and it has a cost: an element arriving while the camera is still may not be added until the view moves, and with no depth buffer bound the world never reads as drawn — so give it a preset of its own rather than leaving it on. |
| **Camera field of view (degrees)** | The camera's vertical field of view, used to work out which way each surface faces so a floor or ceiling can be left out of the depth reading. A wrong value tilts that reading rather than changing which surfaces are left out. |

### AutoMask

The settings always in play.

| Setting | What it does |
| --- | --- |
| **Mask grow radius** | Grows the mask slightly so anti-aliased edges and thin text come out solid instead of speckled. `0` turns it off. |
| **Luma step counted as a boundary** | Stops that growth at a real edge in the picture, so the mask snaps to the HUD's outline instead of spilling out into the scenery. |
| **Drift horizon (seconds)** *(Use Compute Shaders only)* | How long the slow colour average the drift comparison reads remembers. It catches scenery that shifts by less than one step of colour a frame — a skybox panning slowly — which the frame-to-frame comparison cannot see. `0` turns the comparison off. |
| **Stop specks entering the mask** | Off by default. On, a still pixel with no protected pixel beside it takes twice as long to be added, so lone specks and scenery are not added to the mask; a solid element still appears normally. |
| **RGB step counted as a change** | How much a pixel's colour may change between two frames before it counts as motion, as a number of colour steps out of 255. A colour is stored with 256 possible values, so `1` is the most sensitive: any change at all counts as motion. Raise it only if the overlay shows red over things genuinely not moving — noise, dithering, temporal anti-aliasing — at the cost of no longer seeing the smallest movements. It decides whether a pixel moved, never what moving costs. |

### RGB step detection

*(Use Compute Shaders only)*

| Setting | What it does |
| --- | --- |
| **Auto-detect RGB step** | On, the RGB step is measured from the scene each frame rather than read from the slider, so the picture's own noise is forgiven automatically. Start here if you have ever found yourself nudging that slider. |
| **Noise floor (percent)** | How strict that measurement is, as a share of the screen. Lower forgives more; higher keeps the smallest movements at the cost of admitting more noise as motion. Shown only while auto-detect is on. |

### Isolated pixels

The filter below ships off, so the mask is unchanged out of the box.

| Setting | What it does |
| --- | --- |
| **Enable isolated pixel removal** | On, a masked pixel is kept only while enough of its neighbourhood is still, or a line through it is still along most of its length, so lone specks and scenery are not protected. Off, nothing extra is removed: the mask is exactly what the grow radius produces. |
| **Still neighbourhood density (percent)** | What share of the neighbourhood must be still — the pixel itself counted — for a masked pixel to stay. Raise it to drop sparser specks, lower it if something solid comes back with holes. |
| **Isolation radius in pixels** | How far that neighbourhood reaches, as a square `2 × this + 1` across. It is separate from the mask grow radius: a wider box is stricter against thin strokes. |

### Anti-bloom

A bloom or glare effect will find the bright edges of your HUD and smear them out over the scene.
Anti-bloom blacks the interface out in the frame your other effects see, so there is nothing bright for
bloom to pick up; `AutoMask_Restore` puts the real pixels back, so the final picture is unchanged. It is
a compile-time switch and on by default.

### Diagnostics

*(needs the diagnostics overlay switch)*

On, the overlay draws one reading over the picture, and the toggles below pick which. Each tints only
the pixels it names and leaves the rest exactly as the game drew it. Compare it against the game
underneath: that is the only way to tell a genuine mistake from something the shader can never get
right. The **motion view**, with the **motion gain** that belongs to it, is the one to use; the two
views below it are development readings.

| Setting | What it draws |
| --- | --- |
| **Diagnostics: motion view** | Red where the frame sees a change, nothing where it does not. This is the view to watch while setting the RGB step: no red over something you can see moving means the setting is above it. |
| **Diagnostics: motion gain** | Brightens the red motion reading, so a change too small to see becomes visible. |
| **Diagnostics: confidence view** | Two flat colours rather than a grade: **cyan** where the mask already includes the pixel, **magenta** where it is part-way there but has not made it yet. Magenta over dim scenery, with no interface there, is the shader part-way to protecting the world. |
| **Diagnostics: depth normals** *(depth check only)* | White where the surface faces up or down — the floor and ceiling, which depth motion cannot see on a walk — and black where it faces the way you walk. |

The small block in the bottom-left corner is always drawn, and its colour tells you what the whole
screen is doing: **magenta** while the world is being drawn, so what you are looking at is a live
judgement, and **yellow** while it is not, so the mask is frozen and can only shrink.

With **Use Compute Shaders** on and **Auto-detect RGB step** ticked, a small **digit** is drawn in the
bottom-right corner: the RGB step the measurement has settled on, from 1 to 8. Higher means the shader is
currently forgiving more small movement as noise. It shows nothing when auto-detect is off, since there is
no measured value to show.

### The depth check

Depth can help decide when the world is being drawn, the question the whole mask waits on, because
the UI writes no depth: a panel drawn over the scene takes the scene's own depth, so depth sees
the world and never the interface.

It is off by default for two reasons. Depth buffer access is not always there — online games often block
it. It also needs ReShade's Depth Buffer settings to be correct. Generally, if available it is probably
more accurate and should be used alone (i.e. Depth only enabled).

### Use Compute Shaders

On, the mask is more accurate: it picks up smaller and more local movement, so less scenery is wrongly
protected and fine detail is caught more reliably. It also adds settings that do some tuning for you —
measuring the picture's own noise automatically, and watching for scenery that drifts slowly.

It is off by default because it costs a little more GPU time and roughly 60 MB more memory at 1440p.
It also needs a Direct3D 11 or newer game, or Vulkan — on Direct3D 9 or 10 leave it off, as the effect
will not build with it on. Turn it on if your card and frame rate can spare it.

## What it can't do

These aren't settings you haven't found yet — they're limits of the idea, and knowing about them saves
time:

- **Semi-transparent interface is never protected.** If the world shows through an element, those pixels
  keep changing and never look still. This is the one case where a hand-painted mask does better.
- **A quiet interior with nothing moving.** Nothing in view animates, so a wall that never moves is
  indistinguishable from a HUD. The shader adds nothing to the mask while the world is stopped,
  so a stopped scene can only keep what it already had, or lose it.
- **A still patch of world beside an animating one.** The motion reading is one number for the whole
  screen, so a waterfall or fire covering enough of the view makes the shader protect every still patch,
  including a wall or the backdrop behind a menu. Raising **Motion needed to trust stillness** helps only
  while the animating part is small.
- **Scenery drifting too slowly to change a pixel between two frames.** Colour creeping by less than half
  of one step out of 255 in a frame rounds to no change at all, and no change is what the shader calls
  interface. Dim, smoothly shaded regions are where this bites. **Frames a move is remembered** helps.
- **A panel opening over a scene that has already stopped.** It is caught only by its own opening
  movement, so a small or slow one may not be.
- **Something that moves while the world is stopped falls out of the mask.** A spinner, a flashing icon,
  a looping background: those pixels keep changing and drop out. This is the trade that keeps a stopped
  scene from filling in.
- **A frame that is fully black or fully white never counts as still**, since a colour at the top or
  bottom of its range may be saturated rather than motionless. A letterbox bar or a hard fade gains no
  protection while it stays that colour.
- **Interface that animates for a long stretch loses its protection.** Raise **Frames of absence before
  decay starts** for an element like that.
- **A player character tethered to the camera in third-person games.** Running forward, the camera moves
  with you, so your character's back stays locked at the same screen position — identical to a HUD
  element as far as the comparison can tell.
- **A HUD that flickers without moving, when Compute Shaders are on.** Dithering and temporal
  anti-aliasing make a still pixel wander a step or two of colour, which the drift horizon reads as
  movement, so the element is left out of the mask. No setting avoids it: shortening the drift horizon
  gives up the slowest drift it was catching, and raising the RGB step gives up the same small movements.
- **Very thin interface can be dropped by the isolated-pixel filter**, off by default: its line test
  keeps a straight one-pixel stroke — across, down or either diagonal — while a stroke at an angle or a
  curve is only partly covered.
- **Bloom can still find an edge at the HUD contour.** Suppression removes the interface as a bloom
  source, but a hard black step against a bright scene is itself contrast, so a faint edge can remain.
- **A wrong mask shows the whole time.** A hand-painted mask toggles an effect at the wrong moment;
  this one is continuously visible if it is wrong. If in doubt, tune toward a longer **Frames of absence
  before decay starts** and a smaller mask grow radius.
- **It is expensive.** Several full-screen passes every frame and several full-resolution buffers while
  it's loaded. If your frame rate is tight, this is not the shader to add.

## Credit

The idea of building a UI mask from what holds still, the store-the-pixels-first /
restore-them-last arrangement, and the anti-bloom trick all come from Kaiser's `UIDetectMulti`, which
builds on work by Brussels1. This shader shares no code with that project — see `LICENSE`.
