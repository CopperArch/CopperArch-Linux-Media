#!/bin/bash
# dashboard-pane.sh — decides what runs in the dashboard's terminal pane.
#
# ttyd is started with --url-arg, so the page picks a program by URL:
#     http://127.0.0.1:7682/?arg=claude
#     http://127.0.0.1:7682/?arg=htop
#     http://127.0.0.1:7682/?arg=ask&arg=why+is+radarr+failing
#
# Arguments arrive as argv (never a shell string) and the first one is matched
# against a fixed whitelist here, so the URL can only ever select one of these
# programs — it can't smuggle in a command.
#
# Every pane falls back to an interactive shell when its program exits, so the
# pane is never a dead black rectangle.
set -uo pipefail
# ttyd execs this script directly (not as a login/interactive shell), so
# ~/.bashrc never runs — opencode's own PATH entry lives there and has to be
# repeated here or every "command not found: opencode" pane fails silently.
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
cd "$HOME" || exit 1

PROG="${1:-claude}"
shift || true

# Agent panes run real, possibly long fixes — closing the dock (width -> 0)
# blanks the iframe, which drops ttyd's websocket and sends the child SIGHUP
# (see status-dashboard's 2026-09-04 "off" fix). Running these under tmux
# means that SIGHUP just detaches the tmux client; the session (and whatever
# the agent is doing) keeps running headless, and reopening the same pane
# reattaches to it instead of starting over. One session per agent id
# (dash-claude, dash-opencode, dash-oa, ...) so different panes never share
# state. DASHBOARD_PANE_TMUX guards against re-wrapping once we're already
# the tmux-managed re-exec.
AGENT_PANES=(claude opencode oa mm qw gpt gm hy ds)
# "free:<openrouter model id>" panes (the picker's FREE tier) are agent panes
# too. tmux session names can't hold ':' '.' or '/', so those are flattened.
if [[ -z "${DASHBOARD_PANE_TMUX:-}" ]] && command -v tmux >/dev/null 2>&1 \
   && { printf '%s\n' "${AGENT_PANES[@]}" | grep -qx -- "$PROG" || [[ "$PROG" == free:* ]]; }; then
    export DASHBOARD_PANE_TMUX=1
    # Highlight-to-copy. The agents turn on mouse tracking and tmux passes
    # that through to ttyd's xterm.js, so a drag went to the app and nothing
    # could ever be selected. With tmux owning the mouse, a left-drag (or
    # double/triple click) always selects, and releasing copies straight to
    # the desktop clipboard for pasting into a terminal, editor, etc. Plain
    # clicks and the scroll wheel still reach the app.
    CLIP=""
    if command -v wl-copy >/dev/null 2>&1; then CLIP="wl-copy"
    elif command -v xclip >/dev/null 2>&1; then CLIP="xclip -selection clipboard"
    elif command -v xsel  >/dev/null 2>&1; then CLIP="xsel -ib"
    fi
    # ';' separates top-level tmux commands; '\;' chains inside a binding.
    COPY_OPTS=(';' set-option mouse on)
    if [[ -n "$CLIP" ]]; then
        COPY_OPTS+=(
          ';' bind-key -T root MouseDrag1Pane select-pane -t = '\;' copy-mode -M
          ';' bind-key -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$CLIP"
          ';' bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "$CLIP"
          ';' bind-key -T root DoubleClick1Pane select-pane -t = '\;' copy-mode -M '\;' send-keys -X select-word '\;' send-keys -X copy-pipe-and-cancel "$CLIP"
          ';' bind-key -T root TripleClick1Pane select-pane -t = '\;' copy-mode -M '\;' send-keys -X select-line '\;' send-keys -X copy-pipe-and-cancel "$CLIP"
        )
    fi
    exec tmux new-session -A -s "dash-${PROG//[^A-Za-z0-9_-]/_}" "$0" "$PROG" "$@" "${COPY_OPTS[@]}"
fi

# Which local model the llm/askllm panes use. Override in the environment to
# switch without editing this script.
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"

