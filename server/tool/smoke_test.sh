#!/usr/bin/env bash
# End-to-end check of the sync protocol against a real server binary.
#
# Simulates two devices talking through one server and asserts the properties
# the design actually promises: messages from both sides survive, a stale write
# loses and is told what won, deletions propagate, and attachment bytes go
# round trip. Everything here talks HTTP exactly as a client would.
#
# Usage: server/tool/smoke_test.sh <path-to-server-binary>
set -euo pipefail

BIN="${1:?usage: smoke_test.sh <server-binary>}"
PORT="${SMOKE_PORT:-18787}"
PASSWORD="smoke-test-password"
WORKDIR="$(mktemp -d)"
BASE="http://127.0.0.1:${PORT}"

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ] && [ -f "$WORKDIR/server.log" ]; then
    echo "--- server log (last 30 lines) ---" >&2
    tail -30 "$WORKDIR/server.log" >&2 || true
  fi
  if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORKDIR"
  return "$code"
}
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

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

echo "== startup =="
for _ in $(seq 1 40); do
  if curl -sf "$BASE/api/health" > "$WORKDIR/health.json" 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q '"ok":true' "$WORKDIR/health.json" || fail "health check never came up"
pass "health responds"

echo "== auth =="
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -d '{"password":"wrong"}')
[ "$code" = "401" ] || fail "wrong password was accepted (HTTP $code)"
pass "wrong password rejected"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/changes?since=0")
[ "$code" = "401" ] || fail "unauthenticated read was allowed (HTTP $code)"
pass "unauthenticated read rejected"

TOKEN_A=$(curl -sf -X POST "$BASE/api/login" -d "{\"password\":\"$PASSWORD\"}" | json 'd["token"]')
TOKEN_B=$(curl -sf -X POST "$BASE/api/login" -d "{\"password\":\"$PASSWORD\"}" | json 'd["token"]')
[ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] || fail "login returned no token"
pass "both devices logged in"

auth_a=(-H "Authorization: Bearer $TOKEN_A")
auth_b=(-H "Authorization: Bearer $TOKEN_B")

push() { # push <token-header...> <json-records>
  local token_header="$1"; shift
  curl -sf -X POST "$BASE/api/push" -H "$token_header" \
    -H 'content-type: application/json' -d "{\"records\":$1}"
}

echo "== messages from two devices both survive =="
# Device A starts a conversation and a message in it.
push "$TOKEN_A" '[
  {"namespace":"conversation","id":"c1","payload":{"id":"c1","title":"from A","updated_at":1000},"updatedAt":1000,"deviceId":"dev-a"},
  {"namespace":"message","id":"m1","payload":{"id":"m1","conversation_id":"c1","text":"hello from A"},"updatedAt":1000,"deviceId":"dev-a"}
]' "$WORKDIR/p1.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p1.json")" = "2" ] || fail "device A push was not accepted"
pass "device A published its conversation and message"

# Device B pulls, then adds its own message to the SAME conversation.
get "/api/changes?since=0" "$TOKEN_B" "$WORKDIR/b1.json"
[ "$(json 'len(d["changes"])' < "$WORKDIR/b1.json")" = "2" ] || fail "device B did not see both records"
pass "device B received device A's records"

push "$TOKEN_B" '[
  {"namespace":"message","id":"m2","payload":{"id":"m2","conversation_id":"c1","text":"hello from B"},"updatedAt":2000,"deviceId":"dev-b"}
]' "$WORKDIR/p2.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p2.json")" = "1" ] || fail "device B push was not accepted"

# Device A pulls: it must now hold BOTH messages. This is the property that
# matters most -- two devices appending to one conversation must not lose either.
get "/api/changes?since=0" "$TOKEN_A" "$WORKDIR/a2.json"
count=$(json 'len([c for c in d["changes"] if c["namespace"]=="message"])' < "$WORKDIR/a2.json")
[ "$count" = "2" ] || fail "expected 2 messages after merge, saw $count"
pass "both devices' messages survive (union, not overwrite)"

