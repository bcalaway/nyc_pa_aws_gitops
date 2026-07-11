# sw-10g (MikroTik CRS309-1G-8S+, 10.0.1.12) — service hardening only.
#
# This is NOT a full device config (unlike routeros/nyc/initial-config.rsc
# for the router) -- sw-10g's bridge/port config isn't tracked in Git yet,
# just this security-relevant slice. Apply via SSH:
#   ssh <user>@10.0.1.12   (from NYC LAN, or via the EC2 hub jump host)
#   then paste the commands below, or run them non-interactively.
#
# Context: security review found telnet/ftp/api/api-ssl all enabled with
# no source-address restriction, and unlike the RB5009 routers, this
# switch has no firewall of its own -- so /ip service address= is the
# only layer of defense here, not defense-in-depth on top of a firewall.
# Applied 2026-07-11.

# Telnet and FTP send credentials in plaintext and were never used by
# this project (SSH only) -- disable outright.
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes

# RouterOS API not used by this project (SSH only) -- disable outright.
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes

# SSH, Winbox, and the web UI restricted to NYC LAN + WireGuard subnet --
# same scope the routers themselves use for SSH (see initial-config.rsc),
# not the broader cross-site LAN trust that only applies to the routers'
# forward chain for general traffic.
/ip service set ssh address=10.0.1.0/24,10.0.3.0/24 disabled=no
/ip service set winbox address=10.0.1.0/24,10.0.3.0/24 disabled=no
/ip service set www address=10.0.1.0/24,10.0.3.0/24 disabled=no

# Already disabled (no certificate configured) -- set explicitly so this
# script is idempotent regardless of starting state.
/ip service set www-ssl disabled=yes
