import createCore from './poststudio_hdr.mjs';

const ready = createCore();
let core;
function checked(value) {
  if (!value) throw new Error(core.UTF8ToString(core._ps_error()) || 'Image processing failed');
  return value;
}
function copyIn(bytes) {
  const pointer = checked(core._malloc(bytes.byteLength));
  core.HEAPU8.set(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength), pointer);
  return pointer;
}
async function decode(bytes, maxSide = 0) {
  const pointer = copyIn(bytes);
  try {
    if (core._ps_is_hdr(pointer, bytes.length)) return checked(core._ps_decode(pointer, bytes.length, maxSide));
  } finally { core._free(pointer); }
  const bitmap = await createImageBitmap(new Blob([bytes]));
  try {
    const scale = maxSide ? Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height)) : 1;
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    if (width * height > 16777216 || Math.max(width, height) > 8192) throw new Error('Image exceeds the 16 megapixel working limit.');
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext('2d', { colorSpace: 'srgb', willReadFrequently: true });
    context.drawImage(bitmap, 0, 0, width, height);
    const rgba = context.getImageData(0, 0, width, height).data;
    const p = copyIn(rgba);
    try { return checked(core._ps_rgba(p, width, height)); }
    finally { core._free(p); }
  } finally { bitmap.close(); }
}
function adjust(handle, options, enhanced = false) {
  let pointer = 0;
  try {
    if (options.colorMatrix?.length === 20) pointer = copyIn(new Float32Array(options.colorMatrix));
    core._ps_adjust(handle, pointer, options.highlights || 0, options.shadows || 0,
      options.hdrBrightness ?? 1, enhanced ? 1 : 0);
  } finally { if (pointer) core._free(pointer); }
}
function encode(handle, hdr, preview = false) {
  checked((preview ? core._ps_encode_preview : core._ps_encode)(handle, hdr ? 1 : 0));
  const pointer = core._ps_data(handle), length = core._ps_size(handle);
  return core.HEAPU8.slice(pointer, pointer + length);
}
// Retain at most two megapixels (~40 MB) of pristine decoded previews.
// Adjust a clone so slider changes never accumulate destructive edits.
const decodedPreviews = new Map();
let decodedPixels = 0;
function clearPreviews() {
  for (const entry of decodedPreviews.values()) core._ps_destroy(entry.handle);
  decodedPreviews.clear(); decodedPixels = 0;
}
async function previewSource(payload) {
  const key = `${payload.sourceKey || ''}:${payload.maxSide || 1024}`;
  if (payload.sourceKey && decodedPreviews.has(key)) {
    const entry = decodedPreviews.get(key); decodedPreviews.delete(key); decodedPreviews.set(key, entry);
    return checked(core._ps_clone(entry.handle));
  }
  const handle = await decode(payload.bytes, payload.maxSide || 1024);
  if (!payload.sourceKey) return handle;
  const pixels = core._ps_width(handle) * core._ps_height(handle);
  while (decodedPreviews.size && decodedPixels + pixels > 2097152) {
    const oldest = decodedPreviews.keys().next().value, entry = decodedPreviews.get(oldest);
    core._ps_destroy(entry.handle); decodedPixels -= entry.pixels; decodedPreviews.delete(oldest);
  }
  if (pixels > 2097152) return handle;
  decodedPreviews.set(key, { handle, pixels }); decodedPixels += pixels;
  return checked(core._ps_clone(handle));
}
function crop(sourceWidth, sourceHeight, frameAspect, x, y, scale) {
  const imageAspect = sourceWidth / sourceHeight;
  let width = Math.max(frameAspect, imageAspect) * Math.max(1, scale);
  let height = width / imageAspect;
  const left = Math.min(0, Math.max(frameAspect - width, (frameAspect - width) / 2 + x * frameAspect));
  const top = Math.min(0, Math.max(1 - height, (1 - height) / 2 + y));
  const sx = Math.round(-left / width * sourceWidth);
  const sy = Math.round(-top / height * sourceHeight);
  return [sx, sy, Math.max(1, Math.min(sourceWidth - sx, Math.round(frameAspect / width * sourceWidth))),
    Math.max(1, Math.min(sourceHeight - sy, Math.round(1 / height * sourceHeight)))];
}
async function render(payload) {
  const index = payload.targetPageIndex, page = payload.pages[index];
  const width = payload.exportWidth, height = Math.round(width * page.aspectHeight / page.aspectWidth);
  const hdr = payload.hdrMode !== 'off';
  const dest = checked(core._ps_page(width, height, page.backgroundColor >>> 0, hdr && page.backgroundHdr ? 2 : 1));
  try {
    for (const element of payload.elements) {
      if (!element.allowCrossPage && element.anchorPageIndex !== index) continue;
      const dx = Math.round((element.x - index) * width), dy = Math.round(element.y * height);
      const dw = Math.max(1, Math.round(element.width * width));
      if (dx >= width || dx + dw <= 0) continue;
      let source;
      if (element.type === 'text') {
        if (!element.rgba) continue;
        const pointer = copyIn(element.rgba);
        try { source = checked(core._ps_rgba(pointer, element.rasterWidth, element.rasterHeight)); }
        finally { core._free(pointer); }
        try { core._ps_draw(dest, source, dx, dy, element.rasterWidth, element.rasterHeight,
          0, 0, element.rasterWidth, element.rasterHeight, 0); }
        finally { core._ps_destroy(source); }
        continue;
      }
      if (element.type !== 'image') continue;
      const bytes = payload.images[element.src];
      if (!bytes) throw new Error('An image required for export is missing.');
      source = await decode(bytes, 4096);
      try {
        adjust(source, element, hdr && payload.hdrMode === 'enhanced');
        const sw = core._ps_width(source), sh = core._ps_height(source);
        const aspect = element.aspectRatio > 0 ? element.aspectRatio : sw / sh;
        const dh = Math.max(1, Math.round(dw / aspect));
        const rect = crop(sw, sh, aspect, element.cropOffsetX || 0, element.cropOffsetY || 0, element.cropScale || 1);
        core._ps_draw(dest, source, dx, dy, dw, dh, ...rect, (element.borderRadiusRatio || 0) * Math.min(dw, dh));
      } finally { core._ps_destroy(source); }
    }
    return encode(dest, hdr);
  } finally { core._ps_destroy(dest); }
}
async function process(op, payload) {
  core = await ready;
  if (op === 'ready') return true;
  if (op === 'inspect') {
    const pointer = copyIn(payload.bytes);
    try { return !!core._ps_is_hdr(pointer, payload.bytes.length); }
    finally { core._free(pointer); }
  }
  if (op === 'render') { clearPreviews(); return render(payload); }
  if (op === 'warmPreview') {
    const source = await previewSource(payload); core._ps_destroy(source); return true;
  }
  if (op === 'preview') {
    const source = await previewSource(payload);
    try { adjust(source, payload); return encode(source, payload.hdrView !== false, true); }
    finally { core._ps_destroy(source); }
  }
  throw new Error(`Unknown image operation: ${op}`);
}
// Serial jobs keep native heap usage bounded even while several views load.
let queue = Promise.resolve();
self.onmessage = ({ data: { id, op, payload } }) => {
  queue = queue.then(async () => {
    try {
      const result = await process(op, payload);
      self.postMessage({ id, result }, result instanceof Uint8Array ? [result.buffer] : []);
    } catch (error) { self.postMessage({ id, error: String(error.message || error) }); }
  });
};
