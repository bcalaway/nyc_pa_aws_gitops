import logging
import os
import time

from prometheus_client import Gauge, start_http_server
from rachiopy import Rachio

API_KEY = os.environ["RACHIO_API_KEY"]
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "60"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rachio-exporter")

rachio = Rachio(API_KEY)

# Just an on/off indicator per zone -- Bill's actual ask ("mostly just an
# indicator that the watering has happened or not per date"). Sampled every
# POLL_INTERVAL_SECONDS like every other exporter here, so Grafana's own
# stored history *is* the per-date record (a state-timeline panel over
# rachio_zone_watering already shows exactly this) -- no separate ingestion
# of Rachio's historical-events API needed.
g_zone_watering = Gauge(
    "rachio_zone_watering", "1 while this zone is actively watering, else 0", ["device", "zone"]
)
g_last_success = Gauge(
    "rachio_exporter_last_success_timestamp_seconds", "Unix timestamp of the last successful poll"
)

# device_id -> {zone_id: zone_name}, and device_id -> device_name. Fetched
# once at startup rather than every poll -- zone/device names don't change
# on their own, and the current_schedule endpoint is the only one that
# actually needs polling.
_devices = {}


def discover_devices():
    _, person_info = rachio.person.getinfo()
    person_id = person_info["id"]
    _, person = rachio.person.get(person_id)

    devices = {}
    for device in person.get("devices", []):
        zones = {zone["id"]: zone["name"] for zone in device.get("zones", [])}
        devices[device["id"]] = {"name": device.get("name", device["id"]), "zones": zones}
    return devices


def poll():
    for device_id, device in _devices.items():
        _, schedule = rachio.device.get_current_schedule(device_id)
        # Empty dict (or no zoneId key) when nothing is running -- confirmed
        # against RachioPy's own behavior, not yet against Bill's real
        # account/device (no API key available while writing this). Verify
        # this shape live the first time this actually deploys.
        active_zone_id = schedule.get("zoneId") if schedule else None

        for zone_id, zone_name in device["zones"].items():
            is_active = 1 if zone_id == active_zone_id else 0
            g_zone_watering.labels(device=device["name"], zone=zone_name).set(is_active)

    g_last_success.set(time.time())
    log.info("poll ok: %d device(s)", len(_devices))


def main():
    global _devices
    start_http_server(9200)
    log.info("rachio-exporter listening on :9200, polling every %ds", POLL_INTERVAL_SECONDS)

    while not _devices:
        try:
            _devices = discover_devices()
            for device in _devices.values():
                log.info("found device %r with zones: %s", device["name"], list(device["zones"].values()))
        except Exception:
            log.exception("device discovery failed, will retry")
            time.sleep(POLL_INTERVAL_SECONDS)

    while True:
        try:
            poll()
        except Exception:
            log.exception("poll failed, will retry next interval")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
