"""Read the source registry and emit validated download jobs for the updater."""

import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

try:
    import yaml
except ImportError:
    sys.exit("Reading the source registry requires PyYAML")


TYPES_FILE = "types.yaml"
LABEL = r"[a-z0-9]+(?:-[a-z0-9]+)*"
FIELDS = {"download_url", "info_url", "format", "types", "tier"}
OPTIONAL_FIELDS = {"volatile_raw"}
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


def load_types(root):
    """Return the type definitions, mapping each label to its description."""
    types = yaml.load((root / TYPES_FILE).read_text(encoding="utf-8"), Loader=RegistryLoader)
    if (not isinstance(types, dict) or not types
            or any(not isinstance(label, str) or not re.fullmatch(LABEL, label)
                   or not isinstance(text, str) or not text.strip()
                   for label, text in types.items())):
        raise ValueError("expected a mapping of kebab-case type labels to descriptions")
    return types


def entry_paths(root):
    return sorted(path for path in root.rglob("*.yaml") if path != root / TYPES_FILE)


def load_entry(path, root, known_types=None):
    """Return the source name and its validated registry entry."""
    name = path.relative_to(root).with_suffix("").as_posix()
    if not re.fullmatch(f"{LABEL}/{LABEL}", name):
        raise ValueError("expected <vendor>/<specialisation>.yaml with kebab-case names")

    entry = yaml.load(path.read_text(encoding="utf-8"), Loader=RegistryLoader)
    if (not isinstance(entry, dict) or not FIELDS <= entry.keys()
            or not entry.keys() <= FIELDS | OPTIONAL_FIELDS):
        raise ValueError("expected download_url, info_url, format, types, tier and optionally volatile_raw")
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
            or any(not isinstance(label, str) or not re.fullmatch(LABEL, label)
                   for label in types)
            or len(set(types)) != len(types)):
        raise ValueError("types must be a nonempty list of unique kebab-case labels")
    if known_types is not None and (unknown := [label for label in types if label not in known_types]):
        raise ValueError(f"types not defined in {TYPES_FILE}: {', '.join(unknown)}")
    tier = entry["tier"]
    if type(tier) is not int or tier not in (1, 2, 3):
        raise ValueError("tier must be an integer from 1 to 3")
    if type(entry.get("volatile_raw", False)) is not bool:
        raise ValueError("volatile_raw must be true or false")
    return name, entry


def read_entry(path, root, known_types):
    name, entry = load_entry(path, root, known_types)
    volatile = "1" if entry.get("volatile_raw", False) else "0"
    return entry["format"], name, entry["download_url"], volatile


def main(root):
    paths = entry_paths(root)
    if not paths:
        print(f"{root}: no YAML registry entries found", file=sys.stderr)
        return 1
    status = 0
    try:
        known_types = load_types(root)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        # Still emit the downloads so that every source is attempted.
        print(f"{root / TYPES_FILE}: {exc}", file=sys.stderr)
        known_types, status = None, 1
    for path in paths:
        try:
            print(*read_entry(path, root, known_types), sep="\t")
        except (OSError, TypeError, ValueError, yaml.YAMLError) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
