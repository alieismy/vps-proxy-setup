#!/usr/bin/env python3
"""UDP test client of the FR-13 cases (verification plan 4.5): datagrams
through a SOCKS5 proxy (RFC 1928, UDP ASSOCIATE, no authentication) to HOST
as a domain name, never resolved here, so that the proxy decides what to do
with the name. Each datagram carries its own payload; echoes are counted by
payload. Prints one JSON line: host, port, sent, echoed and an error, if any.

  udpsend.py --proxy 127.0.0.1:7890 --host NAME --port 7 --count 10
"""
import argparse
import json
import secrets
import socket
import struct
import time


def socks_address(data, i):
    """(host, port, next index) of the SOCKS5 address at data[i:]."""
    kind = data[i]
    if kind == 1:
        host, i = socket.inet_ntop(socket.AF_INET, data[i + 1:i + 5]), i + 5
    elif kind == 4:
        host, i = socket.inet_ntop(socket.AF_INET6, data[i + 1:i + 17]), i + 17
    elif kind == 3:
        size = data[i + 1]
        host, i = data[i + 2:i + 2 + size].decode('ascii', 'replace'), i + 2 + size
    else:
        raise ValueError(f'address type {kind}')
    return host, struct.unpack('!H', data[i:i + 2])[0], i + 2


def recv_exact(sock, size):
    data = b''
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError('the proxy closed the control connection')
        data += chunk
    return data


def associate(proxy):
    """The control connection and the relay address of a UDP association."""
    control = socket.create_connection(proxy, timeout=10)
    control.sendall(b'\x05\x01\x00')
    if recv_exact(control, 2) != b'\x05\x00':
        raise ConnectionError('the proxy refused the method without authentication')
    control.sendall(b'\x05\x03\x00\x01' + bytes(6))
    head = recv_exact(control, 4)
    if head[1] != 0:
        raise ConnectionError(f'UDP ASSOCIATE refused with reply {head[1]}')
    if head[3] == 1:
        rest = recv_exact(control, 6)
    elif head[3] == 4:
        rest = recv_exact(control, 18)
    else:
        size = recv_exact(control, 1)
        rest = size + recv_exact(control, size[0] + 2)
    host, port, _ = socks_address(head[3:4] + rest, 0)
    if host in ('0.0.0.0', '::'):
        host = proxy[0]
    return control, (host, port)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--proxy', required=True, help='HOST:PORT of the SOCKS5 proxy')
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--count', type=int, default=10)
    parser.add_argument('--wait', type=float, default=5, help='seconds to wait for echoes after the last send')
    args = parser.parse_args()
    proxy_host, _, proxy_port = args.proxy.rpartition(':')
    result = {'host': args.host, 'port': args.port, 'sent': 0, 'echoed': 0}
    payloads = {f'vps-udp {i} {secrets.token_hex(8)}'.encode() for i in range(args.count)}
    try:
        control, relay = associate((proxy_host, int(proxy_port)))
        name = args.host.encode('ascii')
        header = b'\x00\x00\x00\x03' + bytes([len(name)]) + name + struct.pack('!H', args.port)
        with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            for payload in sorted(payloads):
                udp.sendto(header + payload, relay)
                result['sent'] += 1
                time.sleep(0.1)
            deadline = time.monotonic() + args.wait
            seen = set()
            while seen != payloads and time.monotonic() < deadline:
                udp.settimeout(max(deadline - time.monotonic(), 0.01))
                try:
                    data = udp.recv(65535)
                except socket.timeout:
                    break
                if len(data) > 3 and data[2] == 0:
                    _, _, i = socks_address(data, 3)
                    if data[i:] in payloads:
                        seen.add(data[i:])
            result['echoed'] = len(seen)
    except (OSError, ValueError) as e:
        result['error'] = f'{type(e).__name__}: {e}'
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
