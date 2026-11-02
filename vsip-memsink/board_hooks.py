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

DEFAULT_CTL_BASE = 0xF9040000
DEFAULT_CTL_SIZE = 0x40000
DEFAULT_TGT_BASE = 0xC0000000
DEFAULT_TGT_SIZE = 0x4000
DEFAULT_SLOT = "vsip_memsink_0"


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


def wire_vsip_memsink(
    board,
    slot: str = DEFAULT_SLOT,
    ctl_base: int = DEFAULT_CTL_BASE,
    ctl_size: int = DEFAULT_CTL_SIZE,
    tgt_base: int = DEFAULT_TGT_BASE,
    tgt_size: int = DEFAULT_TGT_SIZE,
    phys_mem_path: str = "fpga.hps.apu.phys_mem",
) -> None:
    """Map control MMIO and H2F target window into HPS phys_mem.

    Must run in post_instantiate (after phys_mem exists).
    """
    phys_mem = board.get_slot(phys_mem_path)
    vsip_mmio = board.get_slot(f"{slot}.mmio")
    vsip_tgt = board.get_slot(f"{slot}.tgt_space")
    new_map = list(phys_mem.map)
    new_map.append([ctl_base, vsip_mmio, 0, 0, ctl_size])
    new_map.append([tgt_base, vsip_tgt, 0, 0, tgt_size])
    phys_mem.map = new_map

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
        f"tgt@0x{tgt_base:x}+0x{tgt_size:x}",
    )
