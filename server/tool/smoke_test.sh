#!/usr/bin/env bash
# End-to-end check of the sync protocol against a real server binary.
#
# Simulates two devices talking through one server and asserts the properties
# the design actually promises: messages from both sides survive, a stale write
# loses and is told what won, deletions propagate, and attachment bytes go round
# trip. Everything here talks HTTP exactly as a client would.
#
# Usage: server/tool/smoke_test.sh <path-to-server-binary>
#        SMOKE_FAKE_BASE=<url> server/tool/smoke_test.sh -   (use an existing server)
set -euo pipefail

BIN="${1:?usage: smoke_test.sh <server-binary>}"
PORT="${SMOKE_PORT:-18787}"
PASSWORD="smoke-test-password"
EXTERNAL_BASE="${SMOKE_FAKE_BASE:-}"
BASE="${EXTERNAL_BASE:-http://127.0.0.1:${PORT}}"
WORKDIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ] && [ -z "$EXTERNAL_BASE" ] && [ -f "$WORKDIR/server.log" ]; then
    echo "--- server log (last 30 lines) ---" >&2
    tail -30 "$WORKDIR/server.log" >&2 || true
  fi
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORKDIR"
  return "$code"
}
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

# Overridable because some Windows setups alias `python3` to a Microsoft Store
# stub that exits immediately without running anything.
PYTHON="${PYTHON:-python3}"
json() { "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

if [ -z "$EXTERNAL_BASE" ]; then
  mkdir -p "$WORKDIR/data"
  cat > "$WORKDIR/config.json" <<EOF
{
  "password": "$PASSWORD",
  "dataDir": "$WORKDIR/data",
  "host": "127.0.0.1",
  "port": $PORT
}
EOF
  "$BIN" --config "$WORKDIR/config.json" > "$WORKDIR/server.log" 2>&1 &
  SERVER_PID=$!
fi

# Every request goes through here so a failure prints what the server said.
# A bare `curl -f` exits with no explanation, which is exactly how an earlier
# version of this script failed silently at the first push.
api() { # api <method> <path> [token] [body-file] -> body on stdout
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local out="$WORKDIR/resp.json"
  local status
  # Arguments spelled out rather than collected into an array: `local -a x=(...)`
  # behaved inconsistently across the bash builds this ran under, leaving curl
  # with nothing to do, which is the worst possible failure here -- silent.
  if [ -n "$body" ]; then
    status=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "$BASE$path" \
      -H "Authorization: Bearer $token" \
      -H 'content-type: application/json' \
      --data-binary "@$body" 2>/dev/null || true)
  else
    status=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "$BASE$path" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
  fi
  if [ "$status" != "200" ]; then
    echo "  !! $method $path -> HTTP ${status:-<no response>}" >&2
    head -c 400 "$out" 2>/dev/null >&2 || true
    echo >&2
    exit 1
  fi
  cat "$out"
}

push() { # push <token> <json-array> -> response body
  # The array has to be wrapped: the endpoint takes {"records":[...]}, and a
  # bare array is rejected as invalid_records.
  printf '{"records":%s}' "$2" > "$WORKDIR/body.json"
  api POST /api/push "$1" "$WORKDIR/body.json"
}

echo "== startup =="
for _ in $(seq 1 40); do
  if api GET /api/health > "$WORKDIR/health.json" 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q '"ok":true' "$WORKDIR/health.json" || fail "health check never came up"
pass "health responds"

echo "== auth =="
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" \
  -H 'content-type: application/json' -d '{"password":"wrong"}')
[ "$code" = "401" ] || fail "wrong password was accepted (HTTP $code)"
pass "wrong password rejected"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/changes?since=0")
[ "$code" = "401" ] || fail "unauthenticated read was allowed (HTTP $code)"
pass "unauthenticated read rejected"

login() { # login -> token
  printf '{"password":"%s"}' "$PASSWORD" > "$WORKDIR/login.json"
  api POST /api/login "" "$WORKDIR/login.json" | json 'd["token"]'
}

TOKEN_A=$(login)
TOKEN_B=$(login)
[ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] || fail "login returned no token"
pass "both devices logged in"

echo "== messages from two devices both survive =="
push "$TOKEN_A" '[
  {"namespace":"conversation","id":"c1","payload":{"id":"c1","title":"from A","updated_at":1000},"updatedAt":1000,"deviceId":"dev-a"},
  {"namespace":"message","id":"m1","payload":{"id":"m1","conversation_id":"c1","text":"hello from A"},"updatedAt":1000,"deviceId":"dev-a"}
]' > "$WORKDIR/p1.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p1.json")" = "2" ] || fail "device A push was not accepted"
pass "device A published its conversation and message"

