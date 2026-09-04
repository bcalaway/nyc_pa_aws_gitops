import logging
import os
import re
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import requests
from prometheus_client import Gauge, start_http_server

STATION_HOST = os.environ["STATION_HOST"]
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "60"))
# The station's own daily-reset metrics (e.g. daily max gust) roll over at
# its local midnight; the daily temp high/low tracked below matches that.
STATION_TZ = ZoneInfo(os.environ.get("STATION_TZ", "America/New_York"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("weather-exporter")

# EcoWitt's get_livedata_info is an undocumented local API (the same JSON
# the console's own web UI live-data view consumes internally, confirmed by
# polling a real WS3900B at 10.0.2.245 -- see CLAUDE.md's Gotchas). Ecowitt
# publishes no field reference for it, unlike their documented push/upload
# protocol (tempf, humidity, etc.), so the id->meaning mapping below is
# based on the widely-referenced convention used across community
# integrations (WeeWX, Home Assistant's local-API mode, etc.) and confirmed
# self-consistent against real readings (e.g. dew point a hair below temp at
# 99% humidity). A handful of ids seen in real responses (0x05, 0x6D, 0x7C,
# 0x7D) aren't confidently identified and are deliberately left unmapped
# rather than guessed. Firmware updates could change this API without
# notice -- if metrics suddenly go missing, check the raw response shape
# first before assuming this exporter broke.
_NUM_RE = re.compile(r"[-+]?\d*\.\d+|[-+]?\d+")


def _num(val: str) -> float:
    m = _NUM_RE.search(val)
    return float(m.group()) if m else float("nan")


# Per-key running min/max since station-local midnight. Rolls over on the
# date change, matching the station's own daily-reset metrics. An exporter
# restart mid-day resets the window -- the "daily high" then re-climbs from
# the current reading, same caveat as the speedtest scheduling elsewhere.
_daily_stats: dict[str, dict] = {}


def _track_daily(key: str, value: float):
    if value != value:  # NaN
        return None
    today = datetime.now(STATION_TZ).date()
    rec = _daily_stats.get(key)
    if rec is None or rec["day"] != today:
        rec = _daily_stats[key] = {"day": today, "min": value, "max": value}
    else:
        rec["min"] = min(rec["min"], value)
        rec["max"] = max(rec["max"], value)
    return rec["min"], rec["max"]


g_outdoor_temp = Gauge("weather_outdoor_temp_fahrenheit", "Outdoor temperature")
g_apparent_temp = Gauge("weather_apparent_temp_fahrenheit", 'Apparent ("feels like") temperature')
g_dew_point = Gauge("weather_dew_point_fahrenheit", "Dew point")
g_outdoor_humidity = Gauge("weather_outdoor_humidity_percent", "Outdoor relative humidity")
g_indoor_temp = Gauge("weather_indoor_temp_fahrenheit", "Console indoor temperature")
g_indoor_humidity = Gauge("weather_indoor_humidity_percent", "Console indoor relative humidity")
g_pressure_rel = Gauge("weather_pressure_relative_inhg", "Relative (sea-level-adjusted) barometric pressure")
g_pressure_abs = Gauge("weather_pressure_absolute_inhg", "Absolute (station-elevation) barometric pressure")
g_wind_dir = Gauge("weather_wind_direction_degrees", "Wind direction")
g_wind_speed = Gauge("weather_wind_speed_mph", "Wind speed")
g_wind_gust = Gauge("weather_wind_gust_mph", "Current wind gust speed")
g_wind_gust_daily_max = Gauge("weather_wind_gust_daily_max_mph", "Maximum wind gust today")
g_solar_radiation = Gauge("weather_solar_radiation_watts_per_m2", "Solar irradiance")
g_uv_index = Gauge("weather_uv_index", "UV index")

# labeled by sensor: this station reports both a classic tipping-bucket gauge
# and a WS90 piezo rain sensor.
g_rain_event = Gauge("weather_rain_event_inches", "Rain accumulated in the current rain event", ["sensor"])
g_rain_rate = Gauge("weather_rain_rate_inches_per_hour", "Current rain rate", ["sensor"])
g_rain_day = Gauge("weather_rain_day_inches", "Rain accumulated today", ["sensor"])
g_rain_week = Gauge("weather_rain_week_inches", "Rain accumulated this week", ["sensor"])
g_rain_month = Gauge("weather_rain_month_inches", "Rain accumulated this month", ["sensor"])
g_rain_year = Gauge("weather_rain_year_inches", "Rain accumulated this year", ["sensor"])
# Battery encoding differs by sensor type -- the classic tipping-bucket
# reports 0=OK/1=low, but the WS90 piezo sensor reports a 0-5 level instead
# (confirmed live: piezo read "5" while healthy) -- reporting both under one
# "_low" boolean would misrepresent the piezo's real value, so this is the
# raw report as-is; interpret per sensor label, not as a single threshold.
g_rain_battery_raw = Gauge(
    "weather_rain_sensor_battery_raw", "Raw battery report from the rain sensor (encoding differs by sensor)",
    ["sensor"],
)
g_rain_voltage = Gauge("weather_rain_sensor_voltage", "Battery voltage, piezo (WS90) sensor only", ["sensor"])

g_extra_temp = Gauge("weather_extra_sensor_temp_fahrenheit", "Extra temp/humidity sensor channel", ["channel"])
g_extra_humidity = Gauge(
    "weather_extra_sensor_humidity_percent", "Extra temp/humidity sensor channel", ["channel"]
)

# Daily high/low, reset at station-local midnight (see _track_daily).
g_outdoor_temp_daily_max = Gauge("weather_outdoor_temp_daily_max_fahrenheit", "Outdoor temp daily high")
g_outdoor_temp_daily_min = Gauge("weather_outdoor_temp_daily_min_fahrenheit", "Outdoor temp daily low")
g_indoor_temp_daily_max = Gauge("weather_indoor_temp_daily_max_fahrenheit", "Console indoor temp daily high")
g_indoor_temp_daily_min = Gauge("weather_indoor_temp_daily_min_fahrenheit", "Console indoor temp daily low")
g_extra_temp_daily_max = Gauge(
    "weather_extra_sensor_temp_daily_max_fahrenheit", "Extra temp sensor daily high", ["channel"]
)
g_extra_temp_daily_min = Gauge(
    "weather_extra_sensor_temp_daily_min_fahrenheit", "Extra temp sensor daily low", ["channel"]
)

g_last_success = Gauge(
    "weather_exporter_last_success_timestamp_seconds", "Unix timestamp of the last successful poll"
)


def _find(entries, id_):
    for entry in entries:
        if entry.get("id") == id_:
            return entry
    return None


def _apply_rain(entries, sensor):
    if e := _find(entries, "0x0D"):
        g_rain_event.labels(sensor=sensor).set(_num(e["val"]))
    if e := _find(entries, "0x0E"):
        g_rain_rate.labels(sensor=sensor).set(_num(e["val"]))
    if e := _find(entries, "0x10"):
        g_rain_day.labels(sensor=sensor).set(_num(e["val"]))
    if e := _find(entries, "0x11"):
        g_rain_week.labels(sensor=sensor).set(_num(e["val"]))
    if e := _find(entries, "0x12"):
        g_rain_month.labels(sensor=sensor).set(_num(e["val"]))
    if e := _find(entries, "0x13"):
        g_rain_year.labels(sensor=sensor).set(_num(e["val"]))
        if "battery" in e:
            g_rain_battery_raw.labels(sensor=sensor).set(_num(e["battery"]))
        if "voltage" in e:
            g_rain_voltage.labels(sensor=sensor).set(_num(e["voltage"]))


def poll():
    resp = requests.get(f"http://{STATION_HOST}/get_livedata_info", timeout=5)
    resp.raise_for_status()
    data = resp.json()

    common = data.get("common_list", [])
    if e := _find(common, "0x02"):
        outdoor_t = _num(e["val"])
        g_outdoor_temp.set(outdoor_t)
        if mm := _track_daily("outdoor", outdoor_t):
            g_outdoor_temp_daily_min.set(mm[0])
            g_outdoor_temp_daily_max.set(mm[1])
    if e := _find(common, "3"):
        g_apparent_temp.set(_num(e["val"]))
    if e := _find(common, "0x03"):
        g_dew_point.set(_num(e["val"]))
    if e := _find(common, "0x07"):
        g_outdoor_humidity.set(_num(e["val"]))
    if e := _find(common, "0x0A"):
        g_wind_dir.set(_num(e["val"]))
    if e := _find(common, "0x0B"):
        g_wind_speed.set(_num(e["val"]))
    if e := _find(common, "0x0C"):
        g_wind_gust.set(_num(e["val"]))
    if e := _find(common, "0x19"):
        g_wind_gust_daily_max.set(_num(e["val"]))
    if e := _find(common, "0x15"):
        g_solar_radiation.set(_num(e["val"]))
    if e := _find(common, "0x17"):
        g_uv_index.set(_num(e["val"]))

    wh25 = data.get("wh25", [])
    if wh25:
        indoor = wh25[0]
        indoor_t = _num(indoor["intemp"])
        g_indoor_temp.set(indoor_t)
        g_indoor_humidity.set(_num(indoor["inhumi"]))
        g_pressure_abs.set(_num(indoor["abs"]))
        g_pressure_rel.set(_num(indoor["rel"]))
        if mm := _track_daily("indoor", indoor_t):
            g_indoor_temp_daily_min.set(mm[0])
            g_indoor_temp_daily_max.set(mm[1])

    _apply_rain(data.get("rain", []), sensor="bucket")
    _apply_rain(data.get("piezoRain", []), sensor="piezo")

    for ch in data.get("ch_aisle", []):
        channel = ch.get("channel")
        if channel is None:
            continue
        extra_t = _num(ch["temp"])
        g_extra_temp.labels(channel=channel).set(extra_t)
        g_extra_humidity.labels(channel=channel).set(_num(ch["humidity"]))
        if mm := _track_daily(f"extra{channel}", extra_t):
            g_extra_temp_daily_min.labels(channel=channel).set(mm[0])
            g_extra_temp_daily_max.labels(channel=channel).set(mm[1])

    g_last_success.set(time.time())
    log.info("poll ok")


def main():
    start_http_server(9101)
    log.info("weather-exporter listening on :9101, polling %s every %ds", STATION_HOST, POLL_INTERVAL_SECONDS)
    while True:
        try:
            poll()
        except Exception:
            log.exception("poll failed, will retry next interval")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