# Local GLM pane — Z.ai's official open-weights GLM-4.7-Flash (30B MoE, ~3B
# active, 19 GB Q4) from the Ollama library, or glm4:9b on <24 GB RAM boxes.
# Slower than qwen on CPU but far stronger at code/reasoning, free/offline. Short
# keep-alive: the service default is 24h, which would pin 19 GB of RAM all day.
# Only pull from the official library (ollama.com/library) — "free GLM-5.x
# installer" repos on GitHub are malware lures (glm-5-ZAI/GLM-5.2, 2026-09-29).
# The installer writes local-ai.env (GLM_MODEL=, sized to this machine's RAM)
# only when "Local AI" was ticked; without it the GLM panes are hidden.
AI_ENV="$HOME/.config/status-dashboard/local-ai.env"
[ -f "$AI_ENV" ] && . "$AI_ENV"
GLM_MODEL="${GLM_MODEL:-glm-4.7-flash}"
GLM_KEEPALIVE="${GLM_KEEPALIVE:-10m}"

# Online DeepSeek — always kept as one of the pane options. Put an API key
# (OpenRouter or compatible) in ~/.config/status-dashboard/deepseek.env:
#   DEEPSEEK_API_KEY=<your-openrouter-key>
#   DEEPSEEK_BASE_URL=https://openrouter.ai/api/v1   (default)
# DEEPSEEK_MODEL/OXALPHA_MODEL/MINIMAX_MODEL/CHATGPT_MODEL below are kept
# current by ai-panes-check.py's managed block in that same file (run
# nightly from daily-routine.sh) — it swaps in a cheap-paid variant if a
# model's free tier disappears rather than dropping the pane, so any of
# these four can end up briefly non-free between runs; see its output for
# the current pricing.
DS_ENV="$HOME/.config/status-dashboard/deepseek.env"
[ -f "$DS_ENV" ] && . "$DS_ENV"
DEEPSEEK_BASE_URL="${DEEPSEEK_BASE_URL:-https://openrouter.ai/api/v1}"
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek/deepseek-v4-flash:free}"

# Ox Alpha (stealth model on OpenRouter — was free during its preview,
# de-anonymized 2026-08-23 as Z.AI's GLM-5.3-Flash; see KNOWN_RENAMES in
# ai-panes-check.py). Same OpenRouter account as DeepSeek above, so it
# reuses DEEPSEEK_API_KEY/DEEPSEEK_BASE_URL — only the model slug differs.
OXALPHA_MODEL="${OXALPHA_MODEL:-stealth/ox-alpha}"

# Minimax M3 (free tier on OpenRouter, top-5 by usage as of 2026-09). Same
# OpenRouter account/key as the two panes above — only the model slug differs.
MINIMAX_MODEL="${MINIMAX_MODEL:-minimax/minimax-m3:free}"

# Qwen 3.8 (added 2026-10-06). No :free variant existed, so it starts on the
# cheapest paid one; ai-panes-check.py switches it to :free if one appears.
# Same OpenRouter account/key as the panes above.
QWEN_MODEL="${QWEN_MODEL:-qwen/qwen3.8-flash}"

# Best available paid models, one per remaining major provider not already
# covered above. No free tier exists for any of these three on OpenRouter —
# every query bills the OpenRouter account. All three are kept current by
# ai-panes-check.py, run nightly from daily-routine.sh.
CHATGPT_MODEL="${CHATGPT_MODEL:-openai/gpt-5.6-sol-pro}"   # ~$2 / $10 per M tokens
GEMINI_MODEL="${GEMINI_MODEL:-google/gemini-3.8-flash}"     # ~$0.75 / $3.75 per M tokens
HY4_MODEL="${HY4_MODEL:-tencent/hy4-preview}"                # ~$0.83 / $2.50 per M tokens

hr() { printf '── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }
fallback() {
    echo
    hr "$1 exited — dropping to a shell"
    exec bash -il
}

# Shared helpers for the ask*/agent model panes below — every one-shot pane
# used to repeat this same curl+python block inline.
need_key() {   # need_key <what-the-key-unlocks>; false (after a message) if unset
    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
        echo "no API key — create ~/.config/status-dashboard/deepseek.env with:"
        echo "  DEEPSEEK_API_KEY=<your key>"
        echo "Key from openrouter.ai ($1)"
        return 1
    fi
}
ask_curl() {   # ask_curl <model> <question> — one-shot OpenRouter chat call
    curl -s -m 120 "$DEEPSEEK_BASE_URL/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$1\",\"max_tokens\":8192,\"messages\":[{\"role\":\"user\",\"content\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")}]}" \
    | python3 -c '
