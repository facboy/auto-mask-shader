# AutoMask

Builds a UI mask for ReShade by watching what holds still.

Nothing to install, nothing to paint, no coordinates to pick. Drop the shader in, place it twice, and
it works out where your HUD is by itself. It is two files — `AutoMask.fx` and `AutoMask.fxh` — and they
go into your ReShade shaders folder together; the shader will not load without its companion.

## What it does

You want to protect the interface — the health bar, the inventory, the map, the dialogue box — from
whatever your other effects are doing to the picture. Normally that means painting a mask image by
hand: which pixels are UI, which are the world. This does it the other way round, from one assumption:
**most of the screen is the world.**

A pixel the game keeps drawing in the same place, frame after frame, is not moving — and that only means
interface while the world around it is being drawn. So the shader compares each frame against the one
before it: hold still for a couple of frames while the view moves and you are taken for interface; keep
changing for a couple of frames and you fall away again. Open a menu and its whole region holds still
while the world carries on behind it, so it lands in the mask; close it and the world starts moving there
again, so it drops back out.

Motion is the stronger of the two readings, so the shader trusts it further. A brief movement — a bar
draining, a list scrolling — is covered by the grace period and never counts against the element. A
movement that lasts is remembered: it is what re-rendering from a new viewpoint looks like, and no panel
is drawn that way. So a pixel seen moving stays out of the mask and must hold still for a while before it
can be claimed as interface — which is what stops a wall being grabbed the moment you stop walking past
it.

The awkward case is a menu opening over a world that has already stopped — a pause screen, say. Nothing
is being redrawn, so stillness proves nothing about what is on screen, and the shader will not add
anything on that evidence. What it does instead is hold: while the world is not being drawn, a still pixel
keeps whatever it had and a moving pixel still falls out. A stopped scene can therefore only lose mask,
never gain it — a quiet room cannot fill in, and nothing animating can sit in the mask. The cost is the
panel that opens by itself into an already-stopped world: it is caught only if its arrival lifts the
screen-wide reading over the motion setting, and a small or slow one may not.

## Placing it

Two pieces, and both positions matter:

1. **AutoMask** — **first** in the effect list, above everything else. It has to see the game's untouched
   picture for the comparison to mean anything.
2. **AutoMask_Restore** — **last**, below everything else. It puts the interface back on top once your
   other effects have finished with the frame.

Neither position is a preference: if `AutoMask` runs after another effect it is comparing processed
frames, and the mask will be wrong.

**Do not load this alongside Kaiser's `UIDetectMulti`.** They want the same two slots, so one of them
ends up reading a frame the other has already written into. They are alternatives, not companions — pick
one.

## The settings

All of them live in the ReShade panel. The defaults are meant to be usable as-is; these are for when
they aren't. The tooltips in the panel give each setting in brief — this table is where the detail
lives.

The panel groups them under headings: **Frame timing** for the four frame-count durations — how long a
pixel takes to earn its mask, to lose it, to bridge a brief pause, and to be forgiven a move — **AutoMask**
for the remaining settings that are always in play, **RGB step detection** for the auto-detect toggle and
the noise floor it governs — the floor is only shown while the toggle is ticked, since it is read by
nothing otherwise — **Isolated pixels** for dropping lone specks that have no still neighbourhood, and
**Diagnostics** for the overlay's settings. The RGB step slider is the last row of
**AutoMask**, so it sits directly above the group that measures it; it cannot move inside that group,
because the pixel path reads it with no measurement at all and with auto-detect ticked it is still the
fallback on a frame where the walk finds no floor. **Depth step counted as a change** is shown only when
the **depth premise** switch below is compiled in, and lives in **AutoMask** beside the RGB step it is the
coarser counterpart of; **Depth only (experiment)** sits beside it, shown with the same switch.

