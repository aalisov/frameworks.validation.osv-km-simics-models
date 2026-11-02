# Variant S: attach a Simics USBIP bridge to KM usb31 *device* (xDCI).
#
# Architecture (see docs/KM-SIMICS-USBIP.md):
#   guest UDC/gadget  <->  km_hps_usb31_device  <->  USBIP bridge  <->  TCP :3240
#                                                              <->  host vhci + usbip attach
#
# The guest must NOT run usbipd/usbip bind on the UDC (wrong polarity).
# This script only wires Simics-side objects. The bridge *model* is a product
# dependency — intel-fpga-main does not ship it today.
#
# Env:
#   USBIP_TCP_PORT   listen port (default 3240)
#   REQUIRE_USBIP_BRIDGE=1  exit/raise if bridge class missing (default: warn)

import os
import simics


# Candidate class / create-command names once modeling lands.
_BRIDGE_CLASS_CANDIDATES = (
    "usbip_bridge",
    "usbip-bridge",
    "km_usbip_bridge",
    "simics_usbip_bridge",
    "usb_usbip_bridge",
)


def _try_get_class(name):
    try:
        return simics.SIM_get_class(name)
    except Exception:  # pylint: disable=broad-except
        return None


def _find_bridge_class():
    for name in _BRIDGE_CLASS_CANDIDATES:
        cls = _try_get_class(name)
        if cls is not None:
            return name, cls
    # Soft scan: any class with both "usb" and "ip" in the name.
    try:
        for cls in simics.SIM_get_all_classes():
            n = cls.name if hasattr(cls, "name") else str(cls)
            low = n.lower().replace("-", "_")
            if "usbip" in low or ("usb" in low and "ip" in low and "bridge" in low):
                return n, cls
    except Exception:  # pylint: disable=broad-except
        pass
    return None, None


def _connect_bridge_to_device(bridge_obj, device):
    """Best-effort wire bridge <-> xDCI / type-C device side."""
    tried = []
    # Attribute-style
    for attr in ("usb_device", "device", "usb", "target"):
        tried.append("attr:" + attr)
        try:
            setattr(bridge_obj, attr, device)
            print("USBIP-bridge: %s.%s <- %s" % (bridge_obj.name, attr, device.name))
            return True
        except Exception:  # pylint: disable=broad-except
            pass
    # Connector-style (board Type-C up / device)
    pairs = (
        ("system.board.fpga.hps.hsp.usb31.usb1_typec_slot", "usb_host"),
        ("system.board.fpga.usb1_typec_slot", "usb_host"),
    )
    for slot, cnt in pairs:
        tried.append("connect %s %s" % (slot, cnt))
        try:
            simics.SIM_run_command(
                "connect %s %s.%s" % (slot, bridge_obj.name, cnt)
            )
            print("USBIP-bridge: connected %s <-> %s.%s" % (slot, bridge_obj.name, cnt))
            return True
        except Exception:  # pylint: disable=broad-except
            pass
    print("USBIP-bridge: WARN could not auto-wire USB; tried: %s" % ", ".join(tried))
    return False


def _listen_tcp(bridge_obj, port):
    for attr in ("tcp_port", "port", "listen_port", "usbip_port"):
        try:
            setattr(bridge_obj, attr, int(port))
            print("USBIP-bridge: %s.%s = %s" % (bridge_obj.name, attr, port))
            return True
        except Exception:  # pylint: disable=broad-except
            pass
    for cmd in (
        "%s.listen port = %s" % (bridge_obj.name, port),
        "%s.tcp-setup port = %s" % (bridge_obj.name, port),
    ):
        try:
            simics.SIM_run_command(cmd)
            print("USBIP-bridge: ran `%s`" % cmd)
            return True
        except Exception:  # pylint: disable=broad-except
            pass
    print(
        "USBIP-bridge: WARN no known TCP listen API on %s — set port manually"
        % bridge_obj.name
    )
    return False


def km_usb31_usbip_bridge():
    port = int(os.environ.get("USBIP_TCP_PORT", "3240"))
    require = os.environ.get("REQUIRE_USBIP_BRIDGE", "0") in ("1", "true", "TRUE", "yes")

    print("USBIP-bridge: Variant S setup (TCP port %d)" % port)
    print("USBIP-bridge: guest stays on UDC/configfs only — no usbip bind in guest")

    # Real-time helps host-side USBIP / TCP timeouts track wall clock.
    try:
        simics.SIM_run_command("enable-real-time-mode")
        print("USBIP-bridge: enable-real-time-mode OK")
    except Exception as exc:  # pylint: disable=broad-except
        print("USBIP-bridge: enable-real-time-mode skipped: %s" % exc)

    cls_name, _cls = _find_bridge_class()
    if cls_name is None:
        msg = (
            "USBIP-bridge: BLOCKED — no Simics USBIP bridge class in this package.\n"
            "  Need modeling: USBIP server on KM usb31 device/xDCI "
            "(candidates: %s).\n"
            "  Until then: Phase 1 UDC/gadget only; host `usbip attach` will fail.\n"
            "  See docs/KM-SIMICS-USBIP.md"
            % (", ".join(_BRIDGE_CLASS_CANDIDATES),)
        )
        print(msg)
        if require:
            raise RuntimeError("REQUIRE_USBIP_BRIDGE=1 but bridge model missing")
        return False

    print("USBIP-bridge: using class %s" % cls_name)
    try:
        device = simics.SIM_get_object("system.board.fpga.hps.hsp.usb31.device")
    except Exception as exc:  # pylint: disable=broad-except
        print("USBIP-bridge: cannot find usb31.device: %s" % exc)
        if require:
            raise
        return False

    try:
        bridge = simics.SIM_create_object(cls_name, "km_usbip_bridge", [])
    except Exception as exc:  # pylint: disable=broad-except
        # Some projects use create-*-comp commands instead.
        print("USBIP-bridge: SIM_create_object failed (%s); try CLI create" % exc)
        try:
            simics.SIM_run_command("create-%s name = km_usbip_bridge" % cls_name)
            bridge = simics.SIM_get_object("km_usbip_bridge")
        except Exception as exc2:  # pylint: disable=broad-except
            print("USBIP-bridge: create failed: %s" % exc2)
            if require:
                raise
            return False

    _connect_bridge_to_device(bridge, device)
    _listen_tcp(bridge, port)

    print(
        "USBIP-bridge: host side next:\n"
        "  sudo modprobe vhci-hcd\n"
        "  usbip list -r 127.0.0.1   # or forwarded IP\n"
        "  sudo usbip attach -r 127.0.0.1 -b <busid>\n"
        "  (helper: ./scripts/host/km-usbip-attach.sh)"
    )
    return True


km_usb31_usbip_bridge()
