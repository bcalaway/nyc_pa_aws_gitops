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
/system identity set name=rambles-rb5009

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
/ip service set winbox  disabled=no
/ip service set www     disabled=no
/ip service set www-ssl disabled=no

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
/ip firewall filter add chain=forward action=accept connection-state=established,related comment=established
/ip firewall filter add chain=forward action=accept src-address=10.0.2.0/24            comment=lan-fwd
/ip firewall filter add chain=forward action=accept src-address=10.0.3.0/24            comment=wg-fwd
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
# /ip dhcp-server lease add mac-address=XX:XX:XX:XX:XX:XX address=10.0.2.X comment=device-name

# ---------------------------------------------------------------------------
# 11. DNS
# ---------------------------------------------------------------------------
/ip dns set servers=1.1.1.1,8.8.8.8 allow-remote-requests=yes

# ---------------------------------------------------------------------------
# 12. WireGuard — spoke to AWS hub (10.0.3.1); this site = 10.0.3.3
# ---------------------------------------------------------------------------
/interface wireguard peers remove [find interface=wg-aws]
/ip address remove [find interface=wg-aws]
/interface wireguard remove [find name=wg-aws]
/interface wireguard add name=wg-aws listen-port=51820 private-key="2D8Z2EbiNUchN4/xX/ZtGbPQByj8SlmIZ0n49XPmf04="
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
# 14. Flush connection tracking — at the very end so no in-flight sessions
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
