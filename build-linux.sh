#!/usr/bin/env bash
# Builds the FFmpeg that Yaparr runs to share and show screens on Linux: only the parts Yaparr uses, under the LGPL, in one
# ffmpeg program for Linux x86-64 or arm64. Run it on a Debian or Ubuntu machine (the workflow does, on Ubuntu 22.04, so the
# program runs on any system with glibc 2.35 or newer); see README.md in this folder.
#
#   build-linux.sh [x64|arm64]   which machine to build for; it has to be this machine (default: this machine's)
#
#   FFMPEG_COMMIT   the FFmpeg commit to build (default: the one Yaparr is tested with, as for Windows)
#   OUT             where the package goes (default: ./out)
#
# libvpx, dav1d and the X11 libraries (libxcb and its helpers) are linked in. Two things are not, on purpose: the C library, and
# libva, which finds the graphics driver for H.264 on Intel and AMD cards and has to be the one of the computer it runs on.
# NVIDIA's encoder library is opened by FFmpeg when it runs, so it is not linked either.
set -euo pipefail

case "$(uname -m)" in
  x86_64) native=x64 ;;
  aarch64) native=arm64 ;;
  *) echo "unsupported machine: $(uname -m)" >&2; exit 1 ;;
esac
TARGET="${1:-$native}"
[ "$TARGET" = "$native" ] || { echo "this machine is $native; build for $TARGET on a $TARGET machine" >&2; exit 1; }

FFMPEG_COMMIT="${FFMPEG_COMMIT:-17a4a474f4013bfef4393abaca282078e24efc35}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.0}"
LIBVPX_TAG="${LIBVPX_TAG:-v1.15.2}"
DAV1D_TAG="${DAV1D_TAG:-1.5.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
SHORT="${FFMPEG_COMMIT:0:10}"
NAME="ffmpeg-yaparr-g${SHORT}-linux-${TARGET}"
PREFIX="$WORK/prefix"
STATIC="$WORK/static-libs"

rm -rf "$WORK" "$OUT/$NAME" "$OUT/$NAME.zip"
mkdir -p "$WORK" "$STATIC" "$OUT/$NAME/bin" "$OUT/$NAME/licenses"
cd "$WORK"

# NVIDIA's encoder is reached through these headers (MIT), which only describe the interface of the driver's library.
git clone --depth 1 --branch "$NV_CODEC_HEADERS_TAG" https://github.com/FFmpeg/nv-codec-headers.git nv-codec-headers
make -C nv-codec-headers PREFIX="$PREFIX" LIBDIR=lib install >/dev/null
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# libvpx (BSD, with Google's patent grant): VP8 only, built here so that every machine gets the same one and so that its static
# library and licence files are at hand.
git clone --depth 1 --branch "$LIBVPX_TAG" https://github.com/webmproject/libvpx.git libvpx
( cd libvpx && ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic --enable-vp8 --disable-vp9     --disable-examples --disable-tools --disable-docs --disable-unit-tests >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )

# dav1d (BSD 2-clause), the AV1 decoder every viewer uses, built here for the same reasons (Ubuntu 22.04's own is too old for this FFmpeg).
git clone --depth 1 --branch "$DAV1D_TAG" https://code.videolan.org/videolan/dav1d.git dav1d
( cd dav1d && meson setup build --prefix="$PREFIX" --libdir=lib --default-library=static -Dbuildtype=release -Denable_tools=false -Denable_tests=false -Denable_examples=false >/dev/null && ninja -C build >/dev/null && ninja -C build install >/dev/null )

# Link these libraries statically: the linker takes the first folder it is given that has the library, and this one only has the
# static ones. (libva is not in it.)
ORIGINALS=()
stage() { # stage <pkg-config name> <file name>
  local dir
  dir="$(pkg-config --variable=libdir "$1")"
  [ -f "$dir/$2" ] || { echo "no static $2 (the -dev package of $1)"; exit 1; }
  cp "$dir/$2" "$STATIC/"
  ORIGINALS+=("$(readlink -f "$dir/$2")")
}
stage vpx libvpx.a
stage xcb libxcb.a
stage xcb-shm libxcb-shm.a
stage xcb-xfixes libxcb-xfixes.a
stage xcb-shape libxcb-shape.a
stage xau libXau.a
stage xdmcp libXdmcp.a

