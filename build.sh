#!/usr/bin/env bash
# Builds the FFmpeg that Yaparr uses to share and show screens: only the parts Yaparr uses, under the LGPL, for Windows x64: FFmpeg's
# libraries (DLLs), which Yaparr loads into itself, so they are shared libraries, which anyone can replace (that is what the LGPL asks of a
# program that links to it). An ffmpeg.exe is built too, only to check the libraries with (verify.sh): it goes in a folder of its own
# beside the package (check-<name>, with copies of the DLLs) and is not shipped. Run it in an MSYS2 UCRT64 shell (the workflow does); see README.md in this folder.
#
#   FFMPEG_COMMIT   the FFmpeg commit to build (default: the one Yaparr is tested with)
#   OUT             where the package goes (default: ./out)
set -euo pipefail

FFMPEG_COMMIT="${FFMPEG_COMMIT:-17a4a474f4013bfef4393abaca282078e24efc35}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
SHORT="${FFMPEG_COMMIT:0:10}"
NAME="ffmpeg-yaparr-g${SHORT}-win64"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT/$NAME/bin" "$OUT/$NAME/licenses"
cd "$WORK"

git clone --filter=blob:none https://github.com/FFmpeg/FFmpeg.git src
git -C src checkout --detach "$FFMPEG_COMMIT"
cd src

# What goes in, and why:
#   libvpx_vp8, vp8            VP8 in software: the encoder for computers without a usable graphics card, and the decoder
#   h264_nvenc, h264_amf, h264_qsv   H.264 on NVIDIA, AMD and Intel graphics cards (the card does the work)
#   h264 (decoder, parser)     every viewer decodes H.264 in software
#   h264_d3d11va, h264_d3d12va, h264_dxva2, scale_d3d12   H.264 decoding on the graphics card, when the app is asked to; the preview of a share
#                              also scales on the card (scale_d3d12), so that only the small picture is copied back to memory
#   av1_nvenc, av1_amf, av1_qsv   AV1 on NVIDIA, AMD and Intel graphics cards (RTX 40, RX 7000, Arc and newer; the card does the work)
#   libdav1d, av1 (parser), av1_metadata   every viewer decodes AV1 in software with dav1d (BSD); av1_metadata is what the IVF writer
#                              uses to put a temporal delimiter in front of each picture
#   ivf, h264 (demuxers/muxers), rawvideo, pipe   the pictures go in and out through standard input and output
#   gfxcapture, hwdownload, format, scale   Windows Graphics Capture, then the download and conversion of each picture
#   lavfi, color, testsrc2, null, wrapped_avframe   only for Yaparr's tests and the checks in verify.sh
#                              (wrapped_avframe is how FFmpeg itself reads a test source)
# Nothing else is switched on: no GPL part (no x264, x265), nothing "nonfree", no network, no other codec, no other program.
./configure \
  --prefix="$WORK/prefix" \
  --arch=x86_64 --target-os=mingw32 \
  --pkg-config-flags=--static \
  --extra-ldflags="-static-libgcc -static-libstdc++" \
  --extra-libs="-lstdc++" \
  --disable-everything --disable-autodetect \
  --enable-shared --disable-static --disable-pthreads --enable-w32threads \
  --disable-doc --disable-debug --disable-network \
  --disable-ffplay --disable-ffprobe \
  --enable-d3d11va --enable-d3d12va --enable-dxva2 \
  --enable-libvpx --enable-libdav1d --enable-libvpl --enable-amf --enable-ffnvcodec --enable-nvenc \
  --enable-encoder=libvpx_vp8,h264_nvenc,h264_amf,h264_qsv,av1_nvenc,av1_amf,av1_qsv,rawvideo \
  --enable-decoder=vp8,h264,libdav1d,wrapped_avframe \
  --enable-hwaccel=h264_d3d11va,h264_d3d11va2,h264_d3d12va,h264_dxva2 \
  --enable-parser=h264,vp8,av1 \
  --enable-demuxer=ivf,h264 \
  --enable-muxer=ivf,h264,rawvideo,null \
  --enable-indev=lavfi \
  --enable-bsf=h264_mp4toannexb,av1_metadata \
  --enable-protocol=pipe,file \
  --enable-filter=gfxcapture,hwdownload,format,scale,scale_d3d12,color,testsrc2 \
  || { tail -n 80 ffbuild/config.log; exit 1; }

make -j"$(nproc)"

