#!/usr/bin/env bash
# Publish KM Simics guest SSH onto a host NIC (LAN-reachable), multi-instance safe.
#
# This does **port publishing** (Simics connect-real-network-port-in), not an L2
# TAP bridge. Each concurrent Simics gets a unique host TCP port; remote users:
#   ssh -p <HOST_SSH_PORT> root@<HOST_LAN_IP>
#
# Usage (run *before* launching Simics; exports env for the sim process):
#   source ./scripts/host/km-simics-ssh-publish.sh --auto --firewall
#   source ./scripts/host/km-simics-ssh-publish.sh --instance 1 --iface eno3
#   ./scripts/host/km-simics-ssh-publish.sh --instance 2 --auto --print-only
#
# Then:
#   ./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE
# Guest: setup-simics-eth.sh   # 10.10.0.100 on eth0 (DT gmac1)
#
# Options:
#   --instance N     SIMICS_INSTANCE (default 0) → HOST_SSH_PORT=4022+100*N
#                    TELNET_PORT=9123+N; guest IP stays 10.10.0.100
#   --iface IFACE    Host NIC whose IPv4 is used for HOST_BIND_IP
#   --auto           Pick iface from IPv4 default route (sets --iface)
#   --host-port P    Override HOST_SSH_PORT
#   --guest-ip IP    Override GUEST_ETH_IP (default 10.10.0.100; rarely needed)
#   --bind-ip IP     HOST_BIND_IP (default: IPv4 of --iface/--auto, else 0.0.0.0)
#   --firewall       Open HOST_SSH_PORT/tcp in firewalld|ufw|iptables (needs root)
#   --print-only     Only print/export vars; do not touch firewall
#   --help
#
# See also: docs/KM-SIMICS-ETH.md
set -euo pipefail

INSTANCE="${SIMICS_INSTANCE:-0}"
IFACE="${HOST_IFACE:-}"
HOST_SSH_PORT="${HOST_SSH_PORT:-}"
GUEST_ETH_IP="${GUEST_ETH_IP:-}"
HOST_BIND_IP="${HOST_BIND_IP:-}"
DO_FW=0
PRINT_ONLY=0
AUTO_IFACE=0

usage() { sed -n '2,36p' "$0" | sed 's/^# \?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --auto) AUTO_IFACE=1; shift ;;
    --host-port) HOST_SSH_PORT="$2"; shift 2 ;;
    --guest-ip) GUEST_ETH_IP="$2"; shift 2 ;;
    --bind-ip) HOST_BIND_IP="$2"; shift 2 ;;
    --firewall) DO_FW=1; shift ;;
    --print-only) PRINT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Defaults from instance id
if [[ -z "$HOST_SSH_PORT" ]]; then
  HOST_SSH_PORT=$((4022 + 100 * INSTANCE))
fi
if [[ -z "$GUEST_ETH_IP" ]]; then
  # Same on every instance: each Simics has its own private service-node LAN.
  GUEST_ETH_IP="10.10.0.100"
fi

iface_ipv4() {
  local ifc="$1"
  ip -4 -o addr show dev "$ifc" 2>/dev/null \
    | awk '{print $4}' | head -1 | cut -d/ -f1
}

default_route_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

if [[ "$AUTO_IFACE" -eq 1 && -z "$IFACE" ]]; then
  IFACE="$(default_route_iface || true)"
  if [[ -z "$IFACE" ]]; then
    echo "WARN: --auto could not find default-route iface" >&2
  else
    echo "AUTO: using default-route iface $IFACE"
  fi
fi

if [[ -z "$HOST_BIND_IP" ]]; then
  if [[ -n "$IFACE" ]]; then
    HOST_BIND_IP="$(iface_ipv4 "$IFACE" || true)"
    if [[ -z "$HOST_BIND_IP" ]]; then
      echo "WARN: no IPv4 on $IFACE — binding 0.0.0.0" >&2
      HOST_BIND_IP="0.0.0.0"
    fi
  else
    HOST_BIND_IP="0.0.0.0"
  fi
fi

# When binding all addresses, still advertise a useful LAN IP for remotes
HOST_LAN_HINT="$HOST_BIND_IP"
if [[ "$HOST_BIND_IP" == "0.0.0.0" || "$HOST_BIND_IP" == "" ]]; then
  _di="$(default_route_iface || true)"
  if [[ -n "$_di" ]]; then
    HOST_LAN_HINT="$(iface_ipv4 "$_di" || true)"
  fi
  [[ -z "$HOST_LAN_HINT" ]] && HOST_LAN_HINT="<this-host-LAN-IP>"
fi

TELNET_PORT="${TELNET_PORT:-$((9123 + INSTANCE))}"

export SIMICS_INSTANCE="$INSTANCE"
export GUEST_ETH_IP
export HOST_SSH_PORT
export HOST_BIND_IP
export HOST_IFACE="${IFACE}"
export HOST_LAN_HINT
export TELNET_PORT

echo "=== KM Simics SSH publish ==="
echo "SIMICS_INSTANCE=$SIMICS_INSTANCE"
echo "GUEST_ETH_IP=$GUEST_ETH_IP          # guest: setup-simics-eth.sh (eth0 ← gmac1)"
echo "HOST_SSH_PORT=$HOST_SSH_PORT        # Simics port-in → guest :22"
echo "HOST_BIND_IP=$HOST_BIND_IP"
echo "TELNET_PORT=$TELNET_PORT            # UART telnet"
[[ -n "$IFACE" ]] && echo "HOST_IFACE=$IFACE"
echo
echo "Remote (or same host):"
echo "  ssh -p $HOST_SSH_PORT root@$HOST_LAN_HINT"
echo "Local loopback:"
echo "  ssh -p $HOST_SSH_PORT root@127.0.0.1"
echo "Local UART:  telnet 127.0.0.1 $TELNET_PORT"
echo
echo "Launch example:"
echo "  source ./scripts/host/km-simics-ssh-publish.sh --instance $INSTANCE --auto --firewall"
echo "  ./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE"
echo "Track live runs: ./scripts/host/km-simics-instances.sh status"
echo "Docs: docs/KM-SIMICS-ETH.md"

open_firewall() {
  local port="$1"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --add-port="${port}/tcp" || true
    echo "firewalld: opened ${port}/tcp (runtime)"
  elif command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -qi active; then
    sudo ufw allow "${port}/tcp" || true
    echo "ufw: allowed ${port}/tcp"
  else
    sudo iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
      || sudo iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    echo "iptables: ACCEPT tcp dport $port"
  fi
}

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  # When executed (not sourced), exit; when sourced, fall through to return
  return 0 2>/dev/null || exit 0
fi

if [[ "$DO_FW" -eq 1 ]]; then
  if [[ "$(id -u)" -ne 0 ]] && ! command -v sudo >/dev/null; then
    echo "ERROR: --firewall needs root/sudo" >&2
    exit 1
  fi
  open_firewall "$HOST_SSH_PORT"
fi

# When sourced, leave exports in the caller shell
return 0 2>/dev/null || exit 0