| Setting | What it does |
| --- | --- |
| **RGB step counted as a change** | How far a pixel's colour may move between two frames before the frame counts it as motion, in whole levels out of 255. The frame is quantized onto that grid first, so a change under half a level reads as no change. It answers one question only — "did this pixel move?" — and is most sensitive at `1`, where any one-level change is motion; `2` forgives a one-level difference, `3` forgives two, and so on, with nothing below `1` because a level is the smallest change a channel can make. Raise it only if you see red in the overlay over things that are genuinely not moving — noise, dithering or temporal anti-aliasing makes a static pixel differ by a level or two — at the cost of no longer seeing the smallest movements; lower it to `1` if anything visibly moving is shown without red. What a moving pixel then *costs* the mask is separate (**Frames moving before unmarked as interface**, and the move memory): every frame this step calls changing costs one frame of the unmarking countdown, however small it was, so it decides *whether* the frame sees a change and nothing else. |
| **Frames still before marked as interface** | How many frames a pixel has to hold still — while the world is being drawn — before it is added to the mask. Raise it if a backdrop that stops when you do keeps getting caught; lower it if a HUD that only briefly holds still fails to appear. A pixel seen moving has to repay its move memory first, so that countdown has to pass before this one starts. A frame that is fully black or fully white — every channel at 0, or every channel at 255 — does not count as still: a colour pressed against the top or bottom of its range may be saturated rather than motionless, and the comparison cannot tell the difference. Moves onto and off full black or white are ordinary changes, judged as usual. |
| **Frames moving before unmarked as interface** | How many frames a pixel has to keep changing — counting from when it was last marked, and past the grace period below — before it is dropped from the mask. Lower clears a region faster once the world starts moving over it again; higher makes the mask linger. The count runs whether or not the world is being drawn, and frames the RGB step calls still cost nothing. Keep it short enough that the world takes the mask back promptly, long enough that one stray changing frame cannot punch holes in a protected element. |
| **Frames of absence before decay starts** | The grace period before that decay begins, and the one that matters most: it keeps an element covered while it animates a little — a draining bar, a scrolling list, a blinking cursor. It runs as a balance, a changing frame adding one and a still frame paying half of one back, so animation that outweighs its pauses banks toward the limit while brief bursts do not. Too short and you get holes over exactly the parts that move; it applies only while the world is being drawn. |
| **Frames a move is remembered** | How long something stays out of the mask after the frame shows it moving. Holding still is only a hint — a wall holds still too — but movement is proof: the game re-renders moving things from a new viewpoint, and nothing paints a panel that way. So a pixel seen moving has to hold still for this many frames before it can be claimed as interface, which is what stops a wall you just walked past being grabbed the moment you stop. The repayment does not wait on the world being drawn, so this is also how long a screen-wide move takes to clear once the view stops. At `0` a move is forgotten the frame after it happens. |
| **Drift horizon (seconds)** *(compute path only)* | How long the shader remembers where a pixel's colour has been, as a running average. It is the second reading a pixel is judged on, and exists for one case: scenery that shifts by *less than a level a frame* — a skybox panning slowly, a distant backdrop drifting past — which the frame-to-frame comparison cannot see, because half a level rounds to no change. Over a horizon that shift adds up, and a pixel creeping away from where it was is not something the game paints in place. The average is held within a couple of steps of the picture, so a move cannot leave it stranded far behind: what the horizon sets is how slow a drift it reaches, not how long a camera pan keeps the screen looking as though it is still being drawn. Longer catches slower movement; shorter brings the mask back sooner after an abrupt change. A wide change — a scene cut or a load — drags the average straight to the new picture, so the mask is never held off waiting for a stale average; what counts as wide enough is fixed, and deliberately much larger than the smallest change the step above calls movement, so the two settings do not interfere: that one decides whether a single pixel moved, this one whether the picture around it has been replaced. `0` turns the comparison off. It is the one setting sized in seconds rather than frames, and that is the point: building a measurable difference out of a change too small to see between two frames takes time, not a handful of frames. |
| **Auto-detect RGB step** *(compute path only)* | When this is checked, the shader stops asking *you* what counts as a change and works it out from the scene. Every frame it tallies how far each pixel moved — one tally per size of change — and reads off the smallest change that only a sliver of the screen is still making. Below that is the picture's own noise: dithering, temporal anti-aliasing, the shimmer that makes a static pixel differ by a level or two. The shader forgives all of it and takes everything above as real movement. If no change size separates the two — a frame where the whole screen is genuinely moving — there is nothing to measure, so it keeps whatever the slider says rather than guessing from a scene with no floor. With this off, **RGB step counted as a change** rules as it always has, and the measurement costs nothing. Start here if you have ever found yourself nudging that slider, and only go back to setting it by hand if the measurement settles on a step you don't like: the two are alternatives, not companions. The motion view is how you watch it work, since the red it draws is graded against the step that was measured — a scene where something visibly moving shows no red has been read correctly. |
| **Noise floor (percent)** *(compute path only)* | How strict the measurement is, as a share of the screen. The rule in one sentence: **the measured step is the smallest change size `1`–`8` at which no more than this much of the screen is still changing by that much or more.** At the `0.5` default that is about 0.5% of the picture, so level `1` is chosen as soon as almost nothing is changing by a full level — which is why the measurement often settles on `1` and looks as though it is doing nothing. Lower it and the shader forgives more, because the step it settles on sits higher and more of the picture's small movement passes as still; raise it and the step sits lower, keeping the smallest movements at the cost of counting more of the noise as motion. It is a share of the screen rather than a count of levels, so it means the same thing at every resolution, and it is one frame behind: the frame being judged never sets its own threshold. Only the levels the RGB step can take are searched, so if no level separates a busy frame the slider's own value stands for that frame rather than a guess. It does nothing while **Auto-detect RGB step** is off, so it is only shown in the panel while that is ticked. |
| **Closing radius in pixels** | Grows the mask slightly to close anti-aliased edges and thin text. `0` turns it off. |
| **Luma step counted as a boundary** | Stops that growth at a real edge in the picture, so the mask snaps to the HUD's outline instead of spilling out into the scenery. |
| **Motion needed to trust stillness (percent)** | How much of the screen has to be changing before the shader believes the world is being drawn. Above it, a pixel that holds still is taken for interface and the mask builds; below it, stillness earns nothing, because what holds still in a still scene is the scenery. This is the line that decides whether the screen is being drawn at all — the premise rather than a refinement, which is why its default is not zero. Raise it if scenery is still getting caught, lower it if a HUD fails to appear. The measure is taken over the pixels that *could* change, not over every pixel: a black or clipped region is counted out of it, because a pixel that is already all-black can never show a difference and would otherwise hold the reading down in proportion to how much of the picture it covers. That said, a large part of the frame that is dark but *not* fully black still counts — the shader cannot tell a static black backdrop from a wall — so on a very dark view a high setting here can still be unreachable, and lowering it is the fix. |
| **Stop specks entering the mask** | The shader's other spatial rule, and it acts *before* the verdict rather than after it. A lone still pixel is exactly what a HUD is not — a stuck pixel, a speck of noise, one lonely sample in a gradient — so with this ticked a still pixel with no protected pixel next to it is added at **half speed**: it has to hold still for twice **Frames still before marked as interface** before it lands. An element is many pixels, so its interior pixels have neighbours from the moment a few of its pixels have been protected; only a genuinely isolated pixel is slowed, and a speck that would have been claimed alone is now claimed twice as late — long enough that whatever else is moving has usually taken it back. It is off by default, so the mask is unchanged out of the box. Turn it on if specks or scenery keep appearing in the mask; the cost is that a brand-new element in the corner of the screen with nothing near it takes twice as long to appear. It is measured on the shader's own still/moving judgement, not on colour, so a HUD's high-contrast text and edges are unaffected. |
| **Enable isolated pixel removal** | The master switch for keeping lone pixels out of the mask, the *second* spatial rule and the one that acts after the verdict. It is off by default, so nothing is filtered and there is nothing extra to tune. A single still pixel with no other still pixels around it is not something a HUD does — it is a stuck pixel, a flat patch between two dithering regions, one lonely sample in a noisy gradient — so with this ticked a masked pixel is kept only while either enough of its neighbourhood agrees with it, or one line drawn through it is still along most of its length. The first is the block of pixels around it; the second is what saves a thin stroke, since a line one pixel wide runs its whole length along one direction however little of the square around it it fills. The count is of the shader's own still/moving judgement, not of similar colours, which makes it the opposite of the closing radius: the closing only ever grows the mask, this only ever takes pixels out of it. Turning it off restores the mask exactly as it was. It and **Stop specks entering the mask** do different jobs — that one stops a speck being claimed at all, this one takes back what was claimed anyway — so they are independent and can be used together. |
| **Still neighbourhood density (percent)** | What share of a masked pixel's neighbourhood must be still — the pixel itself counted — for it to stay in the mask. It is a share rather than a count of pixels so that it means the same thing at every **Isolation radius**: at the `33` default about a third of the box must be still, which drops a lone pixel and an adjacent pair while keeping anything with real substance. `0` keeps every pixel, so turning the filter off is the same thing as unticking **Enable isolated pixel removal**; `100` demands a completely solid neighbourhood and will erode thin strokes unless a line through them saves them. Raise it to drop sparser specks, lower it if something with real substance comes back with holes. |
| **Isolation radius in pixels** | How far the neighbourhood above reaches, as a square `2 × this + 1` across. It is deliberately separate from **Closing radius**: the closing is how far the mask is grown to bridge rough edges, which is about how the mask looks, while this is how much agreement a pixel needs, which is about how much evidence a speck has to produce. Tying them together would move what the density means every time you retune the closing. `1` is the default and the smallest useful box; `0` is treated as `1`, so the setting never silently switches the filter off. It shares the closing's own work, so raising it costs nothing extra — but note that a wider box makes the density test stricter against thin strokes, since a line of a given width fills a smaller fraction of a bigger box. This is also the length the line test is measured over, so raising it asks a stroke to hold still for longer before it counts. |
| **Diagnostics: motion view** | Which reading the overlay draws when it is switched on. On, it is the motion view: red where the frame sees a change, nothing where it does not. Off, it is the verdict view: green where a pixel has earned its place in the mask — the shader's own verdict, without the closing radius — nothing where it has not. Both tint only the pixels they name and leave the rest of the picture exactly as the game drew it; the bottom-left corner marker shows in both. |
| **Diagnostics: confidence view** | The verdict view with its judgement *and* its shades taken out, leaving two flat colours that need no comparing. **Cyan** is a pixel the mask already claims. **Magenta** is a pixel that is earning its place but has not crossed the line yet — the band just under it. Anything in neither colour is left exactly as the game drew it, including a pixel still recovering from a move: that is drawn plain on purpose, so recovery never looks like evidence. It answers a question the verdict view cannot: whether a crowd of pixels is sitting just under the line, and whether that crowd is interface or scenery. **Magenta over dim scenery, with no interface there, is the reading that matters**: it is the shader part-way to protecting the world, because scenery drifting too slowly to change a pixel between two frames reads as perfectly still, and still is what the shader calls interface. That is a limit of the comparison's resolution rather than a bug, and the view is the way to see how much of it a particular game produces. It draws nothing and changes nothing. |
| **Diagnostics: tile view** *(compute path only)* | A third overlay reading, and the one that measures rather than shows. It chops the screen into a 16×16 grid of squares and colours each square by what the mask is doing in it — so it draws a coarse map rather than a per-pixel one, and a whole square is one colour rather than a blend. **Green** is a square that is mostly masked interface, **black** a square that is not, **red** a square that changed a lot this frame and is *not* masked — a panel appearing that the shader has not caught yet, which is the case the screen-wide reading cannot see — and **orange** a square that is not masked but is walled in by mask on every side: a hole inside a protected element. Five bars along the top are the region counts, in the order below. It draws nothing and changes nothing, so flicking it on and off leaves the picture and the mask identical; it exists to be watched while deciding whether the region filters it measures are worth their cost. |

