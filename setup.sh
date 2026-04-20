#!/bin/bash
set -x
set -euo pipefail

touch /tmp/ready

# Wait for network to actually be configured.
until ip route show default | grep -q default; do
  printf "%s Waiting for network configuration\n" "$(date)"
  ip addr || true
  ip route || true
  sleep 1
done

ip route
ip route show default
ip -j addr show eth0 | jq

# Create "vm" network namespace.
unshare -n -- bash -c 'sleep infinity' &
vm_pid=$!

# Give it a moment to exist.
sleep 0.5

# tap0 simulates the tap device used by the hypervisor, veth0 will simulate the guest's main interface.
ip link add tap0 type veth peer name veth0
ip link set veth0 netns "$vm_pid"
nsenter -t "$vm_pid" -n ip link set dev veth0 name eth0

# Setting the route in the guest requires the IPs to be configured, but removing the IP on the host removes the route.
# Save it now and use it afterwards.
defaultRoute=$(ip route show default | head -n1)

# Configure loopback inside guest.
nsenter -t "$vm_pid" -n ip addr add 127.0.0.1/8 dev lo
nsenter -t "$vm_pid" -n ip addr add ::1/128 dev lo

# Copy IP addresses from host eth0 to namespace eth0.
for addr in $(ip -j addr show eth0 | jq -r '.[] | .addr_info[] | "\(.local)/\(.prefixlen)"'); do
  nsenter -t "$vm_pid" -n ip addr add dev eth0 "$addr"
done

# Copy MAC address.
mac=$(ip -j link show eth0 | jq -r '.[0].address')
nsenter -t "$vm_pid" -n ip link set dev eth0 address "$mac"

# Bring interfaces up.
nsenter -t "$vm_pid" -n ip link set lo up
nsenter -t "$vm_pid" -n ip link set eth0 up
ip link set tap0 up

# Add default route inside guest.
nsenter -t "$vm_pid" -n ip route add $defaultRoute

# Set up tc redirection (host side).
tc qdisc add dev eth0 ingress
tc filter add dev eth0 ingress matchall \
    action mirred egress redirect dev tap0

tc qdisc add dev tap0 ingress
tc filter add dev tap0 ingress matchall \
    action mirred egress redirect dev eth0

# Start HTTP server inside the namespace
nsenter -t "$vm_pid" -n python3 -m http.server 8080 &

touch /tmp/ready
wait
