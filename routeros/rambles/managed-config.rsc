# Rambles RB5009 Managed Configuration — safe to reapply to an already-live router
# Apply via: routeros/apply-config.py, or ansible-playbook routeros.yml
#
# This is the ongoing-managed subset of Rambles' router config: firewall
# rules, DHCP server + leases, DNS statics, WireGuard, NTP, SNMP, syslog.
# Split out from initial-config.rsc 2026-07-17 after a full-file reapply
# of that file (for an unrelated one-line DNS change) tore down this
# site's live WireGuard tunnel — initial-config.rsc mixes one-time
# bring-up steps (LAN IP, WAN client) that are actively dangerous to
# rerun against a live router with ongoing-managed steps that (mostly)
# aren't. See CLAUDE.md Gotchas for the full incident writeup.
#
# Known, accepted limitation: the firewall/DHCP-lease/DNS-static sections
# below still use RouterOS's remove-all-then-re-add-all pattern, so
# reapplying this file still causes a brief window with no filter rules /
# no DHCP reservations / no static DNS — same as it always has. Only the
# WireGuard section below is genuinely idempotent (skips entirely if
# wg-aws already exists). Making every section idempotent would mean
# hand-implementing api_modify-style attribute diffing in RouterOS
# script — out of scope for fixing the actual incident (WireGuard).
#
# For a single small change (e.g. one DNS record), don't reapply this
# whole file against a live router — SSH in and run just that one
# command, same as before.

# ---------------------------------------------------------------------------
# 1. Firewall — full-path /ip firewall filter add on every line (no context
#    shorthand). dynamic=no on remove: the filter table always has a
#    dynamic fasttrack counter rule that cannot be removed; remove [find]
#    aborts the batch. src-address for LAN/WireGuard: in-interface=bridge
#    misses TCP on the RB5009 hardware bridge; in-interface=wg-aws fails
#    before wg-aws exists.
# ---------------------------------------------------------------------------
/ip firewall raw    remove [find dynamic=no]
/ip firewall mangle remove [find dynamic=no]
/ip firewall filter remove [find dynamic=no]
/ip firewall filter add chain=input  action=accept connection-state=established,related comment=established
/ip firewall filter add chain=input  action=accept protocol=icmp                        comment=icmp
/ip firewall filter add chain=input  action=accept src-address=10.0.2.0/24             comment=lan
/ip firewall filter add chain=input  action=accept src-address=10.0.3.0/24             comment=wireguard
/ip firewall filter add chain=input  action=accept src-address=10.0.1.0/24             comment=cross-site-lan
/ip firewall filter add chain=input  action=drop                                        comment=drop-input
# forward chain trusts NYC's LAN too (10.0.1.0/24) -- without it, only
# router-to-router traffic (sourced from the WireGuard subnet) crosses sites;
# real LAN devices can't reach each other. See ADR-0001.
/ip firewall filter add chain=forward action=accept connection-state=established,related comment=established
/ip firewall filter add chain=forward action=accept src-address=10.0.2.0/24            comment=lan-fwd
/ip firewall filter add chain=forward action=accept src-address=10.0.3.0/24            comment=wg-fwd
/ip firewall filter add chain=forward action=accept src-address=10.0.1.0/24            comment=nyc-lan-fwd
/ip firewall filter add chain=forward action=drop                                       comment=drop-forward

# ---------------------------------------------------------------------------
# 2. DHCP server
# ---------------------------------------------------------------------------
/ip dhcp-server remove [find interface=bridge]
/ip pool remove [find name=defconf]
/ip pool remove [find name=pool-lan]
/ip pool add name=pool-lan ranges=10.0.2.64-10.0.2.254
/ip dhcp-server add name=dhcp-lan interface=bridge address-pool=pool-lan disabled=no
/ip dhcp-server network remove [find]
/ip dhcp-server network add address=10.0.2.0/24 gateway=10.0.2.1 dns-server=10.0.2.1

