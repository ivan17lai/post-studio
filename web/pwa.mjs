let installPrompt = null;
let installed = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
window.addEventListener('beforeinstallprompt', event => {
  event.preventDefault();
  installPrompt = event;
});
window.addEventListener('appinstalled', () => {
  installed = true;
  installPrompt = null;
});
window.postStudioInstall = async () => {
  if (installed) return 'installed';
  if (!installPrompt) return 'manual';
  const prompt = installPrompt;
  installPrompt = null;
  try {
    await prompt.prompt();
    const choice = await prompt.userChoice;
    return choice.outcome;
  } catch (_) {
    return 'manual';
  }
};

export async function registerOffline() {
  if (!('serviceWorker' in navigator) || !window.isSecureContext) return;
  try {
    // A new worker waits for existing windows to close. Never reload an editor
    // automatically or activate new code over an in-progress export.
    const registration = await navigator.serviceWorker.register(new URL('sw.js', document.baseURI), {
      scope: new URL('./', document.baseURI).pathname,
      updateViaCache: 'none',
    });
    const updateState = () => {
      document.documentElement.dataset.offlineReady = String(registration.active?.state === 'activated');
    };
    updateState();
    registration.installing?.addEventListener('statechange', updateState);
    navigator.serviceWorker.addEventListener('controllerchange', updateState);
  } catch (error) {
    console.warn('Offline installation unavailable; online editor remains available.', error);
  }
}
