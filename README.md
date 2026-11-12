# Yaparr.FFmpeg

[Yaparr](https://github.com/zburtle/Yaparr) shares and shows screens by running FFmpeg as a separate program (see `src/Yaparr.Screen` there). This repository builds that FFmpeg with only the parts Yaparr uses, under the LGPL: a static `ffmpeg.exe` for Windows x64, and an `ffmpeg` for Linux x64 and arm64.

## What is in it

| For | Parts |
|---|---|
| AV1 on the graphics card | `av1_nvenc` (NVIDIA RTX 40 and newer), `av1_amf` (AMD RX 7000 and newer), `av1_qsv` (Intel Arc and newer); on Linux `av1_nvenc` and `av1_vaapi` |
| Viewing AV1 | `libdav1d` (dav1d, BSD 2-clause, built in), the `av1` parser and the `av1_metadata` filter that the IVF writer uses |
| VP8 in software | `libvpx` (encoder), `vp8` (decoder), the IVF container |
| H.264 on the graphics card | `h264_nvenc` (NVIDIA), `h264_amf` (AMD), `h264_qsv` (Intel) |
| Viewing H.264 | the `h264` decoder and parser, and the `h264_d3d11va`, `h264_d3d11va2`, `h264_d3d12va` and `h264_dxva2` hardware decoders (used only when the viewer or the preview of a share is asked to decode on the graphics card), and the `scale_d3d12` filter (the preview scales on the card, so that only the small picture is copied back) |
| Capture | Windows: the `gfxcapture` filter (Windows Graphics Capture), `hwdownload`, `format`, `scale`. Linux: `x11grab`, `hwupload`, `format`, `scale` |
| Linux H.264 on the graphics card | `h264_nvenc` (NVIDIA) and `h264_vaapi` (Intel and AMD, through VA-API) instead of the three Windows ones |
| Input and output | the `pipe` protocol, raw pictures (on Linux also as input: the Wayland pictures GStreamer reads), the raw H.264 stream |
| Tests only | `lavfi`, the `color` and `testsrc2` filters, the `null` muxer |

Nothing else: no GPL part (no x264, no x265), nothing "nonfree", no network, no other codec. `verify.sh` checks all of that on every build and fails if a GPL or nonfree flag, an unexpected codec, or a DLL (Windows) or shared library (Linux) that would have to be shipped with it shows up.

## Building and publishing

The `Build` workflow (`.github/workflows/build.yml`) runs `build.sh` in MSYS2 on a Windows machine, and `build-linux.sh` on Ubuntu 22.04 (x64 and arm64), then `verify.sh` on each (on Linux with a virtual X server, so a real screen capture is tried). A pull request builds and checks it; the result is an artifact of the run.

To publish a build, run the workflow by hand and give it a release tag such as `ffmpeg-4`. That creates a release holding:

- `ffmpeg-yaparr-g<commit>-win64.zip`: `bin/ffmpeg.exe`, `LICENSE.txt` (LGPL 2.1), `SOURCE.txt`, `BUILD-INFO.txt` (how it was configured, the versions of what was used) and `licenses/` (libvpx, oneVPL, AMF and NVIDIA headers, the compiler runtime);
- `ffmpeg-g<commit>-source.tar.xz`: the exact FFmpeg source it was built from;
- `ffmpeg-yaparr-g<commit>-linux-x64.zip` and `-linux-arm64.zip`: `bin/ffmpeg` and the same notices (`LICENSE.txt`, `SOURCE.txt`, `BUILD-INFO.txt`, `licenses/`: libvpx, the X11 client libraries, the NVIDIA codec headers, libva);
- `SHA256SUMS.txt`.

**The Linux program** is built on Ubuntu 22.04, so it runs on any system with glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36 and later). libvpx and the X11 client libraries (libxcb, libXau, libXdmcp) are linked in. Two things are not, on purpose: the C library, and libva (with libdrm), which finds the graphics driver for H.264 on Intel and AMD cards and has to be the computer's own, so that machine needs `libva2` installed for the program to start (desktops have it; Yaparr's `.deb` depends on it). NVIDIA's encoder library belongs to the driver and is opened when FFmpeg runs, so the program starts without it and falls back to the next encoder.

The source file is what the LGPL asks for when the binary is passed on, so it always goes up with the build.

## Using a build

1. Run the workflow with a release tag.
2. Download the zip and run the integration tests against it from a checkout of Yaparr: `set YAPARR_FFMPEG=...\bin\ffmpeg.exe` then `dotnet test tests/Yaparr.Tests --filter FfmpegIntegration`, and try `tools/Yaparr.ScreenDemo` (see `src/Yaparr.Screen/README.md` there).
3. Put the new URLs, SHA-256, sizes and the paths inside the zips into `FfmpegPackage` (`src/Yaparr.Screen/FfmpegInstaller.cs` in Yaparr: the Windows, Linux x64 and Linux arm64 packages), in a pull request there.

The builds up to `ffmpeg-3` are releases of the Yaparr repository (https://github.com/zburtle/Yaparr/releases); they stay there, because Yaparr versions already out download them from those addresses.

## Changing what is in it

Edit the `./configure` options in `build.sh` (Windows) or `build-linux.sh` (Linux) and the matching checks in `verify.sh`, and open a pull request: the build will say if something is missing. Keep to LGPL parts: anything GPL (x264, x265 and others) or "nonfree" (fdk-aac) must not go in. A different FFmpeg commit can be built by giving it to the workflow; Yaparr needs one with the `gfxcapture` fixes of 24 October 2026.
