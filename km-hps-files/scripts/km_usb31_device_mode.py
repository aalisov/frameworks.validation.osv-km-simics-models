# Configure KM USB3.1 (usb31) for guest device/gadget mode.
#
# km_hsp_comp hard-wires NOC target "usb31" -> usb31.host.bank.xhci_regs.
# host_mode=FALSE alone only swaps IRQs when regs_size==0 (KM path); it does
# *not* retarget the NOC. Without that, Linux still talks to xHCI and never
# creates a UDC even with dr_mode=peripheral.
#
# Invoked from boot-to-osbv-smp-usb31-device.simics after board create.
# Guest still needs: osvloaddtoverlay km-usb31-gadget (+ rebind or reboot)

import simics


def _disconnect(a, b):
    try:
        simics.SIM_run_command("disconnect %s %s" % (a, b))
        print("USB31-device: disconnected %s <-> %s" % (a, b))
        return True
    except Exception as exc:  # pylint: disable=broad-except
        print("USB31-device: disconnect skip (%s <-> %s): %s" % (a, b, exc))
        return False


def km_usb31_device_mode():
    pairs = (
        (
            "system.board.fpga.usb3_slot",
            "system.board.usb3_disk.connector_usb_host",
        ),
        (
            "system.board.fpga.usb2_slot",
            "system.board.usb3_hs_disk.connector_usb_host",
        ),
        (
            "system.board.fpga.otg_slot",
            "system.board.usbotg_disk.connector_usb_host",
        ),
    )
    for a, b in pairs:
        _disconnect(a, b)

    usb31 = simics.SIM_get_object("system.board.fpga.hps.hsp.usb31")
    device = simics.SIM_get_object("system.board.fpga.hps.hsp.usb31.device")
    host = simics.SIM_get_object("system.board.fpga.hps.hsp.usb31.host")

    # Flip component mode (IRQ / usb_id); MMIO remap only if regs_size>0.
    usb31.host_mode = False
    print("USB31-device: usb31.host_mode = %s" % usb31.host_mode)

    # KM HSP uses NOC-managed CSRs (regs_size=0) — retarget NOC to xDCI.
    try:
        noc_targets = simics.SIM_get_object(
            "system.board.fpga.hps.hsp.noc.noc_targets"
        )
        xdci = device.bank.regs
        noc_targets.usb31 = xdci
        print("USB31-device: noc.noc_targets.usb31 -> %s (xDCI)" % xdci)
    except Exception as exc:  # pylint: disable=broad-except
        print("USB31-device: NOC retarget FAILED: %s" % exc)
        print(
            "USB31-device: guest will still see xHCI @ usb31 — UDC will stay empty"
        )
        return False

    # Ensure device DMA path sees the same initiator mem as host had.
    try:
        if getattr(device, "phys_mem", None) is None and getattr(host, "phys_mem", None):
            device.phys_mem = host.phys_mem
            print("USB31-device: device.phys_mem <- host.phys_mem")
    except Exception as exc:  # pylint: disable=broad-except
        print("USB31-device: phys_mem wire note: %s" % exc)

    print(
        "USB31-device: guest: osvloaddtoverlay km-usb31-gadget "
        "then rebind dwc3 or reboot; check km-usb31-gadget-check.sh"
    )
    return True


km_usb31_device_mode()
