#!/usr/bin/env python3
"""intrusion-check.py — nightly malware + "is anyone in / watching" pass.

Run by security-check.sh (so its tagged [OK]/[WARN]/[FAIL] lines land on the
dashboard with the rest of the security section); also runnable by hand.
Added 2026-11-05.

  1. Malware     ClamAV over files changed in the last day (home + downloads),
                 the whole home folder on Sundays. Reports, never deletes.
  2. Rootkits    rkhunter --check (via its NOPASSWD sudo rule).
  3. Logins      SSH logins from outside the home LAN/Tailscale, failed SSH and
                 sudo attempts, account changes — from /var/log/auth.log.
  4. App logins  failed Jellyfin and Nextcloud logins (brute-force signs).
  5. Persistence new user accounts, admin (sudo) members, SSH keys, sudoers
                 files, cron jobs, systemd services — compared with a baseline.
  6. Listeners   new listening ports (anything, not just internet-facing).
  7. Outbound    host processes talking to the internet that weren't before,
                 and connections to classic backdoor/IRC ports.

Anything new in 5-7 is reported until it is removed or accepted with
    intrusion-check.py --accept
which records the current state as expected (first run does this itself).
Any [FAIL] also sends one summary e-mail through send-alert.py.
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
CONF = HOME / ".config/status-dashboard"
BASELINE = CONF / "intrusion-baseline.json"
STATE = HOME / ".dbmedia/state"
SEND_ALERT = HOME / ".local/bin/send-alert.py"
DOWNLOADS = Path("{{MEDIA_POOL}}/downloads")
AUTH_LOG = Path("/var/log/auth.log")

# Where logins are expected from: home LAN, Tailscale, loopback.
TRUSTED_NETS = [ipaddress.ip_network(n) for n in (
    "{{LAN_CIDR}}", "100.64.0.0/10", "fd7a:115c:a1e0::/48",
    "127.0.0.0/8", "::1/128")]
# Classic backdoor / botnet C2 / IRC ports. An outbound connection to one of
# these from the host is never normal here.
BAD_PORTS = {23, 1337, 4444, 5555, 6666, 6667, 6668, 6669, 6697, 12345, 31337}
FAILED_SSH_WARN = 20
FAILED_APP_WARN = 10
SCAN_SKIP_DIRS = (".cache", ".local/share/Trash", "snap", ".npm", ".cargo",
                  ".rustup", ".gradle", "Android", "node_modules", ".dbmedia/staging")
SCAN_MAX_MB = 200   # skip big media files; malware isn't a 4 GB .mkv

ACCEPT = "--accept" in sys.argv[1:]
fails = []


def ok(m): print(f"  [OK]   {m}", flush=True)
def warn(m): print(f"  [WARN] {m}", flush=True)
def skip(m): print(f"  [SKIP] {m}", flush=True)


def fail(m):
    print(f"  [FAIL] {m}", flush=True)
    fails.append(m)


def run(cmd, timeout=120, **kw):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
        return r.returncode, r.stdout + r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)


def trusted(ip):
    try:
        a = ipaddress.ip_address(ip.split("%")[0])
    except ValueError:
        return False
    if a.version == 6 and a.ipv4_mapped:
        a = a.ipv4_mapped
    return any(a in n for n in TRUSTED_NETS if n.version == a.version)


def public(ip):
    try:
        a = ipaddress.ip_address(ip.split("%")[0])
    except ValueError:
        return False
    if a.version == 6 and a.ipv4_mapped:
        a = a.ipv4_mapped
    return a.is_global and not trusted(str(a))


# ── 1. Malware (ClamAV) ──────────────────────────────────────────────────────
def malware_scan():
    if not run(["which", "clamscan"])[0] == 0:
        skip("malware scan: ClamAV not installed (sudo apt-get install clamav)")
        return
    full = datetime.now().weekday() == 6
    cutoff = time.time() - 26 * 3600
    roots = [HOME] + ([DOWNLOADS] if DOWNLOADS.is_dir() else [])
    files = []
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            rel = os.path.relpath(dirpath, HOME) if root == HOME else ""
            dirnames[:] = [d for d in dirnames
                           if not (rel == "." and d in ("docker",))
                           and not any(os.path.join(rel, d).startswith(s) or d == s
                                       for s in SCAN_SKIP_DIRS)]
            for f in filenames:
                p = os.path.join(dirpath, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if not os.path.isfile(p) or os.path.islink(p):
                    continue
                if st.st_size > SCAN_MAX_MB * 1048576:
                    continue
                if full or st.st_mtime > cutoff:
                    files.append(p)
    if not files:
        ok("malware scan: no new or changed files to scan")
        return
    lst = STATE / "clamscan-files.txt"
    lst.write_text("\n".join(files))
    rc, out = run(["clamscan", "--no-summary", "--infected", f"--max-filesize={SCAN_MAX_MB}M",
                   f"--max-scansize={SCAN_MAX_MB}M", "--file-list", str(lst)], timeout=6 * 3600)
    hits = [l for l in out.splitlines() if l.endswith(" FOUND")]
    what = "full home scan" if full else "files changed in the last day"
    if hits:
        fail(f"MALWARE found ({what}): " + "; ".join(hits[:10]) +
             (f" (+{len(hits) - 10} more)" if len(hits) > 10 else "") +
             " — not deleted; check and remove them")
    elif rc not in (0, 1):
        warn(f"malware scan did not finish (clamscan rc={rc}): {out.strip()[-200:]}")
    else:
        ok(f"malware scan clean ({len(files)} files, {what})")


# ── 2. Rootkits (rkhunter) ───────────────────────────────────────────────────
def rootkit_scan():
    if not Path("/usr/bin/rkhunter").exists():
        skip("rootkit scan: rkhunter not installed (sudo apt-get install rkhunter)")
        return
    rc, out = run(["sudo", "-n", "/usr/bin/rkhunter", "--check", "--sk", "--rwo",
                   "--nocolors"], timeout=1800)
    if "a password is required" in out or "sudo:" in out[:200]:
        skip("rootkit scan: needs the NOPASSWD sudo rule for rkhunter --check")
        return
    warnings = [l.strip() for l in out.splitlines() if l.strip().startswith("Warning:")]
    rootkits = [w for w in warnings if re.search(r"rootkit|backdoor|trojan", w, re.I)]
    if rootkits:
        fail("rkhunter: " + "; ".join(rootkits[:5]))
    elif warnings:
        warn(f"rkhunter: {len(warnings)} warning(s) — " + "; ".join(warnings[:3]) +
             " (after a system update this is usually a changed file: "
             "sudo rkhunter --propupd once you've checked it)")
    else:
        ok("rootkit scan (rkhunter) clean")


# ── 3. Logins from the system log ────────────────────────────────────────────
def login_audit():
    if not os.access(AUTH_LOG, os.R_OK):
        skip("login audit: can't read /var/log/auth.log (needs the adm group)")
        return
    since = datetime.now(timezone.utc) - timedelta(hours=24)
    accepted, failed, sudo_fail, acct = [], {}, 0, []
    with open(AUTH_LOG, errors="replace") as f:
        for line in f:
            try:
                ts = datetime.fromisoformat(line.split(" ", 1)[0])
            except ValueError:
                continue
            if ts < since:
                continue
            m = re.search(r"Accepted (\S+) for (\S+) from (\S+)", line)
            if m:
                accepted.append((m.group(2), m.group(3), m.group(1)))
                continue
            m = re.search(r"(?:Failed \S+ for (?:invalid user )?\S+|Invalid user \S+) from (\S+)", line)
            if m:
                failed[m.group(1)] = failed.get(m.group(1), 0) + 1
                continue
            if "sudo:" in line and ("authentication failure" in line
                                    or "incorrect password attempt" in line):
                sudo_fail += 1
            if re.search(r"(useradd|groupadd|usermod|userdel|chpasswd|passwd)\[\d+\]:", line) \
                    and re.search(r"new user|new group|add '|delete user|changed|password changed",
                                  line):
                acct.append(line.split(": ", 1)[-1].strip()[:120])
    outside = [a for a in accepted if not trusted(a[1])]
    if outside:
        fail("SSH login(s) from outside your home network/Tailscale: " +
             ", ".join(f"{u} from {ip} ({how})" for u, ip, how in outside[:5]))
    else:
        ok(f"SSH logins in the last day: {len(accepted)}, all from home/Tailscale")
    nfail = sum(failed.values())
    if nfail >= FAILED_SSH_WARN:
        top = sorted(failed.items(), key=lambda x: -x[1])[:3]
        warn(f"{nfail} failed SSH logins in the last day (top: " +
             ", ".join(f"{ip} x{n}" for ip, n in top) + ") — someone is guessing passwords")
    else:
        ok(f"failed SSH logins in the last day: {nfail}")
    if sudo_fail:
        warn(f"{sudo_fail} failed sudo password attempt(s) in the last day")
    if acct:
        fail("user account changes in the last day: " + "; ".join(acct[:5]))


# ── 4. App logins (Jellyfin, Nextcloud) ──────────────────────────────────────
def app_logins():
    rc, out = run(["docker", "logs", "--since", "24h", "jellyfin"], timeout=60)
    if rc == 0:
        denied = re.findall(r"Authentication request for \"?([^\" ]+)\"? has been denied"
                            r"(?:.*?IP: \"?([0-9a-fA-F.:]+))?", out)
        ips = {ip for _, ip in denied if ip}
        if len(denied) >= FAILED_APP_WARN:
            warn(f"Jellyfin: {len(denied)} failed logins in the last day"
                 + (f" from {', '.join(sorted(ips)[:5])}" if ips else ""))
        else:
            ok(f"Jellyfin failed logins in the last day: {len(denied)}")
    rc, out = run(["docker", "exec", "-u", "www-data", "nextcloud", "sh", "-c",
                   "f=$(php occ config:system:get logfile 2>/dev/null); "
                   "f=${f:-/var/www/html/data/nextcloud.log}; tail -c 5000000 \"$f\" 2>/dev/null"],
                  timeout=60)
    if rc == 0:
        since = datetime.now(timezone.utc) - timedelta(hours=24)
        n, ips = 0, set()
        for line in out.splitlines():
            if "Login failed" not in line and "Bruteforce" not in line:
                continue
            try:
                e = json.loads(line)
                if datetime.fromisoformat(e["time"].replace("Z", "+00:00")) < since:
                    continue
                ips.add(e.get("remoteAddr", ""))
            except Exception:
                continue
            n += 1
        if n >= FAILED_APP_WARN:
            warn(f"Nextcloud: {n} failed logins in the last day from "
                 f"{', '.join(sorted(i for i in ips if i)[:5])}")
        else:
            ok(f"Nextcloud failed logins in the last day: {n}")


# ── 5-7. Things compared with the baseline ───────────────────────────────────
def snapshot():
    s = {}
    users = []
    for l in Path("/etc/passwd").read_text().splitlines():
        p = l.split(":")
        if len(p) < 7:
            continue
        if p[2] == "0" or (int(p[2]) >= 1000 and not p[6].endswith(("nologin", "false"))):
            users.append(f"{p[0]}(uid {p[2]}, {p[6]})")
    s["login accounts"] = users
    grp = {l.split(":")[0]: l.split(":")[3] for l in Path("/etc/group").read_text().splitlines()}
    s["admin (sudo) members"] = sorted(set(filter(None, grp.get("sudo", "").split(","))))
    keys = []
    ak = HOME / ".ssh/authorized_keys"
    if ak.exists():
        for l in ak.read_text().splitlines():
            if l.strip() and not l.startswith("#"):
                parts = l.split()
                keys.append(" ".join(parts[-1:]) + " " + parts[1][-12:] if len(parts) > 1 else l[-20:])
    s["SSH keys allowed to log in"] = keys
    s["sudoers files"] = sorted(os.listdir("/etc/sudoers.d"))
    rc, out = run(["crontab", "-l"])
    s["your cron jobs"] = [l for l in out.splitlines() if l.strip() and not l.startswith("#")] if rc == 0 else []
    s["system cron files"] = sorted(f"{d}/{f}" for d in ("/etc/cron.d", "/etc/cron.daily",
                                                        "/etc/cron.hourly", "/etc/cron.weekly")
                                    if os.path.isdir(d) for f in os.listdir(d))
    units = []
    for d in ("/etc/systemd/system", str(HOME / ".config/systemd/user")):
        if os.path.isdir(d):
            units += [f"{d}/{f}" for f in os.listdir(d)
                      if f.endswith((".service", ".timer", ".socket", ".path"))]
    s["systemd services"] = sorted(units)
    # Listening ports: port + address family-agnostic, process if visible.
    rc, out = run(["ss", "-tulnpH"])
    lst = set()
    for l in out.splitlines():
        p = l.split()
        if len(p) < 5:
            continue
        addr = p[4]
        port = addr.rsplit(":", 1)[-1]
        scope = "local" if re.match(r"^(127\.|\[::1\]|\[::ffff:127)", addr) else "network"
        proc = re.search(r'\(\("([^"]+)"', l)
        lst.add(f"{p[0]}/{port} {scope}" + (f" ({proc.group(1)})" if proc else ""))
    s["listening ports"] = sorted(lst)
    # Outbound: which host processes talk to the internet (names only — IPs
    # change constantly). Containers live in their own network namespaces.
    rc, out = run(["ss", "-tnpH", "state", "established"])
    talkers, bad = set(), []
    for l in out.splitlines():
        p = l.split()
        if len(p) < 4:
            continue
        peer = p[3]
        ip, port = peer.rsplit(":", 1)
        ip = ip.strip("[]")
        if not public(ip):
            continue
        proc = re.search(r'\(\("([^"]+)"', l)
        name = proc.group(1) if proc else "(system process)"
        talkers.add(name)
        if port.isdigit() and int(port) in BAD_PORTS:
            bad.append(f"{name} -> {ip}:{port}")
    s["programs talking to the internet"] = sorted(talkers)
    return s, bad


def compare(snap, bad):
    if bad:
        fail("connection(s) to backdoor/IRC ports: " + ", ".join(bad[:5]))
    if ACCEPT or not BASELINE.exists():
        CONF.mkdir(parents=True, exist_ok=True)
        old = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
        # Outbound talkers accumulate: a program seen once is expected later.
        for k in ("programs talking to the internet",):
            snap[k] = sorted(set(snap[k]) | set(old.get(k, [])))
        BASELINE.write_text(json.dumps({"recorded": time.strftime("%Y-%m-%d %H:%M"),
                                        **snap}, indent=1))
        BASELINE.chmod(0o600)
        ok(f"recorded accounts, keys, services, ports and outbound programs as expected ({BASELINE})")
        return
    base = json.loads(BASELINE.read_text())
    severe = {"login accounts", "admin (sudo) members", "SSH keys allowed to log in",
              "sudoers files"}
    for k, now in snap.items():
        new = sorted(set(now) - set(base.get(k, [])))
        if not new:
            ok(f"no new {k}")
            continue
        msg = (f"new {k}: {', '.join(new[:6])}" + (f" (+{len(new) - 6} more)" if len(new) > 6 else "")
               + " — if you added it: intrusion-check.py --accept")
        if k in severe:
            fail(msg)
        else:
            warn(msg)


def main():
    print("  --- intrusion & malware check ---", flush=True)
    STATE.mkdir(parents=True, exist_ok=True)
    for step in (login_audit, app_logins, lambda: compare(*snapshot()),
                 rootkit_scan, malware_scan):
        try:
            step()
        except Exception as e:
            warn(f"{getattr(step, '__name__', 'check')} crashed: {type(e).__name__}: {e}")
    if fails and SEND_ALERT.exists() and not ACCEPT:
        run([str(SEND_ALERT), "[homelab] SECURITY: intrusion/malware check found something",
             "The nightly intrusion & malware check flagged:\n\n- " + "\n- ".join(fails) +
             "\n\nFull output: today's daily-routine log in ~/.dbmedia/maintenance-logs/."
             "\nIf a flagged item is something you added yourself: intrusion-check.py --accept\n"],
            timeout=60)


if __name__ == "__main__":
    main()
