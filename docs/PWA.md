# Home Screen installation

Open https://yihuan-pc.tailb2217a.ts.net:8443/igapp/ in Safari on iPhone or iPad.
Choose Share, Add to Home Screen, enable Open as Web App if offered, then Add.
The installed name is Post Studio. Installation guidance also appears in the
Flutter Settings page. This is a Web app, not a native iOS build.

Keep the first visit online while approximately 21 MiB of application assets
download. The service worker caches the Flutter shell, local CanvasKit variants,
icons and the HDR WebAssembly codec. Photos and projects remain in IndexedDB;
clearing website data removes them. Storage is not synced across devices, and
browser-to-installed-app storage migration has not been verified on iOS.

Visited Google font subsets are cached on demand. Previously unseen characters
may still need connectivity. Optional AI features require connectivity too.
Browser storage eviction can remove offline caches. HDR display depends on the
browser and device; installing the app does not change HDR support.

## Build and update

Run `./scripts/build_web.ps1` (add `-RebuildHdr` after native codec edits).
It runs Flutter and `scripts/prepare_pwa.py`, generating an asset-hashed cache
version and offline asset list. A plain `flutter build web` alone does not finish
the offline build. Python is used at build time; no application backend is added.

The new worker waits for old app windows to close before activating an update.
It does not force-refresh an active editing session. Its scope is `/igapp/`, and
only its own `post-studio-` caches are cleaned up, leaving project storage alone.

## Verification (2026-10-18)

- Flutter release build completed; 28 precached assets, 20.8 MiB.
- Verified the public manifest exposes Post Studio and standalone display.
- In a desktop Chromium browser, waited for worker activation, stopped the
  dedicated loopback test server, reloaded, and opened Settings successfully.
- Physical iPhone Home Screen installation and Safari HDR behavior remain
  unverified. Some font subsets can display placeholders until downloaded.

The Flutter Home and Settings pages include an Install app button. Browsers that provide beforeinstallprompt use the native install prompt; other browsers show manual Safari/Android/desktop instructions. The event listener loads before Flutter startup. Existing open app windows must close before a waiting service-worker update takes over. Prompt/fallback/single-use/error/installed paths were checked with a Node VM harness.
