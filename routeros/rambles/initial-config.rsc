# Rambles RB5009 Initial Configuration — BRING-UP ONLY
# Apply via: System > Terminal in the web UI (http://192.168.88.1)
#
# First login: the default admin password is printed on the bottom of the
# router and in the box manual — it is NOT blank. Log in via WebFig at
# http://192.168.88.1 first (SSH/telnet are locked until you do), then
# change the password or proceed directly to the terminal.
#
# See routeros/NOTES.md for all the RouterOS 7 gotchas learned during
# the NYC bring-up. Read it before touching anything here.
#
# What this does:
#   - Sets LAN to 10.0.2.1/24
#   - WAN1 = ether1 (ISP, DHCP)
#   - SSH enabled on LAN + WireGuard only
#   - Admin password set
#
# This is ONE-TIME FACTORY BRING-UP ONLY (split out 2026-07-17 — see
# CLAUDE.md Gotchas for why). It does NOT configure firewall rules, DHCP
# leases, DNS, WireGuard, NTP, SNMP, or syslog — those live in
# routeros/rambles/managed-config.rsc, which is safe to reapply to an
# already-live router (this file is NOT: it removes the factory LAN IP,
# which would remove a live router's real IP too).
#
# After running this file against a factory-default router, apply
# routeros/rambles/managed-config.rsc immediately afterward (same
# apply-config.py tool, second call) to reach the fully-configured state.
# There is a brief window between the two calls where the router has its
# real LAN IP, NAT, and a WAN address but no firewall filter rules, DHCP
# service, DNS, or WireGuard yet — accepted as fine for a supervised,
# one-time bring-up on hardware you have physical access to; this file
# doesn't try to close that window.
#
# IMPORTANT — script ordering:
#   Sections 1-4 run while SSH is still alive (factory IP 192.168.88.1 intact).
#   Section 5 removes the factory LAN IP — SSH dies here.
#   Sections 6-7 run server-side without SSH (RouterOS continues /import after SSH drop).

# ---------------------------------------------------------------------------
# 1. Identity
# ---------------------------------------------------------------------------
/system identity set name=rt-rambles

# ---------------------------------------------------------------------------
# 2. Admin password
# ---------------------------------------------------------------------------
# Password stored in SSM: /home-platform/router/rambles-admin-password
# apply-config.py fetches it automatically when called with --ssm
/user set admin password="PLACEHOLDER"

# ---------------------------------------------------------------------------
# 3. Bridge — keep factory bridge named "bridge"; just remove WAN ports
#    ether1 = WAN1 (ISP)    — remove from bridge if present
#    ether2 = WAN2 (future) — remove from bridge if present
#    ether3-8, sfp = LAN    — already in factory bridge, leave them there
# ---------------------------------------------------------------------------
/interface bridge port remove [find interface=ether1]
/interface bridge port remove [find interface=ether2]

# ---------------------------------------------------------------------------
# 4. SSH service — restrict to LAN + WireGuard, enable web UI
#    Done here while SSH is alive so the restriction takes effect cleanly.
# ---------------------------------------------------------------------------
/ip service set ssh     address=10.0.2.0/24,10.0.3.0/24 disabled=no
/ip service set telnet  disabled=yes
/ip service set ftp     disabled=yes
/ip service set api     disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox  address=10.0.1.0/24,10.0.2.0/24,10.0.3.0/24 disabled=no
/ip service set www     address=10.0.1.0/24,10.0.2.0/24,10.0.3.0/24 disabled=no
/ip service set www-ssl address=10.0.1.0/24,10.0.2.0/24,10.0.3.0/24 disabled=no

# ---------------------------------------------------------------------------
# 5. LAN IP — removes factory 192.168.88.1; SSH drops here.
#    /import continues running server-side after SSH disconnects.
# ---------------------------------------------------------------------------
/ip address remove [find interface=bridge]
/ip address add address=10.0.2.1/24 interface=bridge

# ---------------------------------------------------------------------------
# 6. WAN1 — ISP DHCP on ether1
# ---------------------------------------------------------------------------
/ip dhcp-client remove [find interface=ether1]
/ip dhcp-client add interface=ether1 disabled=no add-default-route=yes use-peer-dns=no

# ---------------------------------------------------------------------------
# 7. NAT
# ---------------------------------------------------------------------------
/ip firewall nat remove [find chain=srcnat out-interface=ether1]
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade

# ---------------------------------------------------------------------------
# Done with bring-up. Next: apply routeros/rambles/managed-config.rsc.
# Verify with:
#   /ip address print
#   /ip dhcp-client print
# ---------------------------------------------------------------------------
