#!/usr/bin/env python3
"""power-sampler.py — publish CPU/GPU power draw for the desktop dashboard.

Runs as root (power-sampler.service) because the Intel RAPL energy counters
are root-only: a fine-grained counter lets unprivileged code infer secrets
(PLATYPUS, CVE-2020-8694). Instead of loosening those permissions this reads
them itself and publishes only averaged watts — 5-second and 1-minute means,
far too coarse for that side channel — to a world-readable JSON file that
status-collect.py (running as the user) picks up.

Domains (whatever this machine exposes):
  package   whole CPU package          (intel-rapl:0)
  cores     CPU cores only              (intel-rapl:0:0)
  igpu      uncore / integrated GPU     (intel-rapl:0:1)
  dram      memory, if the CPU has it   (intel-rapl:0:2 "dram")
  platform  psys, SoC platform total    (intel-rapl:1)
  gpu       discrete GPU package        (hwmon "xe"/"i915"/"amdgpu" energy)
"""
import json
import os
import time
from collections import deque
from pathlib import Path

OUT = Path("/run/power-sampler/power.json")
INTERVAL = 5
WINDOW = 60

RAPL_NAMES = {"package-0": "package", "core": "cores", "uncore": "igpu",
              "dram": "dram", "psys": "platform"}


def find_counters():
    """name -> (energy file, wrap range in µJ or None)."""
    out = {}
    for z in sorted(Path("/sys/class/powercap").glob("intel-rapl:*")):
        try:
            name = RAPL_NAMES.get((z / "name").read_text().strip())
            rng = int((z / "max_energy_range_uj").read_text())
        except (OSError, ValueError):
            continue
        if name and name not in out:
            out[name] = (z / "energy_uj", rng)
    for h in Path("/sys/class/hwmon").glob("hwmon*"):
        try:
            if (h / "name").read_text().strip() not in ("xe", "i915", "amdgpu"):
                continue
        except OSError:
            continue
        for f in sorted(h.glob("energy*_input")):
            out.setdefault("gpu", (f, None))
    return out


def read(counters):
    vals = {}
    for name, (f, _) in counters.items():
        try:
            vals[name] = int(f.read_text())
        except (OSError, ValueError):
            pass
    return vals


def watts(a, b, dt, counters):
    out = {}
    for name in b:
        if name not in a:
            continue
        d = b[name] - a[name]
        rng = counters[name][1]
        if d < 0:                       # counter wrapped
            if not rng:
                continue
            d += rng
        out[name] = round(d / 1e6 / dt, 1)
    return out


def write(data):
    OUT.parent.mkdir(mode=0o755, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT)


def main():
    counters = find_counters()
    history = deque(maxlen=WINDOW // INTERVAL)
    prev, prev_t = read(counters), time.monotonic()
    while True:
        time.sleep(INTERVAL)
        cur, now = read(counters), time.monotonic()
        w = watts(prev, cur, now - prev_t, counters)
        prev, prev_t = cur, now
        # A reading far past any plausible draw means a glitch; drop it.
        if not w or any(v > 2000 for v in w.values()):
            continue
        history.append(w)
        avg = {k: round(sum(h.get(k, 0) for h in history) / len(history), 1)
               for k in w}
        write({"ts": int(time.time()), "interval": INTERVAL,
               "now": w, "avg_1m": avg})


if __name__ == "__main__":
    main()
