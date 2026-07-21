#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-multipost-video-stt-worker-production}"
RATE="${RATE:-4096kbit}"
BURST="${BURST:-64kbit}"
LATENCY="${LATENCY:-400ms}"
INGRESS_BURST="${INGRESS_BURST:-64k}"

get_network_name() {
  docker inspect "$CONTAINER_NAME" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}'
}

get_host_if() {
  local network_name bridge_name brif_dir host_if
  network_name=$(get_network_name)
  if [ -z "$network_name" ]; then
    echo "Failed to resolve Docker network for ${CONTAINER_NAME}" >&2
    exit 1
  fi

  bridge_name=$(docker network inspect "$network_name" --format '{{index .Options "com.docker.network.bridge.name"}}')
  if [ -z "$bridge_name" ] || [ "$bridge_name" = "<no value>" ]; then
    bridge_name="br-$(docker network inspect "$network_name" --format '{{.Id}}' | cut -c1-12)"
  fi

  brif_dir="/sys/class/net/${bridge_name}/brif"
  if [ ! -d "$brif_dir" ]; then
    echo "Bridge interface directory not found: ${brif_dir}" >&2
    exit 1
  fi

  host_if=$(ls "$brif_dir" | head -1)
  if [ -z "$host_if" ]; then
    echo "Failed to resolve host veth from ${brif_dir}" >&2
    exit 1
  fi

  printf "%s" "$host_if"
}

host_if=$(get_host_if)

tc qdisc replace dev "$host_if" root tbf rate "$RATE" burst "$BURST" latency "$LATENCY"
tc qdisc replace dev "$host_if" handle ffff: ingress
tc filter replace dev "$host_if" parent ffff: protocol all prio 1 u32 match u32 0 0 police rate "$RATE" burst "$INGRESS_BURST" drop flowid :1

echo "Applied bandwidth limit to ${CONTAINER_NAME}"
echo "  upload:   ${RATE}"
echo "  download: ${RATE}"
echo "  host_if:  ${host_if}"
