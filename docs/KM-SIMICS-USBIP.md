# KM Simics USBIP — Variant S (gadget → host VHCI)

Phase 4 host-side enumeration / MSC against KM **usb31 device (xDCI)** without a
second SoC USB host in the session.

## Architecture

```
Guest Linux (UDC + configfs MSC)     ←→  km_hps_usb31_device (xDCI)
                                              ↕ Simics USB
                                    Simics USBIP bridge model  ← PRODUCT DEPENDENCY
                                              ↕ TCP :3240 (default)
                                    Host PC: vhci-hcd + usbip attach
                                              → lsusb / /dev/sd* / drivers
```

| Layer | Owner | Notes |
|-------|--------|--------|
| Guest gadget | Linux | Overlay + UDC bind only — **no** `usbipd` / `usbip bind` |
| USB wire | Simics | Device port / Type-C up (`usb1_typec_slot`) |
| USBIP server | **Simics bridge model** | Not shipped in intel-fpga-main today |
| USBIP client | Host PC / test bench | `vhci-hcd` + `usbip` tools |

**Do not** use classic guest `usbip bind -b <bus-id>` on the UDC — that API
exports devices under a **host** controller; KM in gadget mode *is* the device.

## Run (Simics project)

```bash
cd ~/km-hps && source ./set_simics_env_main.sh
./scripts/run-osbv-smp-usb31-usbip.sh
# optional: REQUIRE_USBIP_BRIDGE=1  USBIP_TCP_PORT=3240
telnet 127.0.0.1 9123
```

Boot script: `scripts/boot-to-osbv-smp-usb31-usbip.simics`  
Hooks: `km_usb31_device_mode.py` then `km_usb31_usbip_bridge.py`  
(`enable-real-time-mode` + create/wire bridge class if present).

### Guest (after login)

```bash
osvloaddtoverlay km-usb31-gadget
echo d000000.usb31 > /sys/bus/platform/drivers/dwc3/unbind
echo d000000.usb31 > /sys/bus/platform/drivers/dwc3/bind
km-usb31-gadget-check.sh
km-usb-gadget-setup.sh    # MSC on first UDC
# do NOT run usbipd / usbip bind
```

### Host PC

```bash
./scripts/host/km-usbip-attach.sh              # list exports
./scripts/host/km-usbip-attach.sh 127.0.0.1 <busid>
# then: lsusb -v ; MSC R/W + checksum
```

TCP is served by the **Simics** bridge on the Simics host’s loopback (or
forwarded IP), not by guest eth0. Guest `ip=off` is fine for this path.

## Bridge model status

`km_usb31_usbip_bridge.py` probes class names:

`usbip_bridge`, `usbip-bridge`, `km_usbip_bridge`, `simics_usbip_bridge`, …

If none exist, boot continues with a **BLOCKED** warning (Phase 1 UDC still
works). `REQUIRE_USBIP_BRIDGE=1` aborts setup when the model is missing.

### Modeling ask (ticket)

Simics USBIP **server** attached to KM usb31 **device/xDCI** (or
`usb1_typec_slot` host-up connector), listening on configurable TCP port
(default **3240**), exportable to Linux `vhci-hcd` via `usbip attach`.

## Related

- Device-only boot (no USBIP hook): `./scripts/run-osbv-smp-usb31-device.sh`
- AXI / NOC notes: [`KM-SIMICS-AXI.md`](KM-SIMICS-AXI.md)
- Guest applicability: `test_configs/km/SIMICS_APPLICABILITY.md` (fpga-sut)
