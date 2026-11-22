#!/bin/bash
# Builds the FFmpeg helper that PSP Video Prep bundles to read formats macOS
# can't open by itself (MKV, WebM, AVI/DivX, WMV, FLV ...).
#
# The build is LGPL-only: no --enable-gpl, no --enable-nonfree, and no external
# libraries beyond what ships with macOS. It is used purely to read and decode;
# the PSP output is still produced by Apple's encoder.
#
# Output: psp_video_prep/Helpers/ffmpeg (universal: arm64 + x86_64)
# Usage:  scripts/build-ffmpeg.sh
set -euo pipefail

VERSION="9.0.2"
SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.ffmpeg-build"
OUTPUT="$ROOT/psp_video_prep/Helpers/ffmpeg"
TARBALL="$WORK/ffmpeg-${VERSION}.tar.xz"

mkdir -p "$WORK" "$(dirname "$OUTPUT")"

if [ ! -f "$TARBALL" ]; then
    echo "Downloading FFmpeg ${VERSION}..."
    curl -fL --retry 3 -o "$TARBALL" "$URL"
fi
echo "${SHA256}  ${TARBALL}" | shasum -a 256 -c -

build_arch() {
    local arch="$1"
    local src="$WORK/src-$arch"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$TARBALL" -C "$src" --strip-components 1

    local flags="-arch $arch -mmacosx-version-min=$MIN_MACOS"
    local extra=()
    if [ "$arch" != "$(uname -m)" ]; then extra+=(--enable-cross-compile --target-os=darwin); fi
    # No assembler for x86 is assumed to be installed; the C code paths are used instead.
    if [ "$arch" = "x86_64" ]; then extra+=(--disable-x86asm); fi

    echo "Configuring for $arch..."
    (
        cd "$src"
        ./configure \
            --arch="$arch" --cc=clang \
            --extra-cflags="$flags" --extra-ldflags="$flags" \
            --disable-autodetect --enable-zlib \
            --enable-videotoolbox --enable-audiotoolbox \
            --disable-shared --enable-static \
            --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
            --disable-network --disable-devices \
            --disable-encoders --enable-encoder=h264_videotoolbox,pcm_s16le,mjpeg,png \
            --disable-muxers --enable-muxer=mov,image2,image2pipe,null \
            --disable-protocols --enable-protocol=file,pipe \
            --disable-filters \
            --enable-filter=scale,format,fps,setsar,bwdif,null,aresample,aformat,pan,anull \
            ${extra[@]+"${extra[@]}"} > "$WORK/configure-$arch.log"
        grep -E "^License:" "$WORK/configure-$arch.log"
        echo "Building for $arch..."
        make -j"$(sysctl -n hw.ncpu)" ffmpeg > "$WORK/make-$arch.log" 2>&1
    )
}

build_arch arm64
build_arch x86_64

lipo -create "$WORK/src-arm64/ffmpeg" "$WORK/src-x86_64/ffmpeg" -output "$OUTPUT"
strip -x "$OUTPUT"
codesign --force --sign - "$OUTPUT"
chmod 755 "$OUTPUT"

echo "Built $OUTPUT"
lipo -info "$OUTPUT"
"$OUTPUT" -hide_banner -version | head -1
"$OUTPUT" -hide_banner -L 2>/dev/null | head -3
