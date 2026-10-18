let worker, sequence = 0;
const pending = new Map();
function imageJob(op, payload = {}) {
  if (!worker) {
    worker = new Worker(new URL('./hdr/worker.mjs', import.meta.url), { type: 'module' });
    worker.onmessage = ({ data }) => {
      const request = pending.get(data.id);
      if (!request) return;
      pending.delete(data.id);
      clearTimeout(request.timer);
      data.error ? request.reject(new Error(data.error)) : request.resolve(data.result);
    };
    worker.onerror = (event) => {
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error(event.message || 'Image worker failed')); }
      pending.clear(); worker.terminate(); worker = null;
    };
  }
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Image processing timed out')); }, 180000);
    pending.set(id, { resolve, reject, timer });
    worker.postMessage({ id, op, payload });
  });
}
const database = new Promise((resolve, reject) => {
  const request = indexedDB.open('post-studio-images', 1);
  request.onupgradeneeded = () => request.result.createObjectStore('assets');
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});
async function stored(key, value) {
  const db = await database;
  return new Promise((resolve, reject) => {
    const transaction = db.transaction('assets', value === undefined ? 'readonly' : 'readwrite');
    const request = value === undefined ? transaction.objectStore('assets').get(key) : transaction.objectStore('assets').put(value, key);
    transaction.oncomplete = () => resolve(request.result);
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error('Image storage failed'));
  });
}
const assets = new Map();
let assetBytes = 0;
function rememberAsset(path, blob) {
  const old = assets.get(path);
  if (old) assetBytes -= old.size;
  assets.delete(path); assets.set(path, blob); assetBytes += blob.size;
  while (assetBytes > 48 * 1024 * 1024 || assets.size > 32) {
    const key = assets.keys().next().value;
    assetBytes -= assets.get(key).size; assets.delete(key);
  }
  return blob;
}
async function blobFor(path) {
  if (assets.has(path)) {
    const blob = assets.get(path); assets.delete(path); assets.set(path, blob); return blob;
  }
  if (path.startsWith('asset:')) {
    const blob = await stored(path);
    if (!blob) throw new Error('This image is no longer stored in this browser.');
    return rememberAsset(path, blob);
  }
  if (!path.startsWith('blob:') && !path.startsWith('data:')) throw new Error('Invalid local image reference');
  const response = await fetch(path);
  if (!response.ok) throw new Error('Unable to read image.');
  return rememberAsset(path, await response.blob());
}
async function bytesFor(path) { return new Uint8Array(await (await blobFor(path)).arrayBuffer()); }

