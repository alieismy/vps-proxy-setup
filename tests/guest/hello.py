#!/usr/bin/env python3
"""TLS client that reshapes its ClientHello, for VT-27 (detailed design 9.7).

OpenSSL writes the ClientHello into a memory BIO. This script sends the same
bytes in one of three shapes, then completes the handshake as usual and makes
one HTTP/1.1 request:

  records   the handshake message framed again as several TLS records: the
            first ends in the middle of the server name, the rest carry at
            most 512 bytes each;
  segments  the record as OpenSSL wrote it, in four TCP segments: the record
            header, then up to the middle of the server name, then the rest
            in two halves, with 100, 200 and 300 ms between them;
  large     the record as OpenSSL wrote it, in one send. It must carry an
            X25519MLKEM768 key share.

Record framing is not part of the handshake transcript, so a server that
reassembles records completes the handshake whatever the shape. The
certificate is verified against the system store, where the test CA is
trusted (detailed design 9.2).

Each attempt prints one JSON line: the shape, the ClientHello size and its
key-share groups, the sizes planned, the sizes sent before any error and the
gaps measured between them, the TLS version, the ALPN, the HTTP status,
whether the body is the expected one, and the error if any. The exit status is
0 only if every attempt got the body.
"""
import argparse
import json
import socket
import ssl
import sys
import time

GROUPS = {0x11ec: 'X25519MLKEM768', 0x001d: 'x25519', 0x0017: 'secp256r1', 0x0018: 'secp384r1',
          0x0019: 'secp521r1', 0x001e: 'x448', 0x0100: 'ffdhe2048'}
MLKEM = 0x11ec
GAPS = (0.1, 0.2, 0.3)


def parse_hello(record):
    """The offset of the server name in the handshake message, its length,
    and the key-share groups of a ClientHello written as one TLS record."""
    if record[0] != 0x16 or int.from_bytes(record[3:5], 'big') != len(record) - 5:
        raise ValueError('not a single handshake record')
    msg = record[5:]
    if msg[0] != 1 or int.from_bytes(msg[1:4], 'big') != len(msg) - 4:
        raise ValueError('not one whole ClientHello')
    i = 4 + 2 + 32
    i += 1 + msg[i]
    i += 2 + int.from_bytes(msg[i:i + 2], 'big')
    i += 1 + msg[i]
    end = i + 2 + int.from_bytes(msg[i:i + 2], 'big')
    i += 2
    name_at = name_len = None
    groups = []
    while i < end:
        ext, size = int.from_bytes(msg[i:i + 2], 'big'), int.from_bytes(msg[i + 2:i + 4], 'big')
        data = i + 4
        if ext == 0:  # server_name: list length, name type, name length, name
            name_at, name_len = data + 5, int.from_bytes(msg[data + 3:data + 5], 'big')
        elif ext == 51:  # key_share: list length, then group, length, key
            j = data + 2
            while j < data + size:
                groups.append(int.from_bytes(msg[j:j + 2], 'big'))
                j += 4 + int.from_bytes(msg[j + 2:j + 4], 'big')
        i = data + size
    if name_at is None:
        raise ValueError('no server name')
    return name_at, name_len, groups


def shape_pieces(shape, record, name_at, name_len):
    """The byte strings to send, in order, and the pause before each."""
    if shape == 'large':
        return [record], [0]
    if shape == 'records':
        msg, version = record[5:], record[1:3]
        cuts = [name_at + name_len // 2]
        while len(msg) - cuts[-1] > 512:
            cuts.append(cuts[-1] + 512)
        chunks = [msg[a:b] for a, b in zip([0] + cuts, cuts + [len(msg)])]
        framed = b''.join(b'\x16' + version + len(c).to_bytes(2, 'big') + c for c in chunks)
        return [framed], [0]
    mid = 5 + name_at + name_len // 2
    half = mid + (len(record) - mid) // 2
    return [record[:5], record[5:mid], record[mid:half], record[half:]], [0, *GAPS]


def attempt(args, ctx, shape):
    result = {'shape': shape, 'ok': False}
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = ctx.wrap_bio(incoming, outgoing, server_hostname=args.sni)
    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                tls.do_handshake()
            except ssl.SSLWantReadError:
                pass
            record = outgoing.read()
            name_at, name_len, groups = parse_hello(record)
            result.update(hello_bytes=len(record), groups=[GROUPS.get(g, hex(g)) for g in groups])
            if shape == 'large' and MLKEM not in groups:
                raise ValueError('the ClientHello has no X25519MLKEM768 key share')
            pieces, pauses = shape_pieces(shape, record, name_at, name_len)
            # Filled in as each piece goes out, so that a connection closed
            # partway shows how far the ClientHello got.
            sent, gaps, last = [], [], None
            result.update(planned=[len(p) for p in pieces], sent=sent, gaps=gaps)
            if shape == 'records':
                result['records'] = count_records(pieces[0])
            for piece, pause in zip(pieces, pauses):
                time.sleep(pause)
                now = time.monotonic()
                sock.sendall(piece)
                if last is not None:
                    gaps.append(round(now - last, 3))
                sent.append(len(piece))
                last = now

            def pump():
                data = outgoing.read()
                if data:
                    sock.sendall(data)
                chunk = sock.recv(65536)
                if chunk:
                    incoming.write(chunk)
                else:
                    incoming.write_eof()

            while True:
                try:
                    tls.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    pump()
            result.update(tls=tls.version(), alpn=tls.selected_alpn_protocol())
            tls.write(f'GET / HTTP/1.1\r\nHost: {args.sni}\r\nConnection: close\r\n\r\n'.encode())
            sock.sendall(outgoing.read())
            response = b''
            while True:
                try:
                    data = tls.read(65536)
                except ssl.SSLWantReadError:
                    pump()
                    continue
                except (ssl.SSLZeroReturnError, ssl.SSLEOFError):
                    break
                if not data:
                    break
                response += data
            head, _, body = response.partition(b'\r\n\r\n')
            status = head.split(b' ', 2)[1].decode() if head.startswith(b'HTTP/') else None
            result.update(status=status, body_ok=body == args.expect.encode() + b'\n')
            result['ok'] = status == '200' and result['body_ok']
    except (OSError, ssl.SSLError, ValueError, IndexError) as e:
        result['error'] = f'{type(e).__name__}: {e}'
    return result


def count_records(data):
    n, i = 0, 0
    while i < len(data):
        i += 5 + int.from_bytes(data[i + 3:i + 5], 'big')
        n += 1
    return n


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, default=443)
    parser.add_argument('--sni', default='target.example')
    parser.add_argument('--expect', default='stand-in target.example', help='the expected body, without its newline')
    parser.add_argument('--shape', choices=['records', 'segments', 'large'], required=True)
    parser.add_argument('--count', type=int, default=20)
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args()
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(['http/1.1'])
    ok = True
    for n in range(1, args.count + 1):
        result = attempt(args, ctx, args.shape)
        result['n'] = n
        print(json.dumps(result, sort_keys=True), flush=True)
        ok = ok and result['ok']
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
