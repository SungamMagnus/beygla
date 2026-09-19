#!/usr/bin/env bash
# Build a minimal, static, universal ffmpeg for bundling inside Beygla.app.
#
# Three things matter here and none of them are satisfied by copying Homebrew's
# binary:
#
#   1. Homebrew's ffmpeg is dynamically linked against dylibs in its own Cellar.
#      Copied on its own it will not run anywhere else.
#   2. It is built for one architecture. Beygla ships universal.
#   3. It is a GPL build, because it links libx264. Redistributing that inside
#      an app drags GPL obligations along with it.
#
# So this builds from source with --disable-gpl, and gets H.264 out of
# VideoToolbox — Apple's own encoder, already in the OS — instead of x264. The
# result is LGPL, which for a separate executable invoked as a subprocess means
# shipping the licence and an offer of source, and nothing more.
#
# Everything Beygla never asks for is switched off, which takes the binary from
# tens of megabytes to a few.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER="${FFMPEG_VERSION:-7.1}"
WORK="$ROOT/vendor/build"
OUT="$ROOT/vendor/ffmpeg"
mkdir -p "$WORK" "$OUT"

SRC="$WORK/ffmpeg-$VER"
if [[ ! -d "$SRC" ]]; then
  echo "==> Fetching ffmpeg $VER"
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "$WORK/ffmpeg.tar.xz"
  tar -xf "$WORK/ffmpeg.tar.xz" -C "$WORK"
fi

# Only what the pipeline actually touches: read the formats people hand it,
# write the one intermediate format that can be moshed, and write a deliverable.
COMPONENTS=(
  --disable-everything
  --enable-demuxer=mov,matroska,avi,mpegts,flv,wav,mp3,aac,flac,ogg,aiff,w64,image2,rawvideo,m4v,mpegvideo,concat,pcm_s16le,pcm_f32le
  --enable-decoder=h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,av1,prores,dnxhd,mjpeg,png,rawvideo,aac,ac3,eac3,mp3,flac,vorbis,opus,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_f32le,pcm_u8
  --enable-encoder=mpeg4,h264_videotoolbox,hevc_videotoolbox,aac,aac_at,pcm_s16le,pcm_f32le,rawvideo,mjpeg,png
  --enable-muxer=avi,mp4,mov,matroska,wav,rawvideo,image2,null
  --enable-parser=h264,hevc,mpeg4video,mpegvideo,aac,ac3,mpegaudio,flac,vp8,vp9,av1,opus,vorbis,dnxhd,mjpeg,png
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,null,mpeg4_unpack_bframes
  --enable-protocol=file,pipe,fd
  --enable-filter=scale,format,fps,null,anull,aformat,aresample,copy,trim,atrim,setpts,asetpts,crop,pad,scale_vt
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-swscale
  --enable-swresample
)

COMMON=(
  --disable-gpl --disable-nonfree --disable-version3
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --disable-network --disable-debug --disable-shared --enable-static
  --disable-ffplay --enable-ffprobe --enable-ffmpeg
  --disable-autodetect
  --enable-pthreads
)

build_arch () {
  local arch="$1"; shift
  local dir="$WORK/$arch"
  echo "==> Configuring $arch"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"

  # macOS ships bash 3.2, where expanding an empty array under `set -u` is an
  # error, hence the guarded expansion at the call below.
  local extra=()
  if [[ "$arch" != "$(uname -m)" ]]; then
    extra+=(--enable-cross-compile --target-os=darwin)
  fi
  # nasm is only needed for the x86_64 assembly. Without it the build still
  # works, just with the C fallbacks.
  if [[ "$arch" == "x86_64" ]] && ! command -v nasm >/dev/null && ! command -v yasm >/dev/null; then
    echo "    (no nasm — building x86_64 without assembly)"
    extra+=(--disable-x86asm)
  fi

  "$SRC/configure" \
    --prefix="$dir/install" \
    --arch="$arch" \
    --cc="clang -arch $arch" \
    --extra-cflags="-arch $arch -mmacosx-version-min=14.0" \
    --extra-ldflags="-arch $arch -mmacosx-version-min=14.0" \
    "${COMMON[@]}" "${COMPONENTS[@]}" ${extra[@]+"${extra[@]}"} > configure.log 2>&1 || {
      echo "configure failed for $arch; tail of log:"; tail -25 configure.log; exit 1; }

  echo "==> Building $arch"
  make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1 || {
      echo "build failed for $arch; tail of log:"; tail -25 build.log; exit 1; }
  echo "    $(ls -lh ffmpeg | awk '{print $5}') ffmpeg, $(ls -lh ffprobe | awk '{print $5}') ffprobe"
}

build_arch arm64
build_arch x86_64

echo "==> Merging"
for tool in ffmpeg ffprobe; do
  lipo -create "$WORK/arm64/$tool" "$WORK/x86_64/$tool" -output "$OUT/$tool"
  strip -S "$OUT/$tool" 2>/dev/null || true
  chmod +x "$OUT/$tool"
  echo "    $tool: $(lipo -archs "$OUT/$tool"), $(ls -lh "$OUT/$tool" | awk '{print $5}')"
done

cp "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
printf '%s\n' "$VER" > "$OUT/VERSION"
echo "==> Done: $OUT"
