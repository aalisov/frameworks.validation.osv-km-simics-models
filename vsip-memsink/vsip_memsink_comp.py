# Copyright (C) 2026
# VSIP mem_sink Simics component (MMIO control/ref/err + H2F target window).

import simics
from comp import StandardConnectorComponent, SimpleConfigAttribute
from simmod.generic_connectors.connectors import FPGASoCBridgeMemUpConnector

KB = 1024


class vsip_memsink_comp(StandardConnectorComponent):
    """VSIP memory traffic checker (mem_sink RTL)."""

    _class_desc = "VSIP mem_sink component"
    _help_categories = ()

    class basename(StandardConnectorComponent.basename):
        val = "vsip_memsink"

    class base_addr(SimpleConfigAttribute(0xF9040000, "i", simics.Sim_Attr_Optional)):
        """CPU-visible control base (OSBV DT: vsip-memsink-ctl@F9040000)."""

    class target_addr(SimpleConfigAttribute(0xC0000000, "i", simics.Sim_Attr_Optional)):
        """H2F target window base (OSBV DT: vsip-memsink-tgt@C0000000)."""

    class target_size(SimpleConfigAttribute(0x4000, "i", simics.Sim_Attr_Optional)):
        """Target window size in bytes (default 16 KiB)."""

    def setup(self):
        StandardConnectorComponent.setup(self)
        if not self.instantiated.val:
            self.add_objects()
        self.add_connectors()

    def add_objects(self):
        mmio = self.add_pre_obj("mmio", "memory-space")
        tgt_space = self.add_pre_obj("tgt_space", "memory-space")
        dev = self.add_pre_obj("dev", "vsip_memsink")

        # Banks relative to the phys_mem window that maps mmio at base_addr.
        mmio.map = [
            [0x00000, [dev, "control"], 0, 0, 64 * KB],
            [0x10000, [dev, "refdata"], 0, 0, 64 * KB],
            [0x20000, [dev, "errors"], 0, 0, 64 * KB],
        ]

        tgt_space.map = [
            [0, [dev, "target"], 0, 0, self.target_size.val],
        ]

        # Absolute PA used when logging error.addr (plugin reads errvecs).
        try:
            dev.tgt_base = self.target_addr.val
        except Exception:
            pass

    def add_connectors(self):
        self.add_connector("mmio_conn", FPGASoCBridgeMemUpConnector("mmio"))
        self.add_connector("tgt_conn", FPGASoCBridgeMemUpConnector("tgt_space"))
