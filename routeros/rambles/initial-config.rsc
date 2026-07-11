# Rambles RB5009 Initial Configuration
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
#   - DHCP server: 10.0.2.64-254
#   - WAN1 = ether1 (ISP, DHCP)
#   - WireGuard spoke to AWS hub (10.0.3.1), this site = 10.0.3.3
#   - Routing to NYC (10.0.1.0/24) and WireGuard network (10.0.3.0/24)
#   - DNS forwarding to 1.1.1.1/8.8.8.8
#   - Firewall: allow established/related, allow ICMP, allow LAN/WireGuard, drop rest
#   - SSH enabled on LAN + WireGuard only
#   - Admin password set
#
# IMPORTANT — script ordering:
#   Sections 1-5 run while SSH is still alive (factory IP 192.168.88.1 intact).
#   Section 6 removes the factory LAN IP — SSH dies here.
#   Sections 7-13 run server-side without SSH (RouterOS continues /import after SSH drop).
#   Section 14 flushes connection tracking at the very end, after all rules are in place.

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
/ip service set winbox  address=10.0.2.0/24,10.0.3.0/24 disabled=no
/ip service set www     address=10.0.2.0/24,10.0.3.0/24 disabled=no
/ip service set www-ssl address=10.0.2.0/24,10.0.3.0/24 disabled=no

# ---------------------------------------------------------------------------
# 5. Firewall — applied BEFORE the IP change so rules are in place when
#    the factory IP is removed and the new one takes over.
#    Full-path /ip firewall filter add on every line (no context shorthand).
#    dynamic=no on remove: the filter table always has a dynamic fasttrack
#    counter rule that cannot be removed; remove [find] aborts the batch.
#    src-address for LAN/WireGuard: in-interface=bridge misses TCP on the
#    RB5009 hardware bridge; in-interface=wg-aws fails before wg-aws exists.
# ---------------------------------------------------------------------------
/ip firewall raw    remove [find dynamic=no]
/ip firewall mangle remove [find dynamic=no]
/ip firewall filter remove [find dynamic=no]
/ip firewall filter add chain=input  action=accept connection-state=established,related comment=established
/ip firewall filter add chain=input  action=accept protocol=icmp                        comment=icmp
/ip firewall filter add chain=input  action=accept src-address=10.0.2.0/24             comment=lan
/ip firewall filter add chain=input  action=accept src-address=10.0.3.0/24             comment=wireguard
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
# 6. LAN IP — removes factory 192.168.88.1; SSH drops here.
#    /import continues running server-side after SSH disconnects.
# ---------------------------------------------------------------------------
/ip address remove [find interface=bridge]
/ip address add address=10.0.2.1/24 interface=bridge

# ---------------------------------------------------------------------------
# 7. WAN1 — ISP DHCP on ether1
# ---------------------------------------------------------------------------
/ip dhcp-client remove [find interface=ether1]
/ip dhcp-client add interface=ether1 disabled=no add-default-route=yes use-peer-dns=no

# ---------------------------------------------------------------------------
# 8. NAT
# ---------------------------------------------------------------------------
/ip firewall nat remove [find chain=srcnat out-interface=ether1]
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade

# ---------------------------------------------------------------------------
# 9. DHCP server
# ---------------------------------------------------------------------------
/ip dhcp-server remove [find interface=bridge]
/ip pool remove [find name=defconf]
/ip pool remove [find name=pool-lan]
/ip pool add name=pool-lan ranges=10.0.2.64-10.0.2.254
/ip dhcp-server add name=dhcp-lan interface=bridge address-pool=pool-lan disabled=no
/ip dhcp-server network remove [find]
/ip dhcp-server network add address=10.0.2.0/24 gateway=10.0.2.1 dns-server=10.0.2.1

# ---------------------------------------------------------------------------
# 10. DHCP reservations — add Rambles devices here
# ---------------------------------------------------------------------------
/ip dhcp-server lease remove [find]
/ip dhcp-server lease add mac-address=30:52:53:07:DB:22 address=10.0.2.226 comment=kvm-nuc5
/ip dhcp-server lease add mac-address=EC:B5:FA:0F:85:97 address=10.0.2.244 comment=hue-rambles

