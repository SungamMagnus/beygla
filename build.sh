#!/usr/bin/env bash
# Build Beygla.app. Pass --debug for a faster, unoptimised build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIG=debug ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
  esac
done

echo "==> Building ($CONFIG${ARCHS:+, universal})"
swift build -c "$CONFIG" "${ARCHS[@]}" --product Beygla
swift build -c "$CONFIG" "${ARCHS[@]}" --product beyglactl

BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"
APP="build/Beygla.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Beygla" "$APP/Contents/MacOS/Beygla"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is a frame of real datamoshed video — see icon/README.md. Rebuild it
# from the plates with `./icon/make.sh`.
if [[ -f icon/Beygla.icns ]]; then
  cp icon/Beygla.icns "$APP/Contents/Resources/Beygla.icns"
fi

# A bundled ffmpeg makes the app self-contained. Build it with
# ./tools/build-ffmpeg.sh — a static, universal, LGPL build with everything
# Beygla never asks for switched off. Without it the app falls back to whatever
# is on PATH or in the usual Homebrew locations.
if [[ -x vendor/ffmpeg/ffmpeg && -x vendor/ffmpeg/ffprobe ]]; then
  cp vendor/ffmpeg/ffmpeg vendor/ffmpeg/ffprobe "$APP/Contents/Resources/"
  [[ -f vendor/ffmpeg/COPYING.LGPLv2.1 ]] && \
    cp vendor/ffmpeg/COPYING.LGPLv2.1 "$APP/Contents/Resources/"
  echo "    bundled ffmpeg $(cat vendor/ffmpeg/VERSION 2>/dev/null || echo '?') ($(lipo -archs vendor/ffmpeg/ffmpeg))"
else
  echo "    no bundled ffmpeg — run ./tools/build-ffmpeg.sh to make the app self-contained"
fi

# Ad-hoc signature. Nested executables have to be signed before the bundle
# that contains them, or the outer signature is invalid the moment it is made.
for nested in "$APP/Contents/Resources/ffmpeg" "$APP/Contents/Resources/ffprobe"; do
  [[ -f "$nested" ]] && codesign --force --sign - --timestamp=none "$nested" >/dev/null 2>&1
done
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    (codesign skipped)"

cp "$BIN/beyglactl" build/beyglactl

echo "==> Done"
echo "    app:  $APP  ($(lipo -archs "$APP/Contents/MacOS/Beygla"))"
echo "    cli:  build/beyglactl"
