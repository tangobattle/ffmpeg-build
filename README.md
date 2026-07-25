# ffmpeg-build

Reproducible builds of a **minimal static `ffmpeg`** for [Tango](https://github.com/tangobattle).

Tango doesn't link `libav*` — it ships a standalone `ffmpeg` binary next to
the app and shells out to it to encode replay exports
(`encoder-facade/src/backend/ffmpeg`). This repo builds that binary for every
platform Tango ships on, containing **only** the codecs/muxers/filters the
exporter actually drives and nothing else (we start from
`--disable-everything` and re-enable feature by feature).

ffmpeg is only an **encoder** here. Tango runs one child per stream — raw
frames or samples in on stdin, a fragmented MP4 carrying that one stream out
on stdout — and assembles the container the user actually gets (MP4 or
Matroska, with chapters, cues and colour tags) in Rust, from those fragments.
So this build has no Matroska muxer, nothing to demux with, no stream-copy
path, and no filesystem access at all.

It replaces the previously-bundled `eugeneware/ffmpeg-static` b6.0 builds,
which carry the full kitchen-sink ffmpeg (~70 MB) when Tango uses a sliver
of it.

## Outputs

The [`build-ffmpeg`](.github/workflows/build.yaml) workflow produces:

| Artifact / release asset      | Platform       | Notes                                       |
| ----------------------------- | -------------- | ------------------------------------------- |
| `ffmpeg-linux-x86_64`         | Linux x86_64   | built on ubuntu-22.04 (glibc baseline)      |
| `ffmpeg-windows-x86_64.exe`   | Windows x86_64 | MSVC toolchain, static CRT — needs no DLLs  |
| `ffmpeg-macos-arm64`          | macOS arm64    | native, min macOS 11.0                      |
| `ffmpeg-macos-x86_64`         | macOS x86_64   | cross-compiled on the arm64 runner          |

The two macOS slices are shipped separately (not `lipo`'d here) because
Tango's `macos/build.sh` already fat-binary's them itself.

The workflow is **manual-only** — start it from the Actions tab (*Run
workflow*). It builds the **latest** FFmpeg release by default; set the
`ffmpeg_version` input (e.g. `7.1.1`) to pin a specific release.

Each run publishes its binaries (each with a `.sha256`) to a GitHub Release
tagged `ffmpeg-<version>`. The workflow creates that tag/release itself — no
tag push is involved — giving stable download URLs, e.g.:

    https://github.com/<owner>/ffmpeg-build/releases/download/ffmpeg-8.1.1/ffmpeg-linux-x86_64

They're also attached to the run as plain Artifacts for quick debugging.

## What's enabled, and why

Single source of truth: [`scripts/ffmpeg-config-common.sh`](scripts/ffmpeg-config-common.sh).
Every line is traced to a Tango code path:

| Component                          | Tango usage                                                   |
| ---------------------------------- | ------------------------------------------------------------- |
| encoder `libx264`                  | scaled export — `-c:v libx264 -vf scale=…,format=yuv420p`     |
| encoder `libx264rgb`               | lossless export — `-c:v libx264rgb -qp 0`                     |
| encoder `aac`                      | lossy-export audio — `-c:a aac -b:a 384k`                     |
| encoder `flac`                     | lossless-export audio — `-c:a flac`                            |
| decoders `rawvideo`, `pcm_s16le`   | the raw RGBA / s16le streams piped from the emulator          |
| demuxers `rawvideo`, `pcm_s16le`   | `-f rawvideo` / `-f s16le` inputs                              |
| muxers `mov`/`mp4`                  | the fragmented-MP4 transport each child writes to `pipe:1`    |
| parser `av1`                       | driven by nothing here; links in anyway on some platforms     |
| bsf `extract_extradata`            | movenc lifts H.264 parameter sets into `avcC` with it         |
| filters `scale`, `format`          | nearest-neighbour upscale + pixel-format conversion           |
| filter `setparams`                 | the sRGB/BT.709 colour tags the scaled path carries           |
| filters `aresample`/`aformat`/…    | auto-inserted s16 → fltp etc. negotiation                     |
| protocol `pipe`                    | `-i pipe:` in, `-f mp4 pipe:1` out — the only I/O a child does |
| external `libx264` (GPL)           | the H.264 encoders above (`--enable-gpl`)                     |

The side-by-side ("twosided") export is composited in Rust and piped as one
double-width rawvideo stream, so **no** `hstack`/`overlay` filter is needed.

Each child is asked for `-movflags empty_moov+default_base_moof` with a
`-frag_duration`, so its output is a `moov` describing the track followed by
a `moof`/`mdat` pair per quarter-second of media. That is what Tango reads
its packets back out of: the fragments state each sample's size, duration
and sync flag, and the `moov` carries the codec configuration — so nothing
has to be recovered by parsing a bitstream, and no stream is ever held whole
until the export ends. **Lossless** exports (libx264rgb + FLAC) land in an
`.mkv`, **scaled** ones in an `.mp4`; both containers are written by Tango,
not by this binary.

The resulting binaries are GPL (because of x264).

Each build is **smoke-tested** ([`scripts/smoke-test.sh`](scripts/smoke-test.sh))
by running Tango's exact commands — both video paths, both audio codecs,
pipe in and pipe out — and checking that what comes back is fragmented, and
that the video track kept the exact GBA timebase it was asked for. A build
missing any enabled component fails in CI rather than in a user's export.

## Versions

Each run builds the **latest** FFmpeg release by default, resolved from the
upstream git tags by `scripts/latest-ffmpeg-version.sh`. To build a specific
release, set the `ffmpeg_version` workflow input. x264 tracks its `stable`
branch (`X264_REF`); pin it to a commit SHA for fully reproducible builds.

## Building locally

```sh
# Linux/macOS (needs nasm, pkg-config, a C compiler, curl, git).
# FFMPEG_VERSION unset -> builds the latest release; set it to pin.
export PREFIX="$PWD/prefix" OUTPUT="$PWD/out/ffmpeg"
./scripts/build-x264.sh
./scripts/build-ffmpeg.sh
./scripts/smoke-test.sh ./out/ffmpeg
```

## Wiring Tango to these builds

Tango's packaging scripts currently download from `eugeneware/ffmpeg-static`.
Point them at this repo's release assets instead — same URL shape, e.g. swap
`.../eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-linux-x64` for
`.../<owner>/ffmpeg-build/releases/download/ffmpeg-<version>/ffmpeg-linux-x86_64`:

- `linux/build.sh` — replace the `ffmpeg-linux-x64` download with
  `ffmpeg-linux-x86_64`.
- `win/build.sh` — replace `ffmpeg-win32-x64` with `ffmpeg-windows-x86_64.exe`.
- `macos/build.sh` — replace the two slices with `ffmpeg-macos-arm64` and
  `ffmpeg-macos-x86_64`; its existing `lipo` step fat-binary's them as-is.

(Those edits live in the Tango repo, not here.)