# ---------------------------------------------------------------------------
# 11. DNS — static entries for known hosts at both sites (ADR-0009: router
#     DNS resolver is authoritative for internal names, not Route53 — LAN
#     clients get this router as their DNS server via DHCP, so that's what
#     actually needs to answer for these names). Mirrored on both routers'
#     configs so a hostname resolves regardless of which site you're on.
#     Source data: docs/network-inventory.md.
# ---------------------------------------------------------------------------
/ip dns set servers=1.1.1.1,8.8.8.8 allow-remote-requests=yes
/ip dns static remove [find]
/ip dns static add name=router.nyc.billandjessie.com address=10.0.1.1
/ip dns static add name=printer.nyc.billandjessie.com address=10.0.1.5
/ip dns static add name=nas2.nyc.billandjessie.com address=10.0.1.7
/ip dns static add name=sw-main.nyc.billandjessie.com address=10.0.1.10
/ip dns static add name=sw-desk.nyc.billandjessie.com address=10.0.1.11
/ip dns static add name=sw-10g.nyc.billandjessie.com address=10.0.1.12
/ip dns static add name=p7670.nyc.billandjessie.com address=10.0.1.40
/ip dns static add name=furry.nyc.billandjessie.com address=10.0.1.41
/ip dns static add name=nuc4.nyc.billandjessie.com address=10.0.1.34
/ip dns static add name=router.rambles.billandjessie.com address=10.0.2.1
/ip dns static add name=kvm-nuc5.rambles.billandjessie.com address=10.0.2.226
/ip dns static add name=nuc5.rambles.billandjessie.com address=10.0.2.10
/ip dns static add name=hue-nyc.nyc.billandjessie.com address=10.0.1.71
/ip dns static add name=hue-rambles.rambles.billandjessie.com address=10.0.2.244

# ---------------------------------------------------------------------------
# 12. WireGuard — spoke to AWS hub (10.0.3.1); this site = 10.0.3.3
#     Private key stored in SSM: /home-platform/wireguard/rambles-private-key
#     Substitute WG_PRIVATE_KEY_PLACEHOLDER manually before applying -- this
#     is separate from apply-config.py's PLACEHOLDER (admin password) sub.
# ---------------------------------------------------------------------------
/interface wireguard peers remove [find interface=wg-aws]
/ip address remove [find interface=wg-aws]
/interface wireguard remove [find name=wg-aws]
/interface wireguard add name=wg-aws listen-port=51820 private-key="WG_PRIVATE_KEY_PLACEHOLDER"
/ip address add address=10.0.3.3/24 interface=wg-aws
/interface wireguard peers add interface=wg-aws public-key="22pH7f4JclotgwuM0sy5W85gLzym5ocobJOVlWzHy3U=" endpoint-address=3.82.89.106 endpoint-port=51820 allowed-address=10.0.3.0/24,10.0.1.0/24 persistent-keepalive=25
/ip route add dst-address=10.0.3.0/24 gateway=wg-aws
/ip route add dst-address=10.0.1.0/24 gateway=wg-aws

# ---------------------------------------------------------------------------
# 13. NTP
# ---------------------------------------------------------------------------
/system ntp client set enabled=yes
/system ntp client servers add address=time.cloudflare.com

# ---------------------------------------------------------------------------
# 14. SNMP — read-only, for snmp_exporter on the AWS hub (Milestone 3).
#     Community is "public" (matches snmp_exporter's if_mib module default,
#     avoiding a hand-patched 34k-line generated MIB config for one string).
#     Real security boundary is the firewall: section 5's default-deny INPUT
#     policy already drops all WAN-sourced traffic, SNMP included. The
#     addresses= restriction below is defense in depth on top of that.
# ---------------------------------------------------------------------------
/snmp set enabled=yes contact="" location=rambles trap-version=2
/snmp community set [find default=yes] name=public addresses=10.0.3.0/24

# ---------------------------------------------------------------------------
# 15. Remote syslog -- forwards to rsyslog on the AWS hub (Milestone 3).
#     One rule per topic, NOT one rule listing all four: RouterOS's topics=
#     list is AND semantics, not OR -- a single rule needs every listed
#     topic present simultaneously, which never happens (a message only
#     ever carries one severity topic). See CLAUDE.md Gotchas.
#
#     KNOWN BROKEN as of 2026-07-04 on RouterOS 7.19.6: packets never
#     leave this router at all, confirmed via tcpdump on the receiving
#     end AND RouterOS's own /tool sniffer here -- yet the firewall's
#     output chain counts them as sent. Left configured since it's
#     harmless and may start working after a RouterOS upgrade. Needs
#     MikroTik-specific research to actually fix.
# ---------------------------------------------------------------------------
/system logging action add name=remotehub target=remote remote=10.0.3.1 remote-port=514
/system logging add topics=info action=remotehub
/system logging add topics=warning action=remotehub
/system logging add topics=error action=remotehub
/system logging add topics=critical action=remotehub

# ---------------------------------------------------------------------------
# 16. Flush connection tracking — at the very end so no in-flight sessions
#     are disrupted. Clears stale entries from the SSH session that dropped
#     when we changed the LAN IP in section 6.
# ---------------------------------------------------------------------------
/ip firewall connection remove [find]

# ---------------------------------------------------------------------------
# Done. Verify with:
#   /ip address print
#   /ip dhcp-client print
#   /interface wireguard print
#   /interface wireguard peers print
#   /ip firewall filter print
# ---------------------------------------------------------------------------
