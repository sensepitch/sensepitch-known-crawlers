#!/usr/bin/env python3
"""Build release zips, one per tier and one with every tier, each with the published
lists and an index.json describing them."""
import datetime
import ipaddress
import json
import re
import sys
import zipfile
from pathlib import Path

import yaml

from registry import TYPES_FILE, entry_paths, load_entry, load_types

SCHEMA = 1
NAME = "sensepitch-verified-ips"
TIERS = {
    "1": "Default public website allow tier for mainstream web search, AI search, "
         "and public user-facing fetches.",
    "2": "Specialist search, SEO tools, site auditing, and advertising crawlers.",
    "3": "Dedicated model training and dataset crawlers, CDNs, monitoring, webhooks, "
         "and broad service pools.",
}


def describe(name, entry):
    path = f"lists/{name}.json"
    data = Path(path).read_bytes()
    counts = {4: 0, 6: 0}
    for prefix in json.loads(data)["prefixes"]:
        for version in (4, 6):
            if f"ipv{version}Prefix" in prefix:
                ipaddress.ip_network(prefix[f"ipv{version}Prefix"], strict=False)
                counts[version] += 1
    if not sum(counts.values()):
        raise ValueError(f"{path}: empty list")
    fetched_at = json.loads(Path(f"provenance/{name}.json").read_text())["fetched_at"]
    vendor, specialisation = name.split("/")
    return data, {
        "id": name,
        "path": path,
        "vendor": vendor,
        "specialisation": specialisation,
        "types": entry["types"],
        "tier": entry["tier"],
        "info_url": entry["info_url"],
        "download_url": entry["download_url"],
        "fetched_at": fetched_at,
        "ipv4_prefixes": counts[4],
        "ipv6_prefixes": counts[6],
    }


def main(registry, version, output):
    if not re.fullmatch(r"\d{4}\.\d{2}\.\d{2}(\.\d+)?", version):
        print(f"Invalid version {version!r}, expected YYYY.MM.DD[.N]", file=sys.stderr)
        return 2
    paths = entry_paths(registry)
    if not paths:
        print(f"{registry}: no YAML registry entries found", file=sys.stderr)
        return 1
    try:
        known_types = load_types(registry)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"{registry / TYPES_FILE}: {exc}", file=sys.stderr)
        return 1
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    lists, files, status = [], {}, 0
    for path in paths:
        try:
            name, entry = load_entry(path, registry, known_types)
            if not Path(f"lists/{name}.json").exists() and Path(f"provenance/{name}.failure").exists():
                print(f"Warning: {name} has never been retrieved, skipped", file=sys.stderr)
                continue
            data, meta = describe(name, entry)
        except (OSError, KeyError, TypeError, ValueError, yaml.YAMLError) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            status = 1
            continue
        lists.append(meta)
        files[meta["path"]] = data
        failure = Path(f"provenance/{name}.failure")
        if failure.exists():
            since = datetime.datetime.fromtimestamp(int(failure.read_text().split()[0]), datetime.timezone.utc)
            print(f"Warning: {name} retrieval failing since {since:%Y-%m-%dT%H:%M:%SZ}, "
                  f"releasing data fetched at {meta['fetched_at']}", file=sys.stderr)
    if status:
        return status
    releases = {f"{NAME}-tier{tier}": [tier] for tier in sorted(TIERS)}
    releases[f"{NAME}-all-tiers"] = sorted(TIERS)
    outputs = {name: output / f"{name}-{version}.zip" for name in releases}
    if existing := [str(path) for path in outputs.values() if path.exists()]:
        print(f"{', '.join(existing)}: already exists", file=sys.stderr)
        return 1
    output.mkdir(parents=True, exist_ok=True)
    for name, tiers in releases.items():
        included = [meta for meta in lists if str(meta["tier"]) in tiers]
        write_release(outputs[name], name, version, now, tiers, included, known_types, files)
        print(f"{outputs[name]}: {len(included)} lists")
    return 0


def write_release(output, name, version, now, tiers, lists, known_types, files):
    used = {label for meta in lists for label in meta["types"]}
    used_types = {label: " ".join(text.split()) for label, text in known_types.items() if label in used}
    index = {
        "schema": SCHEMA,
        "name": name,
        "version": version,
        "generated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tiers": {tier: TIERS[tier] for tier in tiers},
        "types": used_types,
        "lists": lists,
    }
    contents = {"index.json": (json.dumps(index, indent=2) + "\n").encode(),
                **{meta["path"]: files[meta["path"]] for meta in lists}}
    stamp = now.timetuple()[:6]
    with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED) as archive:
        for path, data in contents.items():
            info = zipfile.ZipInfo(path, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: release.py <registry> <version> <output-dir>")
    try:
        sys.exit(main(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])))
    except FileExistsError as exc:
        sys.exit(f"{exc.filename}: already exists")
