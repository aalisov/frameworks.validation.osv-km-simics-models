# Copyright (C) 2026
"""KM OSBV board hooks for VSIP memsrc.

Call from km-universal-board-comp (or equivalent):

    # in add_objects():
    from simmod.vsip_memsrc.board_hooks import add_vsip_memsrc
    add_vsip_memsrc(self, base=self.vsip_memsrc_base.val)

    # in component.post_instantiate():
    from simmod.vsip_memsrc.board_hooks import wire_vsip_memsrc
    wire_vsip_memsrc(self._up, base=self._up.vsip_memsrc_base.val)
"""

from __future__ import annotations

import simics

DEFAULT_BASE = 0x18180000
DEFAULT_SIZE = 0x10000
DEFAULT_SLOT = "vsip_memsrc_0"

# KM APU cores issue Non-Secure PAs with bit 63 set (see km_apu_constants.NS).
# cpu_mem → bt_mem → CCU; phys_mem is debug/F2 only and is NOT on the core path.
NS = 1 << 63


def add_vsip_memsrc(board, slot: str = DEFAULT_SLOT, base: int = DEFAULT_BASE):
    """Instantiate vsip_memsrc_comp on a board component (add_objects phase)."""
    board.add_component(
        slot,
        "vsip_memsrc_comp",
        [["base_addr", base]],
    )


def _append_s_ns(mem_space, base: int, obj, size: int) -> None:
    """Map Secure and Non-Secure aliases for a PA window."""
    new_map = list(mem_space.map or [])
    new_map.append([base, obj, 0, 0, size])
    new_map.append([base | NS, obj, 0, 0, size])
    mem_space.map = new_map


def wire_vsip_memsrc(
    board,
    slot: str = DEFAULT_SLOT,
    base: int = DEFAULT_BASE,
    size: int = DEFAULT_SIZE,
    bt_mem_path: str = "fpga.hps.apu.bt_mem",
    phys_mem_path: str = "fpga.hps.apu.phys_mem",
) -> None:
    """Map MMIO onto the CPU path (bt_mem) and keep phys_mem for F2/debug.

    Must run in post_instantiate. Core accesses use cpu_mem→bt_mem→CCU; a
    phys_mem-only map never sees Linux/supersmasher stores (fault PA looks like
    0x80000000_18188000 = NS|vectors).
    """
    vsip_mmio = board.get_slot(f"{slot}.mmio")

    bt_mem = board.get_slot(bt_mem_path)
    _append_s_ns(bt_mem, base, vsip_mmio, size)
    simics.SIM_log_info(
        3,
        board.obj,
        0,
        f"Mapped VSIP memsrc MMIO on {bt_mem_path} at 0x{base:x}/NS "
        f"(size 0x{size:x})",
    )

    # Debug get/set + optional alias; F2 master still needs phys_mem for DRAM.
    phys_mem = board.get_slot(phys_mem_path)
    _append_s_ns(phys_mem, base, vsip_mmio, size)

    try:
        board.get_slot(f"{slot}.dev").f2_mem = phys_mem
        simics.SIM_log_info(
            3,
            board.obj,
            0,
            f"Routed VSIP memsrc F2 master to {phys_mem_path}",
        )
    except Exception as exc:  # pylint: disable=broad-except
        simics.SIM_log_info(
            1,
            board.obj,
            0,
            f"VSIP F2→phys_mem wire failed: {exc}",
        )
