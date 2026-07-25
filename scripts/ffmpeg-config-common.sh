# shellcheck shell=bash
# Single source of truth for the *minimal* FFmpeg that Tango needs.
#
# Tango never links libav*; it ships a standalone `ffmpeg` binary next
# to the app and shells out to it (encoder-facade/src/backend/ffmpeg).
# This file pins the upstream versions and the exact set of components
# that binary must contain -- and nothing else: we start from
# `--disable-everything` and re-enable one feature at a time, each traced
# back to the Tango code path that needs it.

# Upstream versions.
#   FFMPEG_VERSION: the ffmpeg release to build. Intentionally left unset
#   here -- the CI workflow resolves the newest release and passes it in,
#   and build-ffmpeg.sh falls back to scripts/latest-ffmpeg-version.sh when
#   it is empty, so "no value" means "build the latest release".
#   X264_REF: x264 ships no real release tags; `stable` is the recommended
#   branch. Override with a commit SHA to pin for reproducibility.
: "${X264_REF:=stable}"
export X264_REF

# ---------------------------------------------------------------------------
# What Tango actually runs
#
# One ffmpeg child per stream, each reading raw data on stdin and writing
# a fragmented MP4 carrying that one stream on stdout:
#
#   ffmpeg -f rawvideo -pixel_format rgba -video_size WxH -framerate T/D \
#          -i pipe: -c:v libx264 -vf scale=...,format=yuv420p,setparams=... \
#          -crf 18 -bf 0 -g 30 -video_track_timescale T \
#          -movflags empty_moov+default_base_moof -frag_duration 250000 \
#          -f mp4 pipe:1
#
# ffmpeg is *only* an encoder here. It never writes the file the user
# gets: encoder-facade reads those fragments back with mp4-atom and
# assembles the real container -- MP4 or Matroska, with chapters, cues
# and colour tags -- in Rust. So there is no stream-copy step, no
# intermediate file, and nothing is ever demuxed.
#
# Why each component is enabled:
#
#   Encoders
#     libx264      scaled export    "-c:v libx264 ..."       (H264Quality::Crf)
#     libx264rgb   lossless export  "-c:v libx264rgb -qp 0"  (H264Quality::Lossless)
#     aac          lossy audio      "-c:a aac -b:a 384k"
#     flac         lossless audio   "-c:a flac"
#   Decoders (decode the raw streams the emulator pipes in)
#     rawvideo     "-f rawvideo -pixel_format rgba -i pipe:"
#     pcm_s16le    "-f s16le -ar 48k -ac 2 -i pipe:"
#   Demuxers
#     rawvideo     video input   (-f rawvideo)
#     pcm_s16le    audio input   (-f s16le -> the "s16le" demuxer)
#   Muxers
#     mov,mp4      the fragmented-MP4 transport every child writes. The
#                  mp4 muxer *is* movenc, so mov comes with it either way.
#   Parsers
#     av1          not driven by anything here; the object gets linked in
#                  regardless on some platforms, so it is declared rather
#                  than left to break the link.
#   BSFs
#     extract_extradata   movenc attaches this to an H.264 track to lift
#                         the parameter sets into the avcC that
#                         encoder-facade reads the codec configuration
#                         out of.
#   Filters
#     scale        "-vf scale=...:flags=neighbor", and the automatic
#                  rgba->gbrp conversion libx264rgb needs
#     format       "format=yuv420p"
#     setparams    the colour tags ("setparams=range=pc:colorspace=bt709:...")
#                  that keep an export from looking more saturated than
#                  the emulator did
#     aresample/aformat/null/anull   auto-inserted pixel/sample-format
#                  negotiation
#   Protocols
#     pipe         "-i pipe:" and "-f mp4 pipe:1" -- the only I/O a child
#                  does. Nothing reaches the filesystem through ffmpeg,
#                  so the `file` protocol is not built.
#
# The side-by-side ("twosided") export is composited in Rust and piped as
# one double-width rawvideo stream, so no hstack/overlay filter is needed.
# The ffmpeg CLI's filtergraph plumbing (buffer/buffersink/abuffer/
# abuffersink/fps/...) is auto-selected by `--enable-ffmpeg`.
# ---------------------------------------------------------------------------

ffmpeg_component_flags() {
  cat <<'FLAGS'
--disable-everything
--enable-gpl
--enable-libx264
--enable-encoder=libx264,libx264rgb,aac,flac
--enable-decoder=rawvideo,pcm_s16le
--enable-demuxer=rawvideo,pcm_s16le
--enable-muxer=mov,mp4
--enable-parser=av1
--enable-bsf=extract_extradata
--enable-filter=scale,format,null,aresample,aformat,anull,setparams
--enable-protocol=pipe
FLAGS
}

# Build-shape flags shared by every platform: a single static `ffmpeg`
# executable, no ffplay/ffprobe, no docs/network/devices, size-optimised.
ffmpeg_shape_flags() {
  cat <<'FLAGS'
--enable-static
--disable-shared
--enable-small
--disable-autodetect
--disable-debug
--disable-doc
--disable-network
--disable-avdevice
--disable-devices
--disable-ffplay
--disable-ffprobe
--enable-ffmpeg
FLAGS
}
