"""update_status: what's out of date across the platform (Milestone 19, ADR-0024).

Read-only. Pulls together:

- OS packages on the hub and NUCs: node-exporter textfile metrics written
  by each host's host-update-metrics.timer (compose/*/host/update-metrics.sh):
  pending updates by severity, reboot needed, and (hub only) a newer Amazon
  Linux 2023 release. dnf-automatic already applies security updates daily,
  so anything security-flagged here means it didn't, or is waiting on a reboot
- OS end of life: node_os_info (node-exporter) checked against endoflife.date
- RouterOS / RouterBOOT, Synology DSM, Cisco SG300 firmware: snmp_exporter's
  versions.yml modules, checked against MikroTik's own "newest stable" feed
- Container images pinned in this repo's compose files on `main`, checked
  against their registries (Docker Hub, ghcr.io) for newer releases of the
  same tag shape, plus end-of-life dates for databases

Network lookups (registries, MikroTik, endoflife.date) are cached for
CACHE_SECONDS, so repeated voice questions don't hammer anyone. Every
source fails independently: a broken lookup becomes one "couldn't check"
line, never a failed tool call.
"""

import asyncio
import datetime
import os
import re
import time

import httpx
import yaml

import github_status
from status import PROMETHEUS_URL

OWNER = github_status.OWNER
REPO = os.environ.get("CONTEXT_REPO_NAME", "nyc_pa_aws_gitops")
COMPOSE_FILES = ["compose/aws/docker-compose.yml", "compose/nuc/docker-compose.yml", "compose/nuc/voice-worker/docker-compose.yml"]
CACHE_SECONDS = 6 * 3600
USER_AGENT = "home-mcp update_status (github.com/bcalaway/nyc_pa_aws_gitops)"

# Images whose release line itself is finished, independent of tag numbers.
IMAGE_NOTES = {
    "grafana/promtail": "Promtail is deprecated and Grafana has ended support for it; plan a move to Grafana Alloy",
}
# Images whose major version is a product line with an end-of-life date
# (endoflife.date names Postgres cycles by major version, matching the tag).
EOL_PRODUCTS = {"postgres": "postgresql"}
OS_EOL_PRODUCTS = {"rocky": "rocky-linux", "amzn": "amazon-linux"}
# Hardware no vendor will ship firmware for again.
LEGACY_FIRMWARE = {"cisco": "Cisco SG300 switches are end of life; no more firmware will come, so replacing them is the only fix for future vulnerabilities"}
DSM_UPGRADE = {"1": "an update is available", "2": "up to date", "3": "still checking", "4": "can't reach Synology's update server", "5": "unknown"}

PRERELEASE = re.compile(r"(?i)(rc|beta|alpha|dev|pre|preview|nightly|test|snapshot|edge)")
TAG_RE = re.compile(r"^(v?)(\d+(?:\.\d+)*)(.*)$")

_cache: dict[str, tuple[float, object]] = {}


def _cached(key: str):
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    return None


def _store(key: str, value):
    _cache[key] = (time.monotonic(), value)
    return value


# ---------------------------------------------------------------- tags

def parse_tag(tag: str):
    """'v1.8.2' -> ('v', (1, 8, 2), ''); '7-alpine' -> ('', (7,), '-alpine')."""
    m = TAG_RE.match(tag)
    if not m:
        return None
    prefix, nums, suffix = m.groups()
    return prefix, tuple(int(n) for n in nums.split(".")), suffix


def newest_same_shape(current: str, tags: list[str]) -> str | None:
    """Newest tag shaped like `current` (same prefix, suffix and number of
    components, no pre-releases) that's newer than it; None if up to date."""
    cur = parse_tag(current)
    if not cur or PRERELEASE.search(cur[2]):
        return None
    best, best_nums = None, cur[1]
    for t in tags:
        p = parse_tag(t)
        if not p or p[0] != cur[0] or p[2] != cur[2] or len(p[1]) != len(cur[1]):
            continue
        if PRERELEASE.search(p[2]):
            continue
        if p[1] > best_nums:
            best, best_nums = t, p[1]
    return best


def split_image(ref: str):
    """'ghcr.io/goauthentik/server:2026.2.6' -> ('ghcr.io', 'goauthentik/server', '2026.2.6')."""
    ref = ref.split("@", 1)[0]
    name, _, tag = ref.rpartition(":")
    if not name or "/" in tag:  # no tag, or a registry port
        name, tag = ref, "latest"
    first = name.split("/", 1)[0]
    if "." in first or ":" in first:
        registry, repo = first, name.split("/", 1)[1]
    else:
        registry, repo = "docker.io", name if "/" in name else f"library/{name}"
    return registry, repo, tag


