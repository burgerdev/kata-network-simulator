#!/bin/bash
set -x
set -euo pipefail

while [[ -z "$(ip route)" ]]; do
  printf "%s Waiting for network configuration\n" "$(date)"
  sleep 1
done

# Network namespace 'vm' simulates the Kata VM.
ip netns add vm

# tap0 simulates the tap device used by the hypervisor.
ip link add tap0 type veth peer name veth0
ip link set veth0 netns vm
ip -n vm link set dev veth0 name eth0

# Save default route
defaultRoute=$(ip route show default | head -n1)

# Copy address configuration from host to guest.
ip -n vm addr add dev lo 127.0.0.1/8
ip -n vm addr add dev lo ::1/128

for addr in $(ip -j addr show eth0 | jq -r '.[] | .addr_info[] | "\(.local)/\(.prefixlen)"'); do
  ip -n vm addr add dev eth0 $addr
  ip addr del dev eth0 $addr
done
ip -n vm link set dev eth0 address $(ip -j link show eth0 | jq -r '.[0].address')

# Set the link pair up, otherwise routes won't work.
ip -n vm link set lo up
ip -n vm link set eth0 up
ip link set tap0 up

# Copy the default route (should be enough for the demo).
ip -n vm route add $defaultRoute

# Set up tc redirection.
tc qdisc add dev eth0 ingress
tc filter add dev eth0 ingress matchall \
    action mirred egress redirect dev tap0
tc qdisc add dev tap0 ingress
tc filter add dev tap0 ingress matchall \
    action mirred egress redirect dev eth0

ip addr show eth0

pushd "$(dirname "${BASH_SOURCE[0]}")"
ip netns exec python3 -m http.server 8080 &

touch /tmp/ready
wait
# bash -i
# tcpdump -ni any
