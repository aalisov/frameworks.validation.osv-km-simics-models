# VSIP mem_source

Functional Simics model for VSIP mem_source RTL.

- CPU MMIO @ `0x18180000` (64 KiB, KM DT / LWSOC2NOC)
- Banks (relative, `layout="km"`): control `+0x0`, errors `+0x4000`, vectors `+0x8000`
- Board hooks map MMIO onto `apu.bt_mem` (Secure + NS/`1<<63`); cores use `cpu_mem→bt_mem`, not `phys_mem`
- F2 AXI master still wired to HPS `phys_mem` for DRAM carveout

See top-level `README.md` for km-hps integration and supersmasher notes.

## Write/read bursts (xlen)

`xlen` (`+0x2C`) holds the write length in `[7:0]` and the read length in `[31:24]`; a burst has `len + 1` beats of 256 bit (32 B).

As in the RTL (`mem_source_wr.sv`), one 128 B vector carries 512 bit of data, that is two beats. A burst of `N` beats therefore uses `ceil(N/2)` consecutive vectors: the address comes from the first vector and the data from all of them. The model skips the vectors a burst has consumed, so the next op starts after them. `op = 3` (write burst) is accepted in the vector `op` field.

The data width is fixed at 256 bit on KM; there is no f2sdram interface.