#!/usr/bin/env python3
"""Test vectors from the geo data the release bundles (verification plan
3.6, 3.7). The routing tests use names and addresses that the core's own
files hold, so the repository names none of them.

  geodat.py site FILE CODE   the first domain of type Domain or Full in the
                             list CODE of a geosite.dat
  geodat.py ip FILE CODE     the second address of the first IPv4 block of
                             the list CODE of a geoip.dat

Codes compare without case, as the core does. The files are the GeoSiteList
and GeoIPList messages of Xray-core v26.10.21 (common/geodata/geodat.proto);
only the fields used here are read. The exit status is 1 when the list is
missing or holds nothing that fits.
"""
import ipaddress
import re
import sys

DOMAIN, FULL = 2, 3
HOSTNAME = re.compile(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$')


def varint(buf, i):
    value = shift = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, i
        shift += 7


def fields(buf):
    """(field number, value) for each field of one message: an int for a
    varint, bytes for a length-delimited field."""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = varint(buf, i)
        elif wire == 2:
            size, i = varint(buf, i)
            value, i = buf[i:i + size], i + size
        elif wire == 1:
            value, i = buf[i:i + 8], i + 8
        elif wire == 5:
            value, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f'unsupported wire type {wire}')
        yield number, value


def entry(path, code):
    """The fields of the entry whose code (field 1) is CODE."""
    with open(path, 'rb') as f:
        data = f.read()
    for number, value in fields(data):
        if number != 1 or not isinstance(value, bytes):
            continue
        entry_fields = list(fields(value))
        name = next((v for n, v in entry_fields if n == 1), b'')
        if isinstance(name, bytes) and name.decode('utf-8', 'replace').lower() == code.lower():
            return entry_fields
    return None


def site(path, code):
    for number, value in entry(path, code) or []:
        if number != 2 or not isinstance(value, bytes):
            continue
        domain = dict(fields(value))
        kind, name = domain.get(1, 0), domain.get(2, b'')
        if kind in (DOMAIN, FULL) and isinstance(name, bytes) and HOSTNAME.match(name.decode('ascii', 'replace')):
            return name.decode('ascii')
    return None


def ip(path, code):
    found = entry(path, code)
    if found is None or any(n == 3 and v for n, v in found):
        return None
    for number, value in found:
        if number != 2 or not isinstance(value, bytes):
            continue
        cidr = dict(fields(value))
        address, prefix = cidr.get(1, b''), cidr.get(2, 0)
        if isinstance(address, bytes) and len(address) == 4 and isinstance(prefix, int) and prefix <= 30:
            network = ipaddress.ip_network((address, prefix), strict=False)
            return str(network.network_address + 1)
    return None


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('site', 'ip'):
        sys.exit('usage: geodat.py site|ip FILE CODE')
    result = (site if sys.argv[1] == 'site' else ip)(sys.argv[2], sys.argv[3])
    if result is None:
        sys.exit(1)
    print(result)


if __name__ == '__main__':
    main()
