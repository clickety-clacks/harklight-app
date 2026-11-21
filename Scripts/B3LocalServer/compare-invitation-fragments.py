"""Compare private fragment fingerprints without printing their values or digests."""

import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main():
    operation, source, target = sys.argv[1:]
    if operation == "original":
        fragment = urlsplit(read(source)["join_url"]).fragment.encode("utf-8")
        data = {"bytes": len(fragment), "sha256": hashlib.sha256(fragment).hexdigest()}
        Path(target).write_text(json.dumps(data), encoding="utf-8")
        return
    if operation != "compare":
        raise ValueError
    sent, arrived = read(source), read(target)
    if type(sent.get("bytes")) is not int or sent["bytes"] < 0:
        raise ValueError
    for name in ("is_native_scheme", "is_join_host", "has_query"):
        if type(arrived.get(name)) is not bool:
            raise ValueError
        print(f"B3 invitation handoff {name}={arrived[name]}")
    for name in ("encoded", "decoded"):
        received = arrived[name]
        if type(received.get("bytes")) is not int or received["bytes"] < 0:
            raise ValueError
        matches = bool(sent.get("sha256")) and sent.get("sha256") == received.get("sha256")
        print(f"B3 invitation handoff {name} sent_bytes={sent['bytes']} "
              f"received_bytes={received['bytes']} digest_matches={matches}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, AttributeError):
        print("B3 invitation handoff comparison unavailable.", file=sys.stderr)
        sys.exit(2)