import json,sys
# max_tokens matters: without it OpenRouter reserves the full model output
# limit (131k on Qwen 3.8) against the credit balance up front and refuses
# with 402 once the balance runs low, even for a one-line answer.
try:
    d=json.load(sys.stdin)
except Exception as e:
    print("request failed: no JSON reply", e); sys.exit()
if d.get("error"):
    print("OpenRouter error:", d["error"].get("message", d["error"]))
else:
    msg=d["choices"][0]["message"]
    print(msg.get("content") or "(empty answer — the model spent its whole budget thinking; ask again or shorten the question)")
'
}
press_enter() {
    echo
    hr "done — press enter for a shell"
    read -r _ 2>/dev/null
    exec bash -il
}

# Local (ollama) panes. OLLAMA_HOST must be set: the server is a *user*
# service on loopback, not the old system one. Extra args after the model
# (e.g. --keepalive) are passed straight to `ollama run`.
ollama_up() {
    export OLLAMA_HOST=127.0.0.1:11434
    curl -sf -m 5 -o /dev/null "http://$OLLAMA_HOST/api/version"
}
local_chat() {   # local_chat <model> [ollama-run flags...] — interactive chat
    local model="$1"; shift
    hr "Local LLM — $model"
    if ! ollama_up; then
        echo "ollama is not running — start it with:"
        echo "  systemctl --user start ollama.service"
    elif ! ollama list 2>/dev/null | grep -q "^$model"; then
        echo "model $model not pulled yet — fetching it now"
        ollama pull "$model" && ollama run "$@" "$model"
    else
        ollama run "$@" "$model"
    fi
    fallback "ollama"
}
local_ask() {    # local_ask <model> <question...> [--keepalive X] — one-shot
    local model="$1"; shift
    local flags=()
    if [[ "${*: -2:1}" == "--keepalive" ]]; then
        flags=(--keepalive "${*: -1}"); set -- "${@:1:$#-2}"
    fi
    local query="$*"
    hr "Ask $model"
    if [[ -z "${query// }" ]]; then
        echo "no question given"
    elif ! ollama_up; then
        echo "ollama is not running (systemctl --user start ollama.service)"
    else
        echo "> $query"; echo
        ollama run "${flags[@]}" "$model" "$query"
    fi
    press_enter
}

