# The icon

It is a frame of genuinely datamoshed video, not a glitch filter over a letter.

```
plate A ──┐
          ├── one clip ── encode ── bloom ── decode ── frame 12 ── iconset
plate B ──┘
```

**Plate A** is the letter B, set in Menlo Bold on the system's paper. These are
the pixels that end up in the icon.

**Plate B** is a field of hard-edged bands in the signal palette, panned
diagonally. Nothing from it survives into the icon. It exists only to supply
motion vectors with a strong, coherent direction.

The two are concatenated into one clip with a hard cut between them. Beygla's
own engine forces a keyframe at that cut and then strips it — a `bloom`, the
same op the app performs — so the bands' motion vectors are applied to the
letter's pixels instead of their own. Frames 10 and 12 past the cut are where
the letter has been dragged into blocks while still reading as a B.

Rebuild it with:

```bash
./icon/make.sh
```

## Sizes

Large sizes carry the real mosh. Below 128 a downscaled 1024px plate turns to
mush — the strokes blur and the torn bands collapse into noise — so the small
sizes are set as live type at their target size with a few clean tears standing
in for it. Both the number of tears and how far they slip come down with the
tile: displacement that reads as a torn macroblock row at 64px breaks the letter
into unrecognisable pieces at 16, and an icon that cannot be identified in the
Dock has failed at its only job.

| Size | Art |
|---|---|
| 1024, 512 | frame 12 — the most torn still legible |
| 256, 128 | frame 10 — calmer |
| 64, 32 | live type, two or three tears |
| 16 | live type, one tear, no displacement |

## Why it is full-bleed

The first pass drew an 824pt tile inside a 1024pt canvas, the old Big Sur grid.
Current macOS masks an app icon to the system shape itself and fills whatever
the icon leaves transparent, so that version came back sitting on a grey plate.
The art is now edge to edge: the paper fills the shape and the corner treatment
is left to the OS.

That also settles a real tension. The Sungam system says every corner is square;
the platform wants a squircle. The art keeps the square corners, and the
platform rounds them if that is what it does this year.
