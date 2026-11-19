# Deassert KM HPS I2C models before Linux probe.
# Without this, Linux i2c MMIO can hit Simics
#   "[...i2c0.bank.regs critical] Device in Reset ..."
# and drop to simics> (CI telnet EOF). Also see km_continue_on_device_in_reset.py.
import simics

lsp = conf.system.board.fpga.hps.lsp
for name in ("i2c0", "i2c1", "i2c2", "i2c3", "i2c4"):
    try:
        dev = getattr(lsp, name)
    except AttributeError:
        print(f"i2c deassert: {name} not present")
        continue
    objs = [dev]
    try:
        objs.append(dev.bank)
    except Exception:
        pass
    try:
        objs.append(dev.bank.regs)
    except Exception:
        pass
    for obj in objs:
        try:
            if hasattr(obj, "device_reset_state_device_in_reset"):
                before = obj.device_reset_state_device_in_reset
                obj.device_reset_state_device_in_reset = False
                after = obj.device_reset_state_device_in_reset
                print(f"{obj.name}.device_reset_state_device_in_reset {before} -> {after}")
        except Exception as exc:  # pylint: disable=broad-except
            print(f"{getattr(obj, 'name', obj)} reset-attr: {exc}")
    # Try common reset port names; ignore misses
    for pname in ("HRESET", "SRESET", "reset", "RESET", "PRESET", "presetn", "rstn"):
        try:
            simics.SIM_get_port_interface(dev, "signal", pname).signal_lower()
            print(f"lowered {name}.port.{pname}")
        except Exception:
            pass
    # Drop critical log level on regs bank so access-in-reset is less fatal if possible
    try:
        regs = dev.bank.regs
        for attr in ("log_level", "loglevel"):
            if hasattr(regs, attr):
                try:
                    setattr(regs, attr, 1)
                    print(f"{regs.name}.{attr}=1")
                except Exception:
                    pass
    except Exception:
        pass