// Cache by pixel adjustments only: moving/cropping a surface is pure CSS.
const previews = new Map(), previewJobs = new Map(), inspections = new Map();
let previewBytes = 0;
const warmed = new Set();
let warming = false;
function warmPreview(path) {
  if (warmed.has(path) || warming || pending.size) return;
  warming = true;
  warmed.add(path);
  if (warmed.size > 32) warmed.delete(warmed.values().next().value);
  bytesFor(path).then(bytes => imageJob('warmPreview', { sourceKey: path, bytes }))
    .catch(() => warmed.delete(path)).finally(() => { warming = false; });
}
function previewKey(o) {
  return JSON.stringify([o.path, o.hdrBrightness ?? 1, o.highlights || 0, o.shadows || 0,
    o.colorMatrix || null, o.hdrView !== false]);
}
function originalPixels(o) {
  const identity = [1,0,0,0,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,0];
  return (o.hdrBrightness ?? 1) === 1 && !o.highlights && !o.shadows && o.hdrView !== false &&
    (!o.colorMatrix || (o.colorMatrix.length === 20 && o.colorMatrix.every((v,i) => v === identity[i])));
}
async function inspect(path) {
  if (!inspections.has(path)) {
    const job = bytesFor(path).then(bytes => imageJob('inspect', { bytes }));
    inspections.set(path, job);
    job.catch(() => inspections.delete(path));
    if (inspections.size > 256) inspections.delete(inspections.keys().next().value);
  }
  return inspections.get(path);
}
async function preview(o) {
  const key = previewKey(o);
  if (previews.has(key)) {
    const blob = previews.get(key); previews.delete(key); previews.set(key, blob); return blob;
  }
  if (previewJobs.has(key)) return previewJobs.get(key);
  const job = (async () => {
    const bytes = await bytesFor(o.path);
    const result = await imageJob('preview', { ...o, sourceKey: o.path, bytes });
    const blob = new Blob([result], { type: 'image/jpeg' });
    previews.set(key, blob); previewBytes += blob.size;
    while (previewBytes > 24 * 1024 * 1024 || previews.size > 32) {
      const oldest = previews.keys().next().value;
      previewBytes -= previews.get(oldest).size; previews.delete(oldest);
    }
    return blob;
  })();
  previewJobs.set(key, job);
  try { return await job; } finally { previewJobs.delete(key); }
}
function download(bytes, name, type) {
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const link = document.createElement('a');
  link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
const temporary = [];
globalThis.postStudioMedia = {
  async call(op, payload) {
    switch (op) {
      case 'read': return bytesFor(payload.path);
      case 'prepare': {
        if (payload.path.startsWith('asset:')) return { displayPath: payload.path, originalPath: payload.path, isUltraHdr: await inspect(payload.path) };
        const bytes = await bytesFor(payload.path);
        const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), v => v.toString(16).padStart(2, '0')).join('');
        const key = `asset:${hash}`;
        const blob = rememberAsset(key, new Blob([bytes]));
        await stored(key, blob);
        return { displayPath: key, originalPath: key, isUltraHdr: await inspect(key) };
      }
      case 'inspect': return inspect(payload.path);
      case 'capabilities': await imageJob('ready'); return { supportsGainmap: true, hdrDisplay: matchMedia('(dynamic-range: high)').matches };
      case 'previewFile': {
        const url = URL.createObjectURL(new Blob([payload.bytes], { type: 'image/jpeg' }));
        temporary.push(url); if (temporary.length > 24) URL.revokeObjectURL(temporary.shift());
        return url;
      }
      case 'download': download(payload.bytes, payload.name, payload.type); return true;
      case 'render': warmed.clear(); return imageJob('render', payload);
      default: throw new Error(`Unknown media operation: ${op}`);
    }
  },
  attach(element, options) {
    element.style.cssText = 'width:100%;height:100%;overflow:hidden;position:relative;pointer-events:none;';
    const image = document.createElement('img');
    image.alt = ''; image.draggable = false; image.decoding = 'async';
    image.style.cssText = 'position:absolute;pointer-events:none;max-width:none;dynamic-range-limit:no-limit;';
    const status = document.createElement('span');
    status.setAttribute('role', 'status');
    status.style.cssText = 'position:absolute;bottom:6px;right:6px;padding:4px 8px;border-radius:12px;background:#333b;color:white;font:12px system-ui;pointer-events:none;';
    element.replaceChildren(image, status);
    const chinese = navigator.language.startsWith('zh');
    let currentUrl, disposed = false, revision = 0, timer, warmTimer, busy = false, wantedKey, shownKey, sourcePath;
    const urls = new Set();
    function message(text) { status.textContent = text; status.hidden = !text; }
    function show(blob, key) {
      if (disposed) return;
      const url = URL.createObjectURL(blob); urls.add(url); currentUrl = url;
      image.onload = () => {
        for (const previous of urls) if (previous !== currentUrl) { URL.revokeObjectURL(previous); urls.delete(previous); }
        if (element.dataset.processing !== 'true') message('');
      };
      image.onerror = () => message(chinese ? '無法顯示照片' : 'Unable to display photo');
      image.src = url; shownKey = key;
    }
    function layout() {
      const w = element.clientWidth, h = element.clientHeight;
      if (!w || !h) return;
      if (!options.sourceAspectRatio) {
        image.style.width = '100%'; image.style.height = '100%'; image.style.left = '0'; image.style.top = '0';
        image.style.objectFit = options.fit || 'fill'; return;
      }
      const ratio = options.sourceAspectRatio;
      const iw = Math.max(w, h * ratio) * Math.max(1, options.cropScale || 1), ih = iw / ratio;
      image.style.width = `${iw}px`; image.style.height = `${ih}px`;
      image.style.left = `${Math.min(0, Math.max(w-iw, (w-iw)/2+(options.cropOffsetX || 0)*w))}px`;
      image.style.top = `${Math.min(0, Math.max(h-ih, (h-ih)/2+(options.cropOffsetY || 0)*h))}px`;
    }
    const observer = new ResizeObserver(layout); observer.observe(element);
    async function update() {
      if (busy || disposed || shownKey === wantedKey) return;
      busy = true;
      const next = options, key = wantedKey, version = revision;
      try {
        const blob = originalPixels(next) ? await blobFor(next.path) : await preview(next);
        if (!disposed && version === revision) {
          element.dataset.processing = 'false'; show(blob, key);
        }
      } catch (error) {
        if (!disposed && version === revision) {
          element.dataset.processing = 'false'; shownKey = key;
          message(chinese ? '預覽更新失敗，保留原圖' : 'Preview failed; keeping original');
          console.error('HDR preview:', error);
        }
      } finally {
        busy = false;
        if (!disposed && key !== wantedKey) timer = setTimeout(update, 0);
      }
    }
    function schedule(next) {
      options = next; layout();
      image.style.setProperty('dynamic-range-limit', next.hdrView === false ? 'standard' : 'no-limit');
      const key = previewKey(next);
      if (key === wantedKey) return;
      wantedKey = key; ++revision;
      clearTimeout(timer);
      element.dataset.processing = 'true';
      message(chinese ? (currentUrl ? '更新預覽…' : '載入照片…') : (currentUrl ? 'Updating preview…' : 'Loading photo…'));
      if (sourcePath !== next.path || originalPixels(next)) {
        sourcePath = next.path;
        const version = revision;
        // First paint never waits for WASM. Native browser decoding also preserves
        // the original gain map and color profile when no adjustment is required.
        blobFor(next.path).then(blob => {
          if (disposed || version !== revision) return;
          if (originalPixels(next)) element.dataset.processing = 'false';
          show(blob, originalPixels(next) ? key : undefined);
          // Prepare adjustments after the original has painted; never hold up
          // first paint, and don't enqueue work for views already disposed.
          clearTimeout(warmTimer);
          warmTimer = setTimeout(() => { if (!disposed && sourcePath === next.path) warmPreview(next.path); }, 750);
        }).catch(error => { if (!disposed) { message(chinese ? '無法讀取照片' : 'Unable to read photo'); console.error(error); } });
      }
      timer = setTimeout(update, originalPixels(next) ? 0 : 100);
    }
    schedule(options);
    return { update: schedule, dispose() { disposed = true; ++revision; clearTimeout(timer); clearTimeout(warmTimer); observer.disconnect(); for (const url of urls) URL.revokeObjectURL(url); urls.clear(); } };
  },
};
