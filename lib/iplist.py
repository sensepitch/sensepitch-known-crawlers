#!/usr/bin/env python3
"""Validate publisher lists and convert plain CIDRs to Google's JSON shape."""
import datetime
import ipaddress
import json
import pathlib
import sys


def read(data, kind):
    data = data.decode('utf-8')
    if kind == 'json':
        obj = json.loads(data)
        entries = [p[k] for p in obj['prefixes'] for k in ('ipv4Prefix', 'ipv6Prefix') if k in p]
        if len(entries) != len(obj['prefixes']):
            raise ValueError('invalid prefix entry')
    elif kind == 'fastly':
        obj = json.loads(data)
        entries = obj['addresses'] + obj['ipv6_addresses']
    elif kind == 'ahrefs':
        entries = [entry['ip_address'] for entry in json.loads(data)['ips']]
    elif kind == 'text':
        entries = [s.strip() for s in data.splitlines() if s.strip() and not s.lstrip().startswith('#')]
    else:
        raise ValueError('unknown format')
    networks = [ipaddress.ip_network(s, strict=False) for s in entries]
    if not networks:
        raise ValueError('empty list')
    return {v: list(ipaddress.collapse_addresses(n for n in networks if n.version == v)) for v in (4, 6)}


def coverage(networks):
    return {version: sum(n.num_addresses for n in networks[version]) for version in (4, 6)}


try:
    kind, source, output, previous = sys.argv[1:]
    source_data = pathlib.Path(source).read_bytes()
    current = read(source_data, kind)
    current_coverage = coverage(current)
    old_coverage = {4: 0, 6: 0}
    previous_data = None
    if previous != '-' and pathlib.Path(previous).exists():
        previous_data = pathlib.Path(previous).read_bytes()
        old = current if kind == 'json' and source_data == previous_data else read(previous_data, 'json')
        old_coverage = coverage(old)
        for version in (4, 6):
            before = old_coverage[version]
            after = current_coverage[version]
            if before and 2 * after <= before:
                raise ValueError(f'IPv{version} coverage dropped by 50% or more')
    if kind == 'json':
        pathlib.Path(output).write_bytes(source_data)
    elif previous_data is not None and current == old:
        pathlib.Path(output).write_bytes(previous_data)
    else:
        result = {'creationTime': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'prefixes': [{f'ipv{v}Prefix': str(n)} for v in (4, 6) for n in current[v]]}
        pathlib.Path(output).write_text(json.dumps(result, indent=2) + '\n')
    print(sum(old_coverage.values()), sum(current_coverage.values()))
except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError) as exc:
    print(f'invalid list: {exc}', file=sys.stderr)
    sys.exit(1)
