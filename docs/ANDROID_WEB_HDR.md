# Android and Web HDR

The editor and all controls remain shared Flutter widgets. Platform adapters in
`lib/platform/` separate Android files/gallery from browser IndexedDB/downloads.
Native iOS is outside this implementation's scope. iOS can install the Web app
to its Home Screen; see [PWA installation](PWA.md).

## Image pipeline

- `native/gainmap_math.cpp` supplies gain-map normalization and synthesized
  highlight curves to Android through JNI and to Web through WebAssembly.
- Android keeps the existing `NativePageRenderer` and hybrid-composition HDR
  image view. Android's Gainmap API handles JPEG encoding and display on API 34+.
- Web runs `native/web_codec.cpp` and vendored libultrahdr 1.4.0 inside a worker.
  It decodes Ultra HDR JPEG into SDR and linear HDR planes, applies adjustments,
  crops/composites pages, then writes an Ultra HDR JPEG with XMP and ISO metadata.
  Text is rasterized with Flutter TextPainter and composited at SDR brightness.
- `HdrImageView` uses a browser-native image surface inside the Flutter layout
  so the browser can display JPEG gain maps. The surrounding UI remains Flutter.
- Single-page downloads are JPEG; multiple selected pages are one ZIP, numbered
  in the requested export order. Original passthrough retains original bytes.
- Imported browser images remain in IndexedDB on that browser/origin. This
  static deployment does not upload photos or sync projects between devices.

## Build

Prerequisites: Flutter/Dart, CMake, Ninja, Android SDK/NDK for Android, and
Emscripten 4.0.15 for Web. libultrahdr source and its licenses are included under
`native/third_party/libultrahdr-1.4.0/` from the upstream v1.4.0 release:
https://github.com/google/libultrahdr/tree/v1.4.0

Install/activate Emscripten 4.0.15 with the official emsdk:
https://github.com/emscripten-core/emsdk/tree/4.0.15
The local installation used here is `work/toolchains/emsdk-4.0.15` (ignored).
If installing elsewhere, pass its directory to `-Emsdk` below. Emscripten obtains
its libjpeg port during the first build.

```powershell
flutter pub get
./scripts/build_hdr_web.ps1
./scripts/build_web.ps1
node native/codec_test.mjs
```

Rebuild the C++ module before Flutter whenever native Web code changes. Generated
`web/hdr/poststudio_hdr.mjs` and `.wasm` are ignored. Android CMake builds the JNI
library automatically through Gradle. The JNI library uses 16 KB ELF alignment.

For the pure C++ math tests, configure `native/CMakeLists.txt` with a host C++
compiler and run CTest, or compile `gainmap_math.cpp` + `gainmap_test.cpp` with
Emscripten and run the resulting program under Node.

## Local preview and public access

```powershell
python -X utf8 scripts/serve_web.py --port 8798
tailscale funnel --bg --https=8443 --set-path=/igapp http://127.0.0.1:8798
```

Only `build/web` is served, on loopback. The public deployment is:
https://yihuan-pc.tailb2217a.ts.net:8443/igapp/

The Python server is currently running as a hidden background process. The PC,
server and Tailscale must remain running. Restart the Python server after a PC
restart. No startup task was installed. Existing Tailscale root routes and other
ports are preserved. To remove only this route:

```powershell
tailscale funnel --https=8443 --set-path=/igapp off
```

## Verification and current limits

See [Web performance verification](WEB_PERFORMANCE.md) for the subsequent
first-paint/interaction optimization, measured timings and phone-test limits.

- Flutter release Web build succeeded; focused geometry/render/dialog/export
  tests passed (105 tests).
- API 34 x86_64 emulator integration passed forward/reverse/subset export and
  HDR off/on/enhanced modes, including the shared C++ synthesis JNI path.
- C++ tests passed neutrality, brightness, highlight and transfer-function
  checks. WASM codec tests passed HDR/SDR round trips, odd dimensions, neutral
  SDR overlays, synthesized highlights and malformed-input rejection.
- Browser UI import, project persistence after reload, native image preview and
  JPEG download were exercised. The downloaded 1080 x 1440 image independently
  decoded as Ultra HDR, with peak linear brightness approximately 2.002.
- Analyzer has 14 pre-existing warning/info findings and no errors.
- Web working space is linear sRGB; out-of-gamut negative values are clipped.
  Wide-gamut fidelity is not identical to the Android native pipeline.
- Web source processing is capped at 4096 pixels on the longest side for page
  composition, preview at 1024, and working images at 16 megapixels/8192 per side.
  Very large sources/exports may still exceed browser memory. Original-byte
  passthrough is separate from these decoded-image limits.
- HDR file generation is verified. Actual HDR brightness depends on the browser,
  OS HDR setting and display; the emulator cannot verify physical HDR output.
  Dedicated 1080p/2K screen-layout checks were deferred per the request.

Work remains local on the existing branch; no commit or push was performed.
