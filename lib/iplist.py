#!/usr/bin/env python3
"""Validate publisher IP lists and convert them to Google's JSON shape."""
import datetime
import html
import ipaddress
import json
import pathlib
import re
import sys
import tomllib


def match_once(pattern, data):
    matches = re.findall(pattern, data, re.DOTALL)
    if len(matches) != 1:
        raise ValueError('expected exactly one publisher list')
    return matches[0]


def read_amazon(data):
    block = match_once(r'<pre>\s*<code class="container">\s*(\{.*?\})\s*</code>\s*</pre>', data)
    entries = []
    for prefix in json.loads(html.unescape(block))['prefixes']:
        if not isinstance(prefix, dict) or len(prefix) != 1:
            raise ValueError('invalid Amazon prefix entry')
        key, address = next(iter(prefix.items()))
        family = {'ipv4Prefix': 4, 'ip_prefix': 4, 'ipv6Prefix': 6, 'ipv6_prefix': 6}.get(key)
        if not isinstance(address, str) or ipaddress.ip_network(address, strict=False).version != family:
            raise ValueError('invalid Amazon prefix entry')
        entries.append(address)
    return entries


def read_sail(data):
    document = tomllib.loads(data)
    if document['schema'] != 'draft-kelley-webbotauth-sail-00':
        raise ValueError('unsupported SAIL schema')
    services = [service for service in document['services'] if service['name'] == 'Claude-Agent']
    if len(services) != 1:
        raise ValueError('expected one Claude-Agent service')
    sets = document['prefix_sets']
    prefixes = {item['name']: item for item in sets}
    if len(prefixes) != len(sets):
        raise ValueError('duplicate SAIL prefix set')
    entries = []
    for name in services[0]['prefix_sets']:
        prefix_set = prefixes[name]
        for version in (4, 6):
            for address in prefix_set.get(f'ipv{version}_prefixes', []):
                if not isinstance(address, str) or ipaddress.ip_network(address, strict=False).version != version:
                    raise ValueError('invalid SAIL prefix family')
                entries.append(address)
    return entries


def read(data, kind):
    data = data.decode('utf-8')
    if kind in ('json', 'json-sanitised'):
        obj = json.loads(data)
        entries = [p[k] for p in obj['prefixes'] for k in ('ipv4Prefix', 'ipv6Prefix') if k in p]
        if len(entries) != len(obj['prefixes']):
            raise ValueError('invalid prefix entry')
    elif kind == 'fastly':
        obj = json.loads(data)
        entries = obj['addresses'] + obj['ipv6_addresses']
    elif kind == 'ahrefs':
        entries = [entry['ip_address'] for entry in json.loads(data)['ips']]
    elif kind == 'json-array':
        entries = json.loads(data)
        if not isinstance(entries, list) or any(not isinstance(entry, str) for entry in entries):
            raise ValueError('expected an array of IP addresses')
    elif kind == 'amazon-html':
        entries = read_amazon(data)
    elif kind == 'marginalia-html':
        start, end = match_once(
            r'IP Address Range\s*</h3>\s*<p\b[^>]*>\s*([\d.]+)\s*-\s*([\d.]+)\s*</p>', data)
        entries = [str(network) for network in ipaddress.summarize_address_range(
            ipaddress.IPv4Address(start), ipaddress.IPv4Address(end))]
    elif kind == 'semrush-html':
        entries = [match_once(r"The bot's IP addresses are:\s*<strong>\s*([\d.]+/\d+)\s*</strong>",
                              html.unescape(data))]
    elif kind == 'you-html':
        entries = [match_once(r'Legitimate YouBot requests originate from\s*<strong\b[^>]*>\s*([\d.]+/\d+)\s*</strong>',
                              data)]
    elif kind == 'sail':
        entries = read_sail(data)
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


def format_count(value):
    names = ('', 'thousand', 'million', 'billion', 'trillion', 'quadrillion',
             'quintillion', 'sextillion', 'septillion', 'octillion', 'nonillion',
             'decillion', 'undecillion')
    scale = 0
    while scale + 1 < len(names) and value >= 1000 ** (scale + 1):
        scale += 1
    if not scale:
        return str(value)
    divisor = 1000 ** scale
    hundredths = (value * 100 + divisor // 2) // divisor
    number = f'{hundredths // 100}.{hundredths % 100:02d}'.rstrip('0').rstrip('.')
    return f'{number} {names[scale]}'


def format_coverage(before, after):
    left, right = format_count(before), format_count(after)
    if before != after and left == right:
        left += f' ({before:,})'
        right += f' ({after:,})'
    return f'{left} -> {right}'


try:
    if len(sys.argv) == 4 and sys.argv[1] == '--format-coverage':
        print(format_coverage(int(sys.argv[2]), int(sys.argv[3])))
        sys.exit(0)
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
    elif kind == 'json-sanitised':
        source_obj = json.loads(source_data)
        if previous_data is not None and current == old:
            creation_time = json.loads(previous_data).get('creationTime')
        else:
            creation_time = source_obj.get('creationTime')
        if not creation_time:
            creation_time = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result = {'creationTime': creation_time,
                  'prefixes': [{f'ipv{v}Prefix': str(n)} for v in (4, 6) for n in current[v]]}
        pathlib.Path(output).write_text(json.dumps(result, indent=2) + '\n')
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
