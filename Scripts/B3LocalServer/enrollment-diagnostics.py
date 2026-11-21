"""Print only structured, redacted enrollment phases and diagnostic codes."""

import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    events = json.load(source)["events"]
for event in events:
    area = event.get("area")
    if area != "enrollment" and not (
        area == "connection" and event.get("phase") in {"approvedConnection", "foregroundCompletion"}
    ):
        continue
    fields = [event.get(key) or "none" for key in ("phase", "transition", "causeCode")]
    if all(isinstance(field, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", field) for field in fields):
        print("B3 diagnostic", area, *fields)
