# Frontend HDR performance verification — 2026-10-18

All image storage, decoding, adjustments, composition and JPEG/ZIP creation run
inside the browser. IndexedDB retains originals. The Python process only serves
the compiled static files; no image-processing API, upload endpoint or backend
runtime is required. `build/web` can be hosted on an ordinary static host.

## Measurements

Same Windows machine, Chromium 155, same 4000 x 3000 synthetic Ultra HDR JPEG
(8,997,481 bytes), same 360 x 270 preview and 1080 x 1440 output. Timings come
from `performance.now()` inside the browser, not automation-call wall time.
These are individual observed runs, not a statistical/device certification.

| Operation | Original | Optimized |
| --- | ---: | ---: |
| Import/hash/store/identify | 230 ms | 206 ms |
| First visible image, after import | 2651 ms | 25 ms |
| First adjustment after 4 s viewing | 2390 ms | 417 ms |
| Next adjustment | 2385 ms | 366 ms |
| 1080 HDR export | 5897 ms | 3860 ms |
| Geometry changes re-encode pixels | Yes | No |

Without background preparation, the first adjustment still took 2584 ms. The
original photo stays visible during that work. First paint uses the browser's
original-image decoder (including its original gain map/color profile), so it
does not wait for C++ re-encoding. Preview adjustments use 1024-pixel images,
JPEG quality 90 and a quarter-size gain map; downloads keep quality 100 and
full-resolution gain maps. Comparisons therefore describe different preview
strategies, not a faster implementation of identical preview encoding settings.

Raw results: `work/performance/{baseline-result,optimized-result,
optimized-warm-result,interaction-result}.json`. The benchmark source, generated
fixture script and unchanged original module snapshot are in the same folder.
No measurement above was made on the user's Xiaomi 14 Ultra, and no claim of
matching native Android performance is made. Real photographs, phone/browser,
thermal state, memory and initial network download affect timings.

## Changes

- Separate CSS geometry from image-pixel changes; keep Web platform views stable
  when cropping and skip identical Flutter updates.
- Show originals immediately; label pending adjustment work instead of showing
  an empty canvas. Restore original pixels immediately when resetting controls.
- Bound source-blob and encoded-preview LRU caches; deduplicate identical work
  across surfaces. Coalesce slider changes to one in-progress and one latest
  request per surface.
- Prepare a decoded preview after first paint when the worker is idle. Retain
  at most two megapixels of pristine decoded previews (~40 MB); adjust clones,
  and release this cache before full-page exports.
- Skip neutral per-pixel adjustments in C++; use a lighter encoder for preview
  only. Store already-compressed JPEGs directly in ZIPs without Deflate work on
  Flutter's main thread.

## Verification

- Web release build succeeds. Analyzer has the existing 14 warning/info findings
  and no errors. 16 focused Flutter rendering/export/dialog tests passed.
- WASM codec tests cover HDR/SDR round trips, odd sizes, neutral SDR overlays,
  non-destructive clones, fast-preview HDR preservation and malformed input.
- Browser interaction checks: 100 geometry updates cause no encoding; rapid
  adjustment changes produce only two preview jobs; a second surface reuses
  the cached result; reset and disposal behave correctly.
- Actual Flutter UI: imported the 12 MP JPEG, displayed it, changed highlights,
  switched tools and completed HDR export at a 412 x 915 viewport.
- Downloaded benchmark JPEG independently decoded: 1,356,249 bytes,
  1080 x 1440, Ultra HDR, peak linear red approximately 3.9863.
- Browser automation download unexpectedly took roughly 46,656 seconds despite
  its requested timeout. The file was ultimately saved. This tool latency is
  excluded from all app-performance measurements; its cause is unconfirmed.

The public static preview remains at
https://yihuan-pc.tailb2217a.ts.net:8443/igapp/ . Refresh existing tabs to replace
their old workers/modules. Work remains local; no push was performed.
