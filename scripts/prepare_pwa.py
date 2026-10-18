"""Generate a content-versioned, scoped service worker from the actual build."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
output = root / 'build' / 'web'
paths = ['index.html', 'flutter_bootstrap.js', 'main.dart.js', 'manifest.json',
         'favicon.png', 'media.mjs', 'pwa.mjs', 'hdr/worker.mjs',
         'hdr/poststudio_hdr.mjs', 'hdr/poststudio_hdr.wasm']
for directory in ['assets', 'icons']:
    paths.extend(path.relative_to(output).as_posix() for path in (output / directory).rglob('*') if path.is_file())
for variant in ['', 'chromium/', 'webparagraph/']:
    paths.extend('canvaskit/' + variant + name for name in ['canvaskit.js', 'canvaskit.wasm'])
paths = sorted(set(paths))
digest = hashlib.sha256()
size = 0
for path in paths:
    data = (output / path).read_bytes()
    digest.update(path.encode('utf-8') + b'\0' + data)
    size += len(data)
template = (root / 'web' / 'sw.js').read_text(encoding='utf-8')
digest.update(template.encode('utf-8'))
version = digest.hexdigest()[:20]
worker = template.replace('__BUILD_VERSION__', version).replace('/*__PRECACHE__*/ []', json.dumps(paths))
assert '__BUILD_VERSION__' not in worker and '/*__PRECACHE__*/' not in worker
(output / 'sw.js').write_text(worker, encoding='utf-8')
(output / 'offline-build.json').write_text(json.dumps({'version':version,'files':len(paths),'bytes':size}), encoding='utf-8')
print(f'PWA {version}: {len(paths)} files, {size / 1024 / 1024:.1f} MiB. Scope /igapp/.')
