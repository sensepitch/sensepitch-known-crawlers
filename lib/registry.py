"""Read the source registry and emit validated download jobs for the updater."""

import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

try:
    import yaml
except ImportError:
    sys.exit("Reading the source registry requires PyYAML")


FIELDS = {"download_url", "info_url", "format", "types", "tier"}
FORMATS = {
    "json", "json-sanitised", "text", "json-array", "fastly", "ahrefs",
    "amazon-html", "marginalia-html", "semrush-html", "you-html", "sail",
}


class RegistryLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        keys = [self.construct_object(key) for key, _ in node.value]
        if len(set(keys)) != len(keys):
            raise ValueError("duplicate YAML key")
        return super().construct_mapping(node, deep=deep)


def read_entry(path, root):
    name = path.relative_to(root).with_suffix("").as_posix()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*/[a-z0-9]+(?:-[a-z0-9]+)*", name):
        raise ValueError("expected <vendor>/<specialisation>.yaml with kebab-case names")

    entry = yaml.load(path.read_text(encoding="utf-8"), Loader=RegistryLoader)
    if not isinstance(entry, dict) or entry.keys() != FIELDS:
        raise ValueError("expected download_url, info_url, format, types and tier")
    for field in ("download_url", "info_url"):
        url = entry[field]
        if not isinstance(url, str) or re.search(r"[\s\x00-\x1f\x7f]", url):
            raise ValueError(f"{field} must be an HTTPS URL")
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError(f"{field} must be an HTTPS URL")
    kind = entry["format"]
    if not isinstance(kind, str) or kind not in FORMATS:
        raise ValueError(f"unsupported format {kind!r}")
    types = entry["types"]
    if (not isinstance(types, list) or not types
            or any(not isinstance(label, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", label)
                   for label in types)
            or len(set(types)) != len(types)):
        raise ValueError("types must be a nonempty list of unique kebab-case labels")
    tier = entry["tier"]
    if type(tier) is not int or tier not in (1, 2, 3):
        raise ValueError("tier must be an integer from 1 to 3")
    return kind, name, entry["download_url"]


def main(root):
    paths = sorted(root.rglob("*.yaml"))
    if not paths:
        print(f"{root}: no YAML registry entries found", file=sys.stderr)
        return 1
    status = 0
    for path in paths:
        try:
            print(*read_entry(path, root), sep="\t")
        except (OSError, TypeError, ValueError, yaml.YAMLError) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
