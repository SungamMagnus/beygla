#!/usr/bin/env bash
# Rebuild the app icon.
#
# The icon is not a glitch filter over a letter. It is a frame of genuinely
# datamoshed video: a letterform is encoded, a keyframe is stripped by Beygla's
# own engine, and a frame is pulled from a few past the bloom, by which point
# the letter's pixels have been dragged around by motion that belonged to a
# different picture entirely.
set -euo pipefail
cd "$(dirname "$0")/.."

W=icon/work
mkdir -p "$W"

echo "==> Rendering the plates"
swiftc -O icon/render.swift -o "$W/render"
"$W/render"

echo "==> Building the source clip"
# Plate A is held, then the bands pan diagonally. Nothing from the bands
# survives into the icon; they exist only to supply motion vectors with a
# strong, coherent direction.
ffmpeg -y -v error \
  -loop 1 -t 0.3333 -i "$W/plate_a.png" \
  -loop 1 -t 0.8    -i "$W/plate_b.png" \
  -filter_complex "[0:v]scale=1024:1024,fps=30,setsar=1[a];\
[1:v]scale=1500:1500,fps=30,crop=1024:1024:x='(iw-ow)*min(1,t/0.8)':y='(ih-oh)*min(1,t/0.8)',setsar=1[b];\
[a][b]concat=n=2:v=1:a=0[v]" \
  -map "[v]" -c:v libx264 -crf 12 -pix_fmt yuv420p "$W/source.mp4"

echo "==> Moshing it with Beygla"
CLI=build/beyglactl
[[ -x "$CLI" ]] || CLI=.build/release/beyglactl
[[ -x "$CLI" ]] || CLI=.build/debug/beyglactl
"$CLI" render "$W/source.mp4" "$W/moshed.mp4" --at 0.3333 --effect bloom --dur 1.0 --quality 4

echo "==> Pulling frames"
# 10 is the calmer tear used at the middle sizes; 12 is the one the large
# sizes are cut from.
for n in 10 12; do
  ffmpeg -y -v error -i "$W/moshed.mp4" -vf "select='eq(n\,$n)'" -frames:v 1 "$W/f$n.png"
done

echo "==> Composing the iconset"
swiftc -O icon/compose.swift -o "$W/compose"
"$W/compose"
iconutil -c icns icon/Beygla.iconset -o icon/Beygla.icns

echo "==> Done: icon/Beygla.icns"
