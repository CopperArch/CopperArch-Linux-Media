#!/bin/bash
# ollama-model-update.sh — keep the local LLM models current.
#
# `ollama pull` is a no-op when the remote manifest matches what is on disk, so
# this is safe to run nightly: it only transfers layers that actually changed.
# Called from daily-routine.sh (§8c); also fine to run by hand.
#
#   ollama-model-update.sh            # update every installed model
#   ollama-model-update.sh --check    # report only, pull nothing
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"

CHECK=false
[[ "${1:-}" == "--check" ]] && CHECK=true
say() { echo "  $*"; }

# Local AI is opt-in at install time; nothing to do on machines without it.
if ! command -v ollama >/dev/null 2>&1; then
    say "[SKIP] ollama not installed (Local AI not selected)"
    exit 0
fi

# The server is a user service; without it nothing below can work.
if ! curl -sf -m 8 -o /dev/null "http://$OLLAMA_HOST/api/version"; then
    say "  ollama not responding — trying to start it"
    systemctl --user start ollama.service 2>/dev/null
    for i in $(seq 1 15); do
        curl -sf -m 3 -o /dev/null "http://$OLLAMA_HOST/api/version" && break
        sleep 2
    done
fi
if ! curl -sf -m 8 -o /dev/null "http://$OLLAMA_HOST/api/version"; then
    say "[FAIL] ollama is not running — skipping model updates"
    exit 1
fi

MODELS=$(curl -sf -m 15 "http://$OLLAMA_HOST/api/tags" \
    | python3 -c 'import sys,json;[print(m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2>/dev/null)

if [[ -z "${MODELS// }" ]]; then
    say "[SKIP] no models installed yet"
    exit 0
fi

# Models live on the mergerfs pool, not root — but check anyway, because a
# pull that fills a disk is exactly the failure this box has had before.
MDIR=$(systemctl --user show ollama.service -p Environment --value 2>/dev/null \
       | tr ' ' '\n' | sed -n 's/^OLLAMA_MODELS=//p')
MDIR="${MDIR:-$HOME/.ollama/models}"
AVAIL_GB=$(df -BG --output=avail "$MDIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$AVAIL_GB" && "$AVAIL_GB" -lt 20 ]]; then
    say "[FAIL] only ${AVAIL_GB}G free at $MDIR — refusing to pull"
    exit 1
fi

# Digest of one model as ollama currently has it on disk.
digest_of() {
    curl -sf -m 15 "http://$OLLAMA_HOST/api/tags" 2>/dev/null | python3 -c "
import sys,json
want=sys.argv[1]
for m in json.load(sys.stdin).get('models',[]):
    if m['name']==want: print(m.get('digest','')); break
" "$1" 2>/dev/null
}

UPDATED=0; CURRENT=0; FAILED=0
while read -r m; do
    [[ -z "$m" ]] && continue
    if $CHECK; then
        say "[INFO] would check $m"
        continue
    fi
    # Compare the stored digest before and after. `ollama pull` prints
    # "pulling <layer> 100%" for cached layers too, so parsing its output
    # reports an update every single night even when nothing changed.
    BEFORE=$(digest_of "$m")
    OUT=$(ollama pull "$m" 2>&1 | tr '\r' '\n' | tail -20)
    AFTER=$(digest_of "$m")

    if echo "$OUT" | grep -qiE '^Error|error:|failed'; then
        say "[FAIL] $m — $(echo "$OUT" | grep -iE '^Error|error:|failed' | tail -1 | cut -c1-90)"
        FAILED=$((FAILED+1))
    elif [[ -n "$BEFORE" && -n "$AFTER" && "$BEFORE" != "$AFTER" ]]; then
        say "[FIX]  $m updated (${BEFORE:0:12} -> ${AFTER:0:12})"
        UPDATED=$((UPDATED+1))
    else
        say "[OK]   $m already current (${AFTER:0:12})"
        CURRENT=$((CURRENT+1))
    fi
done <<< "$MODELS"

$CHECK && exit 0
say "[OK]   models: $CURRENT current, $UPDATED updated, $FAILED failed"
say "       store: $MDIR (${AVAIL_GB:-?}G free)"
exit $(( FAILED > 0 ))
