# Mopeka BLE proxy

An ESP32 running ESPHome's `bluetooth_proxy` component, placed near the
propane tanks (out of range of both NUCs' onboard Bluetooth). It doesn't
decode anything itself -- it just forwards every raw BLE advertisement it
hears to whatever connects to its native API. A Python exporter elsewhere
on the LAN connects to that API directly (via `aioesphomeapi`, no Home
Assistant needed) and decodes the Mopeka-specific ones. See the propane
monitoring section of [../../docs/roadmap.md](../../docs/roadmap.md) for
the exporter/dashboard side.

Board: any ESP32 works (recommended: M5Stack Atom Lite, ~$10 -- small,
enclosed, USB-C powered, no soldering).

## One-time flash

Two ways to get this onto the board -- pick one:

**Option A -- ESPHome's official prebuilt Bluetooth Proxy firmware
(simplest, no build tooling needed at all):**
1. Plug the board into a computer via USB, open Chrome or Edge.
2. Go to https://web.esphome.io, click "Connect", select the board's
   serial port.
3. Choose "Bluetooth Proxy" from the list of ready-made projects (M5Stack
   Atom Lite is a supported target) and follow the wizard -- it flashes
   and lets you enter WiFi credentials through the browser.
4. Done -- skip the rest of this file. This project's `mopeka-proxy.yaml`
   isn't used in this path.

**Option B -- flash this repo's tracked config (use this if the config
ever needs customizing, e.g. a static IP):**
1. Install the ESPHome CLI (`pip install esphome`) -- do this on whatever
   machine has the USB cable, not necessarily this workstation.
2. `cp secrets.yaml.example secrets.yaml` and fill in real values (WiFi
   creds, a generated API encryption key -- see the comment in the
   example file). `secrets.yaml` is gitignored -- never commit it.
3. Plug the board in via USB, then from this directory:
   `esphome run mopeka-proxy.yaml` -- builds and flashes over USB, first
   time only. Every subsequent update can go out over WiFi
   (`esphome upload mopeka-proxy.yaml` with no cable needed).
4. Note the IP it joins the LAN with (printed at the end of the run, or
   check the router's DHCP leases) -- the exporter needs it.

Either way, once it's up: place it near the tanks, plug it into power, and
confirm it's on the Rambles LAN (10.0.2.0/24).
