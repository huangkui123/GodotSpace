# PICO Cast isolated FFmpeg bundle

PICO RTMP input uses one coherent BtbN LGPL shared FFmpeg 6.1.3 build. The
wrapper and all five FFmpeg libraries use the same headers and binary release:

- `libavcodec 60.31.102`
- `libavformat 60.16.100`
- `libavutil 58.29.100`
- `libswresample 4.12.100`
- `libswscale 7.5.100`

Do not connect this `avformat` to an older same-major `avcodec` through a symbol
proxy. FFmpeg 6.1 added fields to constructor-owned public structures such as
`AVCodecParameters`; a newer library calling an older allocator is not a
supported compatibility direction and corrupts the stream-information path.

The BtbN archive is:

- Release: `autobuild-2025-08-31-13-00`
- Asset: `ffmpeg-n6.1.3-win64-lgpl-shared-6.1.zip`
- SHA-256: `b5af042081d2f7887c18894801e1d91ccb6d565ebcea0d32c0070869f5f611cc`
- Source: <https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2025-08-31-13-00>
- License: `res://addons/ffmpeg/LICENSE-ffmpeg.txt`

The GDExtension wrapper is built from
<https://github.com/IvanWoehr/godot-ffmpeg-rtsp2> at commit
`c799616195e441cc1df888d453ccc7e5e1d54896`, with
`godot_ffmpeg_pico_cast.patch` applied, against that archive's `include` and
`lib` directories. Build both `template_debug` and `template_release`.

Replace every file under the wrapper's existing `thirdparty/ffmpeg/include`,
`lib`, and `bin` directories. Do not rely on copying the top-level directories
over an existing tree: PowerShell can leave older same-named headers in place.
Before building, verify that
`include/libavcodec/codec_par.h` contains `coded_side_data` and
`nb_coded_side_data`, then force all wrapper C++ sources to rebuild. A wrapper
compiled with the older `AVCodecParameters` layout will link successfully but
fail at runtime with `AVERROR(ENOMEM)` followed by an access violation in
`avcodec-60.dll`.

`patch_pe_imports.ps1` copies the matching runtime libraries and changes the PE
import basenames without changing their byte lengths:

| Upstream name | Isolated name |
| --- | --- |
| `avcodec-60.dll` | `pxcodec-60.dll` |
| `avformat-60.dll` | `pxformat-60.dll` |
| `avutil-58.dll` | `pxutil-58.dll` |
| `swresample-4.dll` | `pxresample-4.dll` |
| `swscale-7.dll` | `pxscale-7.dll` |

This avoids collisions with another already-loaded FFmpeg build in the Godot
editor. Both wrapper DLLs and the copied FFmpeg DLLs must be processed together.
Afterward, use `dumpbin /dependents` to confirm that the wrapper and isolated
libraries reference only `px*.dll` names.

The PICO Cast URL is a live, non-seekable RTMP input. The wrapper must not run
the normal playback-start, playback-stop, or explicit seek operations against
any URL input. Do not rely on `AVIOContext.seekable`: PICO Cast may expose a
seekable input buffer even though seeking the live session invalidates later
reads. The wrapper also must not set short `rw_timeout` or `stimeout` values:
once FFmpeg records a transient read error in the input buffer, later reads
keep returning that error. Opening the stream still has an interrupt callback
so startup can be cancelled or capped without imposing a timeout on
steady-state frame reads. URL opening and stream probing must run on the
decoder worker thread; doing either operation on Godot's main thread can stall
ENet long enough for an otherwise healthy multiplayer client to be
disconnected. Keep the default demuxer buffering for URL inputs:
`AVFMT_FLAG_NOBUFFER`, `AVFMT_FLAG_DISCARD_CORRUPT`, and
`AVFMT_FLAG_NONBLOCK` can discard the first packets consumed by RTMP stream
probing or turn a temporary lack of data into a terminal decoder failure.

For live input, do not create the `ImageTexture` until the first decoded frame
arrives. The Godot-side connection monitor treats a non-null texture as proof
that video is visible, so an eagerly created transparent texture suppresses
retries after an RTMP connection that produced no frames.
