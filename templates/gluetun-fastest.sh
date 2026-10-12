#!/usr/bin/env bash
# Cycle the gluetun VPN exit (same in-place control-server cycle as
# gluetun-rotate.sh — no container restart, netns siblings untouched) up to
# a few times, measuring latency through the tunnel after each reconnect, and
# stop as soon as a good-enough exit turns up.
#
# HONEST LIMITATION: the VPN provider assigns the exit node, not us — there is
# no "connect to server X" call for OpenVPN here, only "reconnect and get
# whatever the pool hands you". So this is a bounded best-of-N search, not a
# guaranteed-fastest pin: if attempt 2 was the fastest of the batch but
# attempt 5 (the last one tried) wasn't as good, the tunnel is left on
# attempt 5's exit, not rewound to attempt 2's — that would require yet
# another reconnect gambling on getting the same node back. The threshold
# below just means "stop early once it's good, instead of always burning all
# N attempts."
#
# Manual/dashboard-triggered only (not cron).
set -uo pipefail

KEY_FILE="${HOME}/.config/gluetun/rotate.key"
LOG="${HOME}/.local/state/gluetun-fastest.log"
CTRL="http://127.0.0.1:8000"
MAX_WAIT=150
MAX_ATTEMPTS=5
GOOD_ENOUGH_MS=35
PING_TARGET=1.1.1.1
PING_COUNT=4

mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

[ -r "$KEY_FILE" ] || { log "ERROR: no key at $KEY_FILE"; exit 1; }
KEY="$(cat "$KEY_FILE")"

ctrl() { # ctrl <method> <path> [body]
  docker exec gluetun wget -q -O- --method="$1" \
    --header="X-API-Key: ${KEY}" \
    ${3:+--header="Content-Type: application/json" --body-data="$3"} \
    "${CTRL}$2" 2>/dev/null
}

# See gluetun-rotate.sh: the control server's own publicip lookup rate-limits
# and goes empty for long stretches, so fall back to a direct check through
# the tunnel, which is what actually matters here anyway.
ip_now() {
  local ip
  ip="$(ctrl GET /v1/publicip/ip | sed -n 's/.*"public_ip":"\([^"]*\)".*/\1/p')"
  if [ -z "$ip" ]; then
    ip="$(docker exec gluetun wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null \
          | tr -d '[:space:]')"
    case "$ip" in *[!0-9.]*|"") ip="" ;; esac
  fi
  printf '%s' "$ip"
}

cycle() {
  ctrl PUT /v1/openvpn/status '{"status":"stopped"}' >/dev/null
  sleep 3
  ctrl PUT /v1/openvpn/status '{"status":"running"}' >/dev/null
  for _ in $(seq 1 $((MAX_WAIT / 3))); do
    sleep 3
    NEW="$(ip_now)"
    [ -n "$NEW" ] && return 0
  done
  return 1
}

# Average round-trip ms through the tunnel, or empty on failure/no ping.
latency_ms() {
  local out
  out="$(docker exec gluetun ping -c "$PING_COUNT" -W 2 "$PING_TARGET" 2>/dev/null)" || true
  printf '%s' "$out" | sed -n 's#.*/\([0-9.]*\)/[0-9.]*\s*ms$#\1#p' | tail -1
}

docker ps --format '{{.Names}}' | grep -qx gluetun || { log "ERROR: gluetun not running"; exit 1; }

log "searching for a fast VPN exit (up to $MAX_ATTEMPTS attempts, accepting <= ${GOOD_ENOUGH_MS}ms)"

best_ms="" best_ip="" any_ok=0
for attempt in $(seq 1 $MAX_ATTEMPTS); do
  if ! cycle; then
    log "attempt $attempt: reconnect got no public IP, trying again"
    continue
  fi
  ip="$NEW"
  ms="$(latency_ms)"
  if [ -z "$ms" ]; then
    log "attempt $attempt: exit ${ip} — ping failed, treating as slow"
    continue
  fi
  any_ok=1
  log "attempt $attempt: exit ${ip} — ${ms}ms"
  if [ -z "$best_ms" ] || awk -v a="$ms" -v b="$best_ms" 'BEGIN{exit !(a<b)}'; then
    best_ms="$ms"; best_ip="$ip"
  fi
  if awk -v a="$ms" -v b="$GOOD_ENOUGH_MS" 'BEGIN{exit !(a<=b)}'; then
    log "good enough — stopping on exit ${ip} (${ms}ms)"
    break
  fi
done

if [ "$any_ok" -eq 0 ]; then
  log "ERROR: every attempt failed to reconnect or measure latency — tunnel may be down"
  exit 1
fi

final_ip="$(ip_now)"
log "RESULT: settled on exit ${final_ip:-unknown}; best seen this run was ${best_ip} at ${best_ms}ms"
if [ "$final_ip" != "$best_ip" ]; then
  log "note: the current exit isn't the best one seen — the provider assigns the node on reconnect, so the fastest of the batch can't be pinned after the fact"
fi