def images_in_compose(text: str) -> list[str]:
    services = (yaml.safe_load(text) or {}).get("services", {}) or {}
    return sorted({s["image"] for s in services.values() if isinstance(s, dict) and s.get("image")})


async def _dockerhub_tags(client: httpx.AsyncClient, repo: str) -> list[str]:
    ns, name = repo.split("/", 1)
    url = f"https://hub.docker.com/v2/namespaces/{ns}/repositories/{name}/tags"
    params = {"page_size": 100, "ordering": "last_updated"}
    tags: list[str] = []
    for _ in range(3):
        r = await client.get(url, params=params, timeout=15)
        r.raise_for_status()
        d = r.json()
        tags += [t["name"] for t in d.get("results", [])]
        if not d.get("next"):
            break
        url, params = d["next"], None
    return tags


async def _ghcr_tags(client: httpx.AsyncClient, repo: str) -> list[str]:
    r = await client.get("https://ghcr.io/token", params={"scope": f"repository:{repo}:pull", "service": "ghcr.io"}, timeout=10)
    r.raise_for_status()
    headers = {"Authorization": f"Bearer {r.json()['token']}"}
    url = f"https://ghcr.io/v2/{repo}/tags/list?n=1000"
    tags: list[str] = []
    for _ in range(10):
        r = await client.get(url, headers=headers, timeout=15)
        r.raise_for_status()
        tags += r.json().get("tags") or []
        link = r.headers.get("link", "")
        m = re.search(r"<([^>]+)>;\s*rel=\"next\"", link)
        if not m:
            break
        url = m.group(1) if m.group(1).startswith("http") else f"https://ghcr.io{m.group(1)}"
    return tags


async def _registry_tags(client: httpx.AsyncClient, registry: str, repo: str) -> list[str]:
    key = f"tags:{registry}/{repo}"
    hit = _cached(key)
    if hit is not None:
        return hit
    if registry == "docker.io":
        tags = await _dockerhub_tags(client, repo)
    elif registry == "ghcr.io":
        tags = await _ghcr_tags(client, repo)
    else:
        raise ValueError(f"unsupported registry {registry}")
    return _store(key, tags)


async def _eol(client: httpx.AsyncClient, product: str) -> list[dict]:
    key = f"eol:{product}"
    hit = _cached(key)
    if hit is not None:
        return hit
    r = await client.get(f"https://endoflife.date/api/v1/products/{product}/", timeout=10)
    r.raise_for_status()
    return _store(key, r.json().get("result", {}).get("releases", []))


def _eol_line(releases: list[dict], cycle: str, today: datetime.date) -> tuple[str, bool] | None:
    """(phrase, urgent) for a release cycle, or None if not near end of life."""
    for rel in releases:
        if str(rel.get("name")) != cycle:
            continue
        eol = rel.get("eolFrom")
        if rel.get("isEol"):
            return (f"reached end of life{f' on {eol}' if eol else ''}", True)
        if eol:
            days = (datetime.date.fromisoformat(eol) - today).days
            if days <= 180:
                return (f"reaches end of life on {eol}", days <= 60)
        return None
    return None


async def _mikrotik_latest(client: httpx.AsyncClient, major: str) -> str:
    channel = "NEWESTa7.stable" if major == "7" else "NEWEST6.stable"
    key = f"mikrotik:{channel}"
    hit = _cached(key)
    if hit is not None:
        return hit
    r = await client.get(f"https://upgrade.mikrotik.com/routeros/{channel}", timeout=10)
    r.raise_for_status()
    return _store(key, r.text.split()[0])


async def _prom(client: httpx.AsyncClient, query: str) -> list[dict]:
    r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": query}, timeout=10)
    r.raise_for_status()
    return r.json()["data"]["result"]


def _vtuple(v: str):
    return tuple(int(x) for x in re.findall(r"\d+", v))


# ---------------------------------------------------------------- sections

