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
**hole in the presentation timeline**, and decoding with `-fps_mode cfr` refills
the hole by repeating the last picture. Frame count restored exactly, sync
intact, and the intermediate AVI stays playable in other tools.

Verified across all seven effects at 30 fps (240 frames in → 240 out) and at
23.976 fps (143 → 143, `24000/1001` preserved).

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
| **Teal** | The effect engine — everything that decides *what*. |
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
