# Copyright (C) 2026
# Minimal P3T1755 I3C temperature sensor component for KM Simics.

from comp import *


class p3t1755_comp(StandardConnectorComponent):
    """Minimal NXP P3T1755-compatible I3C temperature sensor."""

    _class_desc = "P3T1755 temp sensor component"
    _help_categories = ()

    class pid(SimpleConfigAttribute(0x236152A0090, "i", simics.Sim_Attr_Optional)):
        """Provisioned ID: manuf 0x11B, part 0x152A, extra 0x090 (DT 236152A0090)."""

    class dcr(SimpleConfigAttribute(0x63, "i", simics.Sim_Attr_Optional)):
        """Device Characteristic Register (0x63 = temperature sensor)."""

    class static_address(SimpleConfigAttribute(0xFF, "i", simics.Sim_Attr_Optional)):
        """Static/I2C 7-bit address (0xff = none, matches DT reg first cell 0)."""

    class temperature_c(SimpleConfigAttribute(25, "i", simics.Sim_Attr_Optional)):
        """Initial simulated temperature in Celsius."""

    def setup(self):
        StandardConnectorComponent.setup(self)
        if not self.instantiated.val:
            self.add_objects()
        self.add_connector("bus_slot", I3CLinkUpConnector("target", "bus"))

    def add_objects(self):
        tgt = self.add_pre_obj("target", "p3t1755")
        tgt.provisional_id = self.pid.val
        tgt.dcr = self.dcr.val
        tgt.static_address = self.static_address.val
        tgt.temperature_c = self.temperature_c.val