git clone --filter=blob:none https://github.com/FFmpeg/FFmpeg.git src
git -C src checkout --detach "$FFMPEG_COMMIT"
cd src

# What goes in, and why (the same as the Windows build, with the Linux capture and card encoders in place of Windows' ones):
#   libvpx_vp8, vp8            VP8 in software: the encoder for computers without a usable graphics card, and the decoder
#   h264_nvenc, h264_vaapi     H.264 on NVIDIA graphics cards, and on Intel and AMD ones through VA-API (the card does the work)
#   h264 (decoder, parser)     every viewer decodes H.264 in software
#   av1_nvenc, av1_vaapi       AV1 on NVIDIA graphics cards, and on Intel and AMD ones through VA-API (newer cards; the card does the work)
#   libdav1d, av1 (parser), av1_metadata   every viewer decodes AV1 in software with dav1d; av1_metadata is what the IVF writer
#                              uses to put a temporal delimiter in front of each picture
#   ivf, h264 (demuxers/muxers), rawvideo, pipe   the pictures go in and out through standard input and output (rawvideo in:
#                              the pictures GStreamer reads from the Wayland portal)
#   xcbgrab (x11grab), hwupload, format, scale   copying an X11 screen or window, then the conversion of each picture
#   lavfi, color, testsrc2, null, wrapped_avframe   only for Yaparr's tests and the checks in verify.sh
# Nothing else is switched on: no GPL part (no x264, x265), nothing "nonfree", no network, no other codec, no other program.
./configure \
  --prefix="$PREFIX" \
  --pkg-config-flags=--static \
  --extra-ldflags="-L$STATIC" \
  --disable-everything --disable-autodetect \
  --disable-shared --enable-static \
  --disable-doc --disable-debug --disable-network \
  --disable-ffplay --disable-ffprobe \
  --enable-libxcb --enable-libxcb-shm --enable-libxcb-xfixes --enable-libxcb-shape \
  --enable-libvpx --enable-libdav1d --enable-vaapi --enable-ffnvcodec --enable-nvenc \
  --enable-encoder=libvpx_vp8,h264_nvenc,h264_vaapi,av1_nvenc,av1_vaapi,rawvideo \
  --enable-decoder=vp8,h264,libdav1d,rawvideo,wrapped_avframe \
  --enable-parser=h264,vp8,av1 \
  --enable-demuxer=ivf,h264,rawvideo \
  --enable-muxer=ivf,h264,rawvideo,null \
  --enable-indev=xcbgrab,lavfi \
  --enable-bsf=h264_mp4toannexb,av1_metadata \
  --enable-protocol=pipe,file \
  --enable-filter=scale,format,null,hwupload,color,testsrc2 \
  || { tail -n 80 ffbuild/config.log; exit 1; }

make -j"$(nproc)"

VERSION="$(./ffbuild/version.sh .)"
CONFIGURE_LINE="$(grep -m1 '^configuration:' <(./ffmpeg -hide_banner -version) | sed 's/^configuration: //')"
cp ffmpeg "$OUT/$NAME/bin/ffmpeg"
strip "$OUT/$NAME/bin/ffmpeg"
chmod 755 "$OUT/$NAME/bin/ffmpeg"
cp COPYING.LGPLv2.1 "$OUT/$NAME/LICENSE.txt"

