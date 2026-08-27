# VSIP mem_source

Functional Simics model for VSIP mem_source RTL.

- CPU MMIO @ `0xF9000000`: control `+0x0`, vectors `+0x10000`, errors `+0x20000`
- Nested mmio banks are **relative** to the phys_mem window
- F2 AXI master must be wired to HPS `phys_mem` by the board component

See top-level `README.md` for km-hps integration and supersmasher notes.

