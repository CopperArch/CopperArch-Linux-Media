#!/usr/bin/env python3
"""Update gate for the media/VPN-stack containers that have NO automated
verify+rollback path (media-stack-auto-update.py owns the 8 that do:
sonarr/radarr/prowlarr/qbittorrent/jellyseerr/overseerr/plex/jellyfin).

These used to be blindly `docker compose pull` + `up -d` every night with
zero review (daily-routine.sh's old step 11). 2026-09-26: replaced with a
manual gate — detect a new image nightly and surface it as a dashboard
bubble, only actually applying it when the user clicks Update (or clears
the flag with Skip) rather than auto-applying.

Three subcommands:
  check          non-mutating: pull, compare against the running container's
                 image, write/clear pending-update state. Never recreates
                 anything. Called nightly from daily-routine.sh.
  apply <name>   recreate that service now (gluetun takes its whole netns
                 sibling group with it, same as the old auto-apply logic —
                 recreating gluetun alone destroys the shared network
                 namespace the siblings joined via network_mode:
                 service:gluetun). Called synchronously from the dashboard's
                 "Update" button.
  skip <name>    remember the currently-pending image id as skipped so it
                 stops flagging until an even newer image shows up. Called
                 from the dashboard's "Skip" button.

chrome is excluded from detection: it's a locally-built image
(pull_policy: never in vpn-stack/docker-compose.yml), so there is no
registry update to ever flag for it. It still gets swept along as a netns
companion when gluetun's update is applied.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path.home()
STATE_DIR = ROOT / ".hermes/state/docker-updates"
SKIPPED_DIR = ROOT / ".hermes/state/docker-updates-skipped"
STATE_DIR.mkdir(parents=True, exist_ok=True)
SKIPPED_DIR.mkdir(parents=True, exist_ok=True)

# compose_dir -> services eligible for this gate. chrome intentionally left
# out (see module docstring) but still a member of NETNS_DIR's compose file.
STACK_SERVICES = {
    ROOT / "docker/media-stack": [
        "immich-redis", "immich-postgres", "immich-server",
        "immich-machine-learning", "portainer", "tugtainer", "watchstate", "caddy",
    ],
    ROOT / "docker/vpn-stack": ["gluetun", "flaresolverr"],
}
NETNS_DIR = ROOT / "docker/vpn-stack"
NETNS_SIBLINGS = ["sonarr", "radarr", "prowlarr", "qbittorrent", "jellyseerr", "chrome", "flaresolverr"]


def sh(cmd, cwd=None, timeout=180):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 1, "TIMEOUT"


def image_id_of_container(name):
    rc, out = sh(["docker", "inspect", name, "--format", "{{.Image}}"])
    return out.strip() if rc == 0 else None


def image_ref_of_container(name):
    rc, out = sh(["docker", "inspect", name, "--format", "{{.Config.Image}}"])
    return out.strip() if rc == 0 else None


def local_image_id(ref):
    rc, out = sh(["docker", "image", "inspect", ref, "--format", "{{.Id}}"])
    return out.strip() if rc == 0 else None


def find_service(name):
    for compose_dir, services in STACK_SERVICES.items():
        if name in services:
            return compose_dir, services
    return None, None


def pending_path(name):
    return STATE_DIR / f"{name}.json"


def skipped_path(name):
    return SKIPPED_DIR / f"{name}.json"


def write_json(path, data):
    path.write_text(json.dumps(data))


def clear(path):
    path.unlink(missing_ok=True)


def check():
    for compose_dir, services in STACK_SERVICES.items():
        if not compose_dir.is_dir():
            print(f"  [SKIP] {compose_dir} not found")
            continue
        rc, out = sh(["docker", "compose", "pull", *services], cwd=compose_dir, timeout=240)
        if rc != 0:
            print(f"  WARNING: pull had errors in {compose_dir}: {out.strip()[-300:]}")
        for name in services:
            old_id = image_id_of_container(name)
            if old_id is None:
                print(f"  [SKIP] {name}: container not found")
                continue
            ref = image_ref_of_container(name)
            new_id = local_image_id(ref) if ref else None
            if not new_id or new_id == old_id:
                clear(pending_path(name))
                print(f"  [OK]   {name}: up to date")
                continue

            skip_file = skipped_path(name)
            if skip_file.exists():
                try:
                    skipped_id = json.loads(skip_file.read_text()).get("skipped_image_id")
                except Exception:
                    skipped_id = None
                if skipped_id == new_id:
                    clear(pending_path(name))
                    print(f"  [OK]   {name}: new image {new_id[:19]} already skipped by user, staying quiet")
                    continue
                clear(skip_file)  # an even newer image showed up — the old skip no longer applies

            write_json(pending_path(name), {
                "old_image_id": old_id, "new_image_id": new_id,
                "image_ref": ref, "checked_at": time.time(),
            })
            print(f"  [WARN] {name}: update available ({old_id[:19]} -> {new_id[:19]}), "
                  f"flagged for manual review on the dashboard")


def apply(name):
    compose_dir, services = find_service(name)
    if compose_dir is None:
        print(f"ERROR: {name} is not a gated service", file=sys.stderr)
        return 1

    up_services = [name]
    if name == "gluetun":
        up_services = ["gluetun"] + NETNS_SIBLINGS
        print(f"  gluetun owns the VPN network namespace — recreating it with all "
              f"{len(NETNS_SIBLINGS)} netns sibling(s) together to avoid stranding them")

    rc, out = sh(["docker", "compose", "up", "-d", "--no-deps", *up_services],
                 cwd=compose_dir, timeout=180)
    if rc != 0:
        print(f"ERROR: recreate failed: {out.strip()[-400:]}", file=sys.stderr)
        return 1

    time.sleep(5)
    rc, out = sh(["docker", "inspect", name, "--format", "{{.State.Status}}"])
    status = out.strip() if rc == 0 else "unknown"
    clear(pending_path(name))
    clear(skipped_path(name))
    if status != "running":
        print(f"ERROR: {name} recreated but state is '{status}', not running", file=sys.stderr)
        return 1
    print(f"[OK] {name} updated and running" +
          (f" (with {', '.join(NETNS_SIBLINGS)})" if name == "gluetun" else ""))
    return 0


def skip(name):
    p = pending_path(name)
    if not p.exists():
        print(f"ERROR: no pending update for {name}", file=sys.stderr)
        return 1
    new_id = json.loads(p.read_text()).get("new_image_id")
    write_json(skipped_path(name), {"skipped_image_id": new_id, "skipped_at": time.time()})
    clear(p)
    print(f"[OK] {name}: image {new_id[:19]} marked skipped — won't flag again unless a newer one appears")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    if cmd == "check":
        check()
        return 0
    if cmd == "apply" and len(sys.argv) == 3:
        return apply(sys.argv[2])
    if cmd == "skip" and len(sys.argv) == 3:
        return skip(sys.argv[2])
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