# ---------------------------------------------------------------------------
# 3. DHCP reservations — add Rambles devices here
# ---------------------------------------------------------------------------
/ip dhcp-server lease remove [find]
/ip dhcp-server lease add mac-address=30:52:53:07:DB:22 address=10.0.2.226 comment=kvm-nuc5
/ip dhcp-server lease add mac-address=EC:B5:FA:0F:85:97 address=10.0.2.244 comment=hue-rambles

# ---------------------------------------------------------------------------
# 4. DNS — static entries for known hosts at both sites (ADR-0009: router
#     DNS resolver is authoritative for internal names, not Route53 — LAN
#     clients get this router as their DNS server via DHCP, so that's what
#     actually needs to answer for these names). Mirrored on both routers'
#     configs so a hostname resolves regardless of which site you're on.
#     Source data: docs/network-inventory.md.
# ---------------------------------------------------------------------------
/ip dns set servers=1.1.1.1,8.8.8.8 allow-remote-requests=yes
/ip dns static remove [find]
/ip dns static add name=rt-nyc.nyc.billandjessie.com address=10.0.1.1
/ip dns static add name=printer.nyc.billandjessie.com address=10.0.1.5
/ip dns static add name=nas2.nyc.billandjessie.com address=10.0.1.7
/ip dns static add name=sw-main.nyc.billandjessie.com address=10.0.1.10
/ip dns static add name=sw-desk.nyc.billandjessie.com address=10.0.1.11
/ip dns static add name=sw-10g.nyc.billandjessie.com address=10.0.1.12
/ip dns static add name=p7670.nyc.billandjessie.com address=10.0.1.40
/ip dns static add name=furry.nyc.billandjessie.com address=10.0.1.41
/ip dns static add name=nuc4.nyc.billandjessie.com address=10.0.1.34
/ip dns static add name=rt-rambles.rambles.billandjessie.com address=10.0.2.1
/ip dns static add name=kvm-nuc5.rambles.billandjessie.com address=10.0.2.226
/ip dns static add name=nuc5.rambles.billandjessie.com address=10.0.2.10
/ip dns static add name=hue-nyc.nyc.billandjessie.com address=10.0.1.71
/ip dns static add name=hue-rambles.rambles.billandjessie.com address=10.0.2.244
/ip dns static add name=kvm-nyc.nyc.billandjessie.com address=10.0.1.66
/ip dns static add name=hub.billandjessie.com address=10.0.3.1

# ---------------------------------------------------------------------------
# 5. WireGuard — spoke to AWS hub (10.0.3.1); this site = 10.0.3.3
#     Private key stored in SSM: /home-platform/wireguard/rambles-private-key
#     Pass --wg-key-ssm /home-platform/wireguard/rambles-private-key to
#     apply-config.py to substitute WG_PRIVATE_KEY_PLACEHOLDER.
#
#     IDEMPOTENT as of 2026-07-17: only creates wg-aws if it does not
#     already exist. Reapplying this file against an already-configured
#     router is a safe no-op for this section — it will NOT touch a live
#     tunnel's interface, address, peer, or routes, even with
#     WG_PRIVATE_KEY_PLACEHOLDER still present (harmless in that branch:
#     the block referencing it is skipped entirely by the :if before ever
#     reaching that line). See the 2026-07-17 incident in CLAUDE.md Gotchas
#     -- this is the exact section that caused it.
#
#     This does NOT detect or fix partial/drifted state (e.g. interface
#     exists but a route is missing, or the peer's endpoint changed). If
#     WireGuard config genuinely needs to change, SSH in and run the
#     specific command by hand (see routeros/NOTES.md "Rotating a
#     WireGuard key without locking yourself out"), then update this file
#     so Git matches reality for the next factory bring-up.
# ---------------------------------------------------------------------------
:if ([:len [/interface wireguard find name=wg-aws]] = 0) do={
    /interface wireguard add name=wg-aws listen-port=51820 private-key="WG_PRIVATE_KEY_PLACEHOLDER"
    /ip address add address=10.0.3.3/24 interface=wg-aws
    /interface wireguard peers add interface=wg-aws public-key="22pH7f4JclotgwuM0sy5W85gLzym5ocobJOVlWzHy3U=" endpoint-address=3.82.89.106 endpoint-port=51820 allowed-address=10.0.3.0/24,10.0.1.0/24 persistent-keepalive=25
    /ip route add dst-address=10.0.3.0/24 gateway=wg-aws
    /ip route add dst-address=10.0.1.0/24 gateway=wg-aws
} else={
    :log warning "wg-aws already exists -- skipping WireGuard section (idempotent reapply)."
}

