# Deassert KM HPS OSPI combophy before Linux cadence-xspi probe.
# Without this, aux/PHY MMIO hits Simics "Device in Reset" critical stop.
import simics

parent = conf.system.board.fpga.hps.lsp.ospi_combophy0
before = getattr(parent, "device_reset_state_device_in_reset", None)
print("ospi_combophy0.device_reset_state_device_in_reset before:", before)
parent.device_reset_state_device_in_reset = False
print("ospi_combophy0.device_reset_state_device_in_reset after:",
      parent.device_reset_state_device_in_reset)

for pname in ("HRESET", "SRESET", "reset"):
    try:
        simics.SIM_get_port_interface(parent, "signal", pname).signal_lower()
        print(f"lowered ospi_combophy0.port.{pname}")
    except Exception as e:
        print(f"ospi_combophy0.port.{pname}: {e}")
