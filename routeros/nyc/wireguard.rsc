# WireGuard client config for NYC RB5009
# WireGuard IP: 10.0.3.2
# Covers site subnet: 10.0.1.0/24
# Hub: 3.82.89.106:51820 (AWS EC2 Elastic IP)

/interface wireguard
add name=wg-aws listen-port=51820 private-key="2KwOB22Jgzc6fKijCka95KTL5YsjWjuKYADlV4Mwd3c="

/ip address
add address=10.0.3.2/24 interface=wg-aws

/interface wireguard peers
add interface=wg-aws \
    public-key="22pH7f4JclotgwuM0sy5W85gLzym5ocobJOVlWzHy3U=" \
    endpoint-address=3.82.89.106 \
    endpoint-port=51820 \
    allowed-address=10.0.3.0/24,10.0.2.0/24 \
    persistent-keepalive=25

/ip route
add dst-address=10.0.3.0/24 gateway=wg-aws
add dst-address=10.0.2.0/24 gateway=wg-aws
