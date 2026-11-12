# Shared U-Boot bootmenu control for KM Simics boot scripts.
# Exec'd from .simics via: @exec(open(.../km_uboot_menu_select.py).read())
#
# Default (no uboot_menu / empty / menu / true): interactive `bootmenu`.
# uboot_menu=1..5: auto-run matching boot_* (see km_osbv_default.env).
# stop_at_uboot=TRUE: stay at SOCFPGA_KM # (no menu, no boot).
#
# Writes:
#   simenv.km_uboot_menu_mode = "prompt" | "menu" | "auto"
#   simenv.km_uboot_menu_cmd  = e.g. "run boot_mmc" (auto only)

_MENU = {
    "1": "run boot_qspi",
    "2": "run boot_mmc",
    "3": "run boot_usb",
    "4": "run boot_net",
    "5": "run boot_ram",
}

def _as_bool(val):
    return str(val).strip().lower() in ("1", "true", "yes", "on")

_stop = _as_bool(getattr(simenv, "stop_at_uboot", False))
_raw = str(getattr(simenv, "uboot_menu", "") or "").strip()
_key = _raw.lower()
simenv.stop_at_uboot = _stop

if _stop:
    simenv.km_uboot_menu_mode = "prompt"
    simenv.km_uboot_menu_cmd = ""
    print("KM U-Boot: stop_at_uboot — prompt only")
elif _key in _MENU:
    simenv.km_uboot_menu_mode = "auto"
    simenv.km_uboot_menu_cmd = _MENU[_key]
    print("KM U-Boot: uboot_menu=%s → %s" % (_raw, _MENU[_key]))
else:
    simenv.km_uboot_menu_mode = "menu"
    simenv.km_uboot_menu_cmd = ""
    if _raw and _key not in ("", "0", "true", "yes", "on", "menu"):
        print("KM U-Boot: WARN unknown uboot_menu=%r (use 1..5); falling back to bootmenu" % _raw)
    print("KM U-Boot: interactive bootmenu (pass uboot_menu=1..5 to auto-boot)")
