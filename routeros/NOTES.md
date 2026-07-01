# RouterOS 7 / RB5009 — Hard-won notes

These were all discovered the painful way during the NYC RB5009 bring-up.
Read this before touching another site.

---

## First login

The factory admin password is **not blank**. It is printed on a sticker on
the bottom of the router and also in the box manual. You must log in via
**WebFig (http://192.168.88.1) before SSH will accept connections**. Until
you complete the first WebFig login, SSH returns "Connection closed"
regardless of credentials.

---

## Factory bridge is named "bridge"

After Quick Set, RouterOS 7 creates a bridge named exactly `bridge` (not
`bridge-lan`, not `br-lan`). The LAN IP (192.168.88.1/24) is on it.
Do not rename it — several factory references (interface lists, defconf
rules) depend on the name. Instead, remove only the ports you don't want
(ether1/ether2 for WAN) and leave the rest.

---

## `remove [find]` aborts on dynamic rules — use `remove [find dynamic=no]`

The firewall filter table always contains at least one dynamic rule (rule 0,
the fasttrack counter, flagged `D`). Dynamic rules cannot be removed.

```
/ip firewall filter remove [find]        # WRONG — aborts entire batch
/ip firewall filter remove [find dynamic=no]   # CORRECT
```

Same applies to raw and mangle tables as a precaution. If the batch aborts,
none of the subsequent `add` commands run, the factory rules stay, and the
rest of the script silently stops — including the LAN IP change. You will
see "Import completed without connection drop" instead of the expected drop.

---

## Don't reference an interface before it exists in firewall rules

`in-interface=wg-aws` in a firewall `add` command fails if `wg-aws` has not
been created yet. RouterOS aborts the entire `/import` script at that line.

Use `src-address=10.0.3.0/24` instead — it is functionally equivalent for
the INPUT chain and has no interface dependency:

```
# WRONG (fails if wg-aws not yet created):
/ip firewall filter add chain=input action=accept in-interface=wg-aws

# CORRECT:
/ip firewall filter add chain=input action=accept src-address=10.0.3.0/24
```

---

## Hardware bridge offloading: use `src-address`, not `in-interface=bridge`

The RB5009 uses a Marvell switching chip with hardware-accelerated bridging.
Unicast packets destined for the router itself arrive tagged with the
physical port (ether3, ether4, …) as `in-interface`, not with the bridge
interface. As a result, `in-interface=bridge` never matches TCP traffic
(though it works for broadcasts like DHCP).

Use `src-address=10.0.1.0/24` (or whatever the LAN subnet is) for INPUT
chain rules that need to accept traffic from LAN clients:

```
# WRONG — TCP never matches:
/ip firewall filter add chain=input action=accept in-interface=bridge

# CORRECT:
/ip firewall filter add chain=input action=accept src-address=10.0.1.0/24
```

---

## `/import` continues server-side after SSH drops

When the script removes the factory LAN IP (192.168.88.1), the SSH
connection drops. This is **expected and correct** — the `/import` process
keeps running on the router without SSH. All sections after the IP change
(DHCP, WireGuard, routes, NTP, etc.) still execute. Do not retry the import
just because SSH dropped.

In the apply script, catch the exception and treat it as success:

```python
except Exception:
    print("Connection dropped — IP changed to 10.0.1.1 (expected)")
```

---

## Flush connection tracking at the END, not the beginning

`/ip firewall connection remove [find]` kills all tracked connections,
including the active SSH session running the import. If it runs at the top of
the script, the established SSH entry is removed; the `drop invalid` rule
then drops subsequent packets from that session, killing the import mid-run.

Move it to the very last line, after all rules are in place:

```
# Section 14 — last line of the script
/ip firewall connection remove [find]
```

---

## WebFig terminal as a recovery path

If SSH is locked out (wrong source IP, wrong address restriction), WebFig
(http://router-ip) is not subject to the SSH `address=` restriction.
Use System → Terminal (or the Quick Terminal icon) to inspect state or
temporarily re-open SSH:

```
/ip service set ssh address="" disabled=no
```

---

## Use full-path commands in import scripts

Context shorthand (`/ip firewall filter` then bare `add ...`) can be
unreliable in scripts — a prior error can reset the context silently.
Always use the full path on every line:

```
/ip firewall filter add chain=input action=accept src-address=10.0.1.0/24
```

---

## Script ordering summary

```
Section 1-5   Run while SSH is alive (factory IP 192.168.88.1 intact)
              Password, bridge ports, SSH service, firewall
Section 6     /ip address remove then add — SSH drops here
Sections 7+   Run server-side (DHCP client, NAT, DHCP server, DNS, WireGuard, NTP)
Last line     /ip firewall connection remove [find]
```

---

## Factory reset procedure (RB5009)

1. Hold the RESET button
2. Power off the router (unplug)
3. Power on (plug back in) while continuing to hold RESET
4. Keep holding until a light blinks — about 30 seconds
5. Release. Router boots to factory defaults (192.168.88.1, factory password on sticker)

Remember: SSH is locked until you complete the first WebFig login after a reset.

---

## Netgear RS700 AP mode (no dedicated toggle)

The RS700 does not have a one-click AP mode. Do it manually while still
connected to the RS700 as the active router:

1. Log into the RS700 web UI at its current LAN IP
2. LAN Setup → change LAN IP to **10.0.1.2** (or whatever is free on the new subnet)
3. LAN Setup → disable DHCP server
4. Save — router reboots to 10.0.1.2
5. Physical cutover: unplug ISP from RS700 WAN; connect ISP to RB5009 ether1;
   connect RS700 **LAN port** (not WAN) to RB5009 LAN port
6. RS700 is now a dumb AP, reachable at http://10.0.1.2

WiFi clients see no change — same SSID/password, same subnet, same gateway IP.

---

## FiOS WAN subnet

FiOS assigns addresses in **192.168.1.0/24** on ether1 (observed: 192.168.1.154/24,
gateway 192.168.1.1). Useful to know if you need to reach the ONT or diagnose
WAN-side issues.