There are four more switches that are not sliders — **anti-bloom** (on by default), the **diagnostics
overlay** (off), the **compute path** (off), and the **depth premise** (off). They are compile-time
switches, so turning one on or off causes a short recompile rather than taking effect instantly. The trade
is worth it: with a switch off, the work it would have done is not just skipped, it isn't in the shader at
all.

**The depth premise** lets the depth buffer help decide when the world is being drawn, which is the
question the whole mask waits on. It helps because the overlay leaves no trace in the depth buffer — a
panel drawn over the scene takes the scene's own depth — so depth sees the world and never the interface.
The ordinary reading is taken from the picture, and a large opaque menu hides most of the picture's
movement behind itself: the shader can conclude the world has stopped exactly while you have a menu open,
and stop tracking. Depth cannot be hidden that way. It only ever *adds* to that reading. It is off by
default for two reasons. Depth buffer access is not always there — online games often block it — and where
none is found the reading is the ordinary one exactly, so there is nothing to switch back. And it needs
ReShade's Depth Buffer settings to be right first: a buffer that is bound but configured wrongly feeds the
premise nonsense rather than nothing, which no amount of turning the switch off will fix. When it is on,
**Depth step counted as a change (percent)** sets how much a surface has to move toward or away from you
in one frame, as a share of its own distance to you, before depth counts as the world moving. Depth is a
distance rather than a brightness, so a share of it means the same thing in every game, and the ramp is
footed at zero so the step is the whole threshold. A share is also larger for a near surface than a far
one — the same metre is a bigger fraction of three metres than of three hundred — so the `10` default
catches near and mid geometry and a distant backdrop needs a lower step. Raise it to stop depth noise
holding the world as drawn over a stopped scene; lower it to reach scenery further off, which is safe
because the screen-wide share the premise reads keeps a low step from turning noise into a drawn world.
It does not help a menu opened over a world that has already stopped — the depth is stopped too — which
stays the documented limit in the list below. **Camera field of view (degrees)** is the other number it
reads: the shader works out which way each surface faces, and one facing straight up or down — a floor or
a ceiling — cannot change depth at all when you walk, so those pixels are left out of the depth reading
rather than counted as "not moving", which would only hold it down. A wall you are walking toward, or a
slope, still counts. **Depth only (experiment)** sits beside it, off by default: with it on the world-drawn
reading comes
from the depth buffer *alone* rather than from depth added to the picture. It exists to answer one
question — whether a scene whose only movement is animation in the picture (flowing water, fire, a
scrolling backdrop) should count as the world being drawn, which is the **still patch of world** limit
below. Off, such a scene reads as drawn and a still wall beside it is claimed; on, the scene reads as
stopped and the mask holds instead. It is not finished behaviour: with the depth buffer missing or wrong,
the world reads as never drawn and the mask never forms, and it withholds stillness over any animating
scenery, so a genuine element appearing while the camera is still may not be claimed until the view moves.
Leave it off unless you are looking at that one question.

