#!/usr/bin/env bash
# Build Moshbox.app. Pass --debug for a faster, unoptimised build.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product Moshbox
swift build -c "$CONFIG" --product moshctl

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Moshbox.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Moshbox" "$APP/Contents/MacOS/Moshbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundling ffmpeg here makes the app self-contained; without it Moshbox falls
# back to whatever is on PATH or in the usual Homebrew locations.
if [[ -n "${MOSHBOX_BUNDLE_FFMPEG:-}" ]]; then
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

cp "$BIN/moshctl" build/moshctl

echo "==> Done"
echo "    app:  $APP"
echo "    cli:  build/moshctl"