# The libraries, and the program beside them for now (Windows looks for a DLL in the folder of the program that needs it, and what the
# program needs is what is shipped); the program is taken out of the package below, once it has served to find and check them.
VERSION="$(./ffbuild/version.sh .)"
cp ffmpeg.exe "$OUT/$NAME/bin/ffmpeg.exe"
# (only the DLLs with their version in the name, which are the ones the program and the app ask for; the build also leaves copies without it)
for dll in lib*/*-[0-9]*.dll; do cp "$dll" "$OUT/$NAME/bin/"; done
# What the libraries need that Windows does not have: dav1d, libvpx, the oneVPL dispatcher, winpthreads and the compiler's runtime, as DLLs of MSYS2's, shipped
# next to them (their licences are collected below). Found by what the program and each DLL import, again for what those need in turn.
more=1
while [ "$more" = 1 ]; do
  more=0
  for file in "$OUT/$NAME/bin/"*.exe "$OUT/$NAME/bin/"*.dll; do
    for dep in $(objdump -p "$file" | awk '/DLL Name/ {print $3}'); do
      [ -e "$OUT/$NAME/bin/$dep" ] && continue
      if [ -e "$MSYSTEM_PREFIX/bin/$dep" ]; then cp "$MSYSTEM_PREFIX/bin/$dep" "$OUT/$NAME/bin/$dep"; echo "also shipped: $dep (needed by $(basename "$file"))"; more=1; fi
    done
  done
done
strip "$OUT/$NAME/bin/"*.exe "$OUT/$NAME/bin/"*.dll
ls -l "$OUT/$NAME/bin"
CONFIGURE_LINE="$(grep -m1 '^configuration:' <("$OUT/$NAME/bin/ffmpeg.exe" -hide_banner -version) | sed 's/^configuration: //')"
# The program, with copies of the libraries next to it, goes where verify.sh finds it, and out of the package: Yaparr does not run it.
CHECK="$OUT/check-$NAME"
rm -rf "$CHECK" && mkdir -p "$CHECK"
cp "$OUT/$NAME/bin/"* "$CHECK/"
rm "$OUT/$NAME/bin/ffmpeg.exe"
cp COPYING.LGPLv2.1 "$OUT/$NAME/LICENSE.txt"

# The licences of what was built in: the packages whose code (or headers) ended up in the libraries. Each package's licence files
# are found through its file list. libvpx (BSD, with Google's patent grant) and the compiler runtime (GPL with the GCC runtime
# exception) must come with the binary: if a package carries no licence files they are fetched from upstream, and the build
# stops if there is still nothing.
LICENSE_DIR="$OUT/$NAME/licenses"
PKG_PREFIX="${MINGW_PACKAGE_PREFIX:-mingw-w64-ucrt-x86_64}"
for pkg in libvpx dav1d libvpl amf-headers ffnvcodec-headers gcc-libs libwinpthread winpthreads crt headers; do
  pacman -Qi "$PKG_PREFIX-$pkg" >/dev/null 2>&1 || continue
  mkdir -p "$LICENSE_DIR/$pkg"
  pacman -Ql "$PKG_PREFIX-$pkg" | awk '{print $2}' | grep -E '/share/(licenses|doc)/.*[^/]$' | grep -i -E 'licen[cs]e|copying|copyright|notice|patents' |
    while read -r file; do [ -f "$file" ] && cp "$file" "$LICENSE_DIR/$pkg"/; done || true
done

fetch() { curl -fsSL "$1" -o "$2" || { echo "could not fetch $1"; exit 1; }; }
if [ -z "$(ls -A "$LICENSE_DIR/libvpx" 2>/dev/null)" ]; then
  mkdir -p "$LICENSE_DIR/libvpx"
  version="$(pacman -Q "$PKG_PREFIX-libvpx" | awk '{print $2}' | sed 's/-[0-9]*$//')"
  fetch "https://raw.githubusercontent.com/webmproject/libvpx/v$version/LICENSE" "$LICENSE_DIR/libvpx/LICENSE"
  fetch "https://raw.githubusercontent.com/webmproject/libvpx/v$version/PATENTS" "$LICENSE_DIR/libvpx/PATENTS"
fi
if [ -z "$(ls -A "$LICENSE_DIR/dav1d" 2>/dev/null)" ]; then
  mkdir -p "$LICENSE_DIR/dav1d"
  version="$(pacman -Q "$PKG_PREFIX-dav1d" | awk '{print $2}' | sed 's/-[0-9]*$//')"
  fetch "https://raw.githubusercontent.com/videolan/dav1d/$version/COPYING" "$LICENSE_DIR/dav1d/COPYING"
fi
if [ -z "$(ls -A "$LICENSE_DIR/gcc-libs" 2>/dev/null)" ]; then
  mkdir -p "$LICENSE_DIR/gcc-libs"
  fetch "https://raw.githubusercontent.com/gcc-mirror/gcc/master/COPYING.RUNTIME" "$LICENSE_DIR/gcc-libs/COPYING.RUNTIME"
  fetch "https://raw.githubusercontent.com/gcc-mirror/gcc/master/COPYING3" "$LICENSE_DIR/gcc-libs/COPYING3"
fi
for required in libvpx dav1d gcc-libs; do
  [ -n "$(ls -A "$LICENSE_DIR/$required" 2>/dev/null)" ] || { echo "no licence text for $required"; exit 1; }
done
find "$LICENSE_DIR" -type d -empty -delete
NO_LICENSE_TEXT=""
for pkg in libvpl amf-headers ffnvcodec-headers libwinpthread winpthreads crt headers; do
  if pacman -Qi "$PKG_PREFIX-$pkg" >/dev/null 2>&1 && [ ! -d "$LICENSE_DIR/$pkg" ]; then NO_LICENSE_TEXT="$NO_LICENSE_TEXT$pkg "; fi
done

# The packages and versions used, as they were on the build machine.
{
  echo "FFmpeg $VERSION"
  echo "commit $FFMPEG_COMMIT"
  echo "built from https://github.com/zburtle/Yaparr.FFmpeg${GITHUB_SHA:+ at commit $GITHUB_SHA}${GITHUB_RUN_ID:+ (workflow run $GITHUB_RUN_ID)}"
  echo
  echo "configure: $CONFIGURE_LINE"
  echo
  echo "Libraries and headers used:"
  for pkg in libvpx dav1d libvpl amf-headers ffnvcodec-headers gcc-libs libwinpthread winpthreads crt headers; do pacman -Q "$PKG_PREFIX-$pkg" 2>/dev/null || true; done
  [ -z "$NO_LICENSE_TEXT" ] || echo "Packages that carry no licence files of their own: $NO_LICENSE_TEXT"
  echo
  echo "Compiler: $(gcc --version | head -1)"
} > "$OUT/$NAME/BUILD-INFO.txt"

cat > "$OUT/$NAME/SOURCE.txt" <<EOF
This is a build of FFmpeg, made for Yaparr (https://github.com/zburtle/Yaparr), with only the parts Yaparr uses.

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later (LICENSE.txt). It is not built with any
GPL or "nonfree" part. It is FFmpeg's libraries, the DLLs in the bin folder (avcodec, avfilter, avformat, avdevice, avutil, swscale
and swresample, each with its version in its name, and the DLLs they need), which Yaparr loads into itself; there is no ffmpeg program.
They are shared libraries, kept apart from Yaparr's own program on purpose, so that they can be replaced: put DLLs of the same
versions, built from the source of this release or from another FFmpeg, in the same folder (an "ffmpeg" folder next to Yaparr,
or the folder YAPARR_FFMPEG_LIBS names).

The source code of this build, the exact commit of FFmpeg that was built, is the file ffmpeg-g${SHORT}-source.tar.xz in the
same release, and https://github.com/FFmpeg/FFmpeg/commit/${FFMPEG_COMMIT}.
The way it was configured and built is in BUILD-INFO.txt here and in the source of the build scripts
(https://github.com/zburtle/Yaparr.FFmpeg).

Built in: libvpx (BSD licence, with Google's patent grant) and dav1d, the AV1 decoder (BSD 2-clause licence). The AMF, NVIDIA codec and oneVPL headers are used to talk to the
graphics driver, which is not part of this package. Their licences are in the licenses folder.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. Yaparr is not endorsed by the FFmpeg project.
EOF

# The source of exactly what was built, for the LGPL.
git archive --format=tar --prefix="ffmpeg-g${SHORT}/" "$FFMPEG_COMMIT" | xz -9 > "$OUT/ffmpeg-g${SHORT}-source.tar.xz"

( cd "$OUT" && zip -9 -r "$NAME.zip" "$NAME" )
echo "NAME=$NAME" > "$OUT/name.txt"
echo "Built $OUT/$NAME.zip"
