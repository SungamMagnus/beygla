#!/usr/bin/env bash
# Prove the app is actually self-contained.
#
# The interesting failure is an app that looks bundled but silently falls back
# to a system ffmpeg.
#
# Emptying PATH does not test that, which is the trap this script was written
# wrong for the first time: the search falls back to hardcoded Homebrew
# prefixes that ignore PATH entirely, and both binaries emit H.264, so the
# output looks identical either way. The app has to be asked directly.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Beygla.app/Contents/Resources"
[[ -x "$APP/ffmpeg" ]] || { echo "no bundled ffmpeg in $APP"; exit 1; }

echo "==> Bundled binary"
echo "    archs:   $(lipo -archs "$APP/ffmpeg")"
echo "    version: $(env -i "$APP/ffmpeg" -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
# otool prints a header line per architecture in a fat binary; only the
# indented lines are actual links.
echo "    linkage: $(otool -L "$APP/ffmpeg" | grep '^\s' | grep -cv '/usr/lib\|/System/Library') non-system dylibs"

echo "==> Licence check — a GPL build would name these"
if env -i "$APP/ffmpeg" -version 2>/dev/null | grep -qE 'enable-gpl|libx264|libx265'; then
  echo "    FAIL: build is GPL"; exit 1
else
  echo "    clean: no GPL components"
fi

echo "==> Encoders that matter"
for e in mpeg4 h264_videotoolbox aac; do
  if env -i "$APP/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q " $e"; then
    echo "    $e"
  else
    echo "    MISSING: $e"; exit 1
  fi
done

# Onset detection pipes raw float PCM out of ffmpeg. The first bundled build
# had no f32le muxer, so this returned nothing and every audio trigger
# vanished — with no error anywhere, because an empty pipe just means no
# onsets. Check the bytes.
echo "==> Audio extraction"
PCM=$(env -i "$APP/ffmpeg" -v quiet -i cuts.mp4 -vn -ac 1 -ar 44100 -f f32le - 2>/dev/null | wc -c | tr -d ' ')
echo "    $PCM bytes of PCM from an 8s clip"
[[ "$PCM" -gt 1000000 ]] || { echo "    FAIL: no PCM — onset detection would find nothing"; exit 1; }

echo "==> What the app actually resolved"
RESOLVED=$(./build/Beygla.app/Contents/MacOS/Beygla --print-tool)
echo "$RESOLVED" | sed 's/^/    /'
grep -q "^source:  bundled" <<<"$RESOLVED" || { echo "    FAIL: app is not using the bundled binary"; exit 1; }
grep -q "^libx264: false" <<<"$RESOLVED" || { echo "    FAIL: resolved binary has libx264, so it is not the LGPL build"; exit 1; }
grep -q "$PWD/build/Beygla.app/Contents/Resources/ffmpeg" <<<"$RESOLVED" || { echo "    FAIL: resolved path is outside the bundle"; exit 1; }

echo "==> End-to-end render"
# Run the CLI with the bundled pair beside it, which is how it resolves a
# bundled copy when it is not inside an app.
STAGE=$(mktemp -d)
cp build/beyglactl "$APP/ffmpeg" "$APP/ffprobe" cuts.mp4 "$STAGE/"
OUT="$STAGE/out.mp4"
RENDER=$( cd "$STAGE" && env -i HOME="$HOME" PATH="" ./beyglactl render cuts.mp4 out.mp4 \
    --band low --effect bloom --dur 0.4 --width 480 2>&1 | tail -6 )
echo "$RENDER" | sed 's/^/    /'

echo "==> Result"
grep -qE "ops +[1-9]" <<<"$RENDER" || { echo "    FAIL: no ops — triggers were not detected"; exit 1; }
env -i "$APP/ffprobe" -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames,codec_name,duration -of csv=p=0 "$OUT" \
    | sed 's/^/    /'
env -i "$APP/ffprobe" -v error -select_streams a:0 \
    -show_entries stream=codec_name,duration -of csv=p=0 "$OUT" | sed 's/^/    audio /'

echo "==> Vector engine (ffgac/ffedit)"
if [[ -x "$APP/ffgac" && -x "$APP/ffedit" ]]; then
  echo "    archs: $(lipo -archs "$APP/ffgac")"
  grep -q "^vector:  bundled" <<<"$RESOLVED" || { echo "    FAIL: app did not resolve the bundled vector engine"; exit 1; }

  # Full round trip through the actual pipeline, same discipline as the main
  # engine: run it, don't infer it. Same staged directory, still in place.
  cp "$APP/ffgac" "$APP/ffedit" "$STAGE/"
  VRENDER=$( cd "$STAGE" && env -i HOME="$HOME" PATH="" ./beyglactl render cuts.mp4 vector_out.mp4 \
      --band low --effect none --vector-effect sink --vector-dur 0.5 2>&1 | tail -8 )
  echo "$VRENDER" | sed 's/^/    /'
  grep -qE "frames    240" <<<"$VRENDER" || { echo "    FAIL: vector render did not produce 240 frames"; exit 1; }
else
  echo "    not bundled — run ./tools/build-ffglitch.sh (vector effects unavailable until then)"
fi

rm -rf "$STAGE"
echo "==> Self-contained."
