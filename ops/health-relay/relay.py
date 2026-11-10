#!/usr/bin/env python3
"""Durable, at-least-once Apple Health relay. Logs contain metadata only."""
import hashlib
import hmac
import http.client
import logging
import os
from pathlib import Path
import secrets
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path.home() / '.local/share/health-relay'
SPOOL = ROOT / 'spool'
KEY_FILE = Path.home() / '.config/health-relay/key'
LIMIT = 64 * 1024 * 1024
DEST = 'health-box.tail1a218f.ts.net'


def sync_dir():
    fd = os.open(SPOOL, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Default HTTP logging includes untrusted request text.

    def setup(self):
        super().setup()
        self.connection.settimeout(60)

    def reply(self, status):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        self.end_headers()
        logging.info('receive status=%s', status)

    def do_HEAD(self):
        self.reply(200 if self.path in ('/apple-health', '/healthz') else 404)

    do_GET = do_HEAD

    def do_POST(self):
        if self.path != '/apple-health':
            self.reply(404)
            return
        supplied = self.headers.get_all('X-Health-Key', [])
        candidate = supplied[0] if len(supplied) == 1 else ''
        if not hmac.compare_digest(hashlib.sha256(candidate.encode()).digest(), self.server.key_digest):
            self.reply(401)
            return
        lengths = self.headers.get_all('Content-Length', [])
        if self.headers.get('Transfer-Encoding') or len(lengths) != 1:
            self.reply(411)
            return
        try:
            length = int(lengths[0])
        except ValueError:
            self.reply(400)
            return
        if length < 0 or length > LIMIT:
            self.reply(413)
            return
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(dir=SPOOL, prefix='.pending-', delete=False) as out:
                tmp = Path(out.name)
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ConnectionError()
                    out.write(chunk)
                    remaining -= len(chunk)
                out.flush()
                os.fsync(out.fileno())
            name = f'{time.time_ns():020d}-{secrets.token_hex(8)}.json'
            os.replace(tmp, SPOOL / name)
            sync_dir()
            logging.info('queued bytes=%s', length)
        except (OSError, ConnectionError):
            logging.warning('receive status=storage_or_connection_error')
            self.reply(503)
            return
        finally:
            if tmp is not None:
                tmp.unlink(missing_ok=True)
        self.reply(200)


class Server(ThreadingHTTPServer):
    def handle_error(self, *_):
        logging.warning('receive status=connection_error')


def forward_one(path, key, connection=None):
    own_connection = connection is None
    if own_connection:
        connection = http.client.HTTPSConnection(DEST, timeout=60)
    try:
        with path.open('rb') as body:
            size = path.stat().st_size
            connection.request('POST', '/apple-health', body=body, headers={
                'X-Health-Key': key, 'Content-Type': 'application/json',
                'Content-Length': str(size),
            })
            response = connection.getresponse()
            status = response.status
            # Drain the response so the next FIFO request can reuse TLS.
            while response.read(65536):
                pass
            logging.info('forward bytes=%s status=%s', size, status)
            if 200 <= status < 300:
                path.unlink()
                sync_dir()
                return True
    except (OSError, http.client.HTTPException):
        connection.close()  # reconnect on the next retry, preserving the file
        logging.warning('forward status=connection_error')
    finally:
        if own_connection:
            connection.close()
    return False


def forward(key):
    last_warning = 0
    connection = http.client.HTTPSConnection(DEST, timeout=60)
    while True:
        paths = sorted(SPOOL.glob('*.json'))
        now = time.time()
        if now - last_warning >= 86400:
            old = sum(now - p.stat().st_mtime > 30 * 86400 for p in paths)
            if old:
                logging.warning('spool status=older_than_30_days count=%s', old)
            last_warning = now
        failed = False
        for path in paths:
            # Preserve FIFO when the receiver is offline or rejects a request.
            if not forward_one(path, key, connection):
                failed = True
                break
        # New arrivals do not need an extra 30-second pause after a full pass.
        if failed or not paths:
            time.sleep(30)


def main():
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    SPOOL.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = KEY_FILE.read_text().strip()
    if not key or '\n' in key or '\r' in key:
        raise SystemExit('Invalid key file')
    if sys.argv[1:] == ['server']:
        server = Server(('127.0.0.1', 18765), Handler)
        server.key_digest = hashlib.sha256(key.encode()).digest()
        server.serve_forever()
    elif sys.argv[1:] == ['forwarder']:
        forward(key)
    else:
        raise SystemExit('Usage: relay.py server|forwarder')


if __name__ == '__main__':
    main()
