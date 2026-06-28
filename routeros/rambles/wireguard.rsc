# WireGuard client config for Rambles RB5009
# WireGuard IP: 10.0.3.3
# Covers site subnet: 10.0.2.0/24
# Hub: 3.82.89.106:51820 (AWS EC2 Elastic IP)

/interface wireguard
add name=wg-aws listen-port=51820 private-key="2D8Z2EbiNUchN4/xX/ZtGbPQByj8SlmIZ0n49XPmf04="

/ip address
add address=10.0.3.3/24 interface=wg-aws

/interface wireguard peers
add interface=wg-aws \
    public-key="22pH7f4JclotgwuM0sy5W85gLzym5ocobJOVlWzHy3U=" \
    endpoint-address=3.82.89.106 \
    endpoint-port=51820 \
    allowed-address=10.0.3.0/24,10.0.1.0/24 \
    persistent-keepalive=25

/ip route
add dst-address=10.0.3.0/24 gateway=wg-aws
add dst-address=10.0.1.0/24 gateway=wg-aws
