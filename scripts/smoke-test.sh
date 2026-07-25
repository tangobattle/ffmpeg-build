#!/usr/bin/env bash
# Exercise *exactly* the ffmpeg pipeline Tango drives (see
# encoder-facade/src/backend/ffmpeg) so a build that is missing any
# enabled component fails here instead of in users' replay exports.
#
# Tango runs one child per stream: raw frames or samples in on stdin, a
# fragmented MP4 carrying that one stream out on stdout. It never asks
# ffmpeg to write a file, to demux anything, or to copy a stream -- the
# container the user gets is assembled in Rust from the fragments these
# commands produce. So every command below is pipe-in, pipe-out, and
# what's checked is that the fragments are there to read back.
#
# Usage: smoke-test.sh /path/to/ffmpeg[.exe]
set -euo pipefail
# Box names are matched in the binary output; keep the tools bytewise.
export LC_ALL=C

[ $# -ge 1 ] || { echo "usage: $0 /path/to/ffmpeg" >&2; exit 2; }

# Absolutise the binary path before we cd into the scratch dir. Using a
# real (Windows-native under MSYS2) cwd + relative data filenames avoids
# any MSYS path-translation surprises when the native exe opens files.
FF="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

W=240; H=160                 # GBA screen (doubled to 480 for two-sided)
TIMESCALE=16777216           # exact GBA frame clock Tango passes...
FRAME_DURATION=280896        # ...as a timebase, not a rounded rate
FRAGMENT=250000              # -frag_duration, in microseconds
# The colour tags the scaled path carries, verbatim from
# `yuv_filter_chain` in encoder-facade.
SCALED_VF="scale=iw*2:ih*2:flags=neighbor:out_range=pc:out_color_matrix=bt709"
SCALED_VF="$SCALED_VF,format=yuv420p,setparams=range=pc:colorspace=bt709"
SCALED_VF="$SCALED_VF:color_primaries=bt709:color_trc=iec61966-2-1"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

echo "== $("$FF" -hide_banner -version | head -n1) =="

# A second of each: 60 RGBA frames of zeros, and 48000 stereo s16le
# frames of silence. A second is the point -- at 250 ms a fragment, it
# takes more than one, which is what proves the stream is being cut on a
# clock rather than held whole until the end.
dd if=/dev/zero of=frames.rgba bs=$((W * H * 4)) count=60 status=none
dd if=/dev/zero of=audio.s16le bs=192000 count=1 status=none

# Tango checks for this muxer by name before it spawns anything, and
# refuses to start an export if a build hasn't got it.
"$FF" -hide_banner -muxers | grep -qE '^ *E +mp4 ' || {
  echo "FAIL: this build does not list the mp4 muxer" >&2; exit 1
}

# Run one encoder child the way Tango runs it: input on stdin, fragmented
# MP4 on stdout, nothing touching the filesystem.
encode() {
  local name="$1" input="$2"; shift 2
  echo "+ ffmpeg $* -movflags empty_moov+default_base_moof -frag_duration $FRAGMENT -f mp4 pipe:1 > $name"
  "$FF" -y -hide_banner -loglevel error -nostdin "$@" \
    -movflags empty_moov+default_base_moof -frag_duration "$FRAGMENT" \
    -f mp4 pipe:1 < "$input" > "$name"
}

# What the reader on the other end needs to find: the track description
# up front, then a fragment per slice of media.
check() {
  local name="$1" box fragments
  [ -s "$name" ] || { echo "FAIL: $name is missing or empty" >&2; exit 1; }
  for box in ftyp moov moof mdat; do
    grep -aqF "$box" "$name" || { echo "FAIL: $name carries no $box box" >&2; exit 1; }
  done
  fragments="$(grep -aoF moof "$name" | wc -l | tr -d ' ')"
  [ "$fragments" -ge 2 ] || {
    echo "FAIL: $name has $fragments fragment(s); -frag_duration did not cut the stream" >&2
    exit 1
  }
  printf 'ok  %-14s %9s bytes, %s fragments\n' "$name" "$(wc -c < "$name" | tr -d ' ')" "$fragments"
}

VIDEO_IN=(-f rawvideo -pixel_format rgba -video_size "${W}x${H}"
          -framerate "$TIMESCALE/$FRAME_DURATION" -i pipe:)
AUDIO_IN=(-f s16le -ar 48000 -ac 2 -i pipe:)

# 1) Lossless video (H264Quality::Lossless): RGB in, RGB out, no
#    conversion. Encoded at native size, which is the only size the
#    lossless preset offers.
encode v_lossless.mp4 frames.rgba "${VIDEO_IN[@]}" \
  -c:v libx264rgb -preset ultrafast -qp 0 -bf 0 -g 30 \
  -video_track_timescale "$TIMESCALE"

# 2) Scaled video (H264Quality::Crf): nearest-neighbour upscale, 4:2:0,
#    and the colour tags that go with it.
encode v_scaled.mp4 frames.rgba "${VIDEO_IN[@]}" \
  -c:v libx264 -vf "$SCALED_VF" -crf 18 -bf 0 -g 30 \
  -video_track_timescale "$TIMESCALE"

# 3) AAC audio (lossy export)   4) FLAC audio (lossless export)
encode a_aac.mp4 audio.s16le "${AUDIO_IN[@]}" -c:a aac -b:a 384000 -ar 48000 -ac 2
encode a_flac.mp4 audio.s16le "${AUDIO_IN[@]}" -c:a flac -ar 48000 -ac 2

for f in v_lossless.mp4 v_scaled.mp4 a_aac.mp4 a_flac.mp4; do
  check "$f"
done

# The video timebase has to survive the encoder exactly: Tango reads a
# frame's duration out of the fragments and expects whole GBA ticks, so a
# track written in some other timescale would be silently out of sync.
# mdhd states it, 20 bytes into the box (version 0: 4 of version+flags, 8
# of times).
for f in v_lossless.mp4 v_scaled.mp4; do
  at="$(grep -aobF mdhd "$f" | head -n1 | cut -d: -f1)"
  [ -n "$at" ] || { echo "FAIL: $f carries no mdhd box" >&2; exit 1; }
  # Byte by byte, since only GNU od can be told an endianness.
  hex="$(dd if="$f" bs=1 skip=$((at + 16)) count=4 status=none | od -An -tx1 | tr -d ' \n')"
  got=$((16#$hex))
  [ "$got" = "$TIMESCALE" ] || {
    echo "FAIL: $f is timed in $got ticks per second, not $TIMESCALE" >&2; exit 1
  }
  printf 'ok  %-14s timescale %s\n' "$f" "$got"
done

echo "SMOKE TEST PASSED"