api GET "/api/changes?since=0" "$TOKEN_B" > "$WORKDIR/b1.json"
[ "$(json 'len(d["changes"])' < "$WORKDIR/b1.json")" = "2" ] || fail "device B did not see both records"
pass "device B received device A's records"

push "$TOKEN_B" '[
  {"namespace":"message","id":"m2","payload":{"id":"m2","conversation_id":"c1","text":"hello from B"},"updatedAt":2000,"deviceId":"dev-b"}
]' > "$WORKDIR/p2.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p2.json")" = "1" ] || fail "device B push was not accepted"

# Device A pulls: it must now hold BOTH messages. This is the property that
# matters most -- two devices appending to one conversation must lose neither.
api GET "/api/changes?since=0" "$TOKEN_A" > "$WORKDIR/a2.json"
count=$(json 'len([c for c in d["changes"] if c["namespace"]=="message"])' < "$WORKDIR/a2.json")
[ "$count" = "2" ] || fail "expected 2 messages after merge, saw $count"
pass "both devices' messages survive (union, not overwrite)"

echo "== stale write loses and is told what won =="
push "$TOKEN_B" '[
  {"namespace":"conversation","id":"c1","payload":{"id":"c1","title":"stale edit"},"updatedAt":500,"deviceId":"dev-b"}
]' > "$WORKDIR/p3.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p3.json")" = "0" ] || fail "stale write was accepted"
[ "$(json 'len(d["rejected"])' < "$WORKDIR/p3.json")" = "1" ] || fail "stale write was not reported back"
winner=$(json 'd["rejected"][0]["payload"]["title"]' < "$WORKDIR/p3.json")
[ "$winner" = "from A" ] || fail "rejected record carried the wrong winner: $winner"
pass "stale write rejected, winner returned (title=$winner)"

echo "== deletions propagate =="
push "$TOKEN_A" '[
  {"namespace":"tombstone","id":"tomb-1","payload":{"scope":"conversation","entity_id":"c1","deleted_at":3000},"updatedAt":3000,"deviceId":"dev-a"}
]' > "$WORKDIR/p4.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p4.json")" = "1" ] || fail "tombstone was not accepted"
api GET "/api/changes?since=0" "$TOKEN_B" > "$WORKDIR/b4.json"
found=$(json 'len([c for c in d["changes"] if c["namespace"]=="tombstone"])' < "$WORKDIR/b4.json")
[ "$found" = "1" ] || fail "device B did not receive the tombstone"
pass "tombstone reached the other device"

echo "== attachment bytes round trip =="
head -c 4096 /dev/urandom > "$WORKDIR/photo.bin"
EXPECTED=$(sha256sum "$WORKDIR/photo.bin" | cut -d' ' -f1)

HASH=$(api POST /api/blob "$TOKEN_A" "$WORKDIR/photo.bin" | json 'd["hash"]')
[ "$HASH" = "$EXPECTED" ] || fail "server computed a different hash: $HASH vs $EXPECTED"
pass "upload stored under its content hash"

printf '{"hashes":["%s","0000000000000000000000000000000000000000000000000000000000000000"]}' \
  "$HASH" > "$WORKDIR/check.json"
present=$(api POST /api/blobs/check "$TOKEN_B" "$WORKDIR/check.json" | json '",".join(d["present"])')
[ "$present" = "$HASH" ] || fail "bulk check reported '$present', expected only '$HASH'"
pass "bulk check reports what the server holds"

curl -s "$BASE/api/blob/$HASH" -H "Authorization: Bearer $TOKEN_B" \
  -o "$WORKDIR/downloaded.bin"
GOT=$(sha256sum "$WORKDIR/downloaded.bin" | cut -d' ' -f1)
[ "$GOT" = "$EXPECTED" ] || fail "downloaded bytes differ from what was uploaded"
pass "the other device downloaded identical bytes"

AGAIN=$(api POST /api/blob "$TOKEN_B" "$WORKDIR/photo.bin" | json 'd["hash"]')
[ "$AGAIN" = "$EXPECTED" ] || fail "re-upload produced a different hash"
pass "identical content deduplicates"

if [ -z "$EXTERNAL_BASE" ]; then
  echo "== persistence across restart =="
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  "$BIN" --config "$WORKDIR/config.json" >> "$WORKDIR/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do
    if curl -sf "$BASE/api/health" > /dev/null 2>&1; then break; fi
    sleep 0.5
  done
  TOKEN_C=$(login)
  api GET "/api/changes?since=0" "$TOKEN_C" > "$WORKDIR/after.json"
  after=$(json 'len(d["changes"])' < "$WORKDIR/after.json")
  [ "$after" -ge 5 ] || fail "records were lost across a restart (saw $after)"
  pass "records and the signing key survived a restart"
fi

echo
echo "SMOKE TEST PASSED"
