# Moshbox

A macOS datamosh editor whose effects are driven by **audio-in** and **MIDI-in**
triggers, so the glitches land on the beat instead of wherever you happened to
drag them.

Inspired by [supermosh](https://github.com/supermosh/supermosh.github.io) and
[Datamosher Pro](https://github.com/Akascape/Datamosher-Pro).

---

## What it does

Load a clip. Moshbox finds the transients in its audio — or listens to a live
input, or to a MIDI controller — and turns each hit into a **trigger**. Each
trigger fires an **effect rule**, and each rule rewrites a span of compressed
video frames. Then it renders.

### The seven effects

| Effect | What happens to the bitstream |
|---|---|
| **Bloom** | Deletes the keyframes in range, so incoming motion vectors land on whatever pixels were already on screen. The classic transition smear. |
| **Glide** | Holds one delta frame and re-applies it for the whole range — the picture keeps sliding in a fixed direction. |
| **Echo** | Cycles a short window of delta frames, giving a rhythmic churn. |
| **Stutter** | Holds each frame for several slots, dropping the ones between. |
| **Reverse** | Plays the range's motion backwards. |
| **Shuffle** | Randomly permutes the delta frames in range. |
| **Freeze** | A true still: no motion applied at all. |

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
Moshbox asked for — one per trigger, placed so `bloom` has something to strip.

**2. Mosh.** Pure Swift, no library. The AVI is parsed as a RIFF tree, each
`00dc` chunk in the `movi` list is classified by picking the
`vop_coding_type` bits out of its MPEG-4 VOP header, and the effect rules
rewrite that array of frames. Then `idx1` is rebuilt and the frame counts in
`avih` / `strh` are patched to match.

**3. Decode.** Back to H.264, with the original audio track muxed in untouched.

### Why it stays in sync

This is the part that makes Moshbox different from the tools that inspired it,
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

What Moshbox writes instead is a synthesised **`vop_coded = 0` P-VOP**: a
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
full range — with a threshold that adapts to a running median, so a quiet
passage and a loud one are judged on their own terms.

Detected times are reported at the **centre** of the analysis window rather than
its start. Without that correction every onset reads about 12 ms early, which is
audible when a smear is supposed to hit with a kick. On a 120 BPM test pattern
the corrected detector lands within 3 ms.

The live detector can't look ahead to compute a median, so it tracks an
asymmetrically smoothed running average instead — quick to rise, slow to fall,
so the tail of a hit doesn't re-arm it.

---

## Building

Requires macOS 14+, Xcode command line tools, and ffmpeg:

```bash
brew install ffmpeg
```

Then:

```bash
./build.sh
```

That produces `build/Moshbox.app` and `build/moshctl`. To make the app
self-contained, bundle ffmpeg into it:

```bash
MOSHBOX_BUNDLE_FFMPEG=1 ./build.sh
```

---

## Using it

### Offline — sync to the clip's own audio

1. Drop a video in.
2. Pick a band and set sensitivity. Ticks appear on the timeline as you drag.
3. Add effect rules. The coloured bars under the waveform show exactly which
   frames each rule will rewrite.
4. **Preview** renders at 640px for a fast look; **Render** does it full size.

### Live — perform the mosh

1. Set the trigger source to **Audio in** or **MIDI in**.
2. Hit **Arm live capture**.
3. Play the clip and perform — tap pads, or let the detector listen to whatever
   is coming into your interface. Each hit is timestamped against the playhead
   and written to the timeline.
4. Disarm, tidy up, render.

Rules can be bound to a specific MIDI note, so one pad blooms and another
stutters. Hit a pad, then press **Learn** on the rule.

### Command line

The CLI shares every line of the actual moshing with the app, so anything odd
in a render can be reproduced here:

```bash
moshctl info clip.mp4                    # geometry, keyframe layout, picture types
moshctl onsets clip.mp4 --band low       # what the detector hears
moshctl render clip.mp4 out.mp4 \
    --band low --effect bloom --dur 0.4  # render
```

---

## Layout

```
Sources/MoshCore/          # no UI, no AppKit — all of it testable from moshctl
  RIFF.swift               #   RIFF/AVI tree parse + serialise
  MPEG4.swift              #   VOP type classification
  MPEG4Skip.swift          #   VOL bit-parsing, skip-VOP synthesis
  AVIDocument.swift        #   the AVI as an array of frames
  MoshEngine.swift         #   the seven effects
  OnsetDetector.swift      #   spectral flux, offline + live
  Triggers.swift           #   events, rules, and compiling one into ops
  FFmpegTool.swift         #   encode / decode / probe / PCM extraction
  RenderPipeline.swift     #   the three stages, with progress and cancellation
Sources/Moshbox/           # SwiftUI app
Sources/moshctl/           # command line front end
```

---

## Known limits

- **ffmpeg is an external dependency.** Found on `PATH` or in the usual Homebrew
  locations unless bundled. The Homebrew build on this machine is x86_64, so it
  runs under Rosetta; an arm64 build will encode noticeably faster.
- **Live triggers are captured, not rendered live.** Arming records your
  performance against the playhead and the render happens after. Real-time
  moshed output is possible with the same engine — stream chunks to a decoder
  instead of a file — but it isn't built yet.
- **Single clip.** Supermosh's multi-clip transitions aren't in yet; the engine
  supports it (concatenate, force keyframes at the junctions, bloom them) but
  there's no UI for a clip list.
- **No app icon**, and the bundle is ad-hoc signed — fine locally, but it needs a
  Developer ID to hand to anyone else.
