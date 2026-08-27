# Copyright (C) 2026
"""KM OSBV board hooks for P3T1755 I3C temperature sensor.

Call from km-universal-board-comp (or equivalent):

    from simmod.p3t1755.board_hooks import add_p3t1755, connect_p3t1755

    add_p3t1755(self)
    connect_p3t1755(self, i3c_bus_dev_slot="i3c_bus[0].dev_slot[4]")
"""

from __future__ import annotations

# Match osbv-i3c0dev-nxp1755 DT: sensor@0,236152A0090
# i3cdev I3C_DEVICE(0x11B, 0x152a) + board extra 0x090
DEFAULT_PID = 0x236152A0090
DEFAULT_DCR = 0x63
DEFAULT_SLOT = "p3t1755_0"


def add_p3t1755(
    board,
    slot: str = DEFAULT_SLOT,
    pid: int = DEFAULT_PID,
    dcr: int = DEFAULT_DCR,
    static_address: int = 0xFF,
    temperature_c: int = 25,
):
    """Instantiate p3t1755_comp on a board component (add_objects phase)."""
    board.add_component(
        slot,
        "p3t1755_comp",
        [
            ["pid", pid],
            ["dcr", dcr],
            ["static_address", static_address],
            ["temperature_c", temperature_c],
        ],
    )


def connect_p3t1755(
    board,
    i3c_bus_dev_slot: str,
    slot: str = DEFAULT_SLOT,
):
    """Connect sensor bus_slot to an I3C bus device slot."""
    board.connect(
        board.get_slot(i3c_bus_dev_slot),
        board.get_slot(f"{slot}.bus_slot"),
    )
