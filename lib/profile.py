"""Install profile: the answers the installer asks once, saved as YAML.

A profile carries NO installer logic — it is pure data. Hand yours to a friend
and they get a template of your *choices*, not your secrets (or load nothing
and the installer asks fresh questions instead).
"""
from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


def _gen_secret() -> str:
    return secrets.token_hex(16)


# Providers gluetun has built-in server lists for (VPN_SERVICE_PROVIDER value
# -> display name). "custom" covers everything else: your own server, or a
# provider that only hands you an .ovpn / WireGuard config.
VPN_PROVIDERS = {
    "airvpn": "AirVPN", "cyberghost": "CyberGhost", "expressvpn": "ExpressVPN",
    "fastestvpn": "FastestVPN", "giganews": "Giganews", "hidemyass": "HideMyAss",
    "ipvanish": "IPVanish", "ivpn": "IVPN", "mullvad": "Mullvad",
    "nordvpn": "NordVPN", "perfect privacy": "Perfect Privacy",
    "privado": "Privado", "private internet access": "Private Internet Access",
    "privatevpn": "PrivateVPN", "protonvpn": "Proton VPN", "purevpn": "PureVPN",
    "slickvpn": "SlickVPN", "surfshark": "Surfshark", "torguard": "TorGuard",
    "vpnsecure": "VPNSecure", "vpn unlimited": "VPN Unlimited",
    "vyprvpn": "VyprVPN", "windscribe": "Windscribe", "custom": "Custom VPN",
}

