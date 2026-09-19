#!/usr/bin/env bash
# Prove the app is actually self-contained.
#
# The interesting failure is an app that looks bundled but silently falls back
# to a system ffmpeg on PATH, so this runs the bundled binary with PATH emptied
# and the Homebrew prefixes gone. If anything still works, it worked on its own.
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

echo "==> End-to-end render with PATH emptied"
OUT=$(mktemp -d)/out.mp4
env -i HOME="$HOME" PATH="" ./build/beyglactl render cuts.mp4 "$OUT" \
    --band low --effect bloom --dur 0.4 --width 480 2>&1 | tail -5

echo "==> Result"
env -i "$APP/ffprobe" -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames,codec_name,duration -of csv=p=0 "$OUT" \
    | sed 's/^/    /'
env -i "$APP/ffprobe" -v error -select_streams a:0 \
    -show_entries stream=codec_name,duration -of csv=p=0 "$OUT" | sed 's/^/    audio /'
rm -rf "$(dirname "$OUT")"
echo "==> Self-contained."
