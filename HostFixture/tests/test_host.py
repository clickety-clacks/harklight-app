import http.client
import json
import threading
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import Host, State


class HostBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.now = [1000]
        self.state = State(clock=lambda: self.now[0])
        self.server = Host(state=self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.secret = self.state.issue_pair_secret()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, payload=None, headers=None, method="POST"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        body = json.dumps(payload or {}).encode() if method == "POST" else None
        supplied = {"Host": self.server.origin[7:], "Origin": self.server.origin,
                    "Content-Type": "application/json"}
        if headers:
            supplied.update(headers)
        connection.request(method, path, body=body, headers=supplied)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, json.loads(data) if data and response.getheader("Content-Type") == "application/json" else data

    def pair(self, profile="synthetic-A"):
        status, body = self.request("/api/pair", {"profile": profile, "secret": self.secret})
        self.assertEqual(status, 200)
        self.assertGreaterEqual(len(body["token"]), 43)
        return body

    def authorized(self, path, session, more=None, headers=None):
        payload = {"profile": session["profile"], "generation": session["generation"]}
        payload.update(more or {})
        supplied = {"Authorization": "Bearer " + session["token"]}
        supplied.update(headers or {})
        return self.request(path, payload, supplied)

    def test_origin_host_and_post_only(self):
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret}, {"Origin": "null"})[0], 403)
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret}, {"Origin": "http://foreign.test"})[0], 403)
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret}, {"Origin": ""})[0], 403)
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret}, {"Host": "localhost:" + str(self.server.server_port)})[0], 403)
        self.assertEqual(self.request("/api/inspect", method="GET")[0], 404)
        self.assertEqual(self.request("/")[0], 403)
        self.assertEqual(self.request("/", method="GET")[0], 200)
        self.assertEqual(self.request("/fixture-run-2", method="GET")[0], 200)
        self.assertEqual(self.request("/api/inspect?token=secret-canary")[0], 403)
        self.assertNotIn("secret-canary", json.dumps(self.state.events))

    def test_pair_one_use_expiry_and_failure_lock(self):
        self.assertGreaterEqual(len(self.secret), 22)
        self.pair()
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret})[0], 403)
        self.secret = self.state.issue_pair_secret()
        self.now[0] += 300
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret})[0], 403)
        self.secret = self.state.issue_pair_secret()
        for _ in range(5):
            self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": "wrong"})[0], 403)
        self.assertEqual(self.request("/api/pair", {"profile": "synthetic-A", "secret": self.secret})[0], 403)
        self.secret = self.state.issue_pair_secret()
        self.pair()

    def test_session_profile_logout_restart_and_expiry(self):
        session = self.pair()
        self.assertEqual(self.authorized("/api/inspect", session)[0], 200)
        self.assertEqual(self.authorized("/api/inspect", session, {"profile": "synthetic-B"})[0], 403)
        self.assertEqual(self.authorized("/api/inspect", session, {"generation": "stale"})[0], 403)
        self.assertEqual(self.authorized("/api/logout", session)[0], 200)
        self.assertEqual(self.authorized("/api/inspect", session)[0], 403)
        self.secret = self.state.issue_pair_secret()
        session = self.pair()
        self.now[0] += 12 * 3600
        self.assertEqual(self.authorized("/api/inspect", session)[0], 403)
        self.secret = self.state.issue_pair_secret()
        session = self.pair()
        self.state.switch_profile("synthetic-B")
        self.assertEqual(self.authorized("/api/inspect", session)[0], 403)
        self.state.revoke_access()
        restarted = State(clock=lambda: self.now[0])
        self.assertFalse(restarted.authorize(session["token"], "synthetic-A", session["generation"]))

    def test_synthetic_intent_recovery_and_inert_content(self):
        session = self.pair()
        status, snapshot = self.authorized("/api/inspect", session)
        self.assertEqual(status, 200)
        self.assertIn("<img", snapshot["item"]["text"])
        self.assertEqual(self.authorized("/api/submit", session, {"item": "wrong", "operation": "op-one", "text": "hi"})[0], 400)
        self.assertEqual(self.authorized("/api/submit", session, {"item": "fixture-one", "operation": "op-one", "text": "exact <hi> "})[0], 200)
        self.assertEqual(self.authorized("/api/submit", session, {"item": "fixture-one", "operation": "op-one", "text": "changed"})[0], 409)
        self.assertEqual(self.authorized("/api/submit", session, {"item": "fixture-one", "operation": "op-one", "text": "exact <hi> "})[0], 200)
        self.assertEqual(self.authorized("/api/submit", session, {"item": "fixture-one", "operation": "op-two", "text": "again"})[0], 409)
        status, found = self.authorized("/api/lookup", session, {"operation": "op-one"})
        self.assertEqual(status, 200)
        self.assertEqual(found["intent"]["text"], "exact <hi> ")
        self.assertEqual(found["intent"]["item"], "fixture-one")
        self.assertEqual(self.state.revision, 1)
        trace = json.dumps(self.state.events)
        self.assertNotIn(session["token"], trace)
        self.assertNotIn(self.secret, trace)
        self.assertNotIn("exact <hi> ", trace)

    def test_profile_switch_fences_intent_but_same_profile_repair_recovers(self):
        a = self.pair()
        self.assertEqual(self.authorized("/api/submit", a, {"item": "fixture-one", "operation": "a-op", "text": "A private answer"})[0], 200)
        self.state.revoke_access()
        self.secret = self.state.issue_pair_secret()
        repaired_a = self.pair()
        self.assertEqual(self.authorized("/api/lookup", repaired_a, {"operation": "a-op"})[1]["intent"]["text"], "A private answer")
        self.state.switch_profile("synthetic-B")
        self.assertEqual(self.authorized("/api/inspect", repaired_a)[0], 403)
        self.secret = self.state.issue_pair_secret()
        b = self.pair("synthetic-B")
        status, snapshot = self.authorized("/api/inspect", b)
        self.assertEqual(status, 200)
        self.assertIsNone(snapshot["intent"])
        self.assertEqual(snapshot["revision"], 0)
        self.assertIsNone(self.authorized("/api/lookup", b, {"operation": "a-op"})[1]["intent"])
        self.assertEqual(self.authorized("/api/submit", b, {"item": "fixture-one", "operation": "b-op", "text": "B answer"})[0], 200)
        self.state.switch_profile("synthetic-A")
        self.secret = self.state.issue_pair_secret()
        new_a = self.pair()
        self.assertIsNone(self.authorized("/api/inspect", new_a)[1]["intent"])

    def test_incremental_stream_and_reconnect(self):
        session = self.pair()
        blocked = threading.Event()
        release = threading.Event()
        first_stream = [True]

        def gate(index):
            if index == 1 and first_stream[0]:
                first_stream[0] = False
                blocked.set()
                if not release.wait(5):
                    raise AssertionError("stream test gate was not released")

        self.state.stream_gate = gate
        def connect():
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
            connection.request("POST", "/api/stream", body=json.dumps({"profile": session["profile"], "generation": session["generation"]}),
                               headers={"Content-Type": "application/json", "Origin": self.server.origin,
                                        "Authorization": "Bearer " + session["token"]})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return connection, response

        connection, response = connect()
        try:
            self.assertEqual(json.loads(response.readline())["snapshot"], 0)
            self.assertTrue(blocked.wait(5), "first stream never reached the controlled second snapshot")
            response.close()
            connection.close()
        finally:
            release.set()
        connection, response = connect()
        try:
            self.assertEqual([json.loads(response.readline())["snapshot"] for _ in range(4)], [0, 1, 2, 3])
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main()
