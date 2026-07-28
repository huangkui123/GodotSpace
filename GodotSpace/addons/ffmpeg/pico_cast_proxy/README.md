# PICO Cast FFmpeg compatibility proxy

The project keeps its existing compact FFmpeg 6 codec libraries. PICO RTMP
input uses BtbN's LGPL shared FFmpeg 6.1.3 `avformat-60.dll`, renamed to
`pvformat-60.dll` so a running Godot editor cannot bind the old non-network
library by mistake.

The debug GDExtension wrapper is built from
<https://github.com/IvanWoehr/godot-ffmpeg-rtsp2> at commit
`c799616195e441cc1df888d453ccc7e5e1d54896`, with
`godot_ffmpeg_pico_cast.patch` applied. The patch keeps the interrupt callback
active while stream metadata is read, removes an RTMP-incompatible generic
`timeout` option, avoids logging short-lived cast URLs, and removes a dead
per-frame sync diagnostic that flooded the Godot console. Its MIT license is
stored at `res://addons/ffmpeg/LICENSE-godot-ffmpeg.txt`.

The BtbN archive is:

- Release: `autobuild-2025-08-31-13-00`
- Asset: `ffmpeg-n6.1.3-win64-lgpl-shared-6.1.zip`
- SHA-256: `b5af042081d2f7887c18894801e1d91ccb6d565ebcea0d32c0070869f5f611cc`
- Source: <https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2025-08-31-13-00>
- License: `res://addons/ffmpeg/LICENSE-ffmpeg.txt`

`pvcodec-60.dll` forwards the codec API required by `pvformat-60.dll` to the
existing `avcodec-60.dll`. It backports three same-major packet side-data
helpers from FFmpeg 6.1 and deliberately rejects the unrelated FITS demuxer's
two private entry points.

Build the proxy from a Visual Studio developer PowerShell:

```powershell
cl /nologo /LD /O2 /std:c++17 pvcodec_proxy.cpp `
  /link /OUT:..\win64\pvcodec-60.dll
```

The wrapper GDExtension's import name is patched from `avformat-60.dll` to
`pvformat-60.dll` after compiling it. Both names have the same byte length, so
the PE import table layout is unchanged.