# ---------------------------------------------------------------------------
# 6. NTP — remove-then-add: /system ntp client servers add errors with
#    "duplicate address" on reapply otherwise (found 2026-07-17 testing
#    the first reapply of this file against a live router).
# ---------------------------------------------------------------------------
/system ntp client set enabled=yes
/system ntp client servers remove [find]
/system ntp client servers add address=time.cloudflare.com

# ---------------------------------------------------------------------------
# 7. SNMP — read-only, for snmp_exporter on the AWS hub (Milestone 3).
#     Community is "public" (matches snmp_exporter's if_mib module default,
#     avoiding a hand-patched 34k-line generated MIB config for one string).
#     Real security boundary is the firewall: section 1's default-deny INPUT
#     policy already drops all WAN-sourced traffic, SNMP included. The
#     addresses= restriction below is defense in depth on top of that.
# ---------------------------------------------------------------------------
/snmp set enabled=yes contact="" location=rambles trap-version=2
/snmp community set [find default=yes] name=public addresses=10.0.3.0/24

# ---------------------------------------------------------------------------
# 8. Remote syslog -- forwards to rsyslog on the AWS hub (Milestone 3).
#     One rule per topic, NOT one rule listing all four: RouterOS's topics=
#     list is AND semantics, not OR -- a single rule needs every listed
#     topic present simultaneously, which never happens (a message only
#     ever carries one severity topic). See CLAUDE.md Gotchas.
#
#     Remove-then-add (unlike the original file): /system logging action
#     add errors on a duplicate name and the topic rules have no unique
#     key, so without an explicit remove first, reapplying this file would
#     either fail outright (duplicate action name) or silently pile up
#     duplicate topic rules on every run. Fixed 2026-07-17 alongside the
#     WireGuard idempotency work, while making this file safe to reapply.
#
#     Order matters here: remove the logging RULES before the ACTION they
#     reference, not after. Doing it the other way round (tried first,
#     2026-07-17) let `/system logging remove [find action=remotehub]`
#     silently match nothing once the "remotehub" action it's filtering on
#     no longer existed to resolve against -- the rules piled up as
#     duplicates on every reapply instead of being replaced. Caught via a
#     real reapply against this router during testing, not a review.
#
#     KNOWN BROKEN as of 2026-07-04 on RouterOS 7.19.6: packets never
#     leave this router at all, confirmed via tcpdump on the receiving
#     end AND RouterOS's own /tool sniffer here -- yet the firewall's
#     output chain counts them as sent. Left configured since it's
#     harmless and may start working after a RouterOS upgrade. Needs
#     MikroTik-specific research to actually fix.
# ---------------------------------------------------------------------------
/system logging remove [find action=remotehub]
/system logging action remove [find name=remotehub]
/system logging action add name=remotehub target=remote remote=10.0.3.1 remote-port=514
/system logging add topics=info action=remotehub
/system logging add topics=warning action=remotehub
/system logging add topics=error action=remotehub
/system logging add topics=critical action=remotehub

# ---------------------------------------------------------------------------
# 9. Flush connection tracking — at the very end so no in-flight sessions
#    are disrupted.
# ---------------------------------------------------------------------------
/ip firewall connection remove [find]

# ---------------------------------------------------------------------------
# Done. Verify with:
#   /interface wireguard print
#   /interface wireguard peers print
#   /ip firewall filter print
#   /ip dhcp-server lease print
#   /ip dns static print
# ---------------------------------------------------------------------------
