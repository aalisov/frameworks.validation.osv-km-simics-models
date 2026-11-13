# Host-PC / LAN access to KM guest eth: real-time + inbound SSH port forward.
#
# Pair with guest: setup-simics-eth.sh  (default 10.10.0.100/24)
#
# Env (set by run-*.sh or host/km-simics-ssh-publish.sh):
#   GUEST_ETH_IP=10.10.0.100
#   HOST_SSH_PORT=4022          # unique per concurrent Simics instance
#   HOST_BIND_IP=0.0.0.0        # or LAN IP of the host NIC (e.g. 192.168.1.10)
#   SIMICS_INSTANCE=0           # optional; if set and HOST_SSH_PORT unset -> 4022+100*id
#
# Invoked from boot-to-osbv-smp-usb31-*.simics after board create.

import os
import simics


def _instance_default_ssh_port():
    inst = os.environ.get("SIMICS_INSTANCE", "").strip()
    if inst == "":
        return 4022
    try:
        return 4022 + 100 * int(inst)
    except ValueError:
        return 4022


def _find_ethernet_links():
    links = []
    try:
        for obj in simics.SIM_object_iterator(None):
            try:
                cls = simics.SIM_get_class_name(obj)
            except Exception:  # pylint: disable=broad-except
                continue
            low = cls.lower().replace("-", "_")
            if low in (
                "ethernet_link",
                "ethernet_switch",
                "ethernet_hub",
            ) or ("ethernet" in low and ("link" in low or "switch" in low)):
                links.append(obj.name)
    except Exception:  # pylint: disable=broad-except
        pass
    # Prefer objects whose name suggests the HPS eth0 path
    preferred = [n for n in links if "eth0" in n.lower() or "hps" in n.lower()]
    return preferred + [n for n in links if n not in preferred]


def km_simics_eth_host_fwd():
    ip = os.environ.get("GUEST_ETH_IP", "10.10.0.100")
    host_port = int(os.environ.get("HOST_SSH_PORT", str(_instance_default_ssh_port())))
    host_bind = os.environ.get("HOST_BIND_IP", "0.0.0.0")

    print(
        "ETH-fwd: guest=%s host_ssh_port=%d bind=%s (guest: setup-simics-eth.sh)"
        % (ip, host_port, host_bind)
    )

    try:
        simics.SIM_run_command("enable-real-time-mode")
        print("ETH-fwd: enable-real-time-mode OK")
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: enable-real-time-mode skipped: %s" % exc)

    # NAPT + default forwards (may also claim 4022)
    try:
        simics.SIM_run_command('connect-real-network target-ip = "%s"' % ip)
        print("ETH-fwd: connect-real-network OK")
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: connect-real-network note: %s" % exc)

    links = _find_ethernet_links()
    if not links:
        print(
            "ETH-fwd: WARN no ethernet-link found; relying on connect-real-network defaults"
        )
        print(
            "ETH-fwd: from LAN: ssh -p %d root@<host-ip>  (if 4022 was opened)"
            % host_port
        )
        return False

    eth = links[0]
    print("ETH-fwd: using ethernet-link %s" % eth)

    # Explicit SSH forward: configurable host port + bind address (multi-sim / LAN)
    cmd = (
        'connect-real-network-port-in "ssh" ethernet-link = %s '
        'host-port = %d target-ip = "%s" host-ip = "%s" -tcp -f'
        % (eth, host_port, ip, host_bind)
    )
    try:
        simics.SIM_run_command(cmd)
        print("ETH-fwd: port-in OK — ssh -p %d root@%s" % (host_port, host_bind))
        if host_bind in ("0.0.0.0", ""):
            print(
                "ETH-fwd: bound all host addrs; use host LAN IP from other machines"
            )
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: connect-real-network-port-in FAILED: %s" % exc)
        print("ETH-fwd: cmd was: %s" % cmd)
        return False

    # USBIP (guest usbipd / VUDC device mode) — host :USBIP_HOST_PORT → guest :3240
    usbip_host_port = int(os.environ.get("USBIP_HOST_PORT", "3240"))
    usbip_guest_port = int(os.environ.get("USBIP_GUEST_PORT", "3240"))
    # First arg is target-port|service (do NOT also pass target-port=).
    usbip_cmd = (
        "connect-real-network-port-in %d ethernet-link = %s "
        'host-port = %d target-ip = "%s" host-ip = "%s" -tcp -f'
        % (usbip_guest_port, eth, usbip_host_port, ip, host_bind)
    )
    try:
        simics.SIM_run_command(usbip_cmd)
        print(
            "ETH-fwd: usbip port-in OK — host :%d → guest %s:%d"
            % (usbip_host_port, ip, usbip_guest_port)
        )
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: usbip port-in FAILED: %s" % exc)
        print("ETH-fwd: cmd was: %s" % usbip_cmd)
        # SSH still works; do not fail the whole helper
    return True


km_simics_eth_host_fwd()