**The compute path** changes *how* the mask is worked out, not what it means, and everything in the table
above still applies. On the pixel path the screen-wide reading the mask depends on is an approximation:
the picture is reduced to a 16×16 grid with four samples per block, so about a thousand samples stand in
for every pixel on screen, and a small panel arriving — or a region falling between the samples — can
move that reading without the sampler seeing why. With the compute path on, the accumulator itself counts
every pixel it calls changed, collapsed per block of 256 before it is added up, so the reading is exact
and the two coarse-grid passes disappear. What it buys is not a faster shader — it costs a little more
than the pixel path and allocates two more full-screen buffers — but a reading you can trust, the drift
horizon below, and a step measured from the scene rather than guessed. If you are happy with the pixel
path, there is no reason to move.

It needs a Direct3D 11 or newer device, or Vulkan. On Direct3D 9 or 10, or any device without compute
support, leave it off — the shader cannot fall back to the pixel path on its own, and the technique will
fail to build. On anything modern it is safe to switch on, and worth doing if you have ever seen the
screen-wide reading behave oddly — a mask that forms or refuses to form for no visible reason, or scenery
that creeps in slowly while nothing appears to be moving.

It carries four settings the pixel path cannot — **Drift horizon**, **Auto-detect RGB step** and its
**Noise floor**, and **Diagnostics: tile view** — all described in the table above. The drift average is the most memory-hungry part of
the shader, and deliberately so: it has to creep toward the picture by a fraction of a level a frame,
finer than half precision can resolve over the brighter half of the range, so it is the one buffer kept
in full precision instead of half. The pair comes to about 120 MB at 1440p, and what that buys is the
channel working across the whole brightness range rather than only in the dark.

