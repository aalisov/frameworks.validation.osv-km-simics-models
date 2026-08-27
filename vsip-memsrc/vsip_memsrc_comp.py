# Copyright (C) 2026
# VSIP mem_source Simics component (MMIO + optional F2 master memory space).

import simics
from comp import StandardConnectorComponent, SimpleConfigAttribute
from simmod.generic_connectors.connectors import FPGASoCBridgeMemUpConnector

KB = 1024
MB = 1024 * KB


class vsip_memsrc_comp(StandardConnectorComponent):
    """VSIP memory traffic generator (mem_source RTL)."""

    _class_desc = "VSIP mem_source component"
    _help_categories = ()

    class basename(StandardConnectorComponent.basename):
        val = "vsip_memsrc"

    class base_addr(SimpleConfigAttribute(0xF9000000, "i", simics.Sim_Attr_Optional)):
        """CPU-visible base address (OSBV DT: vsip-memsrc@F9000000)."""

    class f2_mem_size(SimpleConfigAttribute(512 * MB, "i", simics.Sim_Attr_Optional)):
        """Size of the backing RAM for F2 master transactions (soc2fpga stub)."""

    def setup(self):
        StandardConnectorComponent.setup(self)
        if not self.instantiated.val:
            self.add_objects()
        self.add_connectors()

    def add_objects(self):
        mmio = self.add_pre_obj("mmio", "memory-space")
        dev = self.add_pre_obj("dev", "vsip_memsrc")

        # Banks are relative to the phys_mem window that maps this mmio
        # space at base_addr (see km_universal_board_comp post_instantiate).
        # Absolute F90xxxxx addresses here break offset lookups (e.g. +0x20000).
        mmio.map = [
            [0x00000, [dev, "control"], 0, 0, 64 * KB],
            [0x10000, [dev, "vectors"], 0, 0, 64 * KB],
            [0x20000, [dev, "errors"], 0, 0, 64 * KB],
        ]

        f2_space = self.add_pre_obj("f2_mem_space", "memory-space")
        f2_ram = self.add_pre_obj("f2_ram", "ram")
        f2_image = self.add_pre_obj("_image_f2_ram", "image", size=self.f2_mem_size.val)
        f2_ram.image = f2_image
        f2_space.map = [[0, f2_ram, 0, 0, self.f2_mem_size.val]]

        dev.f2_mem = f2_space

    def add_connectors(self):
        self.add_connector("mmio_conn", FPGASoCBridgeMemUpConnector("mmio"))
        self.add_connector("f2_mem_conn", FPGASoCBridgeMemUpConnector("f2_mem_space"))
