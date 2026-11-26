#!/usr/bin/env python3
"""Package saved lists and their registry metadata for the edge proxy."""
import datetime
import ipaddress
import json
import subprocess
import sys
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml

from registry import TYPES_FILE, entry_paths, load_entry, load_types

TIERS = (1, 2, 3)
PREFIX_FAMILIES = {"ipv4Prefix": 4, "ipv6Prefix": 6}


def read_list(path):
    data = path.read_bytes()
    prefixes = json.loads(data)["prefixes"]
    if not isinstance(prefixes, list) or not prefixes:
        raise ValueError(f"{path}: expected a nonempty prefixes array")
    for prefix in prefixes:
        keys = PREFIX_FAMILIES.keys() & prefix.keys() if isinstance(prefix, dict) else set()
        if len(keys) != 1:
            raise ValueError(f"{path}: expected one IP prefix per entry")
        key, = keys
        value = prefix[key]
        if not isinstance(value, str) or ipaddress.ip_network(value, strict=False).version != PREFIX_FAMILIES[key]:
            raise ValueError(f"{path}: invalid {key}: {value!r}")
    return data


def collect_lists(registry, paths, known_types):
    tiers = {tier: [] for tier in TIERS}
    invalid = False
    for path in paths:
        try:
            name, entry = load_entry(path, registry, known_types)
            list_path = Path(f"lists/{name}.json")
            failure = Path(f"provenance/{name}.failure")
            if failure.exists():
                if not list_path.exists():
                    print(f"Warning: {name} has never been retrieved, skipped", file=sys.stderr)
                    continue
                since = datetime.datetime.fromtimestamp(int(failure.read_text().strip()), datetime.timezone.utc)
                print(f"Warning: {name} retrieval failing since {since:%Y-%m-%dT%H:%M:%SZ}, "
                      "including the saved list", file=sys.stderr)
            data = read_list(list_path)
        except (OSError, KeyError, TypeError, ValueError, OverflowError, yaml.YAMLError) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            invalid = True
            continue
        vendor, listname = name.split("/")
        info = {"vendor": vendor, "listname": listname, "tier": entry["tier"], "tags": entry["types"]}
        tiers[entry["tier"]].append((name, data, info))
    return None if invalid else tiers


def commit_metadata():
    git = subprocess.run(
        ["git", "show", "-s", "--no-show-signature", "--no-notes", "--format=%H %ct", "HEAD"],
        capture_output=True, text=True, check=True,
    )
    sha, timestamp = git.stdout.split()
    modified = datetime.datetime.fromtimestamp(int(timestamp), datetime.timezone.utc)
    return {"git-sha": sha, "last-modified": modified.strftime("%Y-%m-%dT%H:%M:%SZ")}


def write_member(archive, name, data):
    # A fixed timestamp and platform make the ZIP independent of file metadata.
    member = zipfile.ZipInfo(name)
    member.create_system = 3
    member.external_attr = 0o644 << 16
    archive.writestr(member, data, compress_type=zipfile.ZIP_DEFLATED)


def json_bytes(data):
    return (json.dumps(data, indent=2) + "\n").encode("utf-8")


def write_archive(path, feeds, metadata):
    with zipfile.ZipFile(path, "x") as archive:
        write_member(archive, "meta.json", json_bytes(metadata))
        for name, data, info in feeds:
            write_member(archive, f"lists/{name}.json", data)
            write_member(archive, f"info/{name}.json", json_bytes(info))


def main(registry, output):
    paths = entry_paths(registry)
    if not paths:
        print(f"{registry}: no YAML registry entries found", file=sys.stderr)
        return 1
    try:
        known_types = load_types(registry)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"{registry / TYPES_FILE}: {exc}", file=sys.stderr)
        return 1
    tiers = collect_lists(registry, paths, known_types)
    if tiers is None:
        return 1
    commit = commit_metadata()

    output.mkdir(parents=True, exist_ok=True)
    destinations = {tier: output / f"sensepitch-known-crawlers-tier{tier}.zip" for tier in TIERS}
    for destination in destinations.values():
        if destination.is_dir():
            raise IsADirectoryError(f"{destination}: expected a ZIP file")
    with TemporaryDirectory(dir=output) as staging:
        staged = {tier: Path(staging) / destination.name for tier, destination in destinations.items()}
        for tier in TIERS:
            write_archive(staged[tier], tiers[tier], {"version": 1, "tier": tier, **commit})
        for tier in TIERS:
            staged[tier].replace(destinations[tier])
            print(f"{destinations[tier]}: {len(tiers[tier])} lists")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: release.py <registry> <output-dir>", file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Cannot read Git HEAD for release metadata: {exc.stderr.strip()}")
    except OSError as exc:
        sys.exit(str(exc))
