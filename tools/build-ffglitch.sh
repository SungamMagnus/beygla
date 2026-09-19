#!/usr/bin/env bash
# Build ffgac + ffedit for bundling inside Beygla.app.
#
# FFglitch is a fork of ffmpeg that can export a frame's motion vectors (and
# several other coded-but-not-pixels quantities) to JSON, run a JavaScript
# transform over them, and re-encode with the edited vectors instead of the
# real ones. That is the effect family Beygla's own engine cannot reach: it
# reorders and drops whole frames, but it cannot reach *inside* one.
#
# Two binaries come out of the same source tree as one build:
#   ffgac    ffmpeg's own encoder, built with -mpv_flags forcemv so every
#            macroblock gets a motion vector instead of skipping still ones
#   ffedit   exports/imports those vectors as JSON, running a QuickJS script
#            over them in between. QuickJS is vendored inside libavutil, so
#            this is one build, not a separate dependency the way it first
#            looked from the outside.
#
# Same rules as tools/build-ffmpeg.sh: --disable-gpl (no libx264), static,
# universal, and everything unused switched off.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REPO="${FFGLITCH_REPO:-https://github.com/ramiropolla/ffglitch-core.git}"
WORK="$ROOT/vendor/build-ffg"
OUT="$ROOT/vendor/ffglitch"
mkdir -p "$WORK" "$OUT"

SRC="$WORK/src"
if [[ ! -d "$SRC" ]]; then
  echo "==> Cloning ffglitch-core"
  git clone --depth 1 "$REPO" "$SRC"
fi

# The effects that actually exist in Beygla move whole frames of mpeg4, so the
# vector work stays on the same codec rather than adding mpeg2 as a second
# format the rest of the app would need to know about.
COMPONENTS=(
  --disable-everything
  --enable-demuxer=rawvideo,mpegvideo,m4v,avi,mov,matroska
  --enable-decoder=mpeg4,rawvideo
  --enable-encoder=mpeg4,rawvideo
  --enable-muxer=rawvideo,avi,null
  --enable-parser=mpeg4video
  --enable-protocol=file,pipe,fd
  --enable-filter=null,scale,format
  --enable-ffedit
)

COMMON=(
  --disable-gpl --disable-nonfree --disable-version3
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --disable-network --disable-debug --disable-shared --enable-static
  --disable-ffplay --disable-ffprobe --enable-ffmpeg
  --disable-autodetect --enable-pthreads
  --progs-suffix=""
)

build_arch () {
  local arch="$1"
  local dir="$WORK/$arch"
  echo "==> Configuring $arch"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"

  local extra=()
  if [[ "$arch" != "$(uname -m)" ]]; then
    extra+=(--enable-cross-compile --target-os=darwin)
  fi
  if [[ "$arch" == "x86_64" ]] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
    extra+=(--disable-x86asm)
  fi

  "$SRC/configure" \
    --prefix="$dir/install" \
    --arch="$arch" \
    --cc="clang -arch $arch" \
    --extra-cflags="-arch $arch -mmacosx-version-min=14.0" \
    --extra-ldflags="-arch $arch -mmacosx-version-min=14.0" \
    "${COMMON[@]}" "${COMPONENTS[@]}" ${extra[@]+"${extra[@]}"} > configure.log 2>&1 || {
      echo "configure failed for $arch; tail of log:"; tail -40 configure.log; exit 1; }

  echo "==> Building $arch"
  make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1 || {
      echo "build failed for $arch; tail of log:"; tail -40 build.log; exit 1; }

  # The ffmpeg binary built with --enable-ffedit is renamed ffgac to keep its
  # role obvious; ffedit is its own program.
  ls -la ffmpeg ffedit 2>/dev/null | awk '{print "    "$5" "$NF}'
}

build_arch arm64
build_arch x86_64

echo "==> Merging"
for pair in "ffmpeg:ffgac" "ffedit:ffedit"; do
  src_name="${pair%%:*}"; out_name="${pair##*:}"
  lipo -create "$WORK/arm64/$src_name" "$WORK/x86_64/$src_name" -output "$OUT/$out_name"
  strip -S "$OUT/$out_name" 2>/dev/null || true
  chmod +x "$OUT/$out_name"
  echo "    $out_name: $(lipo -archs "$OUT/$out_name"), $(ls -lh "$OUT/$out_name" | awk '{print $5}')"
done

cp "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1" 2>/dev/null || true
cp "$SRC/FFGLITCH_VERSION" "$OUT/VERSION" 2>/dev/null || echo "unknown" > "$OUT/VERSION"
echo "==> Done: $OUT"
