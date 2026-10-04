"""Stand-in sync server, so smoke_test.sh can be run without a Dart toolchain.

Usage:
    python server/tool/fake_server.py &
    PYTHON=python SMOKE_FAKE_BASE=http://127.0.0.1:18788 \
      server/tool/smoke_test.sh -

It is the only way to check the script itself when the real binary cannot run
locally; a missing wrapper in the push body was found this way.

Implements the same rules the real server does (last-writer-wins with a
device-id tiebreak, content-addressed blobs) so the script's assertions mean
the same thing here as they do in CI.
"""
import hashlib
import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PASSWORD = "smoke-test-password"
TOKEN = "fake-token-abc"

records = {}
rev = 0
blobs = {}


def merge(incoming):
    global rev
    key = (incoming["namespace"], incoming["id"])
    cur = records.get(key)
    if cur is None:
        rev += 1
        records[key] = (incoming, rev)
        return "accepted", None
    if incoming["updatedAt"] != cur[0]["updatedAt"]:
        wins = incoming["updatedAt"] > cur[0]["updatedAt"]
    elif incoming.get("deleted", False) != cur[0].get("deleted", False):
        wins = incoming.get("deleted", False)
    elif incoming["deviceId"] == cur[0]["deviceId"]:
        wins = json.dumps(incoming["payload"], sort_keys=True) != json.dumps(
            cur[0]["payload"], sort_keys=True
        )
    else:
        wins = incoming["deviceId"] > cur[0]["deviceId"]
    if wins:
        rev += 1
        records[key] = (incoming, rev)
        return "accepted", None
    return "stale", cur[0]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _body(self):
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    def _json(self, code, obj):
        raw = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self):
        header = self.headers.get("authorization") or ""
        return header == f"Bearer {TOKEN}"

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            return self._json(200, {"ok": True, "rev": rev, "connections": 0})
        if parsed.path.startswith("/api/blob/"):
            digest = parsed.path.rsplit("/", 1)[-1]
            data = blobs.get(digest)
            if data is None or not self._authorized():
                return self._json(404, {"error": "no_blob"})
            self.send_response(200)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/api/changes":
            if not self._authorized():
                return self._json(401, {"error": "unauthorized"})
            since = int(parse_qs(parsed.query).get("since", ["0"])[0])
            changes = []
            for (ns, rid), (rec, r) in sorted(records.items(), key=lambda kv: kv[1][1]):
                if r > since:
                    out = dict(rec)
                    out["rev"] = r
                    changes.append(out)
            return self._json(
                200,
                {"rev": rev, "serverRev": rev, "hasMore": False, "changes": changes},
            )
        self._json(404, {"error": "not_found"})

    def do_HEAD(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/blob/"):
            digest = parsed.path.rsplit("/", 1)[-1]
            if digest in blobs and self._authorized():
                self.send_response(200)
            else:
                self.send_response(404)
            self.end_headers()
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/login":
            body = json.loads(self._body() or b"{}")
            if body.get("password") != PASSWORD:
                return self._json(401, {"error": "bad_password"})
            return self._json(200, {"token": TOKEN, "expiresInSeconds": 3600, "rev": rev})
        if not self._authorized():
            return self._json(401, {"error": "unauthorized"})
        if parsed.path == "/api/push":
            body = json.loads(self._body() or b"{}")
            accepted, rejected = 0, []
            for rec in body.get("records", []):
                outcome, current = merge(rec)
                if outcome == "accepted":
                    accepted += 1
                elif outcome == "stale":
                    rejected.append(current)
            return self._json(200, {"rev": rev, "accepted": accepted, "rejected": rejected})
        if parsed.path == "/api/blob":
            data = self._body()
            digest = hashlib.sha256(data).hexdigest()
            blobs[digest] = data
            return self._json(200, {"hash": digest, "size": len(data)})
        if parsed.path == "/api/blobs/check":
            body = json.loads(self._body() or b"{}")
            present = [h for h in body.get("hashes", []) if h in blobs]
            return self._json(200, {"present": present})
        self._json(404, {"error": "not_found"})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 18788), Handler).serve_forever()