The auto-detect measurement is the cheap one. It counts each frame's changes inside a small block of
shared memory first and hands only the block's totals on, so the screen costs a few dozen additions per
block rather than one per pixel, and a frame where almost nothing moved adds almost nothing — which is
exactly the frame a still scene gives it. Turned off it does none of that work at all.

The **speck rule** is an addition to the mask path, and it is nearly free: with it ticked, each pixel
already being judged also glances at the four verdicts around it, so the work is four extra texture reads
in a pass that runs anyway, and those reads are skipped entirely while the box is clear. Its cost is the
delay rather than the arithmetic — a brand-new element with nothing near it arrives at half speed — which
is why it ships off.

The **tile view** is the one addition rather than a retune, and it is not free: while the overlay is
switched on, the compute path also runs a small pass over a 16×16 grid, and that pass is a fixed 256
threads doing a few thousand shared-memory reads apiece per frame. It is nothing beside the full-screen
passes, and with the diagnostics overlay compiled out the pass, its shader and its two small buffers are
not in the shader at all — the same rule every other guarded part of this follows. It is the one instrument
here that outlived its brief: the open questions it was built to measure are all decided, and what it is
now for is watching the two rules that ship — the speck rule and the isolated-pixel filter — which are
about how much of the screen holds still *around* a pixel, and which no per-pixel view can show you. It
does not touch the mask in any way.

## Seeing what it decided

Turn the diagnostics overlay on and it draws one reading over the picture, picked by three toggles:
**Diagnostics: motion view** chooses between red where the frame sees a change and green where the shader
has decided a pixel is interface, and **Diagnostics: confidence view** replaces that green with two flat
colours that split it — one for a pixel the mask claims, one for a pixel still earning its place. They tint
*only* the pixels they name and leave every other pixel exactly as the game drew it, with no global wash.
With the compute path on, **Diagnostics: tile view** replaces them both with the region reading described
below.

- **Red** — the motion view: how much this pixel changed this frame, with nothing the frame forgave drawn
  at all. It is graded over a fixed three-level span: a change one step under the RGB-step setting is the
  first to show, one the size of the setting is a faint red at about a quarter strength, one a step larger
  is about three-quarters, and one two steps above is full red — the same span at every slider position.
  It fades as a region settles and keeps updating even while the world is stopped, so a red patch in a
  held frame is something still moving on screen. This is the view to watch while setting that slider: no
  red over something you can see moving means the setting is above it. A red pixel that the verdict view
  would call yours is an element being left behind as the world starts moving over it — the normal way a
  menu leaving looks.

  On the compute path the red is the larger of two readings, and the second one is graded over its own
  span: a slow drift — scenery moving by less than a level a frame, which the frame-to-frame reading
  rounds to nothing — shows red once the drift has carried the pixel a step or two away from its own
  average. That is the drift horizon at work, and the red it draws is the thing to watch while setting it.
  A pixel in constant motion that reddens only *periodically* is the same scale seen from the other side,
  and it is the frame-to-frame reading rather than anything overflowing: movement under a level a frame
  sits perfectly still on most frames and steps once on the rest, so the shading blinks at the rate the
  picture crosses levels. Raising the drift horizon is what fills those gaps in, which is what it is for.

  With **Auto-detect RGB step** on, that setting is not allowed to change the moment a frame suggests it
  should: it has to be asked for the same thing for a while first. The measurement follows how much of the
  picture is moving, and the red is graded against it, so a setting that chased the measurement would
  forgive the very movement that raised it — the red would switch off over something you can see moving,
  everywhere at once. A whole scene change still reaches it; what it filters out is one scene's own
  movement drifting in and out of the measurement. Nothing except the motion view is graded against it,
  so the mask behaves as before.