case "$PROG" in
    claude)
        hr "Claude Code"
        if command -v claude >/dev/null 2>&1; then claude; else echo "claude not installed"; fi
        fallback "claude" ;;

    opencode)
        hr "opencode"
        if command -v opencode >/dev/null 2>&1; then opencode; else echo "opencode not installed"; fi
        fallback "opencode" ;;

    ask)
        # One-shot LLM query typed into the dashboard's search box. "$*" is a
        # single argv element for claude -p, so spaces and quotes are safe.
        QUERY="$*"
        hr "Ask Claude"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif command -v claude >/dev/null 2>&1; then
            echo "> $QUERY"; echo
            claude -p "$QUERY"
        else
            echo "claude not installed"
        fi
        press_enter ;;

    llm)   local_chat "$OLLAMA_MODEL" ;;
    askllm) local_ask "$OLLAMA_MODEL" "$@" ;;
    glm|askglm)
        if [[ ! -f "$AI_ENV" ]]; then
            hr "GLM (local)"
            echo "Local AI isn't enabled on this machine — re-run the installer"
            echo "and tick \"Local AI: GLM via Ollama\" to download it here."
            press_enter
        elif [[ "$PROG" == glm ]]; then
            local_chat "$GLM_MODEL" --keepalive "$GLM_KEEPALIVE"
        else
            local_ask "$GLM_MODEL" "$@" --keepalive "$GLM_KEEPALIVE"
        fi ;;

    askds)
        # One-shot query against DeepSeek (near-free — see ai-panes-check.py).
        QUERY="$*"
        hr "Ask DeepSeek — $DEEPSEEK_MODEL (near-free, verify at openrouter.ai)"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "model $DEEPSEEK_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$DEEPSEEK_MODEL" "$QUERY"
        fi
        press_enter ;;

    askoa)
        # One-shot query against Ox Alpha (near-free — see ai-panes-check.py).
        QUERY="$*"
        hr "Ask GLM 5.3 — $OXALPHA_MODEL (near-free, verify at openrouter.ai)"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane uses model $OXALPHA_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$OXALPHA_MODEL" "$QUERY"
        fi
        press_enter ;;

    oa)
        # Agentic session with Ox Alpha (near-free — see ai-panes-check.py),
        # run through opencode so it gets real file search/read/write/edit
        # and shell tools (with opencode's own per-action approval prompts —
        # not --auto, so it still asks before writing or running anything).
        hr "GLM 5.3 — $OXALPHA_MODEL (near-free, verify at openrouter.ai) — file/shell access via opencode"
        if need_key "this pane uses model $OXALPHA_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$OXALPHA_MODEL"
        fi
        fallback "oxalpha" ;;

    askmm)
        # One-shot query against Minimax M3 (free, online, OpenRouter).
        QUERY="$*"
        hr "Ask Minimax M3 (free)"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane uses model $MINIMAX_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$MINIMAX_MODEL" "$QUERY"
        fi
        press_enter ;;

    mm)
        # Agentic session with Minimax M3 (free, online, OpenRouter), run
        # through opencode for real file/shell tools with its own approval
        # prompts (not --auto).
        hr "Minimax M3 (free) — file/shell access via opencode"
        if need_key "this pane uses model $MINIMAX_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$MINIMAX_MODEL"
        fi
        fallback "minimax" ;;

    askqw)
        # One-shot query against Qwen 3.8 (cheap paid until a :free appears).
        QUERY="$*"
        hr "Ask Qwen 3.8 — $QWEN_MODEL (near-free, verify at openrouter.ai)"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane uses model $QWEN_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$QWEN_MODEL" "$QUERY"
        fi
        press_enter ;;

    qw)
        # Agentic session with Qwen 3.8 through opencode for real file/shell
        # tools with its own approval prompts (not --auto).
        hr "Qwen 3.8 — $QWEN_MODEL (near-free, verify at openrouter.ai) — file/shell access via opencode"
        if need_key "this pane uses model $QWEN_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$QWEN_MODEL"
        fi
        fallback "qwen" ;;

    askgpt)
        # One-shot query against the best available OpenAI model (PAID).
        QUERY="$*"
        hr "Ask ChatGPT ($CHATGPT_MODEL) — PAID, bills OpenRouter"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane is PAID, model $CHATGPT_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$CHATGPT_MODEL" "$QUERY"
        fi
        press_enter ;;

    gpt)
        # Agentic session with the best available OpenAI model (PAID), run
        # through opencode for real file/shell tools with its own approval
        # prompts (not --auto).
        hr "ChatGPT — $CHATGPT_MODEL (PAID, bills OpenRouter) — file/shell access via opencode"
        if need_key "this pane is PAID, model $CHATGPT_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$CHATGPT_MODEL"
        fi
        fallback "chatgpt" ;;

    askgm)
        # One-shot query against the best available Google model (PAID).
        QUERY="$*"
        hr "Ask Gemini ($GEMINI_MODEL) — PAID, bills OpenRouter"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane is PAID, model $GEMINI_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$GEMINI_MODEL" "$QUERY"
        fi
        press_enter ;;

    gm)
        # Agentic session with the best available Google model (PAID), run
        # through opencode for real file/shell tools with its own approval
        # prompts (not --auto).
        hr "Gemini — $GEMINI_MODEL (PAID, bills OpenRouter) — file/shell access via opencode"
        if need_key "this pane is PAID, model $GEMINI_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$GEMINI_MODEL"
        fi
        fallback "gemini" ;;

    askhy)
        # One-shot query against the best available Tencent model (PAID).
        QUERY="$*"
        hr "Ask Hy4 ($HY4_MODEL) — PAID, bills OpenRouter"
        if [[ -z "${QUERY// }" ]]; then
            echo "no question given"
        elif need_key "this pane is PAID, model $HY4_MODEL"; then
            echo "> $QUERY"; echo
            ask_curl "$HY4_MODEL" "$QUERY"
        fi
        press_enter ;;

    hy)
        # Agentic session with the best available Tencent model (PAID), run
        # through opencode for real file/shell tools with its own approval
        # prompts (not --auto).
        hr "Hy4 — $HY4_MODEL (PAID, bills OpenRouter) — file/shell access via opencode"
        if need_key "this pane is PAID, model $HY4_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$HY4_MODEL"
        fi
        fallback "hy4" ;;

    ds)
        # Agentic session with DeepSeek (near-free — see ai-panes-check.py),
        # run through opencode for real file/shell tools with its own
        # approval prompts (not --auto).
        hr "DeepSeek — $DEEPSEEK_MODEL (near-free, verify at openrouter.ai) — file/shell access via opencode"
        if need_key "model $DEEPSEEK_MODEL"; then
            OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$DEEPSEEK_MODEL"
        fi
        fallback "deepseek" ;;

    free:*)
        # FREE tier — any model that is $0 on OpenRouter, run through opencode
        # like the other agent panes. The id comes from the URL, so it is only
        # accepted if it is in free-models.json (rewritten nightly by
        # ai-panes-check.py), and its price is re-checked live right here: a
        # model that stopped being free since last night refuses to start
        # instead of quietly billing the account.
        MODEL="${PROG#free:}"
        FREE_FILE="$HOME/.config/status-dashboard/free-models.json"
        hr "FREE — $MODEL — file/shell access via opencode"
        if ! python3 -c 'import json,sys; sys.exit(0 if any(m["id"] == sys.argv[2] for m in json.load(open(sys.argv[1]))["models"]) else 1)' "$FREE_FILE" "$MODEL" 2>/dev/null; then
            echo "$MODEL is not in the current free-model list (it changes nightly)."
            echo "Pick another model from the FREE section of the menu."
        elif need_key "free model $MODEL — a key is still required, but it is not charged"; then
            python3 "$HOME/.local/bin/ai-panes-check.py" --is-free "$MODEL"
            case $? in
                1)  echo "$MODEL is no longer free on OpenRouter — not starting it, so nothing gets billed."
                    echo "The menu drops it at the next daily routine; pick another FREE model." ;;
                *)  # 0 = confirmed free now; 2 = couldn't check, trust last night's list
                    OPENROUTER_API_KEY="$DEEPSEEK_API_KEY" opencode --model "openrouter/$MODEL" ;;
            esac
        fi
        fallback "free model" ;;

    shell)
        hr "Shell"; exec bash -il ;;

    htop)
        hr "Processes"
        if command -v htop >/dev/null 2>&1; then htop; else top; fi
        fallback "htop" ;;

    docker)
        hr "Container stats (Ctrl-C to exit)"
        docker stats
        fallback "docker stats" ;;

    logs)
        hr "System log (Ctrl-C to exit)"
        journalctl -f -n 80
        fallback "journalctl" ;;

    dashlog)
        hr "Dashboard collector + repair log"
        journalctl --user -u status-dashboard-server -u status-collect -f -n 60
        fallback "journalctl" ;;

    disk)
        hr "Disk usage — {{MEDIA_POOL}}"
        if command -v ncdu >/dev/null 2>&1; then ncdu {{MEDIA_POOL}}; else du -h -d2 {{MEDIA_POOL}} | sort -h; fi
        fallback "ncdu" ;;

    routine)
        hr "Latest daily-routine log"
        L=$(ls -t "$HOME"/.hermes/maintenance-logs/daily-routine-*.log 2>/dev/null | head -1)
        [[ -n "$L" ]] && less +G "$L" || echo "no daily-routine logs yet"
        fallback "log viewer" ;;

    *)
        hr "Unknown pane '$PROG' — shell"
        exec bash -il ;;
esac
