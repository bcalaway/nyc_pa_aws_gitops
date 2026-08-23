import logging
import os
import time
from datetime import date, datetime, timedelta

import requests
from prometheus_client import Gauge, start_http_server

API_KEY = os.environ["RACHIO_API_KEY"]
# This is a historical-summary API, not a live status endpoint -- nothing is
# gained by polling faster than a person would actually check it.
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "900"))
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "3"))

# Bill's controller is a Rachio Smart Hose Timer (the "puck" base station +
# battery valves), not the classic wall-mounted sprinkler controller --
# confirmed live 2026-08-23 that the classic public API's
# /person/{id} always returns devices=[] for this product line. It lives on
# an entirely separate API/object model (BaseStations/Valves), not covered
# by the rachiopy library (which only wraps the classic API), so this talks
# to the REST endpoints directly.
CLASSIC_API_BASE = "https://api.rach.io/1/public"
VALVE_API_BASE = "https://cloud-rest.rach.io"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rachio-exporter")

session = requests.Session()
session.headers.update({"Authorization": f"Bearer {API_KEY}"})

# Deliberately no "date" label -- that would create a new time series per
# valve per calendar day forever. A plain "did it water today" boolean,
# recomputed every poll, gives the same per-date picture through Grafana's
# own sample history (a state-timeline panel over this gauge renders one
# block per day on its own), matching the original "current status" design
# but now driven by the accurate skip-aware signal below instead of a live
# current-schedule guess.
g_watered_today = Gauge(
    "rachio_valve_watered_today", "1 if this valve has actually watered today, else 0", ["valve"]
)
g_last_watered_timestamp = Gauge(
    "rachio_valve_last_watered_timestamp_seconds",
    "Unix timestamp of the most recent non-skipped watering start, per valve",
    ["valve"],
)
g_last_success = Gauge(
    "rachio_exporter_last_success_timestamp_seconds", "Unix timestamp of the last successful poll"
)

_base_station_id = None
_valve_names = {}  # valve id -> name


def discover():
    global _base_station_id, _valve_names

    person_id = session.get(f"{CLASSIC_API_BASE}/person/info").json()["id"]

    stations = session.get(f"{VALVE_API_BASE}/valve/listBaseStations/{person_id}").json()
    base_stations = stations.get("baseStations", [])
    if not base_stations:
        raise RuntimeError("no Rachio base station found for this account")
    _base_station_id = base_stations[0]["id"]

    valves = session.get(f"{VALVE_API_BASE}/valve/listValves/{_base_station_id}").json()
    _valve_names = {v["id"]: v["name"] for v in valves.get("valves", [])}
    log.info("found base station %s with valves: %s", _base_station_id, list(_valve_names.values()))


def _runs_for_day(day):
    """Flatten a day's program/quick/manual run summaries into one list,
    each tagged with whether it was actually skipped.

    Program runs nest their valve runs under "valveRunSummaries" and mark a
    skipped one with a "skip" key -- confirmed against Bill's real watering
    history 2026-08-23 (a rain/weather-intelligence skip keeps
    durationSeconds at the originally-planned value, so duration alone
    doesn't distinguish a real run from a skipped one). Manual runs use the
    same nested "valveRunSummaries" wrapper (seen live for a real ad hoc
    run). Quick runs were empty in every sample checked -- assumed to share
    the same wrapper shape, unverified.
    """
    runs = []
    for wrapper in day.get("valveProgramRunSummaries", []):
        for run in wrapper.get("valveRunSummaries", []):
            runs.append({**run, "_skipped": "skip" in run})
    for wrapper in day.get("valveQuickRunSummaries", []) + day.get("valveManualRunSummaries", []):
        for run in wrapper.get("valveRunSummaries", []):
            runs.append({**run, "_skipped": False})
    return runs


def poll():
    today = date.today()
    start = today - timedelta(days=LOOKBACK_DAYS)
    body = {
        "start": {"year": start.year, "month": start.month, "day": start.day},
        "end": {"year": today.year, "month": today.month, "day": today.day},
        "resourceId": {"baseStationId": _base_station_id},
    }
    resp = session.post(f"{VALVE_API_BASE}/summary/getValveDayViews", json=body).json()

    watered_today = {name: False for name in _valve_names.values()}
    latest_run_start = {}

    for day in resp.get("valveDayViews", []):
        d = day["date"]
        day_date = date(d["year"], d["month"], d["day"])

        for run in _runs_for_day(day):
            if run["_skipped"]:
                continue
            # Seen live for the "Back" valve on several days: 0 duration,
            # no skip present. Treated as "didn't really water" rather than
            # guessing -- worth Bill double-checking against the Rachio
            # app's own history for that valve specifically.
            if run.get("durationSeconds", 0) <= 0:
                continue

            valve_name = _valve_names.get(run.get("valveId"), run.get("valveName", run.get("valveId")))
            if day_date == today:
                watered_today[valve_name] = True

            start_dt = datetime.fromisoformat(run["start"].replace("Z", "+00:00"))
            if valve_name not in latest_run_start or start_dt > latest_run_start[valve_name]:
                latest_run_start[valve_name] = start_dt

    for valve_name, watered in watered_today.items():
        g_watered_today.labels(valve=valve_name).set(1 if watered else 0)
    for valve_name, start_dt in latest_run_start.items():
        g_last_watered_timestamp.labels(valve=valve_name).set(start_dt.timestamp())

    g_last_success.set(time.time())
    log.info("poll ok: watered_today=%s", watered_today)


def main():
    start_http_server(9200)
    log.info("rachio-exporter listening on :9200, polling every %ds", POLL_INTERVAL_SECONDS)

    while _base_station_id is None:
        try:
            discover()
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