- **Green** — the verdict view: the shader's judgement right now, that this pixel has earned its place in
  the mask. It is on or off, never a shade, because it is a decision — and it is the verdict *without*
  the closing radius, so an element shows exactly its own area and nothing grown around it. This is the
  view for asking what the shader thinks it is protecting: a menu should light up while open and go dark
  as the world takes it back. A stopped world adds nothing, so in a held frame (marker yellow) the green
  is the last state decided, and may only shrink, never grow.
- **Cyan** — the mask already claims this pixel.
- **Magenta** — this pixel is earning its place but has not crossed the line yet: the band just under it.
  Magenta over dim scenery, with no interface in it, is the shader part-way to protecting the world, and
  the reason is the comparison's resolution rather than any setting: a pixel is judged by how far its
  colour moved since the last frame, in whole levels, so scenery drifting slowly enough to move less than
  half a level a frame reads as *exactly* no change — and a pixel that never changed is what the shader
  calls interface. Dim, smoothly shaded regions are where that shows, because the same movement changes a
  level far less there than it does on bright detail. Watch the band while it is there: one that travels
  along with the scenery is that limit, while one sitting still on an element is the element settling.
  Anything in neither colour, including a pixel still recovering from a move, is passed through untouched.

### The tile view, square by square

The motion and verdict views answer a per-pixel question — did *this* dot change, is *this* dot protected.
The tile view answers a per-region one, and it is the only reading that does: it draws the screen as a
16×16 grid and colours each square by what is happening inside it. Every pixel of a square gets that
square's colour, so you are looking at a mosaic, not at the picture.

| Colour | What that square is |
| --- | --- |
| **Green** | Mostly masked interface — the shader is protecting it. |
| **Black** | Not masked, and not changing much: ordinary world, working as intended. |
| **Red** | Changing strongly and **not** masked, while the world has gone quiet. This is a panel appearing over a stopped scene that the shader has not noticed yet — the one case the screen-wide reading cannot see, and the reason the instrument exists. |
| **Orange** | Not masked, but sealed off from the screen edge by mask on every side — a hole left inside an element. The mask caught the outline and missed the middle. |

A square is green as soon as **the mask touches any of it** — it is a footprint reading, so a square a
thin bar merely crosses still counts as interface. Red needs **most** of the square to be changing strongly
*and* the corner marker to be yellow: a panel appearing is only an arrival when the world is not otherwise
being drawn, so while you are panning or the scenery is busy no square is red, however much it moves. The
boundaries you see are the reading's resolution, not a hard edge in the mask.

The five bars along the top are the numbers that map produced, filled left to right, one bar each:

1. **White — how many separate pieces the mask is in.** One bar nearly full means the mask is one solid
   region, as it should be. A bar filling up means it has broken into specks, which is the isolation
   filter's problem to clean up. The bar is filled to sixteen pieces; past that it stays full.
2. **Green — how big the largest piece is**, as a share of the whole mask. Full means one region holds
   everything; a short bar means the mask is a scattering of small ones.
3. **Orange — how much of the screen is sealed off by mask.** This is the size of the orange squares:
   the interior holes. It is normally tiny — a handful of squares, or none. A bar that climbs while a
   menu is open is the case a fill filter would fix; a bar that jumps to most of the screen during a
   camera move means the reading has gone wrong, because movement cannot seal anything off from the
   screen edge.
4. **Red — how many separate patches changed a lot at once while the world was quiet.** This is the
   arrival signature: a panel opening over a stopped scene makes one or two big patches. Ordinary scenery
   motion, however much of it there is, makes none — the bar stays empty through a camera move by design.
5. **Magenta — how much of the screen those patches cover.** Together with the bar above it, this says
   whether what just appeared is a panel-sized region or a scatter of noise.

None of it does anything. Nothing here is read by the mask, nothing changes the picture, and the whole
reading is only compiled in when the overlay is on.

The small block in the bottom-left corner is always drawn, and its colour tells you what the whole screen
is doing — which decides whether what you are looking at is a current judgement or a held one:

- **Magenta** — the world is being drawn. The reading on screen is live: the verdict view's greens are
  being earned, the motion view's reds are clearing.
- **Yellow** — the world has stopped being drawn. The mask is now held: anything still keeps exactly the
  state it was in, and anything the frame shows moving is still falling out. So in a yellow frame the
  green view is the last state decided and will not change on a still pixel, while red and the falling of
  a moving pixel stay live.

The block is drawn flat, with no blending, by the very last thing in the chain, so nothing can paint over
it — it keeps its colour whatever the game or your other effects do underneath, including behind your own
interface. It is a colour to read, like a traffic light, not part of the picture; it is there only while
both techniques are enabled, since the second one draws it. It reflects the state about to be used, one
frame ahead of the decision the mask has just made, so do not be surprised if it changes a frame before
the mask visibly does.

Compare it against the game underneath. That is the only way to tell a genuine mistake from something the
shader can never get right, so it is worth turning on the first time you use this.

## Anti-bloom

