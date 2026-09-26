#!/usr/bin/env python3
"""Safe nightly auto-update for the *arr/Seerr/Plex/Jellyfin apps.

For each managed service: pull the image, and if a new one actually landed,
recreate the container and verify it's actually healthy (not just "up").
If verification fails, roll back to the previous image (and, for the small
config apps, the pre-update config backup too) and remember the bad image ID
so we don't hammer the same broken update every night.

Added 2026-07-23 after manually updating Radarr to 6.3.0 and checking it by
hand — this automates that same pull/verify/rollback pattern.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path.home()
VPN_DIR = ROOT / "docker/vpn-stack"
MEDIA_DIR = ROOT / "docker/media-stack"
BACKUP_DIR = ROOT / "backups/auto-update"
STATE_DIR = ROOT / ".hermes/state/auto-update"
BACKUP_DIR.mkdir(parents=True, exist_ok=True)
STATE_DIR.mkdir(parents=True, exist_ok=True)

# backup=True services get a full config tar before update + tar restore on
# rollback (all under ~1GB combined). Plex/Jellyfin configs are 17-18GB each
# — too big to tar every run on a box that's filled its root disk twice
# before — so those two rely on their built-in Docker healthcheck + an
# image-only rollback (no data touched, so nothing to restore).
SERVICES = [
    dict(name="sonarr", compose_dir=VPN_DIR, image="lscr.io/linuxserver/sonarr:latest",
         mount="vpn-stack_sonarr_config", backup=True, kind="arr", port=8989, api_base="/api/v3"),
    dict(name="radarr", compose_dir=VPN_DIR, image="lscr.io/linuxserver/radarr:latest",
         mount="vpn-stack_radarr_config", backup=True, kind="arr", port=7878, api_base="/api/v3"),
    dict(name="prowlarr", compose_dir=VPN_DIR, image="lscr.io/linuxserver/prowlarr:latest",
         mount="vpn-stack_prowlarr_config", backup=True, kind="arr", port=9696, api_base="/api/v1"),
    dict(name="qbittorrent", compose_dir=VPN_DIR, image="lscr.io/linuxserver/qbittorrent:latest",
         mount="vpn-stack_qbittorrent_config", backup=True, kind="http", port=8080, path="/"),
    dict(name="jellyseerr", compose_dir=VPN_DIR, image="ghcr.io/seerr-team/seerr:v3.3.0",
         mount="vpn-stack_jellyseerr_config", backup=True, kind="seerr", port=5056, pinned=True),
    dict(name="overseerr", compose_dir=MEDIA_DIR, image="ghcr.io/seerr-team/seerr:v3.3.0",
         mount=str(MEDIA_DIR / "overseerr"), backup=True, kind="seerr", port=5055, pinned=True),
    dict(name="plex", compose_dir=MEDIA_DIR, image="plexinc/pms-docker",
         mount=None, backup=False, kind="dockerhealth", port=32400),
    dict(name="jellyfin", compose_dir=MEDIA_DIR, image="jellyfin/jellyfin",
         mount=None, backup=False, kind="dockerhealth", port=8096),
]

# No container may go longer than this without a genuine update attempt —
# not a floating-tag "pull found nothing new" (that's not staleness, there's
# nothing to apply), but either a hard version pin that never moves on its
# own, or a remembered-bad image that would otherwise be skipped forever.
# Added 2026-09-26.
STALE_DAYS = 60
STALE_SECONDS = STALE_DAYS * 86400


def log(msg):
    print(f"  {msg}", flush=True)


# Every warn() is also collected and emailed as one digest at the end of the
# run (added 2026-08-06). Before this, a failed update + rollback was visible
# only as a WARNING buried in that night's daily-routine log, which nobody reads.
WARNINGS = []


def warn(msg):
    print(f"  WARNING: {msg}", flush=True)
    WARNINGS.append(msg)


def flush_alerts():
    if not WARNINGS:
        return
    import importlib.util
    host = os.uname().nodename
    critical = any("CRITICAL" in w for w in WARNINGS)
    subject = (f"[homelab] CRITICAL: media-stack auto-update rollback failed on {host}"
               if critical else
               f"[homelab] {len(WARNINGS)} auto-update warning(s) on {host}")
    body = ("media-stack-auto-update.py reported:\n\n"
            + "\n".join(f"  - {w}" for w in WARNINGS)
            + "\n\nFull log: ~/.hermes/maintenance-logs/daily-routine-*.log\n")
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "send-alert.py")
        spec = importlib.util.spec_from_file_location("send_alert", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        rc, info = mod.send(subject, body)
    except Exception as e:
        print(f"  WARNING: alert email failed to load sender: {e}", flush=True)
        return
    if rc == 0:
        log(f"alert email {info}")
    elif rc == 2:
        log(f"alert email not sent — {info}")
    else:
        print(f"  WARNING: alert email failed — {info}", flush=True)


def sh(cmd, cwd=None, timeout=120):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"


def image_id_of_container(name):
    rc, out = sh(["docker", "inspect", name, "--format", "{{.Image}}"])
    return out.strip() if rc == 0 else None


def local_image_id(ref):
    rc, out = sh(["docker", "image", "inspect", ref, "--format", "{{.Id}}"])
    return out.strip() if rc == 0 else None


def http_get(url, timeout=5, headers=None):
    try:
        h = {"User-Agent": "auto-update-check"}
        if headers:
            h.update(headers)
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception:
        return None, ""


def ghcr_tags(repo):
    """Anonymous-pull tag list for a public ghcr.io repo (e.g.
    'seerr-team/seerr'), via the standard OCI Distribution auth dance: an
    anonymous bearer token, then tags/list. The registry paginates this
    (100/page for this repo, hundreds of sha-*/preview-* build tags) via an
    RFC 5988 `Link: <...>; rel="next"` header — a single unpaginated fetch
    silently returns only the oldest page and can miss the actual current
    pin entirely, which would let a stale/older tag look "newest". Follows
    Link until it's gone (capped at 20 pages, ~2000 tags, as a sanity limit
    against an unexpected infinite loop)."""
    status, body = http_get(f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io")
    if status != 200:
        return []
    try:
        token = json.loads(body).get("token")
    except Exception:
        return []
    if not token:
        return []

    headers = {"Authorization": f"Bearer {token}"}
    path = f"/v2/{repo}/tags/list?n=100"
    tags = []
    for _ in range(20):
        req = urllib.request.Request(f"https://ghcr.io{path}", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read().decode("utf-8", "replace")
                link = r.getheader("Link")
        except Exception:
            break
        try:
            tags.extend(json.loads(body).get("tags", []))
        except Exception:
            break
        m = re.search(r'<([^>]+)>;\s*rel="next"', link or "")
        if not m:
            break
        path = m.group(1)
    return tags


def newest_semver_tag(tags, current=None):
    """Highest vX.Y.Z-style tag, but only if it's strictly newer than
    `current` (when given) — a truncated/odd registry response should never
    be able to look like an upgrade to an older or identical version."""
    current_key = None
    if current:
        m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", current)
        if m:
            current_key = tuple(int(x) for x in m.groups())
    best, best_key = None, current_key
    for t in tags:
        m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", t)
        if not m:
            continue
        key = tuple(int(x) for x in m.groups())
        if best_key is None or key > best_key:
            best_key, best = key, t
    return best


def compose_file(svc):
    return Path(svc["compose_dir"]) / "docker-compose.yml"


def bump_pinned_tag(svc, new_tag):
    """Rewrite this service's `image:` line in its compose file in place.
    Returns (old_image, new_image), or None if the current pin wasn't found
    (compose file edited by hand since, format changed, etc — don't guess)."""
    path = compose_file(svc)
    text = path.read_text()
    old_image = svc["image"]
    if old_image not in text:
        return None
    new_image = old_image.rsplit(":", 1)[0] + ":" + new_tag
    path.write_text(text.replace(old_image, new_image, 1))
    return old_image, new_image


def revert_pinned_tag(svc, old_image, new_image):
    path = compose_file(svc)
    text = path.read_text()
    if new_image in text:
        path.write_text(text.replace(new_image, old_image, 1))
    svc["image"] = old_image


def check_pinned_update(svc, state, now):
    """A hard-pinned tag (Seerr apps) never looks "new" to `compose pull`, so
    without this it would sit on the same pin forever. Once the pin has gone
    STALE_DAYS without a real update, check ghcr.io directly for a newer
    semver tag and, if one exists, attempt to move to it with the exact same
    backup/verify/rollback safety net as a normal update — a bumped pin is
    exactly as risky as an unpinned one. Always returns True (handled,
    whether by acting or by confirming there's nothing newer) so process()
    knows to skip the normal pull path for this service this run."""
    name = svc["name"]
    repo = svc["image"].split(":", 1)[0].split("ghcr.io/", 1)[1]
    current_tag = svc["image"].rsplit(":", 1)[1]
    newest = newest_semver_tag(ghcr_tags(repo), current=current_tag)
    if not newest or newest == current_tag:
        log(f"{name}: pinned at {current_tag}, no newer tagged release on ghcr.io "
            f"(checked because it's been {STALE_DAYS}+ days since the last update)")
        state["last_updated_at"] = now
        save_state(name, state)
        return True

    log(f"{name}: pin is {STALE_DAYS}+ days stale and ghcr.io has {newest} "
        f"(currently {current_tag}) — attempting to move to it")
    old_id = image_id_of_container(name)
    bumped = bump_pinned_tag(svc, newest)
    if not bumped:
        warn(f"{name}: could not find its pinned image line in {compose_file(svc)} to bump")
        return True
    old_image, new_image = bumped
    svc["image"] = new_image

    backup_config(svc)
    rc, out = compose(svc, "pull", name, timeout=180)
    if rc == 0:
        rc, out = compose(svc, "up", "-d", "--no-deps", name)
    verifier = VERIFIERS[svc["kind"]]
    ok, detail = (False, f"pull/recreate failed: {out.strip()[-300:]}") if rc != 0 else verifier(svc)

    if ok:
        warn(f"{name}: moved pinned tag {current_tag} -> {newest} and verified ({detail}). "
             f"docker-compose.yml updated — this was a deliberate version pin, worth a quick manual look.")
        state["last_updated_at"] = now
        state["last_good_image_id"] = local_image_id(svc["image"])
        save_state(name, state)
        return True

    warn(f"{name}: pin bump to {newest} FAILED verification ({detail}) — reverting to {current_tag}")
    restore_config(svc)
    revert_pinned_tag(svc, old_image, new_image)
    sh(["docker", "tag", old_id, old_image])
    compose(svc, "up", "-d", "--no-deps", name)
    ok2, detail2 = verifier(svc)
    if ok2:
        warn(f"{name}: reverted to {current_tag} successfully ({detail2})")
    else:
        warn(f"{name}: CRITICAL — revert after failed pin bump ALSO failed to verify ({detail2}); "
             f"check manually. Backup at {BACKUP_DIR}/{name}_preupdate.tar.gz")
    # Tried either way — don't hammer a broken newer release nightly, wait
    # out the same 60 days before trying this tag (or whatever's newest by
    # then) again.
    state["last_updated_at"] = now
    save_state(name, state)
    return True


def get_arr_api_key(container):
    rc, out = sh(["docker", "exec", container, "cat", "/config/config.xml"])
    if rc != 0:
        return None
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", out)
    return m.group(1) if m else None


def load_state(name):
    f = STATE_DIR / f"{name}.json"
    if f.exists():
        try:
            return json.loads(f.read_text())
        except Exception:
            return {}
    return {}


def save_state(name, state):
    (STATE_DIR / f"{name}.json").write_text(json.dumps(state))


def backup_config(svc):
    if not svc["backup"]:
        return True
    dest = BACKUP_DIR / f"{svc['name']}_preupdate.tar.gz"
    rc, out = sh([
        "docker", "run", "--rm",
        "-v", f"{svc['mount']}:/data:ro",
        "-v", f"{BACKUP_DIR}:/backup",
        "alpine", "tar", "czf", f"/backup/{dest.name}", "-C", "/data", "."
    ], timeout=180)
    if rc != 0:
        warn(f"{svc['name']}: config backup failed, proceeding without it ({out.strip()[-200:]})")
        return False
    return True


def restore_config(svc):
    if not svc["backup"]:
        return True
    src = BACKUP_DIR / f"{svc['name']}_preupdate.tar.gz"
    if not src.exists():
        warn(f"{svc['name']}: no backup file to restore from ({src})")
        return False
    rc, out = sh([
        "docker", "run", "--rm",
        "-v", f"{svc['mount']}:/data",
        "-v", f"{BACKUP_DIR}:/backup",
        "alpine", "sh", "-c",
        "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null; "
        f"tar xzf /backup/{src.name} -C /data"
    ], timeout=180)
    if rc != 0:
        warn(f"{svc['name']}: config restore failed ({out.strip()[-200:]})")
        return False
    return True


def compose(svc, *args, timeout=120):
    return sh(["docker", "compose", *args], cwd=svc["compose_dir"], timeout=timeout)


def verify_arr(svc, timeout=60):
    deadline = time.time() + timeout
    key = None
    while time.time() < deadline:
        key = key or get_arr_api_key(svc["name"])
        if key:
            status, body = http_get(f"http://localhost:{svc['port']}{svc['api_base']}/health",
                                     timeout=5, headers={"X-Api-Key": key})
            if status == 200:
                try:
                    issues = json.loads(body)
                except Exception:
                    issues = None
                if issues is not None:
                    errors = [i for i in issues if i.get("type") == "error"]
                    if errors:
                        return False, f"health API reports errors: {[e['message'] for e in errors]}"
                    return True, "health API clean"
        time.sleep(3)
    return False, "app never came up / API key unreadable within timeout"


def verify_http(svc, timeout=60):
    deadline = time.time() + timeout
    path = svc.get("path", "/")
    while time.time() < deadline:
        status, _ = http_get(f"http://localhost:{svc['port']}{path}", timeout=5)
        if status and status < 500:
            return True, f"HTTP {status}"
        time.sleep(3)
    return False, "no successful HTTP response within timeout"


def verify_seerr(svc, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, _ = http_get(f"http://localhost:{svc['port']}/", timeout=5)
        rc, out = sh(["docker", "exec", svc["name"], "sh", "-c", "cat /app/config/settings.json"])
        if status and status < 500 and rc == 0:
            try:
                d = json.loads(out)
                init = d.get("public", {}).get("initialized", False)
                if init:
                    return True, f"HTTP {status}, initialized"
            except Exception:
                pass
        time.sleep(3)
    return False, "not serving + initialized within timeout"


def verify_dockerhealth(svc, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rc, out = sh(["docker", "inspect", svc["name"], "--format", "{{.State.Health.Status}}"])
        status = out.strip()
        if status == "healthy":
            return True, "docker healthcheck: healthy"
        if status == "unhealthy":
            return False, "docker healthcheck: unhealthy"
        time.sleep(5)
    return False, f"docker healthcheck never went healthy (last: {out.strip() if rc == 0 else 'unknown'})"


VERIFIERS = {
    "arr": verify_arr,
    "http": verify_http,
    "seerr": verify_seerr,
    "dockerhealth": verify_dockerhealth,
}


def container_restarting(name):
    rc, out = sh(["docker", "inspect", name, "--format", "{{.State.Status}} {{.RestartCount}}"])
    if rc != 0:
        return True, "?"
    parts = out.strip().split()
    status = parts[0] if parts else "?"
    return status not in ("running",), status


def process(svc):
    name = svc["name"]
    old_id = image_id_of_container(name)
    if old_id is None:
        warn(f"{name}: container not found, skipping")
        return

    now = time.time()
    state = load_state(name)

    if svc.get("pinned") and now - state.get("last_updated_at", 0) >= STALE_SECONDS:
        if check_pinned_update(svc, state, now):
            return

    rc, out = compose(svc, "pull", name, timeout=180)
    if rc != 0:
        warn(f"{name}: docker compose pull failed: {out.strip()[-300:]}")
        return

    new_id = local_image_id(svc["image"])
    if new_id == old_id:
        log(f"{name}: up to date (no new image)")
        return

    if state.get("known_bad_image_id") == new_id:
        bad_since = state.get("known_bad_image_id_since", now)
        if now - bad_since < STALE_SECONDS:
            log(f"{name}: skipping — image {new_id[:19]} already failed verification on a previous run, "
                f"waiting on upstream for a newer one")
            return
        log(f"{name}: image {new_id[:19]} was marked bad {STALE_DAYS}+ days ago — forcing a retry "
            f"rather than skipping it forever")

    log(f"{name}: new image found ({old_id[:19]} -> {new_id[:19]}), updating")
    backup_config(svc)

    rc, out = compose(svc, "up", "-d", "--no-deps", name)
    if rc != 0:
        warn(f"{name}: docker compose up failed: {out.strip()[-300:]}")
        return

    verifier = VERIFIERS[svc["kind"]]
    ok, detail = verifier(svc)
    restarting, dstatus = container_restarting(name)
    if ok and not restarting:
        log(f"{name}: [OK] update verified ({detail})")
        state["last_good_image_id"] = new_id
        state["last_updated_at"] = now
        state.pop("known_bad_image_id", None)
        state.pop("known_bad_image_id_since", None)
        save_state(name, state)
        return

    if not ok:
        detail = f"{detail}"
    else:
        detail = f"container not in 'running' state ({dstatus})"
    warn(f"{name}: update FAILED verification ({detail}) — rolling back to previous image")

    restore_config(svc)
    rc, out = sh(["docker", "tag", old_id, svc["image"]])
    if rc != 0:
        warn(f"{name}: CRITICAL — could not retag old image ({out.strip()[-200:]}), manual fix needed")
        state["known_bad_image_id"] = new_id
        state["known_bad_image_id_since"] = now
        save_state(name, state)
        return

    rc, out = compose(svc, "up", "-d", "--no-deps", name)
    if rc != 0:
        warn(f"{name}: CRITICAL — rollback recreate failed: {out.strip()[-300:]}")
        state["known_bad_image_id"] = new_id
        state["known_bad_image_id_since"] = now
        save_state(name, state)
        return

    ok2, detail2 = verifier(svc)
    if ok2:
        warn(f"{name}: rolled back successfully, previous version restored and verified ({detail2})")
    else:
        warn(f"{name}: CRITICAL — rollback verification ALSO failed ({detail2}). "
             f"Container may be broken; check manually. Backup at {BACKUP_DIR}/{name}_preupdate.tar.gz")

    # Refresh the cooldown on every failure (first time or a forced 60-day
    # retry) so a persistently broken upstream image gets retried at most
    # once every STALE_DAYS, never nightly.
    state["known_bad_image_id"] = new_id
    state["known_bad_image_id_since"] = now
    save_state(name, state)


def main():
    for svc in SERVICES:
        try:
            process(svc)
        except Exception as e:
            warn(f"{svc['name']}: unexpected error in auto-update: {e}")
    flush_alerts()


if __name__ == "__main__":
    main()