async def _hosts(client: httpx.AsyncClient, today: datetime.date) -> tuple[list[str], list[str], list[str]]:
    """(urgent, other, couldnt) lines for OS packages and OS end of life."""
    urgent, other, couldnt = [], [], []
    pending, reboot, release, last, osinfo = await asyncio.gather(
        _prom(client, 'host_updates_pending{job="node-exporter"}'),
        _prom(client, 'host_reboot_required{job="node-exporter"}'),
        _prom(client, 'host_os_release_update_available{job="node-exporter"}'),
        _prom(client, 'host_updates_last_check_timestamp_seconds{job="node-exporter"}'),
        _prom(client, 'node_os_info{job="node-exporter", instance=~"aws-hub|nuc.*"}'),
    )
    by_host: dict[str, dict] = {}
    for r in pending:
        by_host.setdefault(r["metric"]["instance"], {})[r["metric"]["type"]] = int(float(r["value"][1]))
    reboots = {r["metric"]["instance"] for r in reboot if r["value"][1] == "1"}
    checked = {r["metric"]["instance"]: float(r["value"][1]) for r in last}
    now = time.time()
    off_season = today.month >= 11 or today.month <= 4
    for host in ("aws-hub", "nuc4", "nuc5"):
        name = "hub" if host == "aws-hub" else host
        if host not in checked:
            if host == "nuc5" and off_season:
                continue
            couldnt.append(f"{name}: no update data yet (its update check hasn't reported)")
            continue
        if now - checked[host] > 24 * 3600:
            couldnt.append(f"{name}: update check hasn't run for {int((now - checked[host]) // 3600)} hours")
        c = by_host.get(host, {})
        sec, crit, imp = c.get("security", 0), c.get("critical", 0), c.get("important", 0)
        parts = []
        if c.get("all"):
            parts.append(f"{c['all']} package update{'s' if c['all'] != 1 else ''} pending")
        if sec:
            parts.append(f"{sec} security ({crit} critical, {imp} important)")
        if host in reboots:
            parts.append("needs a reboot to finish installing updates")
        line = f"{name}: " + ", ".join(parts) if parts else ""
        if crit or imp or host in reboots:
            urgent.append(line)
        elif line:
            other.append(line)
    for r in release:
        if r["value"][1] == "1":
            m = r["metric"]
            other.append(f"hub: Amazon Linux {m.get('latest')} is available (running {m.get('current')}); dnf upgrade won't pick it up on its own, it needs dnf upgrade --releasever")
    for r in osinfo:
        m = r["metric"]
        product = OS_EOL_PRODUCTS.get(m.get("id", ""))
        if not product:
            continue
        cycle = m.get("version_id", "").split(".")[0]
        try:
            hit = _eol_line(await _eol(client, product), cycle, today)
        except httpx.HTTPError:
            couldnt.append(f"end-of-life dates for {m.get('name', product)}")
            continue
        if hit:
            (urgent if hit[1] else other).append(f"{m['instance']}: {m.get('pretty_name', product)} {hit[0]}")
    return urgent, other, couldnt


async def _network(client: httpx.AsyncClient, today: datetime.date) -> tuple[list[str], list[str], list[str]]:
    urgent, other, couldnt = [], [], []
    ros, boot, boot_up, dsm, dsm_up, cisco = await asyncio.gather(
        _prom(client, "mtxrLicVersion"),
        _prom(client, "mtxrFirmwareVersion"),
        _prom(client, "mtxrFirmwareUpgradeVersion"),
        _prom(client, "synoDsmVersion"),
        _prom(client, "synoUpgradeAvailable"),
        _prom(client, "rlPhdUnitGenParamSoftwareVersion"),
    )
    off_season = today.month >= 11 or today.month <= 4
    seen = {r["metric"].get("device") for r in ros}
    for dev in ("rt-nyc", "rt-rambles", "sw-10g"):
        if dev not in seen and not (dev == "rt-rambles" and off_season):
            couldnt.append(f"{dev}: RouterOS version not reported over SNMP")
    boot_by = {r["metric"].get("device"): r["metric"].get("mtxrFirmwareVersion", "") for r in boot}
    boot_up_by = {r["metric"].get("device"): r["metric"].get("mtxrFirmwareUpgradeVersion", "") for r in boot_up}
    for r in ros:
        dev, ver = r["metric"].get("device"), r["metric"].get("mtxrLicVersion", "")
        major = ver.split(".")[0]
        try:
            latest = await _mikrotik_latest(client, major)
        except httpx.HTTPError:
            couldnt.append("MikroTik's latest RouterOS release")
            continue
        if _vtuple(latest) > _vtuple(ver):
            line = f"{dev}: RouterOS {ver}, {latest} is the current stable"
            # A jump in the second number (7.19 -> 7.20) usually carries
            # security fixes worth taking; a patch release less often.
            (urgent if _vtuple(latest)[:2] != _vtuple(ver)[:2] else other).append(line)
        if boot_by.get(dev) and boot_up_by.get(dev) and boot_by[dev] != boot_up_by[dev]:
            other.append(f"{dev}: RouterBOOT {boot_by[dev]} is behind the installed RouterOS ({boot_up_by[dev]}); /system routerboard upgrade, then reboot")
    dsm_status = {r["metric"].get("device"): r["value"][1] for r in dsm_up}
    for r in dsm:
        dev = r["metric"].get("device")
        st = dsm_status.get(dev, "5")
        if st == "1":
            urgent.append(f"{dev}: DSM {r['metric'].get('synoDsmVersion', '')}, {DSM_UPGRADE['1']}")
        elif st in ("4", "5"):
            couldnt.append(f"{dev}: DSM says {DSM_UPGRADE[st]}")
    if not dsm:
        couldnt.append("nas2: DSM version not reported over SNMP")
    if cisco:
        devs = sorted({r["metric"].get("device") for r in cisco})
        vers = sorted({r["metric"].get("rlPhdUnitGenParamSoftwareVersion", "") for r in cisco})
        other.append(f"{' and '.join(devs)} (firmware {', '.join(vers)}): {LEGACY_FIRMWARE['cisco']}")
    return urgent, other, couldnt


