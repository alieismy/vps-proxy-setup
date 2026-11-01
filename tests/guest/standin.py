#!/usr/bin/env python3
"""Target stand-in for the M1 VM tests (detailed design 9.2).

Serves target.example and other.example with TLS 1.3, h2 and HTTP/1.1 from
one certificate of the per-run test CA, each host with its own fixed body.
--mode strict routes by SNI and ignores Host and :authority; --mode cross
routes by Host or :authority, as a server that mixes virtual hosts would, so
that the cross-authority probes of target-check have something to find
(VT-81). An unknown host gets 404. --large puts the same 4 MiB in front of
every body and 32 MiB after it: the bodies differ only past the 4 MiB that
target-check reads (detailed design 5), so they compare equal if, and only
if, it stops there, and a client that stops leaves most of each body unsent.

Every TCP connection is logged as one JSON line: time, peer, SNI, ALPN and,
for each request, the protocol, the Host or :authority received, the path,
the status and whether the body was sent to the end. The authority actually
received is the evidence of DO-8.
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
PREFIX = 4 << 20  # VPS_BODY_MAX in lib/vps-proxy-setup/target.sh
LARGE = 32 << 20


def text(value):
    return value.decode('latin-1') if isinstance(value, bytes) else value


class StandIn:
    def __init__(self, args):
        self.mode = args.mode
        self.large = args.large
        # Large: the host name sits right at PREFIX, and the two names differ in
        # their first byte.
        self.bodies = {name: b'.' * PREFIX + name.encode() + b'.' * LARGE if args.large else body
                       for name, body in BODIES.items()}
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
        body = self.bodies.get(name or '')
        return (200, body) if body else (404, b'not found\n')

    @staticmethod
    def h2_body(conn, h2c, stream_id, body):
        """Send BODY in frames within the flow-control window, reading the
        client's WINDOW_UPDATE frames while the window is closed."""
        view = memoryview(body)
        while view:
            size = min(len(view), h2c.local_flow_control_window(stream_id), h2c.max_outbound_frame_size)
            if size == 0:
                conn.sendall(h2c.data_to_send())
                data = conn.recv(65535)
                if not data:
                    raise ConnectionError('closed while the flow-control window was closed')
                h2c.receive_data(data)
                continue
            h2c.send_data(stream_id, view[:size].tobytes())
            view = view[size:]
            conn.sendall(h2c.data_to_send())
        h2c.end_stream(stream_id)

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
        # Logged before the body: a client that stops reading ends the send.
        request = {'proto': 'http/1.1', 'host': host, 'path': words[1] if len(words) > 1 else '',
                   'status': status, 'complete': False}
        record['requests'].append(request)
        conn.sendall(f'HTTP/1.1 {status} {REASONS[status]}\r\nContent-Type: text/plain\r\n'
                     f'Content-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode())
        conn.sendall(body)
        request['complete'] = True

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
                    request = {'proto': 'h2', 'authority': authority, 'host': headers.get('host'),
                               'path': headers.get(':path', ''), 'status': status, 'complete': False}
                    record['requests'].append(request)
                    h2c.send_headers(event.stream_id, [(':status', str(status)), ('content-type', 'text/plain'),
                                                       ('content-length', str(len(body)))])
                    try:
                        self.h2_body(conn, h2c, event.stream_id, body)
                    except h2.exceptions.ProtocolError as e:
                        # The client reset the stream while the body was being sent.
                        record['error'] = f'h2: {e}'
                        return
                    request['complete'] = True
                elif isinstance(event, h2.events.ConnectionTerminated):
                    conn.sendall(h2c.data_to_send())
                    return
            out = h2c.data_to_send()
            if out:
                conn.sendall(out)

    def serve(self, raw, peer):
        record = {'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'mode': self.mode,
                  'peer': f'{peer[0]}:{peer[1]}', 'requests': []}
        if self.large:
            record['large'] = True
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
    parser.add_argument('--large', action='store_true',
                        help='the same 4 MiB before every body and 32 MiB after it')
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
