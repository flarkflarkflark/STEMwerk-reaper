# Portable FFmpeg for macOS Apple Silicon

The Apple Silicon package builds `ffmpeg` and `ffprobe` from the official FFmpeg 8.0.3
source release instead of copying Homebrew executables.

- source: <https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz>
- source SHA-256: `6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`
- upstream release signature (additional upstream provenance only): <https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz.asc>
- license: LGPL-2.1-or-later (`CONFIG_GPL=0`, `CONFIG_NONFREE=0`)
- target: thin arm64, macOS 12.0 or later

The release pipeline verifies the pinned SHA-256 above. It does not currently perform automated
GPG verification; the signature link is provided only as additional upstream provenance.

`tools/macos_ffmpeg.py` is the executable recipe. It disables dependency autodetection,
shared FFmpeg libraries, networking, and external codecs. The resulting command-line tools
retain FFmpeg's built-in file/audio demuxers, decoders, encoders, muxers, resamplers, and
filters required by STEMwerk. They dynamically reference only libraries and frameworks
shipped with macOS.

The builder records the exact configure/build commands, source checksum, binary checksums,
runtime version output, architecture, deployment target, Xcode/clang/SDK details, and complete
`otool -L` dependency inventory in
`ffmpeg/SOURCE_PROVENANCE.json`. The package audit rejects package-manager or other external
absolute dylib paths and executes both tools with `-version` under a minimal PATH.

The release builder preserves the exact verified archive as the accompanying artifact
`ffmpeg-8.0.3.tar.xz` and writes `ffmpeg-8.0.3.tar.xz.sha256`. This provides the corresponding
upstream source used by the build; final license-distribution approval remains a maintainer/legal
check. The recipe uses pinned source and auditable build inputs. It does not claim byte-identical
reproducibility across different Apple toolchains.

This source-build route is preferred over third-party prebuilt binaries because it is pinned,
reviewable, independent of a build machine's package manager, and compatible with the normal
Developer ID signing/notarization pipeline. The
individual binaries are linker/ad-hoc signed by Apple clang; release packaging may replace
that with the project's Developer ID signature before notarization.