If you run a bloom or glare effect it will find the bright edges of your HUD and smear them out over the
scene behind. Anti-bloom stops that: while it is on, the interface pixels are blacked out in the frame
your other effects see, so there is nothing bright there for bloom to pick up. The real interface is put
back by `AutoMask_Restore` at the end, so you never see the black.

The final picture is therefore unchanged by this switch; it only changes what the effects in between are
allowed to see. It blacks the interface at the closing radius's contour, since a partly-blackened pixel
is a partly-lost bloom source, and the black step against a bright scene is what bloom keys on either
way.

## What it can't do

These aren't settings you haven't found yet — they're limits of the idea, and knowing about them saves
time:

- **Semi-transparent interface is never protected.** If the world shows through an element — a faded
  health bar, a translucent map overlay — those pixels are constantly changing, so they never look still
  and never get protected. This is the one case where a hand-painted mask genuinely does better.
- **Standing still somewhere with nothing moving.** Face a wall or a closed door in a quiet room and
  nothing in view is animating, so a wall that never moves is never distinguished from a HUD by the
  comparison alone. This is what the motion setting above is for, and why it is the premise rather than a
  refinement: while the world is not being drawn the shader does not take stillness for interface at all,
  so a stopped scene cannot fill the mask in — it can only hold what it already had, or lose it.

  Remembering movement cannot help here: the shader only knows what the last two frames looked like. A
  wall you walked past was moving in the picture, so it is remembered and cannot be grabbed when you stop;
  a wall you have been standing in front of the whole time never moved, so there is nothing to remember —
  and on the evidence available it is genuinely indistinguishable from a HUD.
- **A still patch of world in a scene that is otherwise animating.** The reading above is one number for
  the whole screen: it answers "is anything being drawn", not "which part". So if enough of the view is
  repainting itself — a waterfall, a river, fire, trees in wind — the shader decides the world is being
  drawn and starts taking stillness as interface wherever it finds it. A wall, a closed door, or the
  backdrop behind a menu in that same frame is still, and is claimed exactly as a HUD would be. This is
  the commoner shape of the quiet-room limit above: there nothing at all animates, here something does,
  but it is nowhere near the patch that gets taken — which is the point, because a patch of stillness is
  what a HUD is. The two cannot be told apart from the picture, since a still wall and a still HUD look
  identical. Raising **Motion needed to trust stillness** demands more of the screen animate before
  stillness counts, which helps only while the animating part is small: a river across a third of the
  view cannot be raised past without switching the premise off for ordinary play.
- **A frame that is fully black or fully white never counts as still.** A colour pressed against the top
  or bottom of its range may be saturated rather than motionless, so a letterbox bar, a hard fade or a
  clipped sky earns nothing while it holds, and a screenful of it converges toward no mask rather than
  filling one — the right side to be wrong on. Moves onto and off full black or white are ordinary
  changes, judged as usual.
- **Scenery that drifts too slowly to change a pixel between two frames.** The shader judges a pixel by how
  far its colour moved since the last frame, in whole levels out of 255, so movement slower than about
  half a level a frame reads as *exactly* no change — and a pixel that never changed is the shader's
  definition of interface. Dim, smoothly shaded regions are where this bites, because the same movement
  across the screen changes a level far less there than on bright detail: the scenery slides along unseen,
  each pixel holding still long enough to be claimed, and the mask covers it. Neither the motion setting
  nor the move memory addresses it by name — the world genuinely is being drawn, and the drift never stops,
  so there is no quiet scene and no single move to remember. What helps is **Frames a move is remembered**:
  every time the drift does cross a level the pixels are knocked back, and a long memory stops them coming
  back before the next crossing. The **Drift horizon** is the reading built for movement this slow, since
  it compares against a long baseline; be aware that lengthening it can go the other way, because the same
  reading also feeds the screen-wide "is the world being drawn" measure, and holding that up is what lets
  the drifting scenery earn. The overlay is where to see which way it goes in a given game.
- **A panel that opens over a scene that has already stopped.** The cost of the same premise: a menu that
  pops open over a paused world is caught only because its opening is itself movement, which has to lift
  the screen-wide reading over the motion threshold. A large panel fades in, so it usually registers; a
  small one, or a slow one, may not, and then the shader has no evidence to work with. Lower the motion
  threshold for that, and accept that scenery will be caught more readily while the view is quiet.
- **Something that moves while the world is stopped falls out of the mask.** A spinner, a flashing icon,
  a video-style background loop — with the world stopped, those pixels keep changing, so they are treated
  as moving and drop out even though they are not really interface. This is the deliberate trade that
  keeps a stopped scene from filling in — the shader would rather lose a genuinely animating element in a
  paused scene than protect something it cannot identify — and it is why the mask can shrink but never
  grow while the world is stopped.
