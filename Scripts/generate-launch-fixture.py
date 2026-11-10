"""Create small synthetic inbox messages for process-cold launch measurements.

Usage: python3 generate-launch-fixture.py original-fixture.json count output.json
Supply the output as the test app's bundled attention-client-m2-fixtures.json.
"""
import copy
import json
import pathlib
import sys

source, count, destination = sys.argv[1], int(sys.argv[2]), sys.argv[3]
fixture = json.loads(pathlib.Path(source).read_text())
template = {
    "sender_id": "fixture:Studio", "created_at": 1791792000000,
    "body": "Review this synthetic inbox message.",
    "answer_ui": {"schema": "attention-client.actions/1", "actions": [
        {"id": "ok", "kind": "value", "label": "OK", "value": True}]}}
fixture = {"account": fixture["account"]}
requests = []
for index in range(count):
    request = copy.deepcopy(template)
    request["message_id"] = "review-01" if index == count - 1 else f"launch-{index:05d}"
    request["title"] = "Studio review" if index == count - 1 else f"Inbox launch message {index:05d}"
    requests.append(request)
fixture["requests"] = requests
fixture["requestOrder"] = [request["message_id"] for request in requests]
pathlib.Path(destination).write_text(json.dumps(fixture, separators=(",", ":")))
print(f"messages={count} bytes={pathlib.Path(destination).stat().st_size}")
