# Simics fixups for agilex72-universal on km-hps.
#
# Old Simics (intel-fpga-ext, arm_dsu_120): PPU MMIO is missing inside lsp_periphs.
# Map 4KB set-memory stubs so ATF/Linux SMP writes do not abort the script.
#
# New Simics (intel-fpga-main / intelfpga-internal, km_hps_dsu_120): real
# cluster_ppu / core_ppu banks exist. Do NOT stub those pages — stubs shadow
# the real model and break secondary bring-up.

CLUSTER_PPU_ADDR = 0x08030000
CORE_PPU_ADDRS = [
    0x08080000,  # core 0
    0x08180000,  # core 1
    0x08280000,  # core 2
    0x08380000,  # core 3
]
PPU_PAGE_SIZE = 0x1000
PPU_ON = 0x8
PPU_MAP_PRIORITY = 1


def _obj_exists(name):
    import simics
    try:
        simics.SIM_get_object(name)
        return True
    except Exception:
        return False


def _has_real_ppu_model(hps):
    import simics
    try:
        dsu = simics.SIM_get_object(hps + ".apu.mpu.dsu")
        return dsu.classname == "km_hps_dsu_120"
    except Exception:
        return False


def _page_mapped(pm, base):
    return any(e[0] == base for e in pm.map)


def _ensure_ppu_page(pm, hps, base, idx):
    if _page_mapped(pm, base):
        return False
    import simics
    name = "km_ppu_page_%d" % idx
    path = hps + "." + name
    if _obj_exists(path):
        stub = simics.SIM_get_object(path)
    else:
        stub = simics.SIM_create_object("set-memory", name, [])
    pm.map = pm.map + [
        [base, stub, 0, PPU_MAP_PRIORITY, PPU_PAGE_SIZE, None, 0, 0, 0]
    ]
    return True


def km_simics_smp_fixup():
    import simics
    import conf

    conf.sim.stop_on_error = False
    conf.sim.sigtrap_on_error_log = False

    hps = "system.board.fpga.hps"
    msgs = ["stop_on_error=False"]

    if _has_real_ppu_model(hps):
        msgs.append("real km_hps_dsu_120 PPU (no stubs)")
        return "; ".join(msgs)

    pm = simics.SIM_get_object(hps + ".apu.phys_mem")
    pages = [CLUSTER_PPU_ADDR] + CORE_PPU_ADDRS
    added = 0
    for idx, base in enumerate(pages):
        if _ensure_ppu_page(pm, hps, base, idx):
            added += 1
    if added:
        msgs.append("phys_mem PPU stubs: %d (legacy arm_dsu_120)" % added)

    return "; ".join(msgs)


def km_simics_cluster_ppu_on():
    km_simics_smp_fixup()
    return "cluster PPU @ 0x%08x" % CLUSTER_PPU_ADDR