@dataclass
class Profile:
    # identity / network
    user: str = ""
    lan_ip: str = ""
    lan_cidr: str = "192.168.1.0/24"
    host_ip: str = ""                    # what Plex advertises (LAN IP or tailscale)
    # domains
    domain: str = ""                     # base domain (e.g. example.org) or ""
    jellyfin_public_url: str = ""        # https://jellyfin.example.org ("" = skip)
    nextcloud_domain: str = ""
    immich_domain: str = ""
    duckdns_domains: str = ""            # e.g. myname,mynameplex,mynameseerr
    duckdns_token: str = ""
    # storage
    media_pool: str = "/mnt/storage"
    nextcloud_data: str = "/mnt/nextcloud-data"
    media_disks: list[str] = field(default_factory=list)   # extra mount checks
    # vpn — any provider gluetun supports (see VPN_PROVIDERS), or "custom"
    # for a server of your own / a provider that isn't on the list.
    vpn_provider: str = "surfshark"
    vpn_type: str = "openvpn"            # openvpn | wireguard
    vpn_name: str = ""                   # dashboard label; blank = provider name
    vpn_user: str = ""                   # OpenVPN
    vpn_password: str = ""
    vpn_openvpn_config: str = ""         # custom + openvpn: path to your .ovpn file
    vpn_wg_private_key: str = ""         # WireGuard
    vpn_wg_addresses: str = ""           # e.g. 10.64.222.21/32
    vpn_wg_preshared_key: str = ""       # optional
    vpn_wg_public_key: str = ""          # custom + wireguard: the server's public key
    vpn_wg_endpoint_ip: str = ""         # custom + wireguard: the server's IP
    vpn_wg_endpoint_port: str = "51820"
    vpn_server_countries: str = "Netherlands"   # ignored for "custom"
    vpn_rotate_hourly: bool = True
    # components
    use_media_stack: bool = True         # immich/plex/jellyfin/portainer/caddy/seerr
    use_vpn_stack: bool = True           # gluetun/qbit/sonarr/radarr/prowlarr/chrome
    use_dashboard: bool = True
    use_daily_routine: bool = True
    use_post_reboot_check: bool = True
    use_duckdns: bool = False
    use_wastebins: bool = True
    use_alerts: bool = False
    # Local AI: Z.ai's official open-weights GLM via Ollama, downloaded only on
    # machines where this is ticked. "auto" picks by RAM at install time
    # (glm-4.7-flash, 19 GB, needs ~24 GB RAM; else glm4:9b, 5.5 GB).
    use_local_glm: bool = False
    glm_model: str = "auto"
    # nightly self-heal schedule -- also changeable live from the dashboard
    # (status-dashboard-server.py's /api/schedule), which rewrites the
    # crontab directly; these fields are just what a fresh install seeds it
    # with.
    daily_routine_frequency: str = "daily"   # "daily" | "weekly" | "monthly" | "yearly"
    daily_routine_time: str = "03:00"        # HH:MM, 24h
    # secrets
    nc_db_password: str = ""
    nc_admin_password: str = ""
    immich_db_password: str = ""
    plex_claim: str = ""
    tugtainer_secret: str = ""
    qbit_user: str = "admin"
    qbit_password: str = ""
    vnc_pw: str = ""
    openrouter_api_key: str = ""
    # alerts (SMTP)
    smtp_host: str = ""
    smtp_port: str = "587"
    smtp_user: str = ""
    smtp_pass: str = ""
    mail_from: str = ""
    mail_to: str = ""

    # ── derived render dictionary ────────────────────────────────────────
    def render_vars(self) -> dict:
        home = str(Path.home())
        user = self.user or Path.home().name
        pool = self.media_pool or "/mnt/storage"
        disks = [d for d in self.media_disks if d] or \
                [f"{pool}/disk{i}" for i in (1, 2, 3)]
        while len(disks) < 3:
            disks.append(disks[-1])
        return {
            "HOME": home,
            "DASH_USER": user,
            "LAN_IP": self.lan_ip or "127.0.0.1",
            "LAN_CIDR": self.lan_cidr,
            "LAN_GLOB": (self.lan_ip.rsplit(".", 1)[0] + ".*") if self.lan_ip else "127.0.0.*",
            "HOST_IP": self.host_ip or self.lan_ip or "127.0.0.1",
            "DOMAIN": self.domain,
            "JELLYFIN_PUBLIC_URL": self.jellyfin_public_url,
            "NEXTCLOUD_DOMAIN": self.nextcloud_domain,
            "IMMICH_DOMAIN": self.immich_domain,
            "DUCKDNS_DOMAIN_MEDIA": self.duckdns_domains.split(",")[0].strip() + ".duckdns.org"
                                     if self.duckdns_domains else "",
            "DUCKDNS_DOMAIN_PLEX": (self.duckdns_domains.split(",")[1].strip() + ".duckdns.org"
                                    if "," in self.duckdns_domains else ""),
            # 3rd (optional) slot: "myname,mynameplex,mynameseerr" -- Seerr is
            # on the same docker network as Caddy (unlike qBittorrent/Sonarr/
            # Radarr/Prowlarr, which are deliberately loopback-only inside
            # gluetun's netns and aren't safely reverse-proxyable without a
            # bigger network redesign), so it's the one easy addition here.
            "DUCKDNS_DOMAIN_SEERR": (self.duckdns_domains.split(",")[2].strip() + ".duckdns.org"
                                     if self.duckdns_domains.count(",") >= 2 else ""),
            "DUCKDNS_TOKEN": self.duckdns_token,
            "MEDIA_POOL": pool,
            "NEXTCLOUD_DATA": self.nextcloud_data or f"{pool}/nextcloud-data",
            "MEDIA_DISK1": disks[0],
            "MEDIA_DISK2": disks[1],
            "MEDIA_DISK3": disks[2],
            "MEDIA_DISK_PREFIX": repr(tuple(disks)),
            "NC_DB_ROOT_PASSWORD": self.nc_db_password,
            "NC_DB_PASSWORD": self.nc_db_password,
            "NC_ADMIN_PASSWORD": self.nc_admin_password,
            "IMMICH_DB_PASSWORD": self.immich_db_password,
            "UPLOAD_LOCATION": f"{self.nextcloud_data}/immich",
            "PLEX_CLAIM": self.plex_claim,
            "TUGTAINER_SECRET": self.tugtainer_secret,
            "QBIT_USER": self.qbit_user,
            "QBIT_PASSWORD": self.qbit_password,
            "VNC_PW": self.vnc_pw,
            "OPENVPN_USER": self.vpn_user,
            "OPENVPN_PASSWORD": self.vpn_password,
            "VPN_SERVER_COUNTRIES": self.vpn_server_countries,
            "TAILSCALE_IP": "",
        }

    # ── yaml round-trip ──────────────────────────────────────────────────
    def to_yaml(self) -> str:
        d = {"meta": {"created": datetime.now(timezone.utc).isoformat(),
                      "installer": "copperarch-media-setup"}}
        for f in self.__dataclass_fields__:
            d[f] = getattr(self, f)
        return yaml.safe_dump(d, sort_keys=False, default_flow_style=False)

    def save(self, path: Path) -> Path:
        path.write_text(self.to_yaml())
        path.chmod(0o600)
        return path

    @classmethod
    def from_yaml(cls, path: Path) -> "Profile":
        data = yaml.safe_load(Path(path).read_text()) or {}
        p = cls()
        for f in p.__dataclass_fields__:
            if f in data and data[f] is not None:
                setattr(p, f, data[f])
        return p

    @property
    def vpn_is_custom(self) -> bool:
        return (self.vpn_provider or "").strip().lower() == "custom"

    @property
    def vpn_label(self) -> str:
        """Name the dashboard shows for the active VPN."""
        if self.vpn_name.strip():
            return self.vpn_name.strip()
        key = (self.vpn_provider or "").strip().lower()
        return VPN_PROVIDERS.get(key, key.title() or "VPN")

    def _validate_vpn(self) -> list[str]:
        errs = []
        prov = (self.vpn_provider or "").strip().lower()
        vtype = (self.vpn_type or "").strip().lower()
        if not prov:
            errs.append("vpn_provider is required (a gluetun provider name, or 'custom')")
        elif prov not in VPN_PROVIDERS:
            errs.append(f"vpn_provider '{self.vpn_provider}' is not one gluetun knows — "
                        "use 'custom' for your own server or an unlisted provider")
        if vtype not in ("openvpn", "wireguard"):
            errs.append("vpn_type must be 'openvpn' or 'wireguard'")
        elif vtype == "wireguard":
            if not (self.vpn_wg_private_key and self.vpn_wg_addresses):
                errs.append("vpn_wg_private_key / vpn_wg_addresses required for WireGuard")
            if self.vpn_is_custom and not (self.vpn_wg_public_key and self.vpn_wg_endpoint_ip):
                errs.append("vpn_wg_public_key / vpn_wg_endpoint_ip required for a "
                            "custom WireGuard server")
        elif self.vpn_is_custom:
            if not self.vpn_openvpn_config:
                errs.append("vpn_openvpn_config (path to your .ovpn file) required for "
                            "a custom OpenVPN server")
            elif not Path(self.vpn_openvpn_config).expanduser().is_file():
                errs.append(f"vpn_openvpn_config: no such file {self.vpn_openvpn_config}")
        elif not (self.vpn_user and self.vpn_password):
            errs.append("vpn_user / vpn_password required for OpenVPN")
        return errs

    def validate(self) -> list[str]:
        errs = []
        if self.use_media_stack or self.use_vpn_stack:
            if not re.fullmatch(r"[0-9a-fA-F.:]+", self.lan_ip or ""):
                errs.append("network.lan_ip must be a valid IPv4/IPv6 address")
        if self.use_vpn_stack:
            errs += self._validate_vpn()
        if self.use_duckdns and not (self.duckdns_token and self.duckdns_domains):
            errs.append("duckdns_token + duckdns_domains required when DuckDNS is enabled")
        if self.use_alerts and not self.smtp_host:
            errs.append("smtp settings required when alerts are enabled")
        return errs

    @classmethod
    def with_generated_secrets(cls) -> "Profile":
        p = cls()
        p.nc_db_password = _gen_secret()
        p.nc_admin_password = _gen_secret()
        p.immich_db_password = _gen_secret()
        p.tugtainer_secret = _gen_secret()
        p.qbit_password = _gen_secret()
        p.vnc_pw = _gen_secret()
        return p
