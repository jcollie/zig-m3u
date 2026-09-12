# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# Does something other than this library understand what it writes?
#
# Everything in `zig build test` is this library checking its own work, and
# the round-trip property it leans on hardest -- parse, write, parse again,
# and the two playlists are equal -- would be satisfied by a writer that
# emitted a format only this parser could read. Nothing in the test suite
# would notice.
#
# So: ffmpeg produces a real HLS stream, segments and all; this library parses
# its playlist and writes it back out; and ffprobe decodes the media *through
# the rewritten playlist*. If the output were not a playlist a player accepts,
# ffprobe would not find twelve seconds of video and audio at the end of it.
#
# It runs in the Nix sandbox because it needs no network and no guest -- just
# ffmpeg, which the flake already has.

{
  runCommand,
  ffmpeg,
  zig-m3u,
}:

runCommand "zig-m3u-ffmpeg-interop"
  {
    nativeBuildInputs = [
      ffmpeg
      zig-m3u
    ];
  }
  ''
    set -euo pipefail
    mkdir -p hls "$out"

    echo "# ffmpeg writes an HLS stream"
    # Twelve seconds in three four-second segments, fragmented MP4 so that
    # there is an `#EXT-X-MAP` in the playlist as well as `#EXTINF` lines.
    ffmpeg -hide_banner -loglevel error \
      -f lavfi -i "testsrc=size=320x180:rate=15:duration=12" \
      -f lavfi -i "sine=frequency=440:duration=12" \
      -c:v libx264 -c:a aac -g 30 \
      -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_type fmp4 \
      -master_pl_name master.m3u8 -var_stream_map "v:0,a:0" \
      hls/index.m3u8

    echo "# and this library finds nothing wrong with either playlist"
    zig-m3u check hls/master.m3u8 hls/index.m3u8

    echo "# the multivariant playlist points at the media playlist"
    zig-m3u urls hls/master.m3u8 | tee "$out/master-urls.txt"
    grep -qx 'index.m3u8' "$out/master-urls.txt"

    echo "# rewrite the media playlist through parse and write"
    zig-m3u normalise hls/index.m3u8 > hls/rewritten.m3u8
    cp hls/index.m3u8 hls/rewritten.m3u8 "$out/"

    echo "# it still names every segment and the initialisation section"
    zig-m3u urls hls/rewritten.m3u8 | tee "$out/segment-urls.txt"
    for want in init.mp4 index0.m4s index1.m4s index2.m4s; do
      grep -qx "$want" "$out/segment-urls.txt"
    done

    echo "# and ffprobe decodes the media through what we wrote"
    ffprobe -hide_banner -loglevel error \
      -show_entries format=duration,nb_streams \
      -of default=noprint_wrappers=1 \
      hls/rewritten.m3u8 > "$out/probe.txt"
    cat "$out/probe.txt"

    # Two streams, and twelve seconds of them. A playlist that had lost a
    # segment would come back as eight.
    grep -qx 'nb_streams=2' "$out/probe.txt"
    grep -qx 'duration=12.000000' "$out/probe.txt"

    echo "# writing is a fixed point: the second pass is byte-identical"
    zig-m3u normalise hls/rewritten.m3u8 > hls/twice.m3u8
    cmp hls/rewritten.m3u8 hls/twice.m3u8
  ''
