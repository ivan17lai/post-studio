import assert from 'node:assert/strict';
import fs from 'node:fs';
import createCore from '../web/hdr/poststudio_hdr.mjs';
const m = await createCore();
const check = (value) => { assert.ok(value, m.UTF8ToString(m._ps_error())); return value; };
function encoded(image, hdr) {
  check(m._ps_encode(image, hdr));
  return m.HEAPU8.slice(m._ps_data(image), m._ps_data(image) + m._ps_size(image));
}
function copy(bytes) { const p = check(m._malloc(bytes.length)); m.HEAPU8.set(bytes, p); return p; }
for (const [w,h] of [[32,48],[31,53]]) {
  const page = check(m._ps_page(w,h,0xffffffff,2));
  const text = check(m._ps_page(8,8,0xff808080,1));
  m._ps_draw(page,text,4,4,8,8,0,0,8,8,0);
  assert.ok(m._ps_sample(page,0,0,0)>1.9);
  assert.ok(m._ps_sample(page,6,6,0)<0.23, 'SDR overlay must replace HDR below it');
  const hdr = encoded(page,1);
  const pointer=copy(hdr);
  assert.equal(m._ps_is_hdr(pointer,hdr.length),1);
  const result=check(m._ps_decode(pointer,hdr.length,0));
  assert.equal(m._ps_width(result),w); assert.equal(m._ps_height(result),h);
  assert.ok(m._ps_sample(result,0,0,0)>1.8,'HDR should survive the JPEG round trip');
  assert.ok(m._ps_sample(result,6,6,0)<0.3,'SDR text should remain SDR after round trip');
  const sdr=encoded(page,0), sp=copy(sdr);
  assert.equal(m._ps_is_hdr(sp,sdr.length),0);
  if(w===32) fs.writeFileSync(new URL('../work/verification/cpp-hdr-fixture.jpg',import.meta.url),hdr);
  m._free(pointer); m._free(sp); m._ps_destroy(page);m._ps_destroy(text);m._ps_destroy(result);
}
const bright=check(m._ps_page(24,24,0xffffffff,1));
const clone=check(m._ps_clone(bright));
m._ps_adjust(clone,0,0,0,3,0);
assert.equal(m._ps_sample(bright,12,12,0),1,'cached original must stay pristine');
check(m._ps_encode_preview(clone,1));
const previewBytes=m.HEAPU8.slice(m._ps_data(clone),m._ps_data(clone)+m._ps_size(clone));
const pp=copy(previewBytes);
assert.equal(m._ps_is_hdr(pp,previewBytes.length),1,'fast preview must retain gain map');
const previewDecoded=check(m._ps_decode(pp,previewBytes.length,0));
assert.ok(m._ps_sample(previewDecoded,12,12,0)>2.8,'fast preview preserves HDR highlights');
m._ps_destroy(previewDecoded);m._ps_destroy(clone);m._free(pp);
m._ps_adjust(bright,0,0,0,4,0);
assert.ok(m._ps_sample(bright,12,12,0)>3.9,'SDR highlight synthesis');
const bad=copy(new Uint8Array([1,2,3,4]));
assert.equal(m._ps_is_hdr(bad,4),0);
assert.equal(m._ps_decode(bad,4,0),0);
m._free(bad);m._ps_destroy(bright);
console.log('PASS: HDR/SDR encoding, odd dimensions, headroom, SDR overlays, synthesis, pristine clones, fast HDR previews and malformed input.');
