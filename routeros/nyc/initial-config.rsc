# NYC RB5009 Initial Configuration
# Apply via: System > Terminal in the web UI (http://192.168.88.1)
# Run AFTER connecting laptop directly to RB5009, before going live
#
# First login: the default admin password is printed on the bottom of the
# router and in the box manual — it is NOT blank. Log in via WebFig at
# http://192.168.88.1 first (SSH/telnet are locked until you do), then
# change the password or proceed directly to the terminal.
#
# What this does:
#   - Sets LAN to 10.0.1.1/24 (matches existing Nighthawk, zero client disruption)
#   - Configures DHCP server with same range as Nighthawk (10.0.1.64-254)
#   - Preserves all DHCP reservations (minus z840 which is gone)
#   - WAN1 = ether1 (FiOS, DHCP)
#   - WireGuard tunnel to AWS hub
#   - DNS forwarding to 1.1.1.1/8.8.8.8
#   - Firewall: allow established/related, drop invalid, allow ICMP
#   - SSH enabled on LAN only
#   - Admin password set

# ---------------------------------------------------------------------------
# 1. Identity
# ---------------------------------------------------------------------------
/system identity set name=nyc-rb5009

# ---------------------------------------------------------------------------
# 2. Admin password
# ---------------------------------------------------------------------------
/user set admin password="5192alone!D0ct0rDre"

# ---------------------------------------------------------------------------
# 3. Interfaces — assign roles
#    ether1 = WAN1 (FiOS)
#    ether2 = WAN2 (GL.iNet backup, configured later in Milestone 7)
#    ether3-8, sfp-sfpplus1 = LAN (bridge)
# ---------------------------------------------------------------------------
# Remove any existing bridge port memberships and bridge-lan before (re)creating
/interface bridge port remove [find]
/interface bridge remove [find name=bridge-lan]
/interface bridge add name=bridge-lan

/interface bridge port
add bridge=bridge-lan interface=ether3
add bridge=bridge-lan interface=ether4
add bridge=bridge-lan interface=ether5
add bridge=bridge-lan interface=ether6
add bridge=bridge-lan interface=ether7
add bridge=bridge-lan interface=ether8
add bridge=bridge-lan interface=sfp-sfpplus1

# ---------------------------------------------------------------------------
# 4. LAN IP
# ---------------------------------------------------------------------------
/ip address remove [find address="10.0.1.1/24"]
/ip address add address=10.0.1.1/24 interface=bridge-lan

# ---------------------------------------------------------------------------
# 5. WAN1 — FiOS DHCP
# ---------------------------------------------------------------------------
/ip dhcp-client remove [find interface=ether1]
/ip dhcp-client add interface=ether1 disabled=no add-default-route=yes use-peer-dns=no

# ---------------------------------------------------------------------------
# 6. NAT
# ---------------------------------------------------------------------------
/ip firewall nat remove [find chain=srcnat out-interface=ether1]
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade

# ---------------------------------------------------------------------------
# 7. DHCP server (same range as Nighthawk: 10.0.1.64-254)
# ---------------------------------------------------------------------------
/ip pool remove [find name=pool-lan]
/ip pool add name=pool-lan ranges=10.0.1.64-10.0.1.254

/ip dhcp-server remove [find name=dhcp-lan]
/ip dhcp-server add name=dhcp-lan interface=bridge-lan address-pool=pool-lan disabled=no

/ip dhcp-server network add address=10.0.1.0/24 gateway=10.0.1.1 dns-server=10.0.1.1

# ---------------------------------------------------------------------------
# 8. DHCP reservations (z840 dropped — no longer exists)
# ---------------------------------------------------------------------------
/ip dhcp-server lease
add mac-address=7C:57:58:D0:17:5E address=10.0.1.41 comment=FURRY
add mac-address=98:59:7A:F2:10:B6 address=10.0.1.40 comment=p7670-laptop
add mac-address=38:FC:98:99:7E:5B address=10.0.1.34 comment=nuc4
add mac-address=2C:58:B9:AF:E5:8A address=10.0.1.5  comment=HP-M455DN

# ---------------------------------------------------------------------------
# 9. DNS
# ---------------------------------------------------------------------------
/ip dns set servers=1.1.1.1,8.8.8.8 allow-remote-requests=yes

# ---------------------------------------------------------------------------
# 10. WireGuard — tunnel to AWS hub (10.0.3.1)
# ---------------------------------------------------------------------------
/interface wireguard peers remove [find interface=wg-aws]
/ip address remove [find interface=wg-aws]
/interface wireguard remove [find name=wg-aws]
/interface wireguard add name=wg-aws listen-port=51820 \
    private-key="2KwOB22Jgzc6fKijCka95KTL5YsjWjuKYADlV4Mwd3c="

/ip address add address=10.0.3.2/24 interface=wg-aws

/interface wireguard peers add \
    interface=wg-aws \
    public-key="22pH7f4JclotgwuM0sy5W85gLzym5ocobJOVlWzHy3U=" \
    endpoint-address=3.82.89.106 \
    endpoint-port=51820 \
    allowed-address=10.0.3.0/24,10.0.2.0/24 \
    persistent-keepalive=25

/ip route add dst-address=10.0.3.0/24 gateway=wg-aws
/ip route add dst-address=10.0.2.0/24 gateway=wg-aws

# ---------------------------------------------------------------------------
# 11. Firewall
# ---------------------------------------------------------------------------
/ip firewall filter

# Input chain — traffic destined for the router itself
add chain=input action=accept connection-state=established,related comment="allow established/related"
add chain=input action=drop   connection-state=invalid               comment="drop invalid"
add chain=input action=accept protocol=icmp                          comment="allow ICMP"
add chain=input action=accept in-interface=bridge-lan                comment="allow LAN to router"
add chain=input action=accept in-interface=wg-aws                    comment="allow WireGuard to router"
add chain=input action=drop                                          comment="drop everything else"

# Forward chain — traffic passing through the router
add chain=forward action=accept connection-state=established,related comment="allow established/related"
add chain=forward action=drop   connection-state=invalid             comment="drop invalid"
add chain=forward action=accept in-interface=bridge-lan              comment="allow LAN out"
add chain=forward action=accept in-interface=wg-aws                  comment="allow WireGuard forward"
add chain=forward action=drop                                        comment="drop everything else"

# ---------------------------------------------------------------------------
# 12. SSH — enable, LAN + WireGuard only
# ---------------------------------------------------------------------------
/ip service set ssh address=10.0.1.0/24,10.0.3.0/24 disabled=no

# Disable services we don't need
/ip service set telnet  disabled=yes
/ip service set ftp     disabled=yes
/ip service set api     disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox  disabled=no
/ip service set www     disabled=no
/ip service set www-ssl disabled=no

# ---------------------------------------------------------------------------
# 13. NTP
# ---------------------------------------------------------------------------
/system ntp client set enabled=yes
/system ntp client servers add address=time.cloudflare.com

# ---------------------------------------------------------------------------
# Done. Verify with:
#   /ip address print
#   /ip dhcp-client print
#   /interface wireguard print
#   /interface wireguard peers print
# ---------------------------------------------------------------------------
