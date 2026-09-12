<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-m3u

An M3U and M3U8 playlist parser and writer for Zig.

Requires Zig 0.16. It reads all three layers of history in the format — the
plain `.m3u` list of file names, the extended M3U that added `#EXTM3U` and
`#EXTINF`, and HTTP Live Streaming as
[RFC 8216](https://www.rfc-editor.org/rfc/rfc8216) defines it — plus the tags
added to HLS after that RFC was published: low-latency parts, delta updates,
content steering, variable substitution. Its dependencies are
[zig-uri][zig-uri] for the URIs a playlist is made of and
[zig-datetime][zig-datetime] for the dates its tags carry.

The API documentation is generated from the doc comments, which carry most of
the explanation; `zig build docs` builds it and `zig build docs-serve` reads
it.

```zig
const m3u = @import("m3u");

var playlist = try m3u.Playlist.parse(gpa, bytes, .{});
defer playlist.deinit();

switch (playlist.body) {
    .multivariant => |mv| {
        // §6.3.1: start at the lowest bit rate unless you know better.
        const start = mv.lowestBandwidth().?;
        std.debug.print("{d} bps at {s}\n", .{ start.stream_inf.bandwidth, start.uri });
    },
    .media => |media| {
        std.debug.print("{d} segments, {d:.1}s\n", .{
            media.entries.len,
            media.totalDuration(),
        });
    },
    .basic => |entries| {
        for (entries) |entry| std.debug.print("{s}\n", .{entry.uri});
    },
}
```

## Three kinds of playlist

RFC 8216 §2 has two, and the tags of one may not appear in the other. There is
a third in practice, and `Playlist.body` is a union over all three:

| `Kind` | What it is | How it is recognised |
|---|---|---|
| `.multivariant` | A Multivariant — once Master — Playlist: variants to choose between | any §4.3.4 tag |
| `.media` | A Media Playlist: segments | any §4.3.3 tag, or any §4.3.2 Media Segment tag |
| `.basic` | A plain or extended M3U: a list of URIs with at most an `#EXTINF` apiece | none of the above |

The third one matters more than it looks. **`#EXTINF` alone does not make a
playlist a Media Playlist**, because `#EXTM3U` plus a run of `#EXTINF` lines
and their URIs is what every IPTV channel list and every music player's `.m3u`
is, and none of them is HLS. A parser that classified those as Media Playlists
would report a missing `#EXT-X-TARGETDURATION` for every one of them.

## It is lenient, and it says so

Almost no playlist in the world is strictly conformant. They arrive with byte
order marks, missing `#EXTM3U` lines, unquoted `URI` attributes, spaces after
commas, `#EXT-X-TARGETDURATION:10.0`, attributes nobody has heard of and
enumerated values that postdate whatever wrote the parser. Refusing them would
make the library useless; accepting them quietly would make it untrustworthy.

So it accepts them and writes down every one:

```zig
var diagnostics: m3u.Diagnostics = .init(gpa);
defer diagnostics.deinit();

var playlist = try m3u.Playlist.parse(gpa, bytes, .{ .diagnostics = &diagnostics });
defer playlist.deinit();

std.debug.print("{f}", .{&diagnostics});
// line 1: warning: a byte order mark, which RFC 8216 §4 forbids
// line 3: warning: a quoted-string attribute written without its quotes: URI
// line 4: warning: the tag's value is not of the type it should be: …
```

A `Problem` is either a `.warning` — understood, and not what the
specification says — or an `.invalid`, meaning something was dropped or
defaulted. `ParseOptions.strict` turns the first `.invalid` into a returned
`error.InvalidPlaylist`; warnings never fail a parse, since almost every real
playlist earns one. Passing no `Diagnostics` costs nothing: the parser checks
before it builds a message.

`strict` is about **information, not conformance**. A playlist with a byte
order mark, no `#EXTM3U`, an unquoted `URI` and a non-integer target duration
passes it, because not one of those lost anything.

## A playlist survives being rewritten

Parse a playlist, write it back out, parse that, and the two are deeply equal
— `Playlist.eql` is the comparison, and the test suite asserts it on every
playlist in `tests/playlists` and on three hundred thousand fuzzer-generated
ones on every build, with as many more as you care to wait for on demand.
Write the second one out too and the bytes are identical to the first, so
`write` is a fixed point rather than something that keeps changing the file
every time a tool touches it.

That is what makes the library safe to put in a tool that edits playlists. A
tag it has never heard of comes out the other side intact, and so does an
unknown attribute, an unknown enumerated value, a comment and a blank line:

```
#EXT-X-FUTURE-TAG:WITH=A,LIST="of, things"     → kept verbatim
#EXT-X-KEY:METHOD=AES-256-CTR,X-VENDOR=YES     → method and attribute kept
# a comment, and the blank line after it       → kept where they were found
```

It is **not** a promise about bytes. `write` normalises: tags come out in the
order the writer emits them rather than the order they were read, an unquoted
`URI` gains its quotes, a `YES`/`NO` attribute at its default is left out, and
a number is written in its shortest form — so `#EXT-X-TARGETDURATION:10.0`
comes back as `:10`. `src/Playlist.zig` says exactly what it does.

Getting this right took work, and every bug was found by the fuzzer rather
than by a test somebody thought to write:

- An `#EXTINF` whose duration could not be read kept its title, which `write`
  then had nowhere to put.
- A tag dropped because its value would not parse took the playlist's *kind*
  with it: drop an `#EXT-X-TARGETDURATION:v` and the rewritten playlist is a
  `.basic` one. Unreadable tags are now kept verbatim, and so are segment tags
  left dangling with no URI after them.
- An attribute value ending in a carriage return was written at the end of a
  line, where the next line feed swallowed it.
- A value holding a `"` cannot be written as a `quoted-string` at all, because
  §4.2 gives one no escape sequence. The parser refuses what the writer cannot
  reproduce.

## Resolving what is in a playlist

Almost every URI in a real playlist is relative: a Multivariant Playlist at
`https://example.com/hls/master.m3u8` points at `720p/index.m3u8`, and that
Media Playlist's segments are `seg00001.ts`. Resolution is RFC 3986 §5, which
is more than string concatenation, so [zig-uri][zig-uri] does it:

```zig
var base: m3u.resolve.Base = try .init(gpa, "https://example.com/hls/720p/index.m3u8");
defer base.deinit();

for (playlist.entries()) |entry| {
    const url = try base.resolveAlloc(gpa, entry.uri, .{});
    defer gpa.free(url);
    // https://example.com/hls/720p/seg00001.ts
}
```

`Base` holds the parsed playlist address so that resolving ten thousand
segments does not reparse it ten thousand times.

Note that not every entry *is* a URI. A plain `.m3u` written by a music player
holds filesystem paths, and resolving `..\Music\track.mp3` against an HTTP base
produces something that looks like a URL and is not one. `resolve.looksLikePath`
is the cheap test; the parser leaves the decision alone unless
`ParseOptions.validate_uris` asks it to check.

## What is modelled

Every tag in RFC 8216 and in the low-latency extensions that followed, with
one Zig type each in `m3u.tags`:

| | |
|---|---|
| Basic | `#EXTM3U`, `#EXT-X-VERSION` |
| Media Segment | `#EXTINF`, `#EXT-X-BYTERANGE`, `#EXT-X-DISCONTINUITY`, `#EXT-X-KEY`, `#EXT-X-MAP`, `#EXT-X-PROGRAM-DATE-TIME`, `#EXT-X-DATERANGE`, `#EXT-X-GAP`, `#EXT-X-BITRATE`, `#EXT-X-PART` |
| Media Playlist | `#EXT-X-TARGETDURATION`, `#EXT-X-MEDIA-SEQUENCE`, `#EXT-X-DISCONTINUITY-SEQUENCE`, `#EXT-X-ENDLIST`, `#EXT-X-PLAYLIST-TYPE`, `#EXT-X-I-FRAMES-ONLY`, `#EXT-X-PART-INF`, `#EXT-X-SERVER-CONTROL`, `#EXT-X-SKIP`, `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT` |
| Multivariant | `#EXT-X-MEDIA`, `#EXT-X-STREAM-INF`, `#EXT-X-I-FRAME-STREAM-INF`, `#EXT-X-SESSION-DATA`, `#EXT-X-SESSION-KEY`, `#EXT-X-CONTENT-STEERING` |
| Either | `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-START`, `#EXT-X-DEFINE` |
| Extended M3U | `#EXTGRP`, `#EXTALB`, `#EXTART`, `#EXTGENRE`, `#EXTIMG`, `#EXTBYT`, `#EXTBIN`, `#EXTENC`, `#EXTVLCOPT`, and `#PLAYLIST` |

The extended-M3U directives are recognised by name and carried through rather
than given types, which is what stops them being reported as unknown tags —
a playlist with an `#EXTALB` in it is a well-formed extended M3U.
`Entry.tagValue("EXTALB")` reads one back, and `Playlist.title()` finds the
`#PLAYLIST` directive, which does not begin `#EXT` and so is a comment to
RFC 8216 §4.1 rather than a tag.

Two conventions that are in no specification are modelled too, because every
IPTV playlist has them:

```
#EXTM3U x-tvg-url="https://example.com/guide.xml.gz"
#EXTINF:-1 tvg-id="bbc1.uk" group-title="News, Documentary",BBC One
```

Attributes on the `#EXTM3U` line, and attributes between an `#EXTINF`'s
duration and its comma — space-separated rather than comma-separated, and
quoted often enough that the comma inside `"News, Documentary"` is not the one
that ends the duration. `Entry.attributeValue("group-title")` reads them, and
`Entry.group()` answers with `#EXTGRP` if there is one and `group-title`
otherwise.

## Four grammars underneath

Each is a file of its own, usable without the rest:

- **`m3u.line`** — RFC 8216 §4.1's line syntax. What a line is, and where a
  tag's name ends: at the first byte that cannot be in one, **not** at the
  first colon. The two rules agree on every conformant tag and disagree on
  `#EXTM3U x-tvg-url="https://…"`, where splitting at the colon gives a tag
  called `EXTM3U x-tvg-url="https`.
- **`m3u.attribute`** — §4.2's attribute lists, in both the comma-separated
  form the specification defines and the space-separated form IPTV playlists
  use, with a decoder for each of the seven value types. A `quoted-string` may
  hold commas, so the list cannot be split on the comma without knowing where
  the quotes are.
- **`m3u.time`** — the ISO 8601 dates `#EXT-X-PROGRAM-DATE-TIME` and
  `#EXT-X-DATERANGE` carry. [zig-datetime][zig-datetime] does the grammar,
  the calendar, the range checking and the instants; this is the thin layer
  that adds the two things a *playlist* needs and a date value has no reason
  to carry — how the offset was spelled, since `Z` and `+00:00` mean the same
  instant and are not the same six characters, and how many digits the
  fraction was written with, since `...:23Z`, `...:23.0Z` and `...:23.000Z`
  are three spellings of one time. Without them a tool asked to change one
  tag would rewrite every date in the file into a different notation.
- **`m3u.tags`** — a type per tag, with the attribute tables that drive both
  reading and writing.

## The command line tool

It exists to show what the library looks like from outside, to check a
playlist without writing a program, and to be what a round-trip bug is reduced
with.

```console
$ zig-m3u show master.m3u8
multivariant playlist, version 7
3 renditions
  AUDIO group aac name English [en] default
  AUDIO group aac name Français [fr]
  SUBTITLES group subs name English [en] -> subs/en.m3u8
3 variants
  800000 bps 640x360 [avc1.4d401e,mp4a.40.2] -> 360p/index.m3u8
  2400000 bps 1280x720 [avc1.640020,mp4a.40.2] -> 720p/index.m3u8
  100000 bps 640x360 [avc1.4d401e] I-frame only -> 360p/iframe.m3u8

$ zig-m3u check *.m3u8            # what is not conformant
$ zig-m3u normalise index.m3u8    # parse and write back out
$ zig-m3u urls index.m3u8 --base https://example.com/hls/index.m3u8
https://example.com/hls/720p/init.mp4
https://example.com/hls/720p/seg00001.ts
```

`check` prints every problem and exits 1 only when one of them lost
information, so it is usable in a pipeline: a playlist that is merely
unconformant — which nearly every real playlist is, and which includes the
`#EXT-X-DATERANGE` in RFC 8216's own §8.10 example — exits 0. `--strict`
makes it exit 1 for those too. `urls` lists things in the order a player would
fetch them, each segment's initialisation section before the segments that use
it.

## Using it

Add it to `build.zig.zon`:

```console
$ zig fetch --save=m3u git+https://git.jcollie.dev/jeff/zig-m3u.git
```

and in `build.zig`:

```zig
const m3u = b.dependency("m3u", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("m3u", m3u.module("m3u"));
```

Two dependencies, both fetched by the Zig build system: [zig-uri][zig-uri]
for the URIs and [zig-datetime][zig-datetime] for the dates. Nothing else is
needed to build the library; the flake's devshell is for the tooling around
it.

`build.zig.zon.nix` is the same dependency set for Nix, which has no network,
and is generated rather than written:

```console
$ nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
```

Regenerating it is the whole of adding, removing or updating a dependency. It
includes zig-datetime's *lazy* dependencies — the IANA timezone database, the
Unicode CLDR — which nothing here asks for and which therefore cost the Nix
build some download and nothing else.

## Building and testing

```console
$ nix develop                          # zig, zon2nix, reuse, git-pages-cli, ffmpeg
$ zig build test --summary all         # every test
$ zig build                            # the command line tool
$ zig build check                      # compile what the tests do not
$ zig fmt --check .
$ reuse lint
```

The test suite is in four parts. The unit tests live beside the code they
test, one `test` block per claim. `tests/playlists.zig` reads the playlists in
`tests/playlists` — the examples from RFC 8216 §8 copied out of the RFC, plus
a file per feature the RFC's examples do not cover and a few that are
deliberately malformed — applies the round-trip property to every one of them
whatever it is, and then asserts what is actually in each. `tests/fuzz.zig`
holds the properties. And `nix flake check` runs the one test that is not this
library checking its own work:

```console
$ nix flake check --print-build-logs
```

ffmpeg writes a real HLS stream, segments and all; this library parses its
playlist and writes it back out; and ffprobe decodes the media *through the
rewritten playlist*. Everything else above would be satisfied by a writer that
emitted a format only this parser could read — this would not.

### Fuzzing

**Zig 0.16.0 cannot build a test executable in fuzz mode**, so `zig build fuzz
--fuzz` fails to compile for any project with a fuzz test in it: the compiler's
own `test_runner.zig` hands an error return trace to a function that takes a
different type of stack trace. `flake.nix` patches that one line in a symlink
farm of the standard library, which buys the fuzzer — and not its coverage,
because nothing in this release populates the table of program counters, so a
bounded run ends with `pcs_len was zero` and an unbounded one panics in the
build runner's coverage thread.

So there is a loop of our own instead, in `tools/fuzz.zig`. What it has in
place of coverage feedback is a corpus of real playlists to mutate, which is
enough: it found every round-trip bug listed above.

```console
$ zig build fuzz-run                                     # a minute of each target
$ zig build fuzz-run -- --seconds 600 --target playlists
$ zig build fuzz-run -- --seed 12345                     # exactly again
$ zig build fuzz-run -- --input fuzz-findings/x.bin --target playlists
```

A finding is written to `fuzz-findings/` along with the input that caused it,
and `--input` runs that input again. The same properties run as ordinary tests
under `zig build test`, on the seeds checked in beside them.

### API documentation

```console
$ zig build docs                       # into zig-out/docs
$ zig build docs-serve                 # and read it at http://127.0.0.1:8000
```

It has to be served rather than opened: the viewer Zig emits is a WebAssembly
program that fetches `sources.tar` and `main.wasm` at runtime, and a browser
refuses either from a `file://` page.

## Where this lives

```console
$ git clone https://git.jcollie.dev/jeff/zig-m3u.git
```

which is the canonical home, and what `REUSE.toml` and `package.nix` record.

## Licence

MIT. See `LICENSES/MIT.txt`. The project follows the
[REUSE](https://reuse.software/) specification and `reuse lint` passes.

[zig-uri]: https://git.jcollie.dev/jeff/zig-uri
[zig-datetime]: https://git.jcollie.dev/jeff/zig-datetime
