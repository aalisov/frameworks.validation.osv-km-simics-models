# Copyright (C) 2026
"""KM OSBV board hooks for VSIP memsink.

Call from km-universal-board-comp (or equivalent):

    # in add_objects():
    from simmod.vsip_memsink.board_hooks import add_vsip_memsink
    add_vsip_memsink(self,
                     ctl_base=self.vsip_memsink_ctl_base.val,
                     tgt_base=self.vsip_memsink_tgt_base.val)

    # in component.post_instantiate():
    from simmod.vsip_memsink.board_hooks import wire_vsip_memsink
    wire_vsip_memsink(self._up,
                      ctl_base=self._up.vsip_memsink_ctl_base.val,
                      tgt_base=self._up.vsip_memsink_tgt_base.val)
"""

from __future__ import annotations

import simics

DEFAULT_CTL_BASE = 0x18190000
DEFAULT_CTL_SIZE = 0x30000
DEFAULT_TGT_BASE = 0x40000000
DEFAULT_TGT_SIZE = 0x4000
DEFAULT_SLOT = "vsip_memsink_0"

# See vsip_memsrc.board_hooks: CPU path is bt_mem, not phys_mem.
NS = 1 << 63


def add_vsip_memsink(
    board,
    slot: str = DEFAULT_SLOT,
    ctl_base: int = DEFAULT_CTL_BASE,
    tgt_base: int = DEFAULT_TGT_BASE,
    tgt_size: int = DEFAULT_TGT_SIZE,
):
    """Instantiate vsip_memsink_comp on a board component (add_objects phase)."""
    board.add_component(
        slot,
        "vsip_memsink_comp",
        [
            ["base_addr", ctl_base],
            ["target_addr", tgt_base],
            ["target_size", tgt_size],
        ],
    )


def _append_s_ns(mem_space, base: int, obj, size: int) -> None:
    new_map = list(mem_space.map or [])
    new_map.append([base, obj, 0, 0, size])
    new_map.append([base | NS, obj, 0, 0, size])
    mem_space.map = new_map


def wire_vsip_memsink(
    board,
    slot: str = DEFAULT_SLOT,
    ctl_base: int = DEFAULT_CTL_BASE,
    ctl_size: int = DEFAULT_CTL_SIZE,
    tgt_base: int = DEFAULT_TGT_BASE,
    tgt_size: int = DEFAULT_TGT_SIZE,
    bt_mem_path: str = "fpga.hps.apu.bt_mem",
    phys_mem_path: str = "fpga.hps.apu.phys_mem",
) -> None:
    """Map ctl + tgt onto bt_mem (CPU) and phys_mem (debug).

    Must run in post_instantiate (after bt_mem / phys_mem exist).
    """
    vsip_mmio = board.get_slot(f"{slot}.mmio")
    vsip_tgt = board.get_slot(f"{slot}.tgt_space")

    bt_mem = board.get_slot(bt_mem_path)
    _append_s_ns(bt_mem, ctl_base, vsip_mmio, ctl_size)
    _append_s_ns(bt_mem, tgt_base, vsip_tgt, tgt_size)

    phys_mem = board.get_slot(phys_mem_path)
    _append_s_ns(phys_mem, ctl_base, vsip_mmio, ctl_size)
    _append_s_ns(phys_mem, tgt_base, vsip_tgt, tgt_size)

    try:
        board.get_slot(f"{slot}.dev").tgt_base = tgt_base
    except Exception as exc:  # pylint: disable=broad-except
        simics.SIM_log_info(
            1,
            board.obj,
            0,
            f"VSIP memsink tgt_base set failed: {exc}",
        )

    simics.SIM_log_info(
        3,
        board.obj,
        0,
        f"Mapped VSIP memsink ctl@0x{ctl_base:x}+0x{ctl_size:x} "
        f"tgt@0x{tgt_base:x}+0x{tgt_size:x} on {bt_mem_path} (+ phys_mem)",
    )
