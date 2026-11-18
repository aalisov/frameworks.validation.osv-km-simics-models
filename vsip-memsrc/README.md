# VSIP mem_source

Functional Simics model for VSIP mem_source RTL.

- CPU MMIO @ `0x18180000` (64 KiB, KM DT / LWSOC2NOC)
- Banks (relative, `layout="km"`): control `+0x0`, errors `+0x4000`, vectors `+0x8000`
- Board hooks map MMIO onto `apu.bt_mem` (Secure + NS/`1<<63`); cores use `cpu_mem→bt_mem`, not `phys_mem`
- F2 AXI master still wired to HPS `phys_mem` for DRAM carveout

See top-level `README.md` for km-hps integration and supersmasher notes.
