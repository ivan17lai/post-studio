"""Serve only Flutter's compiled output on loopback (suitable for Tailscale Funnel)."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
import argparse

ROOT = Path(__file__).resolve().parents[1] / 'build' / 'web'

class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      '.mjs': 'text/javascript', '.wasm': 'application/wasm'}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == '/igapp':
            self.send_response(308)
            self.send_header('Location', '/igapp/')
            self.end_headers()
            return
        if path.startswith('/igapp/'):
            self.path = self.path[len('/igapp'):]
        # No directory listing, dot files, or paths outside the compiled build.
        decoded = unquote(urlsplit(self.path).path)
        if any(part.startswith('.') for part in decoded.split('/') if part):
            self.send_error(404)
            return
        super().do_GET()

    def do_HEAD(self):
        if self.path.startswith('/igapp/'):
            self.path = self.path[len('/igapp'):]
        super().do_HEAD()

    def list_directory(self, path):
        self.send_error(404)
        return None

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def log_message(self, *_):
        pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8798)
    args = parser.parse_args()
    if not (ROOT / 'index.html').is_file():
        raise SystemExit('Run flutter build web --release --base-href /igapp/ first.')
    print(f'Serving {ROOT} at http://127.0.0.1:{args.port}/igapp/', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