echo "== stale write loses and is told what won =="
# Device B writes an older version of the same record.
push "$TOKEN_B" '[
  {"namespace":"conversation","id":"c1","payload":{"id":"c1","title":"stale edit"},"updatedAt":500,"deviceId":"dev-b"}
]' "$WORKDIR/p3.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p3.json")" = "0" ] || fail "stale write was accepted"
[ "$(json 'len(d["rejected"])' < "$WORKDIR/p3.json")" = "1" ] || fail "stale write was not reported back"
winner=$(json 'd["rejected"][0]["payload"]["title"]' < "$WORKDIR/p3.json")
[ "$winner" = "from A" ] || fail "rejected record carried the wrong winner: $winner"
pass "stale write rejected, winner returned (title=$winner)"

echo "== deletions propagate =="
push "$TOKEN_A" '[
  {"namespace":"tombstone","id":"[\"conversation\",\"c1\"]","payload":{"scope":"conversation","entity_id":"c1","deleted_at":3000},"updatedAt":3000,"deviceId":"dev-a"}
]' "$WORKDIR/p4.json"
[ "$(json 'd["accepted"]' < "$WORKDIR/p4.json")" = "1" ] || fail "tombstone was not accepted"
get "/api/changes?since=0" "$TOKEN_B" "$WORKDIR/b4.json"
found=$(json 'len([c for c in d["changes"] if c["namespace"]=="tombstone"])' < "$WORKDIR/b4.json")
[ "$found" = "1" ] || fail "device B did not receive the tombstone"
pass "tombstone reached the other device"

echo "== attachment bytes round trip =="
head -c 4096 /dev/urandom > "$WORKDIR/photo.bin"
EXPECTED=$(sha256sum "$WORKDIR/photo.bin" | cut -d' ' -f1)

HASH=$(curl -sf -X POST "$BASE/api/blob" "${auth_a[@]}" \
  --data-binary "@$WORKDIR/photo.bin" | json 'd["hash"]')
[ "$HASH" = "$EXPECTED" ] || fail "server computed a different hash: $HASH vs $EXPECTED"
pass "upload stored under its content hash"

present=$(curl -sf -X POST "$BASE/api/blobs/check" "${auth_b[@]}" \
  -H 'content-type: application/json' \
  -d "{\"hashes\":[\"$HASH\",\"0000000000000000000000000000000000000000000000000000000000000000\"]}" \
  | json '"yes" if d["present"]==["'"$HASH"'"] else "no"')
[ "$present" = "yes" ] || fail "bulk check did not report exactly the stored hash"
pass "bulk check reports what the server holds"

curl -sf "$BASE/api/blob/$HASH" "${auth_b[@]}" -o "$WORKDIR/downloaded.bin"
GOT=$(sha256sum "$WORKDIR/downloaded.bin" | cut -d' ' -f1)
[ "$GOT" = "$EXPECTED" ] || fail "downloaded bytes differ from what was uploaded"
pass "the other device downloaded identical bytes"

# Re-uploading the same content must not create a second object.
AGAIN=$(curl -sf -X POST "$BASE/api/blob" "${auth_b[@]}" \
  --data-binary "@$WORKDIR/photo.bin" | json 'd["hash"]')
[ "$AGAIN" = "$EXPECTED" ] || fail "re-upload produced a different hash"
pass "identical content deduplicates"

echo "== persistence across restart =="
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
"$BIN" --config "$WORKDIR/config.json" >> "$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  if curl -sf "$BASE/api/health" > /dev/null 2>/dev/null; then break; fi
  sleep 0.5
done
TOKEN_C=$(curl -sf -X POST "$BASE/api/login" -d "{\"password\":\"$PASSWORD\"}" | json 'd["token"]')
get "/api/changes?since=0" "$TOKEN_C" "$WORKDIR/after.json"
after=$(json 'len(d["changes"])' < "$WORKDIR/after.json")
[ "$after" -ge 5 ] || fail "records were lost across a restart (saw $after)"
pass "records and the signing key survived a restart"

echo
echo "SMOKE TEST PASSED"
