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
# Invoked from boot-to-osbv-smp-*.simics after board create.

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


def _object_exists(name):
    try:
        simics.SIM_get_object(name)
        return True
    except Exception:  # pylint: disable=broad-except
        return False


def _find_ethernet_links():
    """Return ethernet-link names suitable for connect-real-network-port-in.

    Agilex/KM board scripts create ``ethernet_switch0`` with NAPT on
    ``ethernet_switch0.link``. Prefer that well-known path — object-iterator
    class matching often misses components during early @exec.
    """
    # port-in wants the switch component (ethernet_switch), not the .link child.
    known = [
        "ethernet_switch0",
        "ethernet_switch_cmp0",
        "ethernet_switch0.link",
        "ethernet_switch_cmp0.link",
    ]
    links = [n for n in known if _object_exists(n)]

    try:
        for obj in simics.SIM_object_iterator(None):
            try:
                cls = simics.SIM_get_class_name(obj)
            except Exception:  # pylint: disable=broad-except
                continue
            low = cls.lower().replace("-", "_")
            name = obj.name
            if name in links:
                continue
            if low in (
                "ethernet_link",
                "ethernet_switch",
                "ethernet_hub",
                "eth_switch_link",
            ) or ("ethernet" in low and ("link" in low or "switch" in low)):
                # Prefer .link child for switch components
                child = name + ".link"
                if _object_exists(child):
                    links.append(child)
                else:
                    links.append(name)
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: object iterator note: %s" % exc)

    # Prefer names that look like the board switch link
    def score(n):
        s = 0
        if n.endswith(".link"):
            s += 10
        if "ethernet_switch0" in n:
            s += 5
        if "eth0" in n.lower() or "hps" in n.lower():
            s += 1
        return -s

    links = sorted(set(links), key=score)
    return links


def _port_in(eth, host_port, ip, host_bind):
    cmd = (
        'connect-real-network-port-in "ssh" ethernet-link = %s '
        'host-port = %d target-ip = "%s" host-ip = "%s" -tcp -f'
        % (eth, host_port, ip, host_bind)
    )
    simics.SIM_run_command(cmd)
    print("ETH-fwd: port-in OK — ssh -p %d root@%s (link=%s)" % (host_port, host_bind, eth))


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

    # NAPT + default forwards (often also claims 4022 — fine for instance 0;
    # other instances still need an explicit port-in below).
    try:
        simics.SIM_run_command('connect-real-network target-ip = "%s"' % ip)
        print("ETH-fwd: connect-real-network OK")
    except Exception as exc:  # pylint: disable=broad-except
        print("ETH-fwd: connect-real-network note: %s" % exc)

    links = _find_ethernet_links()
    if not links:
        print(
            "ETH-fwd: WARN no ethernet-link found; trying port-in on ethernet_switch0.link"
        )
        links = ["ethernet_switch0.link"]

    last_err = None
    for eth in links:
        try:
            _port_in(eth, host_port, ip, host_bind)
            if host_bind in ("0.0.0.0", ""):
                print(
                    "ETH-fwd: bound all host addrs; use host LAN IP from other machines"
                )
            return True
        except Exception as exc:  # pylint: disable=broad-except
            last_err = exc
            print("ETH-fwd: port-in failed on %s: %s" % (eth, exc))

    print("ETH-fwd: connect-real-network-port-in FAILED: %s" % last_err)
    return False


km_simics_eth_host_fwd()
