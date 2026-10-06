#!/bin/bash
# power-sampler-install.sh — one-time root install of the dashboard's power
# sampler. Run with sudo. Idempotent: re-run after editing power-sampler.py.
#
# The service runs a root-owned copy in /usr/local/sbin, never the file in
# ~/.local/bin — root executing a user-writable script would hand root to
# anything running as the user.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

SRC="$(dirname "$(readlink -f "$0")")/power-sampler.py"
install -o root -g root -m 0755 "$SRC" /usr/local/sbin/power-sampler.py

cat > /etc/systemd/system/power-sampler.service <<'EOF'
[Unit]
Description=Publish averaged CPU/GPU power draw for the desktop dashboard

[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/power-sampler.py
Restart=always
RestartSec=10
Nice=10
# Reads sysfs counters and writes one file under /run — nothing else.
ProtectSystem=strict
ProtectHome=yes
RuntimeDirectory=power-sampler
RuntimeDirectoryMode=0755
PrivateTmp=yes
PrivateNetwork=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable power-sampler.service
systemctl restart power-sampler.service
sleep 7
if [[ -r /run/power-sampler/power.json ]]; then
    echo "[OK] power-sampler running: $(cat /run/power-sampler/power.json)"
else
    echo "[FAIL] no output yet — check: journalctl -u power-sampler -n 20"
    exit 1
fi
