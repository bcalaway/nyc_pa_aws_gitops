import asyncio
import logging
import os
import time

import yaml
from aioesphomeapi import APIClient
from bluetooth_data_tools import parse_advertisement_data_bytes
from home_assistant_bluetooth import BluetoothServiceInfoBleak
from mopeka_iot_ble import MopekaIOTBluetoothDeviceData
from prometheus_client import Gauge, start_http_server

# One or more ESPHome BLE proxies, as parallel comma-separated lists (same
# order, same length): MOPEKA_PROXIES=host1,host2 and
# MOPEKA_API_KEYS=key1,key2. base64 noise PSKs never contain a comma, so a
# plain split is safe.
PROXY_HOSTS = [h.strip() for h in os.environ["MOPEKA_PROXIES"].split(",") if h.strip()]
PROXY_KEYS = [k.strip() for k in os.environ["MOPEKA_API_KEYS"].split(",")]
PROXY_PORT = int(os.environ.get("MOPEKA_PROXY_PORT", "6053"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9102"))
RECONNECT_DELAY_SECONDS = int(os.environ.get("RECONNECT_DELAY_SECONDS", "10"))
SENSORS_FILE = os.environ.get("MOPEKA_SENSORS_FILE", "sensors.yaml")

if len(PROXY_HOSTS) != len(PROXY_KEYS):
    raise SystemExit(
        "MOPEKA_PROXIES and MOPEKA_API_KEYS must have the same number of comma-separated entries"
    )

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mopeka-exporter")


def _load_sensor_map() -> dict[str, dict]:
    """MAC (upper-case, colon-separated) -> {name, tank_height_mm?}. Missing
    or malformed file is non-fatal -- the exporter just falls back to each
    sensor's firmware name and skips fill_percent."""
    try:
        with open(SENSORS_FILE) as fh:
            raw = yaml.safe_load(fh) or {}
    except FileNotFoundError:
        log.warning("%s not found -- using firmware sensor names, no fill %%", SENSORS_FILE)
        return {}
    except (yaml.YAMLError, OSError):
        log.exception("failed to read %s -- using firmware sensor names", SENSORS_FILE)
        return {}
    out = {}
    for mac, cfg in (raw.get("sensors") or {}).items():
        cfg = cfg or {}
        out[str(mac).upper()] = {
            "name": cfg.get("name"),
            "full_mm": cfg.get("full_mm"),
            "empty_mm": cfg.get("empty_mm", 0),
        }
    log.info("loaded %d named sensor(s) from %s", len(out), SENSORS_FILE)
    return out


def _fill_percent(level_mm: float, cfg: dict) -> float | None:
    """Linear level->percent using the sensor's raw reading at full/empty
    (correct for vertical cylinders -- RV and grill tanks). Returns None
    unless full_mm is configured for this tank."""
    full = cfg.get("full_mm")
    if not full:
        return None
    empty = cfg.get("empty_mm") or 0
    span = full - empty
    if span <= 0:
        return None
    pct = 100.0 * (level_mm - empty) / span
    return max(0.0, min(100.0, pct))


SENSOR_MAP = _load_sensor_map()

# The propane-tank Mopeka Pro Check sensors broadcast passively -- we never
# connect to them. One or more ESP32s running ESPHome's bluetooth_proxy
# (near the tanks, on the Rambles LAN -- see esphome/mopeka-proxy/ and
# docs/network-inventory.md) relay every raw BLE advertisement they hear to
# whoever subscribes to their native API. This exporter subscribes to all
# of them at once, decodes the Mopeka-specific advertisements with
# mopeka-iot-ble (the same library Home Assistant's own Mopeka integration
# uses), and exposes the readings as Prometheus gauges. No Home Assistant
# involved.
#
# Multiple proxies are how BLE coverage scales when the tanks are spread
# out -- a sensor heard by more than one proxy just updates the same
# per-sensor gauges from whichever advertisement arrives; only
# mopeka_sensor_signal_dbm carries a `proxy` label, so you can see which
# proxy has the best line to each tank (max by (sensor)).
#
# NOTE: the ESPHome prebuilt "Bluetooth Proxy" firmware only pushes *raw*
# advertisements (subscribe_bluetooth_le_raw_advertisements) -- the parsed
# subscription (subscribe_bluetooth_le_advertisements) silently delivers
# nothing against it. bluetooth-data-tools does the GAP parsing here
# instead, exactly as Home Assistant does downstream of a proxy.

SOURCE = "mopeka-proxy"

g_temp = Gauge(
    "mopeka_sensor_temperature_celsius",
    "Sensor-reported ambient temperature",
    ["sensor", "mac"],
)
g_battery_percent = Gauge(
    "mopeka_sensor_battery_percent", "Sensor battery level", ["sensor", "mac"]
)
g_battery_volts = Gauge(
    "mopeka_sensor_battery_volts", "Sensor battery voltage", ["sensor", "mac"]
)
# Raw time-of-flight level reading: the height of the propane liquid column
# above the (bottom-mounted) sensor. Higher = more propane. Always exported.
g_tank_level_mm = Gauge(
    "mopeka_sensor_tank_level_mm",
    "Raw ultrasonic level reading (height of propane above the sensor)",
    ["sensor", "mac"],
)
# Only emitted for tanks with `full_mm` set in sensors.yaml (see that file).
g_fill_percent = Gauge(
    "mopeka_sensor_fill_percent",
    "Estimated tank fill (linear from the raw reading at full/empty; vertical tanks)",
    ["sensor", "mac"],
)
g_reading_quality = Gauge(
    "mopeka_sensor_reading_quality_percent",
    "Sensor's own confidence in the current level reading",
    ["sensor", "mac"],
)
g_signal_dbm = Gauge(
    "mopeka_sensor_signal_dbm",
    "BLE signal strength of this sensor as heard by a given proxy",
    ["sensor", "mac", "proxy"],
)
g_last_seen = Gauge(
    "mopeka_sensor_last_seen_timestamp_seconds",
    "Unix timestamp of the last decoded advertisement from this sensor (via any proxy)",
    ["sensor", "mac"],
)
g_proxy_up = Gauge(
    "mopeka_proxy_up",
    "1 if the exporter currently has a live connection to this ESPHome BLE proxy's API",
    ["proxy"],
)
g_last_success = Gauge(
    "mopeka_exporter_last_success_timestamp_seconds",
    "Unix timestamp this proxy's API connection was last established",
    ["proxy"],
)

# mopeka-iot-ble DeviceKey.key -> the gauge it feeds. Keys it emits that
# aren't useful on a tank dashboard (accelerometer_x/y, reading_quality_raw)
# are intentionally left out; signal_strength is handled separately from the
# raw advertisement RSSI so it can carry the proxy label.
_METRIC_BY_KEY = {
    "temperature": g_temp,
    "battery": g_battery_percent,
    "battery_voltage": g_battery_volts,
    "tank_level": g_tank_level_mm,
    "reading_quality": g_reading_quality,
}

# mac -> MopekaIOTBluetoothDeviceData (stateful; keep one per known sensor).
# All proxy tasks share this via the single asyncio event loop -- callbacks
# are sync with no await between dict ops, so no lock is needed.
_sensors: dict[str, MopekaIOTBluetoothDeviceData] = {}


def _mac(address: int) -> str:
    return ":".join(f"{(address >> (8 * i)) & 0xFF:02X}" for i in reversed(range(6)))


def _firmware_name(update, fallback: str) -> str:
    for info in update.devices.values():
        if info and info.name:
            return info.name
    return fallback


def _handle_advertisement(proxy: str, address: int, rssi: int, raw: bytes) -> None:
    mac = _mac(address)
    local_name, service_uuids, service_data, manufacturer_data, tx_power = (
        parse_advertisement_data_bytes(raw)
    )
    service_info = BluetoothServiceInfoBleak(
        name=local_name or mac,
        address=mac,
        rssi=rssi,
        manufacturer_data=dict(manufacturer_data),
        service_data=dict(service_data),
        service_uuids=list(service_uuids),
        source=SOURCE,
        device=None,
        advertisement=None,
        connectable=False,
        time=time.monotonic(),
        tx_power=tx_power if tx_power is not None else -127,
    )

    sensor = _sensors.get(mac)
    if sensor is None:
        candidate = MopekaIOTBluetoothDeviceData()
        if not candidate.supported(service_info):
            return  # not a Mopeka advertisement -- ignore (re-checked next time)
        sensor = _sensors[mac] = candidate
        log.info("[%s] discovered Mopeka sensor %s (%s)", proxy, mac, local_name or "?")

    update = sensor.update(service_info)
    cfg = SENSOR_MAP.get(mac, {})
    name = cfg.get("name") or _firmware_name(update, mac)

    level_mm = None
    for device_key, value in update.entity_values.items():
        if not isinstance(value.native_value, (int, float)):
            continue
        if device_key.key == "tank_level":
            level_mm = value.native_value
        gauge = _METRIC_BY_KEY.get(device_key.key)
        if gauge is not None:
            gauge.labels(sensor=name, mac=mac).set(value.native_value)

    if level_mm is not None:
        pct = _fill_percent(level_mm, cfg)
        if pct is not None:
            g_fill_percent.labels(sensor=name, mac=mac).set(pct)

    g_signal_dbm.labels(sensor=name, mac=mac, proxy=proxy).set(rssi)
    g_last_seen.labels(sensor=name, mac=mac).set(time.time())


def _on_raw(proxy: str, response) -> None:
    for adv in response.advertisements:
        try:
            _handle_advertisement(proxy, adv.address, adv.rssi, bytes(adv.data))
        except Exception:
            log.exception("[%s] failed to handle advertisement from %s", proxy, _mac(adv.address))


async def _run_once(host: str, key: str) -> None:
    disconnected: asyncio.Event = asyncio.Event()

    async def on_stop(expected_disconnect: bool) -> None:
        log.warning("[%s] proxy connection closed (expected=%s)", host, expected_disconnect)
        disconnected.set()

    client = APIClient(host, PROXY_PORT, password="", noise_psk=key)
    try:
        await client.connect(on_stop=on_stop, login=True)
        info = await client.device_info()
        log.info("[%s] connected (%s, esphome %s)", host, info.name, info.esphome_version)
        g_proxy_up.labels(proxy=host).set(1)
        g_last_success.labels(proxy=host).set(time.time())
        client.subscribe_bluetooth_le_raw_advertisements(lambda resp: _on_raw(host, resp))
        await disconnected.wait()
    finally:
        g_proxy_up.labels(proxy=host).set(0)
        try:
            await client.disconnect()
        except Exception:
            pass


async def _proxy_loop(host: str, key: str) -> None:
    while True:
        try:
            await _run_once(host, key)
        except Exception:
            log.exception("[%s] connection error; retrying in %ds", host, RECONNECT_DELAY_SECONDS)
        else:
            log.info("[%s] disconnected; reconnecting in %ds", host, RECONNECT_DELAY_SECONDS)
        await asyncio.sleep(RECONNECT_DELAY_SECONDS)


async def _run_forever() -> None:
    await asyncio.gather(*(_proxy_loop(host, key) for host, key in zip(PROXY_HOSTS, PROXY_KEYS)))


def main() -> None:
    start_http_server(METRICS_PORT)
    for host in PROXY_HOSTS:
        g_proxy_up.labels(proxy=host).set(0)
    log.info(
        "mopeka-exporter listening on :%d, proxies: %s",
        METRICS_PORT,
        ", ".join(f"{h}:{PROXY_PORT}" for h in PROXY_HOSTS),
    )
    asyncio.run(_run_forever())


if __name__ == "__main__":
    main()
