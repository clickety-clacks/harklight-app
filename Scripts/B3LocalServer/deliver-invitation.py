"""Deliver an isolated Server invitation privately to its owned simulator."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    source, signals, device, route, dashboard = sys.argv[1:]
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", device):
        raise ValueError
    invite = json.loads(Path(source).read_text(encoding="utf-8"))
    link = invite["join_url"]
    if route == "bridge":
        token = invite["invite_token"]
        if not re.fullmatch(r"[a-f0-9]{64}", token):
            raise ValueError
        link = dashboard + "/join#" + token
    elif route == "paste":
        status = subprocess.run(["xcrun", "simctl", "pbcopy", device], input=link.encode("utf-8"),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if status.returncode != 0:
            raise OSError
        link = None
    elif route != "native":
        raise ValueError
    target = Path(signals) / "invitation-control.json"
    pending = target.with_suffix(".pending")
    with pending.open("x", encoding="utf-8") as out:
        json.dump({"route": route, "link": link}, out)
    os.replace(pending, target)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, AttributeError, TypeError):
        print("B3 invitation delivery failed.", file=sys.stderr)
        sys.exit(2)
