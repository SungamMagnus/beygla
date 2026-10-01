# Beygla

A macOS datamosh editor whose effects are driven by **audio-in** and **MIDI-in**
triggers, so the glitches land on the beat instead of wherever you happened to
drag them.

Inspired by [supermosh](https://github.com/supermosh/supermosh.github.io) and
[Datamosher Pro](https://github.com/Akascape/Datamosher-Pro).

---

## What it does

Load a clip. Beygla finds the transients in its audio — or listens to a live
input, or to a MIDI controller — and turns each hit into a **trigger**. Each
trigger fires an **effect rule**, and each rule rewrites a span of compressed
video frames. Then it renders.

### The fifteen effects

Grouped by what they do to the frame array, which is also how they are coloured.

**Strips** — destroy reference frames

| Effect | What happens to the bitstream |
|---|---|
| **Bloom** | Deletes the keyframes in range, so incoming motion vectors land on whatever pixels were already on screen. The classic transition smear. |
| **Void** | Kills every frame carrying more data than a threshold: keyframes first, then the heavy refresh frames a codec spends when too much changes at once. |

**Holds** — repeat what is already there

| Effect | What happens to the bitstream |
|---|---|
| **Glide** | Holds one delta frame and re-applies it for the whole range — the picture keeps sliding in one direction. |
| **Echo** | Loops the first few delta frames, so the image churns in a cycle rather than drifting. |
| **Stutter** | Keeps one frame in every few and skips the rest: a hard judder that holds still between updates. |
| **Freeze** | A true still. No motion applied at all. |
| **Overlap** | Takes a run, steps back less than its length, takes another — each run replays part of the one before it. |

**Reorders** — change which frames are used, and in what order

| Effect | What happens to the bitstream |
|---|---|
| **Reverse** | Plays the range's motion backwards. |
| **Invert** | Swaps each frame with its neighbour, so motion advances then corrects, one frame out of step. |
| **Weave** | Interleaves the range with itself reversed — two contradictory directions on alternate frames. |
| **Jiggle** | Displaces each frame in time by a gaussian amount. Motion stumbles rather than tears. |
| **Sort** | Reorders by frame size, which tracks how much changed — so it plays the range from quiet to violent, or the reverse. |
| **Rise** | Skips forward through the range, then holds on the last frame reached. |
| **Shuffle** | Permutes the delta frames individually. |
| **Blocks** | Shuffles in blocks, so motion stays coherent inside each and only the joins are wrong. |

The frame-level modes above come from
[Datamosher Pro](https://github.com/Akascape/Datamosher-Pro) and the Tomato
automosher it builds on. Its other half rewrites the motion vectors *inside*
frames rather than reordering whole ones — a genuinely different mechanism,
covered next.

### Vector effects — rewriting motion, not frames

Eleven more effects, ported from the FFglitch scripts under
`DatamoshLib/FFG_effects/jscripts/` in Datamosher Pro. Where the effects above
treat a compressed frame as an opaque blob and only ever move, hold or delete
whole ones, these decode a frame just far enough to expose its motion vectors
as a plain array, run a transform over that array, and re-encode with the
edited vectors instead of the real ones. It is a genuine decode/edit/re-encode
pass, not byte surgery, so it needs its own tool —
[FFglitch](https://ffglitch.org)'s `ffgac` and `ffedit` — and its own optional
download (`./tools/build-ffglitch.sh`); Beygla runs exactly as before without
it, just with these eleven effects unavailable.

| Effect | What happens to the motion field |
|---|---|
| **Sink** | Freezes anything moving faster than a threshold; slow motion is untouched. |
| **Stop** | Freezes every block's motion, unconditionally. |
| **Invert** | Negates every vector — right becomes left, up becomes down. |
| **Mirror** | Reflects the motion field left to right. |
| **Vibrate** | Adds an independent random jitter to every block, every frame. |
| **Zoom** | Adds an outward (or, at low amount, inward) radial push from centre. |
| **Slam Zoom** | Replaces motion with a pure radial field instead of adding to it. |
| **Shear** | Adds a diagonal offset that grows with distance from centre. |
| **Delay** | Replaces each block's vector with one from several frames ago; Amount past halfway blends a feedback trail instead of a hard swap. |
| **Shift** | Feeds vertical motion into the next frame with a constant added each time, like gravity accelerating a fall. |
| **Noise** | Multiplies the *slowest*-moving blocks instead of the fastest — the inverse of what a glitch usually does. |

Each DMP script carried its own random-threshold self-triggering — "do this
for N frames if a coin flip exceeds 95" — because the tool it was written for
had no other way to place an effect in time. Beygla already has one: the same
trigger, rule, timeline-lane and region system that drives the bitstream
effects drives these too, so that scaffolding is dropped and only the vector
transform itself is kept. `Buffer.js`'s feedback behaviour survives as
Delay's `Amount` knob crossing 0.5 rather than as a thirteenth separate effect,
since the two DMP scripts differ by one line.

A vector value the frame's own encoder precision cannot represent does not
fail cleanly on import — it decodes as a handful of visibly corrupted
macroblocks scattered through an otherwise correct picture. Every effect's
output is clamped against `mv.fcode`, the exact range that frame's MPEG-4
encoding allows, which is exposed directly in FFglitch's own JSON export.

Combining a vector rule and a bitstream rule in one render costs exactly one
extra encode generation — the one `ffgac` needs to force a vector onto every
macroblock — not two independent renders' worth: the vector pass runs first,
its output is remuxed into an AVI losslessly, and the bitstream engine's own
byte surgery runs on that exactly the way it runs on any other moshable AVI.

### Where each effect is live

Each effect gets its own lane on the timeline. A lane with nothing painted on
it is live for the whole clip, which means every effect fires on every trigger.
Drag across a lane to paint a span and that effect only fires on triggers
inside it, so a set of effects takes turns over a clip. Double-click a span to
remove it.

---

## How it works

Datamoshing means feeding a video decoder frames it was never meant to see.
The only practical way to do that is MPEG-4 Part 2 in an AVI container, because
AVI stores each compressed frame as a plainly delimited chunk you can reorder
with a hex editor.

The pipeline is three stages:

```
source.mp4 ──ffmpeg──▶ raw.avi ──Swift byte surgery──▶ moshed.avi ──ffmpeg──▶ out.mp4
             encode                   MoshEngine                    decode + remux audio
```

**1. Encode.** `-c:v mpeg4 -bf 0 -g 999999 -sc_threshold 1000000000`. No
B-frames (they reference in both directions and turn any mosh into mush), and
no automatic keyframes, so the only keyframes in the stream are the ones
Beygla asked for — one per trigger, placed so `bloom` has something to strip.

**2. Mosh.** Pure Swift, no library. The AVI is parsed as a RIFF tree, each
`00dc` chunk in the `movi` list is classified by picking the
`vop_coding_type` bits out of its MPEG-4 VOP header, and the effect rules
rewrite that array of frames. Then `idx1` is rebuilt and the frame counts in
`avih` / `strh` are patched to match.

**3. Decode.** Back to H.264, with the original audio track muxed in untouched.

### Why it stays in sync

This is the part that makes Beygla different from the tools that inspired it,
and it drove most of the design.

Every effect is **length-preserving**. An op only ever overwrites the frame
slots it covers — it never inserts or deletes. The usual approach of
*duplicating* P-frames to stretch a smear makes the video longer than its
audio, which is fine for a one-off render and useless when the whole point is
that the hits land on the kick.

Holding a frame is the interesting case. The obvious move — writing a
zero-length AVI chunk — does not work: the decoder emits no picture for it and
the output comes up short. On an 8-second test clip, holding 30 frames turned
240 frames into 210.

What Beygla writes instead is a synthesised **`vop_coded = 0` P-VOP**: a
six-byte, fully legal MPEG-4 frame that means "this picture is exactly the
previous one". Building it requires reading `vop_time_increment_resolution` out
of the stream's VOL header, which is not byte-aligned, so `MPEG4Skip.swift`
walks it bit by bit.

That frame still produces no decoder output — but it leaves a correctly sized
**hole in the presentation timeline**, and the decode pass refills the hole by
repeating the last picture. Frame count restored exactly, sync intact, and the
intermediate AVI stays playable in other tools.

The refill is done by ffmpeg's `fps` filter, which places each frame at
`round(pts × rate)`. It used to be left to `-fps_mode cfr` alone, and that
turned out to be a frame off: cfr's duplication logic biases by −0.6 of a frame
when it meets a gap, so after every hold it put the next frame one slot early
and then repeated it to catch up. An 18-frame freeze on a kick at frame 30
released at frame 47 instead of 48. The frame count was always right, so every
check that counted frames passed; it took comparing renders frame by frame to
see it. Now the held span is exactly frames 30–47 and the release lands on 48.

Verified across all twenty-six effects at 30 fps (240 frames in → 240 out) and
at 23.976 fps (143 → 143, `24000/1001` preserved).

### Onset detection

Spectral flux over a selectable band — low (kick), mid (snare), high (hats), or
full range.

Peaks are ranked by **prominence**, how far a local maximum stands above the
running median around it, and sensitivity selects what fraction of that ranking
to keep. Thresholding the flux directly is the obvious approach and it gives a
knob that does nothing across most of its travel: on sparse percussive material
the local median sits near zero, so a multiple of it is near zero too and every
candidate clears it at once. Measured on a test signal with three amplitude
tiers, the old curve moved between 31 and 32 onsets across the middle 60% of
the knob; ranking spans 7 (the kicks alone) to 36 (every transient present).

The cut is widened so it never falls between hits of near-equal strength. A
steady four-to-the-floor has eight nearly identical kicks, and a strict
fraction would keep four and drop the rest arbitrarily — defensible as ranking,
wrong as music. Those eight now hold at seven across the whole knob.

Detected times are reported at the **centre** of the analysis window rather than
its start. Without that correction every onset reads about 12 ms early, which is
audible when a smear is supposed to hit with a kick. On a 120 BPM test pattern
the corrected detector lands within 3 ms.

The live detector can't look ahead to compute a median, so it tracks an
asymmetrically smoothed running average instead — quick to rise, slow to fall,
so the tail of a hit doesn't re-arm it.

---

## Building

Requires macOS 14+ and the Xcode command line tools.

```bash
./tools/build-ffmpeg.sh    # once — builds the ffmpeg that ships inside the app
./tools/build-ffglitch.sh  # once — builds the vector-effect engine (optional)
./build.sh --universal
```

That produces `build/Beygla.app` and `build/beyglactl`. `build.sh` bundles
`vendor/ffmpeg` and `vendor/ffglitch` into the app when they are there, so the
result needs nothing installed. Skip a step and the app falls back to whatever
is on `PATH` or in the usual Homebrew locations for the first, or simply runs
without the eleven vector effects for the second — `brew install ffmpeg` if
you would rather do it that way for the main engine (there is no Homebrew
formula for FFglitch; building is the only option there).

### Why ffmpeg is built rather than copied

Copying Homebrew's binary does not work, for three separate reasons. It is
dynamically linked against dylibs inside its own Cellar, so on its own it will
not run anywhere else. It is built for one architecture, and Beygla ships
universal. And it links libx264, which makes it a GPL build — redistributing
that inside an app drags GPL obligations along with it.

`tools/build-ffmpeg.sh` builds from source with `--disable-gpl` and gets H.264
out of **VideoToolbox**, Apple's own encoder, already in the OS. The result is
LGPL, which for a separate executable invoked as a subprocess means shipping
the licence and an offer of source and nothing more. Everything Beygla never
asks for is switched off, which is what keeps it small.

Beygla adapts to whichever binary it finds: with libx264 it encodes the
deliverable at a CRF, and without it uses `h264_videotoolbox` on an inverted
quality scale. The Stream panel names the one in use.

### Building the vector engine

`tools/build-ffglitch.sh` clones
[ramiropolla/ffglitch-core](https://github.com/ramiropolla/ffglitch-core) and
builds it the same way — `--disable-gpl`, static, universal, everything
unused switched off — producing `ffgac` (its own ffmpeg, built with the
`+forcemv` flag that puts a motion vector on every macroblock) and `ffedit`
(exports/imports those vectors as JSON, running a QuickJS script over them in
between). QuickJS turns out to be vendored inside `libavutil` in that source
tree, so this is one build, not the second dependency it looks like from
outside.

```bash
./tools/build-ffglitch.sh
```

---

## Using it

### Offline — sync to a track

1. Drop a video in. To cut to something other than its own audio, load an
   audio file in the **Source** panel: it drives the detection, plays back
   against the picture, and is the track muxed into the render.
2. Pick a band and set sensitivity. Ticks appear on the timeline as you drag.
3. Add effect rules. The coloured bars under the waveform show exactly which
   frames each rule will rewrite.
4. **Preview** renders at 640px for a fast look; **Render** does it full size.
   Either one loads its result into the player when it finishes, drops the
   playhead just before the first trigger and plays. It does not land on frame
   zero: the first frame of a clip is its protected keyframe, so it is the same
   picture in the source and the result, and stopping there shows you nothing.
   The **Source / Result** switch names the file it is holding and keeps the
   playhead when you flip it, so the same moment can be compared both ways.

**Cancel** kills the running ffmpeg outright. Checking a flag between pipeline
stages is not cancelling — the encode of a long clip is one invocation that
blocks for as long as it takes. On a 90-second 1080p clip whose full render
takes 32 seconds, cancelling returns in under two, leaves no stray process and
removes the partial file.

### Sync to a tempo

Set the trigger source to **Sync** and effects fire on a fixed grid instead of
on detected transients. Set the tempo with the knob (which snaps to whole BPM),
the field (which takes decimals), ±1, or **Tap** along — the last eight taps
are averaged, and a pause of two seconds starts a new count. Pick the note
length from a bar down to sixteenths, with quarter and eighth triplets.

Put **beat 1** where the track's downbeat falls with *Set at playhead*. Hits
before beat 1 are still generated, counting backward, so a track with a pickup
is covered. With *Accent the downbeat* on, beat 1 of each bar fires at full
strength and the rest at about half, so an effect's Velocity knob makes the
downbeat hit hardest.

Positions are computed as `offset + n × interval` from an integer n rather than
by adding the interval repeatedly, so a long clip does not accumulate
floating-point drift and land its last hits late.

Switching the source to Sync does not move existing effects: each keeps
listening to the source it was set to, so grid-driven and audio-driven effects
can run in the same render. The source panel says when effects are listening
elsewhere and offers to move them all in one step.

### In and out

**I** and **O** (or the *In* and *Out* buttons) set the range at the playhead;
*Clear* goes back to the whole clip. Outside the range the timeline washes
back, and both Preview and Render cover only the range — encoding starts at the
in point, so a 4-second range on a long file costs 4 seconds of work. Setting In
after Out clears Out, the way an edit suite does, rather than leaving an
inverted range.

A trimmed result starts at zero but represents a slice that starts at the in
point, so the timeline works in one frame of reference throughout: while the
Result is playing, its playhead, scrubbing, the timecode and live capture are
all offset by where that render began. Source and Result line up when you flip
between them.

Triggers before the in point are dropped, and one whose effect straddles it is
clipped to the part inside — previously a pre-trim trigger would have had its
start clamped to frame 0 with its full length kept, piling every one of them
onto the first frame. Trimming also exposed that the video's own audio was
never seeked to the in point (only an override track was); it is now, verified
by rendering 2.5–6.5 s and finding the source's kicks at 3, 4, 5 and 6 s land at
0.50, 1.50, 2.50 and 3.50 s in the output.

### Mix

**Mix** beside Preview and Render is the global amount: how much of the
moshed picture shows over the clean source, from 100% (the mosh alone) to 0%
(the clean clip). Double-click its readout to return to 100%.

It is a wet/dry blend of finished pictures rather than a scale on each
effect's own Amount, and that is deliberate. A global multiplier on Amount
would be inconsistent at best: six of the fifteen bitstream effects ignore
Amount entirely, Sort uses it as a direction switch, and Zoom and Shear are
bipolar around the middle of the knob — scaling them toward zero would turn a
zoom-out into a zoom-in. The blend acts the same way on every effect in both
families. Measured on a frame mid-clip, the difference from the clean source
scales linearly: 1.00, 0.75, 0.50, 0.25 and 0.00 of full at 100, 75, 50, 25 and
0%.

Held frames survive it. Inside a freeze, each 50% frame matches the average of
the 100% render and the clean source to within about 1.5 grey levels, while
differing from clean alone by about 30 — the mosh layer is held through the
gaps, not replaced by the clean picture.

### Smear

**Smear** beside Mix sets how long an effect's damage lingers after the effect
ends before the picture heals. A datamosh smear has no natural end: once an
effect has corrupted the picture, every following delta frame keeps building
on the corrupted pixels until a keyframe repaints them. Beygla puts keyframes
only where it is told to, so until now a smear lasted until the content
happened to repaint itself — a scene cut, a large movement — rather than for
any time you chose. That also meant Bloom's Length knob did nothing: Bloom at
0.1 s and at 1.0 s rendered byte-identical output.

With Smear set, a clean keyframe is forced into the encode that long after
every effect ends. The engine never strips a keyframe outside an effect's own
range, so it survives and resets the picture; if a later effect covers it,
that effect's smear carries on instead, as it should. At 0 the picture heals
the moment an effect ends, and Bloom's Length becomes the smear length. The
top of the fader is ∞, the old behaviour, and the default. On the timeline,
each effect bar gets a faint tail showing how long its smear lasts.

Verified: Bloom at 1, 3 and 5 s, 0.3 s long, Smear 0.5 s — the picture heals
on frames 54, 114 and 174 exactly and is untouched before them. At Smear 0, a
0.1 s Bloom heals at frame 93 and a 1.0 s Bloom at frame 120.

Building this found that the vector pass had been throwing keyframes away. Its
re-encode in `ffgac` was never told to skip scene-change detection, so it put a
keyframe at every scene cut and dropped the ones forced at trigger times —
Bloom behaved differently depending on whether a vector effect was in the
same render. Both the trigger and heal keyframes are now forced in `ffgac` too.

*Strip every keyframe* strips the heal points as well, so Smear has no effect
while it is on; the Stream panel says so.

### Zooming the timeline

A long file needs more than the whole-clip view to edit precisely. The **Zoom**
slider above the timeline narrows the visible window; **Reset** snaps back to
the whole clip. Zoom is felt exponentially — the turn from 1× to 2× and the
turn from 100× to 200× cover the same amount of slider travel — since a linear
mapping would spend most of the slider's length on zoom levels nobody uses.

On a trackpad, **pinch to zoom** — the window narrows around wherever your
fingers are, so the moment you are looking at stays under them rather than the
view recentring on the whole clip — and **swipe with two fingers to pan**
once zoomed in. Every gesture that already worked — click to scrub, drag to
paint a span, double-click to place a trigger or clear a span — keeps working
exactly as before; zoom only changes which slice of time those pixels map to.

### Live — perform the mosh

1. Set the trigger source to **Audio in** or **MIDI in**.
2. Hit **Arm live capture**.
3. Play the clip and perform — tap pads, or let the detector listen to whatever
   is coming into your interface. Each hit is timestamped against the playhead
   and written to the timeline.
4. Disarm, tidy up, render.

### By hand

Double-click anywhere on the timeline to place a trigger at that point. A
hand-placed trigger is an explicit instruction, so it fires **every** enabled
effect regardless of what those effects are otherwise listening to — filtering
it by source would mean a trigger you placed yourself drew a tick and then did
nothing.

The MIDI panel lists every connected source and listens to all of them by
default; pick one to bind the mosh to a single controller. The list is live —
a device plugged in mid-session appears on its own, and unplugging a selected
device falls back to listening to everything rather than silently hearing
nothing.

Rules can be bound to a specific MIDI note, so one pad blooms and another
stutters. Hit a pad, then press **Learn** on the rule.

### Command line

The CLI shares every line of the actual moshing with the app, so anything odd
in a render can be reproduced here:

```bash
beyglactl info clip.mp4                    # geometry, keyframe layout, picture types
beyglactl onsets clip.mp4 --band low       # what the detector hears
beyglactl render clip.mp4 out.mp4 \
    --band low --effect bloom --dur 0.4    # render
beyglactl render clip.mp4 out.mp4 \
    --audio track.wav --effect glide       # cut the clip to a separate track
beyglactl render clip.mp4 out.mp4 \
    --at 1.5,3.0,4.5 --effect stutter      # place triggers by hand
beyglactl render clip.mp4 out.mp4 \
    --effect jiggle --live 2.0-4.0         # only fire inside a span
beyglactl render clip.mp4 out.mp4 \
    --vector-effect sink --vector-dur 0.3  # a vector effect
beyglactl render clip.mp4 out.mp4 \
    --bpm 128 --note eighth --effect stutter   # trigger on a tempo grid
beyglactl render clip.mp4 out.mp4 \
    --in 12.0 --out 20.0 --mix 0.6         # a range, at 60% mix
beyglactl render clip.mp4 out.mp4 \
    --effect bloom --dur 0.4 --smear 0.2   # heal 0.2s after each bloom ends
beyglactl list-vector-effects              # print all eleven, with their DMP source
beyglactl render clip.mp4 out.mp4 \
    --cancel-after 2                       # debug: prove cancelling kills ffmpeg
```

---

## Layout

```
Sources/MoshCore/          # no UI, no AppKit — all of it testable from beyglactl
  RIFF.swift               #   RIFF/AVI tree parse + serialise
  MPEG4.swift              #   VOP type classification
  MPEG4Skip.swift          #   VOL bit-parsing, skip-VOP synthesis
  AVIDocument.swift        #   the AVI as an array of frames
  MoshEngine.swift         #   the fifteen bitstream effects
  VectorOps.swift          #   the eleven vector effects: kinds, ops, rules
  VectorEngine.swift       #   generates the QuickJS driver ffedit runs
  FFglitchTool.swift       #   wraps ffgac / ffedit
  OnsetDetector.swift      #   spectral flux, offline + live
  Triggers.swift           #   events, rules, and compiling one into ops
  FFmpegTool.swift         #   encode / decode / probe / PCM extraction / remux
  RenderPipeline.swift     #   the stages, with progress and cancellation
Sources/Beygla/            # SwiftUI app
  SungamKit.swift          #   the design system, ported to SwiftUI
  TrackpadGestureCapture.swift  # pinch/two-finger-pan, wrapped around the timeline
Sources/beyglactl/           # command line front end
```

---

## Design

The app icon is a frame of genuinely datamoshed video — a letterform run
through Beygla's own engine, with a frame pulled from a few past the bloom.
`icon/README.md` has the method; `./icon/make.sh` rebuilds it.

Beygla is built on the
[Sungam design system](https://github.com/SungamMagnus/sungam-design-system),
which means the app is a panel, not a form. `SungamKit.swift` ports the
system's primitives to SwiftUI: `PanelFrame`, `Knob`, `Latch`, `Selector`,
`Lamp`, `SegmentMeter` and `Wordmark`.

The system's rules are kept rather than approximated:

- **Flat paper.** `#f0ece2` throughout, no gradients, no textures.
- **No shadows.** A control reads by its outline and its arc.
- **Square corners** everywhere.
- **Hairline borders** at partial ink opacity, never a separate grey.
- **One monospace face** at every size — Menlo, the same face JUCE's
  `getDefaultMonospacedFontName()` returns. Panel tokens are sized for a
  plug-in window, so they are scaled up by a single ratio rather than being
  replaced by a second type ramp.
- **No icons, anywhere.** Every indicator is geometric or typographic: a filled
  or outlined square for a lamp, a filled or outlined rectangle for a latch,
  plain text for everything else. There were seven SF Symbols in the first
  build and there are none now.
- **Knobs sweep 317.2°**, leaving the gap at the bottom where the pointer never
  goes. Drag vertically; hold shift for a finer drag. Bipolar knobs — only
  Offset — grow their arc from noon.

### Colour is signal

The system's central rule is that a hue means something and is never chosen to
look nice. Each Sungam product picks its own assignment and then holds to it
absolutely. Beygla's:

| Hue | Means |
|---|---|
| **Coral** | The trigger path — everything that decides *when*. Onsets, the detection curve, audio triggers. |
| **Teal** | The effect engine — everything that decides *what*. Also the sync grid, its ticks and its panel. |
| **Steel** | The render chain — everything after the ops are applied. MIDI triggers, stream settings, progress. |
| **Violet** | Modulation, and only modulation: the four parameters that move another parameter (velocity, chance, jitter, offset). |
| **Amber** | The live state, and nothing else. Armed, the input lamp, the top meter segment. |

The seven effects are not seven colours. They fall into three families by what
they do to the frame array, and each family takes one hue:

- **Bloom** strips reference frames — coral, the primary transform.
- **Glide, Echo, Stutter, Freeze** hold or repeat what is there — teal.
- **Reverse, Shuffle** reorder what is there — steel.

---

## Known limits

- **Live triggers are captured, not rendered live.** Arming records your
  performance against the playhead and the render happens after. Real-time
  moshed output is possible with the same engine — stream chunks to a decoder
  instead of a file — but it isn't built yet.
- **Single clip.** Supermosh's multi-clip transitions aren't in yet; the engine
  supports it (concatenate, force keyframes at the junctions, bloom them) but
  there's no UI for a clip list.
- **Ad-hoc signed.** Fine locally; it needs a Developer ID to hand to anyone
  else.
- **Vector effects need a second optional download.** `./tools/build-ffglitch.sh`
  is a separate step from the main engine — a source clone and build of its
  own — because FFglitch is a genuinely different fork of ffmpeg, not an extra
  flag on the one Beygla already bundles.