async def _images(client: httpx.AsyncClient, today: datetime.date) -> tuple[list[str], list[str], list[str]]:
    urgent, other, couldnt = [], [], []
    refs: set[str] = set()
    for path in COMPOSE_FILES:
        try:
            r = await client.get(f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main/{path}", timeout=10)
            r.raise_for_status()
            refs.update(images_in_compose(r.text))
        except (httpx.HTTPError, yaml.YAMLError):
            couldnt.append(f"image list from {path}")

    async def check(ref: str):
        registry, repo, tag = split_image(ref)
        short = repo.removeprefix("library/")
        if short in IMAGE_NOTES:
            other.append(f"{short}: {IMAGE_NOTES[short]}")
        try:
            tags = await _registry_tags(client, registry, repo)
        except (httpx.HTTPError, ValueError, KeyError):
            couldnt.append(f"newer tags for {short}")
            return
        newer = newest_same_shape(tag, tags)
        cur = parse_tag(tag)
        floating = cur is not None and len(cur[1]) < 3 and cur[1][0] < 1000
        if newer:
            kind = "major" if parse_tag(newer)[1][0] != cur[1][0] else "update"
            other.append(f"{short} {tag} -> {newer} ({kind})" + (" [floating tag]" if floating else ""))
        if short in EOL_PRODUCTS and cur:
            try:
                hit = _eol_line(await _eol(client, EOL_PRODUCTS[short]), str(cur[1][0]), today)
            except httpx.HTTPError:
                couldnt.append(f"end-of-life dates for {short}")
                return
            if hit:
                (urgent if hit[1] else other).append(f"{short} {cur[1][0]} {hit[0]}")

    await asyncio.gather(*(check(ref) for ref in sorted(refs)))
    other.sort()
    return urgent, other, couldnt


async def update_status(detail: bool = False) -> str:
    today = datetime.date.today()
    urgent: list[str] = []
    other: list[str] = []
    couldnt: list[str] = []
    async with httpx.AsyncClient(headers={"User-Agent": USER_AGENT}) as client:
        results = await asyncio.gather(
            _hosts(client, today), _network(client, today), _images(client, today), return_exceptions=True
        )
    for name, res in zip(("OS packages", "network device firmware", "container images"), results):
        if isinstance(res, Exception):
            couldnt.append(f"{name} ({type(res).__name__})")
            continue
        u, o, c = res
        urgent += [x for x in u if x]
        other += [x for x in o if x]
        couldnt += c

    image_lines = [x for x in other if " -> " in x]
    rest = [x for x in other if " -> " not in x]
    if not urgent and not other:
        head = "Everything I can check is up to date."
    else:
        bits = []
        if urgent:
            bits.append(f"{len(urgent)} thing{'s' if len(urgent) != 1 else ''} worth doing soon")
        if rest:
            bits.append(f"{len(rest)} other update{'s' if len(rest) != 1 else ''}")
        if image_lines:
            bits.append(f"{len(image_lines)} container image{'s' if len(image_lines) != 1 else ''} behind")
        head = "Updates: " + ", ".join(bits) + "."
    lines = [head]
    if urgent:
        lines.append("Soon: " + "; ".join(urgent) + ".")
    if detail:
        if rest:
            lines.append("Also: " + "; ".join(rest) + ".")
        if image_lines:
            lines.append(
                "Images (Dependabot opens PRs for these; [floating tag] means patch releases already "
                "arrive on each hub redeploy, the listed jump is a new major/minor line): " + "; ".join(image_lines) + "."
            )
    elif rest or image_lines:
        lines.append("Ask for the detail to hear the rest.")
    if couldnt:
        lines.append("Couldn't check: " + "; ".join(sorted(set(couldnt))) + ".")
    return "\n".join(lines)