# The licences of what was built in: the Debian packages whose code (or headers) ended up in ffmpeg. Each package's own copyright
# file is copied; libvpx's own licence and patent grant, from its source, come with the binary too.
LICENSE_DIR="$OUT/$NAME/licenses"
PACKAGES=""
add_package() { # the package that owns a file, once
  local owner
  owner="$(dpkg -S "$1" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  [ -n "$owner" ] || return 0
  case " $PACKAGES " in *" $owner "*) ;; *) PACKAGES="$PACKAGES $owner" ;; esac
}
for file in "${ORIGINALS[@]}"; do add_package "$file"; done
add_package "$(pkg-config --variable=includedir libva)/va/va.h"
add_package "$(pkg-config --variable=includedir xcb)/xcb/xcb.h"
for pkg in $PACKAGES; do
  [ -f "/usr/share/doc/$pkg/copyright" ] || continue
  mkdir -p "$LICENSE_DIR/$pkg"
  cp "/usr/share/doc/$pkg/copyright" "$LICENSE_DIR/$pkg/copyright"
done
mkdir -p "$LICENSE_DIR/nv-codec-headers"
cp "$WORK"/nv-codec-headers/README* "$LICENSE_DIR/nv-codec-headers/" 2>/dev/null || true
[ -f "$WORK/nv-codec-headers/LICENSE" ] && cp "$WORK/nv-codec-headers/LICENSE" "$LICENSE_DIR/nv-codec-headers/"

mkdir -p "$LICENSE_DIR/libvpx" "$LICENSE_DIR/dav1d"
cp "$WORK/libvpx/LICENSE" "$WORK/libvpx/PATENTS" "$LICENSE_DIR/libvpx/"
cp "$WORK/dav1d/COPYING" "$LICENSE_DIR/dav1d/"
find "$LICENSE_DIR" -type d -empty -delete

# The packages and versions used, as they were on the build machine.
{
  echo "FFmpeg $VERSION"
  echo "commit $FFMPEG_COMMIT"
  echo "built from https://github.com/zburtle/Yaparr.FFmpeg${GITHUB_SHA:+ at commit $GITHUB_SHA}${GITHUB_RUN_ID:+ (workflow run $GITHUB_RUN_ID)}"
  echo
  echo "configure: $CONFIGURE_LINE"
  echo
  echo "Libraries and headers used:"
  echo "nv-codec-headers $NV_CODEC_HEADERS_TAG"
  echo "libvpx $LIBVPX_TAG (built from source)"
  echo "dav1d $DAV1D_TAG (built from source)"
  for pkg in $PACKAGES; do dpkg-query -W -f='${Package} ${Version}\n' "$pkg" 2>/dev/null || true; done
  echo
  echo "Compiler: $(gcc --version | head -1)"
  echo "C library it was built against (the program needs this or newer): $(ldd --version | head -1)"
} > "$OUT/$NAME/BUILD-INFO.txt"

cat > "$OUT/$NAME/SOURCE.txt" <<EOF
This is a build of FFmpeg, made for Yaparr (https://github.com/zburtle/Yaparr), with only the parts Yaparr uses.

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later (LICENSE.txt). It is not built with any
GPL or "nonfree" part. Yaparr runs it as a separate program and does not link to it, so it can be replaced: set YAPARR_FFMPEG
to another ffmpeg, or put one in an "ffmpeg" folder next to Yaparr.

The source code of this build, the exact commit of FFmpeg that was built, is the file ffmpeg-g${SHORT}-source.tar.xz in the
same release, and https://github.com/FFmpeg/FFmpeg/commit/${FFMPEG_COMMIT}.
The way it was configured and built is in BUILD-INFO.txt here and in the source of the build scripts
(https://github.com/zburtle/Yaparr.FFmpeg).

Built in: libvpx (BSD licence, with Google's patent grant), dav1d (the AV1 decoder, BSD 2-clause licence) and the X11 client libraries libxcb, libXau and libXdmcp (MIT
licence). The NVIDIA codec headers (MIT) only describe NVIDIA's encoder library, which is part of the graphics driver, and
libva (MIT) is the computer's own. Their licences are in the licenses folder.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. Yaparr is not endorsed by the FFmpeg project.
EOF

( cd "$OUT" && zip -9 -r -X "$NAME.zip" "$NAME" )
echo "NAME=$NAME" > "$OUT/name-linux-$TARGET.txt"
echo "Built $OUT/$NAME.zip"
