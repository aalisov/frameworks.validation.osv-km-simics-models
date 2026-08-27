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

DEFAULT_BASE = 0xF9000000
DEFAULT_SIZE = 0x40000
DEFAULT_SLOT = "vsip_memsrc_0"


def add_vsip_memsrc(board, slot: str = DEFAULT_SLOT, base: int = DEFAULT_BASE):
    """Instantiate vsip_memsrc_comp on a board component (add_objects phase)."""
    board.add_component(
        slot,
        "vsip_memsrc_comp",
        [["base_addr", base]],
    )


def wire_vsip_memsrc(
    board,
    slot: str = DEFAULT_SLOT,
    base: int = DEFAULT_BASE,
    size: int = DEFAULT_SIZE,
    phys_mem_path: str = "fpga.hps.apu.phys_mem",
) -> None:
    """Map MMIO into HPS phys_mem and route F2 master to the same space.

    Must run in post_instantiate (after phys_mem exists). F2 must see absolute
    PAs used by supersmasher vecscripts (e.g. DRAM carveout @ 0xf0000000).
    """
    phys_mem = board.get_slot(phys_mem_path)
    vsip_mmio = board.get_slot(f"{slot}.mmio")
    new_map = list(phys_mem.map)
    new_map.append([base, vsip_mmio, 0, 0, size])
    phys_mem.map = new_map
    simics.SIM_log_info(
        3,
        board.obj,
        0,
        f"Mapped VSIP memsrc MMIO at 0x{base:x} (size 0x{size:x})",
    )

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
