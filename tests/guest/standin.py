#!/usr/bin/env python3
"""Target stand-in for the M1 VM tests (detailed design 9.2).

Serves target.example and other.example with TLS 1.3, h2 and HTTP/1.1 from
one certificate of the per-run test CA, each host with its own fixed body.
--mode strict routes by SNI and ignores Host and :authority; --mode cross
routes by Host or :authority, as a server that mixes virtual hosts would, so
that the cross-authority probes of target-check have something to find
(VT-81). An unknown host gets 404.

Every TCP connection is logged as one JSON line: time, peer, SNI, ALPN and,
for each request, the protocol, the Host or :authority received, the path and
the status. The authority actually received is the evidence of DO-8.
"""
import argparse
import json
import socket
import ssl
import threading
import time

import h2.config
import h2.connection
import h2.events
import h2.exceptions

BODIES = {
    'target.example': b'stand-in target.example\n',
    'other.example': b'stand-in other.example\n',
}
REASONS = {200: 'OK', 404: 'Not Found'}


def text(value):
    return value.decode('latin-1') if isinstance(value, bytes) else value


class StandIn:
    def __init__(self, args):
        self.mode = args.mode
        self.log_path = args.log
        self.log_lock = threading.Lock()
        self.sni = {}
        self.sni_lock = threading.Lock()
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        self.ctx.load_cert_chain(args.cert, args.key)
        self.ctx.set_alpn_protocols(['h2', 'http/1.1'])
        self.ctx.sni_callback = self.on_sni

    def on_sni(self, conn, name, _ctx):
        with self.sni_lock:
            self.sni[id(conn)] = name

    def log(self, record):
        with self.log_lock, open(self.log_path, 'a', encoding='utf-8') as f:
            f.write(json.dumps(record, sort_keys=True) + '\n')

    def route(self, sni, host):
        name = sni if self.mode == 'strict' else (host or '').rsplit(':', 1)[0].lower()
        body = BODIES.get(name or '')
        return (200, body) if body else (404, b'not found\n')

    def http1(self, conn, sni, record):
        data = b''
        while b'\r\n\r\n' not in data and len(data) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
        lines = data.split(b'\r\n\r\n', 1)[0].decode('latin-1').split('\r\n')
        words = lines[0].split(' ')
        headers = {}
        for line in lines[1:]:
            key, _, value = line.partition(':')
            headers[key.strip().lower()] = value.strip()
        host = headers.get('host', '')
        status, body = self.route(sni, host)
        conn.sendall(f'HTTP/1.1 {status} {REASONS[status]}\r\nContent-Type: text/plain\r\n'
                     f'Content-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)
        record['requests'].append({'proto': 'http/1.1', 'host': host,
                                   'path': words[1] if len(words) > 1 else '', 'status': status})

    def http2(self, conn, sni, record):
        h2c = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        h2c.initiate_connection()
        conn.sendall(h2c.data_to_send())
        while True:
            data = conn.recv(65535)
            if not data:
                return
            try:
                events = h2c.receive_data(data)
            except h2.exceptions.ProtocolError as e:
                record['error'] = f'h2: {e}'
                return
            for event in events:
                if isinstance(event, h2.events.RequestReceived):
                    headers = {text(k): text(v) for k, v in event.headers}
                    authority = headers.get(':authority', '')
                    status, body = self.route(sni, authority)
                    h2c.send_headers(event.stream_id, [(':status', str(status)), ('content-type', 'text/plain'),
                                                       ('content-length', str(len(body)))])
                    h2c.send_data(event.stream_id, body, end_stream=True)
                    record['requests'].append({'proto': 'h2', 'authority': authority, 'host': headers.get('host'),
                                               'path': headers.get(':path', ''), 'status': status})
                elif isinstance(event, h2.events.ConnectionTerminated):
                    conn.sendall(h2c.data_to_send())
                    return
            out = h2c.data_to_send()
            if out:
                conn.sendall(out)

    def serve(self, raw, peer):
        record = {'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'mode': self.mode,
                  'peer': f'{peer[0]}:{peer[1]}', 'requests': []}
        conn = None
        try:
            raw.settimeout(20)
            conn = self.ctx.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            conn.do_handshake()
            with self.sni_lock:
                sni = self.sni.pop(id(conn), None)
            record.update(sni=sni, alpn=conn.selected_alpn_protocol(), tls=conn.version())
            if record['alpn'] == 'h2':
                self.http2(conn, sni, record)
            else:
                self.http1(conn, sni, record)
        except (OSError, ssl.SSLError) as e:
            record['error'] = f'{type(e).__name__}: {e}'
        finally:
            with self.sni_lock:
                record.setdefault('sni', self.sni.pop(id(conn), None) if conn else None)
            (conn or raw).close()
            self.log(record)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['strict', 'cross'], required=True)
    parser.add_argument('--listen', default='198.51.100.2')
    parser.add_argument('--port', type=int, default=443)
    parser.add_argument('--cert', required=True, help='leaf certificate followed by the test CA')
    parser.add_argument('--key', required=True)
    parser.add_argument('--log', required=True)
    args = parser.parse_args()
    server = StandIn(args)
    with socket.create_server((args.listen, args.port), backlog=64) as sock:
        server.log({'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'mode': args.mode, 'event': 'start'})
        while True:
            raw, peer = sock.accept()
            threading.Thread(target=server.serve, args=(raw, peer), daemon=True).start()


if __name__ == '__main__':
    main()