- **Interface that animates for longer than the grace period loses its protection.** The other side of
  the same trade as the wall. The grace runs as a balance, so an element keeps its mask while its
  animation outweighs its pauses and loses it once the changing frames predominate — correct by the
  shader's own reasoning, since something mostly in motion is not something the game paints in place. If
  you have an element like that, raise the grace period until its animation outweighs its pauses.
- **A brand-new element with nothing near it takes twice as long, with this rule on.** **Stop specks
  entering the mask** adds a still pixel at half speed when nothing protected is beside it, which is what
  stops a lone speck being claimed at all. An element is many pixels, so this only bites on the first one
  or two to hold still: once a couple of its pixels have landed, the rest have a neighbour and arrive
  normally. The visible cost is a small, isolated element appearing about twice as late on the first
  frame it opens; leave the rule off if that matters more than the specks.
- **A player character tethered to the camera in third-person games.** When running forward in a
  third-person game, the camera moves with your character, so the background streams past while your
  character's back or torso stays locked at the same screen position — identical to a HUD element as far
  as the comparison can tell, and there is no region you can carve out to exclude it.
- **A HUD that flickers without moving, on the compute path.** Dithering and temporal anti-aliasing make
  a pixel that is standing still differ by a level or two from frame to frame — usually forgiven by the
  RGB step above, but the drift horizon reads it too, because a pixel that keeps wandering does end up
  away from its own average. The direction it fails in is the mild one: the element is left out of the
  mask rather than the scenery being taken in. This is the price of the horizon doing its job, and no
  setting escapes it: a shorter horizon trades away the *slowest* drift it was catching, and a higher RGB
  step forgives the flicker but raises the reading the horizon compares against by the same amount, so it
  gives up that same slow end. Faced with both a flickering element and a drifting backdrop you are
  choosing which one to keep, and the overlay's motion view is where to see how much drift each position
  still catches before deciding.
- **The measured RGB step has nothing to measure in a fully live frame, on the compute path.**
  Auto-detect works by finding where the picture's noise stops, and that only exists while most of the
  screen is holding still. Pan across a detailed scene, or stand in a crowd of moving things, and every
  change size is being made by something somewhere across the screen — there is no quiet majority for the
  floor to be read off. The shader keeps the slider's own value for those frames rather than guessing a
  step from a scene that has no floor, so a fast camera movement cannot talk it into forgiving real
  motion. The measurement is therefore a reading of calm scenes, which is exactly where the slider is
  hardest to set by hand. If it settles on a step you don't like in a particular game, turn it off and
  use the slider — the two are alternatives, and the slider is untouched while auto-detect is on.
- **Very thin interface can be dropped by the isolated-pixel filter.** That filter is off by default,
  and it is the one setting that deliberately removes pixels that earned their mask: it keeps an element
  only while enough of its neighbourhood is still too, or one line through it is still along most of its
  length. The line test is what keeps a stroke one pixel wide, in any of the four directions it measures
  — across, down, or either diagonal — since such a stroke fills almost none of the square around it but
  all of one such line. A stroke at some other angle, or a curve, is only partly covered by it, and is
  still dropped where the square test would drop it. At the `33` default a lone pixel and a two-pixel
  cluster go — which is the whole point, since neither is a HUD — while anything with a bit more
  substance stays. Raising the density drops sparser specks and eventually costs you thin elements; a
  wider **Isolation radius** is the sharper risk, because a line of fixed width fills a smaller share of a
  bigger box, so a stroke that survives at radius `1` can be gone by radius `3` at the same density. If
  one-pixel text or a hairline map border comes back with holes, lower the density or the radius, and if
  it keeps happening, leave the filter off.

  **The closing radius decides how much there is to save.** The filter judges the mask *after* the
  closing, and the closing thickens a hairline along its own length — the luma boundary stops it growing
  across a contour, not along one. So with **Closing radius** at its default `1` a one-pixel line is
  already wide enough for the square test to keep it on its own, and this filter only comes into play at
  **Closing radius** `0`. That is where to look if you want to see what it does: set the closing to `0`,
  which is its pass-through position, and a one-pixel hairline over moving scenery goes from being dropped
  to being kept. A filter that only bites at one position of another slider is worth knowing about rather
  than discovering.
- **A wrong mask is worse than a wrong verdict.** Where a mask image toggles effects at the wrong moment,
  this one is continuously visible if it's wrong. If in doubt, tune toward a longer grace period and a
  tighter closing radius rather than an eager mask.
- **It is expensive.** The mask costs several full-screen passes every frame, and it allocates several
  full-resolution buffers while it's loaded. This is the price of not needing a mask image, and it is the
  most expensive thing in the pack next to `UIDetectMulti` itself. If your frame rate is tight, this is
  not the shader to add.

## Credit

The idea of building a UI mask from what holds still, the store-the-pixels-first /
restore-them-last arrangement, and the anti-bloom trick all come from Kaiser's `UIDetectMulti`, which
builds on work by Brussels1. This shader shares no code with that project — see `LICENSE`.

Licensed MIT.
