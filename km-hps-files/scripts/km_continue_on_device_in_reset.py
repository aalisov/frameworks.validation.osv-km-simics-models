# Auto-continue if Simics stops on "Device in Reset" (CI has no TTY at simics>).
#
# Core_Log_Message + SIM_continue failed with:
#   "SIM_continue called from non-main thread"
# Use Core_Simulation_Stopped + SIM_thread_safe_callback (proc_commands pattern).
import re
import simics

_PAT = re.compile(r"Device in Reset", re.I)
_continuing = False
_pending_dir = False  # set by log hap; Simulation_Stopped may omit the text
_stop_count = 0
_MAX_AUTO_CONTINUE = 128


def _clear_i2c_resets():
    try:
        lsp = conf.system.board.fpga.hps.lsp
    except Exception as exc:
        print("KM: no HPS lsp (%s)" % exc)
        return
    for name in ("i2c0", "i2c1", "i2c2", "i2c3", "i2c4"):
        try:
            dev = getattr(lsp, name)
        except AttributeError:
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
                    print(
                        "KM: %s.device_reset_state_device_in_reset %s -> %s"
                        % (obj.name, before, obj.device_reset_state_device_in_reset)
                    )
            except Exception as exc:
                print("KM: reset-attr %s: %s" % (getattr(obj, "name", obj), exc))
        for pname in ("HRESET", "SRESET", "reset", "RESET", "PRESET", "presetn", "rstn"):
            try:
                simics.SIM_get_port_interface(dev, "signal", pname).signal_lower()
                print("KM: lowered %s.port.%s" % (name, pname))
            except Exception:
                pass


def _do_continue(_data=None):
    global _continuing
    try:
        _clear_i2c_resets()
        print("KM: SIM_continue(0) after Device-in-Reset")
        simics.SIM_continue(0)
    except Exception as exc:  # pylint: disable=broad-except
        print("KM: SIM_continue failed: %s" % exc)
    finally:
        _continuing = False


def _on_sim_stopped(_arg, _obj, _exc, err_str):
    global _continuing, _stop_count, _pending_dir
    try:
        text = err_str if isinstance(err_str, str) else str(err_str)
    except Exception:
        text = ""
    hit = bool(_PAT.search(text)) or _pending_dir
    if not hit:
        return
    _pending_dir = False
    if _continuing:
        return
    _stop_count += 1
    if _stop_count > _MAX_AUTO_CONTINUE:
        print(
            "KM: Device-in-Reset auto-continue limit (%d) — leaving at simics>"
            % _MAX_AUTO_CONTINUE
        )
        return
    print(
        "KM: Device-in-Reset stop (#%d): %r — schedule continue"
        % (_stop_count, text[:120])
    )
    _continuing = True
    _clear_i2c_resets()
    try:
        simics.SIM_thread_safe_callback(_do_continue, None)
    except Exception as exc:  # pylint: disable=broad-except
        print("KM: SIM_thread_safe_callback failed (%s); trying SIM_run_alone" % exc)
        try:
            simics.SIM_run_alone(_do_continue, None)
        except Exception as exc2:  # pylint: disable=broad-except
            print("KM: SIM_run_alone failed: %s" % exc2)
            _continuing = False


def _on_log_msg(*args):
    # Mark pending + pre-clear when the critical is logged (stop hap may omit text).
    global _pending_dir
    text = ""
    for a in args:
        if isinstance(a, (str, bytes)):
            text = a.decode("utf-8", "replace") if isinstance(a, bytes) else a
            break
    if _PAT.search(text):
        _pending_dir = True
        _clear_i2c_resets()



if not globals().get("_km_dir_hap_installed"):
    try:
        conf.sim.stop_on_error = False
        print("KM: conf.sim.stop_on_error=%s" % conf.sim.stop_on_error)
    except Exception as exc:  # pylint: disable=broad-except
        print("KM: stop_on_error set failed: %s" % exc)

    try:
        hid = simics.SIM_hap_add_callback(
            "Core_Simulation_Stopped", _on_sim_stopped, None
        )
        print("KM: Core_Simulation_Stopped hap id=%s" % hid)
    except Exception as exc:  # pylint: disable=broad-except
        print("KM: WARN Core_Simulation_Stopped hap: %s" % exc)

    try:
        hid2 = simics.SIM_hap_add_callback("Core_Log_Message", _on_log_msg, None)
        print("KM: Core_Log_Message pre-clear hap id=%s" % hid2)
    except Exception as exc:  # pylint: disable=broad-except
        print("KM: WARN Core_Log_Message hap: %s" % exc)

    globals()["_km_dir_hap_installed"] = True
else:
    print("KM: Device-in-Reset continue haps already installed")
