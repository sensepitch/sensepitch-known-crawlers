#!/usr/bin/env python3
"""Check that expectations.json matches the prefixes in the fixture ZIPs."""
import ipaddress
import json
import sys
from pathlib import Path
from zipfile import ZipFile

FIXTURE = Path(__file__).resolve().parent


def load_feeds(directory):
    feeds = []
    for tier in (1, 2, 3):
        with ZipFile(directory / f"sensepitch-known-crawlers-tier{tier}.zip") as archive:
            for name in archive.namelist():
                if not name.startswith("lists/"):
                    continue
                vendor, listname = name[len("lists/"):-len(".json")].split("/")
                prefixes = json.loads(archive.read(name))["prefixes"]
                networks = [ipaddress.ip_network(next(iter(p.values()))) for p in prefixes]
                feeds.append(({"vendor": vendor, "listname": listname, "tier": tier}, networks))
    return feeds


def matches(feeds, ip):
    address = ipaddress.ip_address(ip)
    found = [feed for feed, networks in feeds
             if any(address.version == n.version and address in n for n in networks)]
    return sorted(found, key=lambda f: (f["tier"], f["vendor"], f["listname"]))


def main(directory):
    feeds = load_feeds(directory)
    expected = json.loads((FIXTURE / "expectations.json").read_text())
    failed = False
    for case in expected:
        actual = matches(feeds, case["ip"])
        if actual != case["matches"]:
            print(f"{case['ip']}: expected {case['matches']}, got {actual}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURE))
