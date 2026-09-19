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

# Bundling ffmpeg here makes the app self-contained; without it Beygla falls
# back to whatever is on PATH or in the usual Homebrew locations.
if [[ -n "${BEYGLA_BUNDLE_FFMPEG:-}" ]]; then
  for t in ffmpeg ffprobe; do
    src="$(command -v "$t" || true)"
    if [[ -n "$src" ]]; then
      cp "$src" "$APP/Contents/Resources/$t"
      echo "    bundled $t"
    fi
  done
fi

# Ad-hoc signature. Enough for the microphone prompt on a locally built app;
# replace with a Developer ID identity to distribute it.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    (codesign skipped)"

cp "$BIN/beyglactl" build/beyglactl

echo "==> Done"
echo "    app:  $APP  ($(lipo -archs "$APP/Contents/MacOS/Beygla"))"
echo "    cli:  build/beyglactl"
