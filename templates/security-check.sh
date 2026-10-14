#!/usr/bin/env bash
# security-check.sh — the nightly security & firewall pass (daily-routine.sh
# runs it; it can also be run by hand). Each check prints one tagged line
# ([OK] / [WARN] / [FAIL] / [SKIP]) that the dashboard picks up, and fixes
# what it safely can. A fix that was applied is reported as a [WARN] that
# starts "Fixed:", so it shows on the dashboard once, the morning after.
#
#   security-check.sh            check (and fix)
#   security-check.sh --accept   record what is exposed right now as expected
#
# "Exposed" is compared with a baseline (security-baseline.json beside the
# dashboard's keys file), written on the first run: ports reachable from the
# internet, ports Docker publishes to the network (Docker bypasses ufw), and
# Tailscale Funnel addresses. Anything new is reported until it is closed or
# accepted with --accept.
#
# Root-only fixes (enabling ufw, updating cloudflared) go through sudo -n and
# the NOPASSWD rules in /etc/sudoers.d/daily-routine; without them the line
# says which command to run.
set -uo pipefail

CONF="$HOME/.config/status-dashboard"
BASELINE="$CONF/security-baseline.json"
KEYS="$CONF/media-keys.env"
ACCEPT=false
[[ "${1:-}" == "--accept" ]] && ACCEPT=true

ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
fail() { echo "  [FAIL] $*"; }
skip() { echo "  [SKIP] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# ── 1. Host firewall ─────────────────────────────────────────────────────────
if have ufw; then
    UFW=$(sudo -n ufw status verbose 2>/dev/null || sudo -n ufw status 2>/dev/null)
    if [[ -z "$UFW" ]]; then
        skip "ufw: no sudo rule to read its status"
    elif grep -q '^Status: active' <<<"$UFW"; then
        if grep -q '^Default:' <<<"$UFW" && ! grep -q 'deny (incoming)\|reject (incoming)' <<<"$UFW"; then
            fail "ufw is on but lets incoming connections in by default — sudo ufw default deny incoming"
        else
            ok "ufw firewall active, incoming blocked by default"
        fi
    elif sudo -n ufw --force enable >/dev/null 2>&1; then
        warn "Fixed: ufw firewall was OFF — switched it back on"
    else
        fail "ufw firewall is OFF — sudo ufw --force enable"
    fi
elif have firewall-cmd; then
    # Fedora/openSUSE: firewalld
    if sudo -n firewall-cmd --state >/dev/null 2>&1; then
        ok "firewalld firewall running"
    elif sudo -n systemctl start firewalld >/dev/null 2>&1 && sudo -n firewall-cmd --state >/dev/null 2>&1; then
        warn "Fixed: firewalld was stopped — started it again"
    else
        fail "firewalld is not running — sudo systemctl enable --now firewalld"
    fi
else
    warn "no host firewall (ufw or firewalld) installed"
fi

# ── 2. VPN kill switch and leaks ─────────────────────────────────────────────
HOME_IP=$(curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
if running gluetun; then
    GENV=$(docker inspect gluetun --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
    if grep -qiE '^FIREWALL(_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT)?=(off|no|false)' <<<"$GENV"; then
        fail "gluetun's firewall (the VPN kill switch) is switched OFF in its settings"
    else
        ok "VPN kill switch (gluetun firewall) on"
    fi
    VPN_IP=$(docker exec gluetun wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$HOME_IP" && "$VPN_IP" == "$HOME_IP" ]]; then
        # Downloads would be going out on the home connection: stop them first.
        docker stop qbittorrent >/dev/null 2>&1
        fail "VPN LEAK: traffic in the VPN namespace leaves on the home IP — stopped qBittorrent; check gluetun"
    elif [[ -z "$VPN_IP" ]]; then
        warn "VPN tunnel gave no public IP (down or reconnecting) — downloads are blocked, not leaking"
    else
        ok "downloads leave through the VPN, not the home IP"
    fi
    if docker exec gluetun wget -q -O /dev/null --timeout=6 https://api6.ipify.org 2>/dev/null; then
        fail "IPv6 gets out of the VPN namespace — set DNS/IPv6 off in gluetun"
    else
        ok "no IPv6 leak from the VPN namespace"
    fi
    if docker exec gluetun sh -c 'grep -q "^nameserver 127.0.0.1" /etc/resolv.conf' 2>/dev/null; then
        ok "DNS in the VPN namespace goes to gluetun's own resolver"
    else
        warn "DNS in the VPN namespace does not go to gluetun's resolver — possible DNS leak"
    fi
else
    skip "gluetun not running — no VPN checks"
fi

# ── 3. What the internet can reach ───────────────────────────────────────────
# Probed from inside the VPN namespace, so it comes in from outside like any
# stranger would. "web" = answers HTTP(S); "open" = takes a TCP connection.
probe_ports() {
    { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127)' | sed 's/.*://'
      docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '(0\.0\.0\.0|\[::\]|:::)?:?[0-9]+->' | grep -oE '[0-9]+->' | tr -d '>-'
      printf '%s\n' 22 80 443 1443 8443 8080 32400; } | grep -E '^[0-9]+$' | sort -un
}
EXPOSED=""
if running gluetun && [[ -n "$HOME_IP" && -n "${VPN_IP:-}" && "$VPN_IP" != "$HOME_IP" ]]; then
    PORTS=$(probe_ports | tr '\n' ' ')
    EXPOSED=$(docker exec -e H="$HOME_IP" -e PORTS="$PORTS" gluetun sh -c '
        for p in $PORTS; do
          ( if nc -z -w 4 "$H" "$p" 2>/dev/null; then
              if wget -q -O /dev/null -T 5 -t 1 "http://$H:$p/" 2>/dev/null || [ $? -eq 8 ] \
                 || wget -q -O /dev/null -T 5 -t 1 --no-check-certificate "https://$H:$p/" 2>/dev/null || [ $? -eq 8 ]; then
                echo "$p:web"; else echo "$p:open"; fi
            fi ) &
        done; wait' 2>/dev/null | sort -n | tr '\n' ' ')
    EXPOSED=${EXPOSED% }
    if [[ -z "$EXPOSED" ]]; then
        ok "nothing on this box is reachable from the internet (outside the VPN/tunnels)"
    else
        ok "reachable from the internet: $EXPOSED"
    fi
else
    skip "internet exposure: needs a working VPN tunnel to probe from outside"
fi

# Docker publishes ports straight past ufw.
DOCKER_PUB=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | while read -r n ports; do
    grep -oE '(0\.0\.0\.0|\[::\]|:::)[:]?[0-9]+->' <<<"$ports" | grep -oE '[0-9]+->' | tr -d '>-' \
        | sed "s/^/$n:/"; done | sort -u | tr '\n' ' ')
DOCKER_PUB=${DOCKER_PUB% }

FUNNEL=""
if have tailscale; then
    FUNNEL=$(tailscale funnel status 2>/dev/null | grep -oE 'https://[^ ]+' | sort -u | tr '\n' ' ')
    FUNNEL=${FUNNEL% }
fi

if $ACCEPT || [[ ! -s "$BASELINE" ]]; then
    mkdir -p "$CONF"
    python3 - "$BASELINE" "$EXPOSED" "$DOCKER_PUB" "$FUNNEL" <<'PY'
import json, sys, time
path, exposed, docker, funnel = sys.argv[1:]
json.dump({"recorded": time.strftime("%Y-%m-%d %H:%M"),
           "internet": exposed.split(), "docker": docker.split(),
           "funnel": funnel.split()}, open(path, "w"), indent=1)
PY
    chmod 600 "$BASELINE"
    ok "recorded what is exposed now as expected ($BASELINE)"
else
    python3 - "$BASELINE" "$EXPOSED" "$DOCKER_PUB" "$FUNNEL" <<'PY'
import json, sys
path, exposed, docker, funnel = sys.argv[1:]
base = json.load(open(path))
def report(label, now, was, how):
    new = sorted(set(now.split()) - set(base.get(was, [])))
    if new:
        print(f"  [FAIL] new {label}: {' '.join(new)} — {how}, or if it is meant "
              f"to be there: security-check.sh --accept")
    else:
        print(f"  [OK]   no new {label}")
report("ports reachable from the internet", exposed, "internet",
       "close the router port forward / stop the service")
report("Docker ports open to the network (they bypass ufw)", docker, "docker",
       "bind them to 127.0.0.1 in the compose file")
report("Tailscale Funnel addresses (public on the internet)", funnel, "funnel",
       "tailscale funnel reset")
PY
fi

# ── 4. Caddy: plain HTTP only for the home network and Tailscale ─────────────
CADDYFILE=$(docker inspect caddy --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
if [[ -n "$CADDYFILE" && -r "$CADDYFILE" ]]; then
    if grep -q 'abort @outside' "$CADDYFILE"; then
        ok "Caddy refuses plain-HTTP connections from outside the home network"
    else
        warn "Caddy serves plain HTTP to anyone who reaches port 80 — add the @outside guard to $CADDYFILE"
    fi
fi

# ── 5. Containers with control of the host ───────────────────────────────────
RISKY=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format \
    '{{.Name}} {{.HostConfig.Privileged}} {{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null \
    | awk '$2=="true" || /docker\.sock/ {sub("^/","",$1); print $1}' | sort -u | tr '\n' ' ')
if [[ -n "$RISKY" ]]; then
    warn "containers with full control of the host (privileged or Docker socket): $RISKY"
else
    ok "no container is privileged or holds the Docker socket"
fi

# ── 6. Secret files readable by other users ──────────────────────────────────
FIXED=""
for f in "$KEYS" "$BASELINE" "$HOME/.config/gluetun/rotate.key" \
         "$HOME"/docker/*/.env "$HOME"/.dbmedia/*key* "$HOME"/.dbmedia/alert-email.conf; do
    [[ -f "$f" ]] || continue
    if [[ $(( 8#$(stat -c %a "$f") & 8#077 )) -ne 0 ]]; then
        chmod go-rwx "$f" && FIXED+=" ${f/#$HOME/~}"
    fi
done
if [[ -n "$FIXED" ]]; then
    warn "Fixed: secret file(s) were readable by other users, now owner-only:$FIXED"
else
    ok "secret files are readable by their owner only"
fi

# ── 7. Security components up to date ────────────────────────────────────────
latest() { curl -s --max-time 15 "https://api.github.com/repos/$1/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1; }
newer() { [[ -n "$2" && "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]; }

if have cloudflared; then
    CUR=$(cloudflared --version 2>/dev/null | awk '{print $3}')
    NEW=$(latest cloudflare/cloudflared)
    if newer "$CUR" "$NEW"; then
        if sudo -n "$(command -v cloudflared)" update >/dev/null 2>&1 || [[ $? -eq 11 ]]; then
            sudo -n systemctl restart cloudflared 2>/dev/null
            warn "Fixed: cloudflared updated $CUR -> $(cloudflared --version 2>/dev/null | awk '{print $3}')"
        else
            warn "cloudflared $CUR is out of date ($NEW is out) — sudo cloudflared update && sudo systemctl restart cloudflared"
        fi
    else
        ok "cloudflared $CUR is current"
    fi
fi

if running caddy; then
    CUR=$(docker exec caddy caddy version 2>/dev/null | awk '{print $1}' | tr -d v)
    NEW=$(latest caddyserver/caddy)
    DIR=$(docker inspect caddy --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
    if newer "$CUR" "$NEW" && [[ -n "$DIR" ]]; then
        # Built locally (with the DuckDNS plugin): rebuild on the new release.
        if (cd "$DIR" && docker compose build --pull caddy >/dev/null 2>&1 \
              && docker compose up -d caddy >/dev/null 2>&1); then
            sleep 3
            warn "Fixed: Caddy updated $CUR -> $(docker exec caddy caddy version 2>/dev/null | awk '{print $1}')"
        else
            warn "Caddy $CUR is out of date ($NEW is out) and the rebuild failed — cd $DIR && docker compose build --pull caddy && docker compose up -d caddy"
        fi
    elif [[ -n "$CUR" ]]; then
        ok "Caddy $CUR is current"
    fi
fi

if running gluetun; then
    # gluetun shares its network with the download containers: updating it
    # means recreating all of them together, so it is flagged, not done here.
    IMG=$(docker inspect gluetun --format '{{.Config.Image}}')
    LOCAL=$(docker image inspect "$IMG" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')
    REMOTE=$(docker buildx imagetools inspect "$IMG" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
    if [[ -n "$REMOTE" && -n "$LOCAL" && "$REMOTE" != "$LOCAL" ]]; then
        warn "a newer gluetun (VPN) image is out — apply it from the dashboard's Docker updates (recreates the VPN group)"
    elif [[ -n "$REMOTE" ]]; then
        ok "gluetun image is current"
    fi
fi

if have tailscale; then
    if have apt-cache && apt-cache policy tailscale 2>/dev/null | awk '/Installed:/{i=$2} /Candidate:/{c=$2} END{exit !(i!=c && c!="(none)")}'; then
        warn "a Tailscale update is waiting — tonight's system update installs it"
    else
        ok "Tailscale $(tailscale version 2>/dev/null | head -1) is current"
    fi
fi
exit 0
