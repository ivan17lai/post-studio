{{flutter_js}}
{{flutter_build_config}}

const config = { canvasKitBaseUrl: new URL('canvaskit/', document.baseURI).href };
_flutter.loader.load({
  config,
  onEntrypointLoaded: async (initializer) => {
    const app = await initializer.initializeEngine(config);
    await app.runApp();
    // Do not block startup or import while installation assets are downloaded.
    import('./pwa.mjs').then(({ registerOffline }) => registerOffline()).catch(console.error);
  },
});
