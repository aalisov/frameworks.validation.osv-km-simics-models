# How AXI / interconnect is modeled in KM Simics

Platform: `agilex27-universal` / KM HPS (`km_hps_dsu_120`, `intel-fpga-main`).

## One-line summary

KM Simics interconnect is a **memory-mapped NOC graph** (APU CCU ↔ LSP/HSP NOCs ↔ MNOC/RNOC/public bridges) with **AXI naming and some burst/QoS semantics inside devices** — **not** a cycle-accurate AXI4 fabric (no AW/AR/W/R/B channel FSMs across the NOC).

## What “AXI” means here

| Expectation (RTL / databook) | KM Simics reality |
|------------------------------|-------------------|
| Separate AW/AR/W/R/B handshakes | **Not modeled** across the fabric |
| Address decode + master/slave ports | **Yes** — Simics `memory-space` maps, NOC segments, `map_target` / `transaction` |
| Burst type / INCR vs FIXED | **Sometimes** — checked inside device DML (e.g. Cadence xSPI SDMA) |
| QoS / outstanding depth / timing | Largely ignored (VSIP keeps soft counters only) |

Transport primitives:

- Simics `memory-space` / `transaction` / `map_target`
- NOC DML modules (`km-hsp-noc`, `km-lsp-noc`, `km-mnoc-bridge`, `km-rnoc-bridge`, …)
- Device DML that issues `read_bytes` / `write_bytes` (or equivalent) on a connected memory space

VSIP example (`vsip_memsrc.dml`):

```dml
import "simics/devs/memory-space.dml";
connect f2_mem is map_target { … }
/* F2 master traffic = f2_mem.write_bytes / read_bytes — not AXI channel beats */
```

## Architecture layers

Runtime object path (typical):

```text
system.board.fpga.hps.{apu|lsp|hsp}
system.board.fpga.{noc|public_noc|sdm|…}
```

### Component hierarchy

| Layer | Class | Package path |
|-------|-------|--------------|
| System | `km_universal_system_comp` | `platforms/agilex27-universal/modules/km-universal-system-comp/` |
| Board | `km_universal_board_comp` | `…/km-universal-board-comp/` |
| FPGA | `km_universal_fpga_comp` | `…/km-universal-fpga-comp/` |
| HPS | `km_hps_comp` | `simmod/km_hps_comp/` |
| HSP | `km_hsp_comp` | `simmod/km_hsp_comp/` |
| LSP | `km_lsp_comp` | `simmod/km_lsp_comp/` |
| Chip NOC | `km_noc_universal_comp` | `simmod/km_noc_universal_comp/` |
| Bridges | `km_mnoc_bridge`, `km_rnoc_bridge` | DML `.so` |

### CPU → HPS peripherals

```text
APU cores
  → apu.phys_mem / cpu_mem
  → apu.aps.ccu_noc          (km_ccu / km-ccu-noc)
  → lsp.noc  and/or  hsp.noc
  → device bank (regs / sdmmc_bank / xhci_regs / …)
```

HSP ↔ LSP ↔ CCU cross-links are wired in `km_hps_comp.post_instantiate` (NOC `noc_targets` ↔ `initiators`).

### CPU → fabric / DRAM (chip-level)

Wired in `km_universal_fpga_comp.post_instantiate` via TrustZone/SAI translators and MNOC/RNOC bridges.

## Classic H2F / LWH2F / F2H / F2SDRAM ↔ KM names

Classic SM / Agilex names are **not** primary KM object names. Intentional mapping:

| Classic / OSBV name | KM Simics analogue | Where |
|---------------------|--------------------|-------|
| **H2F / soc2fpga** | MNOC `soc2fpga_port` + `fabric_mux_*` stub RAMs | `km_mnoc_bridge`, `km_noc_universal_comp` |
| **LWH2F / lwsoc2fpga** | RNOC `fabric_lwsoc2fpga_target_*` + HSP `rnoc_lwsoc2noc` | `km_rnoc_bridge`, `km_hsp_noc` |
| **F2H / f2soc** | MNOC → HPS (`hps_input`, fabric→HPS) | `km_mnoc_bridge` |
| **F2SDRAM** | MNOC `sdram_port` + SDRAM stub RAMs; APU SAR paths | `km_mnoc_bridge`, `apu_sysmgr.sar_to_mnoc` |

SOCAL window examples (`socal/km_hps/.../km_hps.h`):

| Window | Offset |
|--------|--------|
| lwsoc2fpga 512 MiB | `0x2000_0000` |
| fabric_mux_0 (soc2fpga stub) | `0x4000_0000` |
| SDRAM 2 GiB | `0x8000_0000` |
| lwsoc2fpga 3 GiB | `0x1_0000_0000` |

**OSBV VSIP note:** board hooks for memsrc/memsink append maps onto `fpga.hps.apu.phys_mem` and point memsrc’s F2 master at that same space — a **functional short-circuit**, not traffic through `mnoc_bridge.soc2fpga_port` stub RAMs.

## How devices attach

### Slaves (CSR) — NOC `noc_targets`

**LSP** examples: `dma0`/`dma1` → DMAC regs; `sdmmc0/1`; `ospi0` + `ospi_sdma0`; UART/I2C/I3C/SPI/GPIO/…  

**HSP** examples:

| Target | Default bank |
|--------|----------------|
| `usb31` | `usb31.host.bank.xhci_regs` (host / xHCI) |
| `usb_otg` | `usb_otg.bank.regs` |
| `tsn0..2` | TSN CSR |

### Masters (DMA) — NOC `initiators` (+ SMMU)

DMAC, SDMMC, OSPI, USB31, USB OTG, TSN attach via `address_space` / `dma_master` / `phys_mem` / `host_mem` → LSP/HSP initiator ports, then often `smmu_mem_space[]` (`km_hps_smmu_700`).

### OSBV VSIP models (this repo)

| Model | Slave | Master / target window |
|-------|-------|------------------------|
| `vsip_memsrc` | MMIO @ `0xF900_0000` | F2 → `f2_mem` `map_target` (wired to `apu.phys_mem`) |
| `vsip_memsink` | ctl @ `0xF904_0000` | H2F-style compare tgt @ `0xC000_0000` |

Board wiring: `vsip-*/board_hooks.py` + `patches/0001-…` / `0002-…`.

## USB31 host vs device (AXI CSR mapping pitfall)

HSP hard-wires:

```text
noc.noc_targets.usb31 → usb31.host.bank.xhci_regs
```

`host_mode=FALSE` only remaps CSR when `regs_size > 0`. KM uses **NOC-managed** `regs_size=0`, so gadget mode needs an explicit NOC retarget:

`km-hps-files/scripts/km_usb31_device_mode.py`  
(used by `boot-to-osbv-smp-usb31-device.simics`)

```text
noc.noc_targets.usb31 → usb31.device.bank.regs   # xDCI
```

Guest still needs `osvloaddtoverlay km-usb31-gadget` (+ rebind/reboot).

## Address map cheatsheet (OSBV / KM)

| Resource | Address | Notes |
|----------|---------|-------|
| USB31 DWC3 | `0x0D00_0000` | DT `usb31@d000000` |
| USB2 DWC2 | `0x0D10_0000` | DT `usb@d100000` |
| HPS OSPI (xSPI) | `0x0900_8000` | SDMA window often `0x0400_0000` |
| VSIP memsrc | `0xF900_0000` | +256 KiB |
| VSIP memsink ctl | `0xF904_0000` | |
| VSIP memsink tgt | `0xC000_0000` | +16 KiB compare window |
| lwsoc2fpga | `0x2000_0000` | RNOC stub |
| soc2fpga mux0 | `0x4000_0000` | MNOC stub |
| DRAM | `0x8000_0000` | |

## Accuracy vs gaps

**Good enough for OSBV:** peripheral bases/CSRs; master→memory via NOC+SMMU; fabric **windows** as decode stubs; xSPI SDMA INCR-only host addressing; USB host MSC topology.

**Abstracted:** no channel-accurate AXI; MNOC/RNOC fabric targets mostly RAM stubs; VSIP often bypasses fabric onto `phys_mem`; timing/QoS thin.

**Known gaps:** USB31 `host_mode` without NOC retarget; USB2 gadget host-only (`GHWCFG2.OtgMode`); SDM xSPI firewall; SPI DMA peri HS; full F2SDRAM/F2SOC suites need VSIP + fabric bring-up (see `test_configs/km/SIMICS_APPLICABILITY.md`).

## Key sources

| Area | Path |
|------|------|
| FPGA wiring | `platforms/agilex27-universal/modules/km-universal-fpga-comp/` |
| HPS / HSP / LSP | `simmod/km_{hps,hsp,lsp}_comp/` |
| NOC / bridges | `km-{hsp,lsp,public}-noc.so`, `km-{mnoc,rnoc}-bridge.so` |
| VSIP OSBV | this repo `vsip-memsrc/`, `vsip-memsink/` |
| USB31 device boot | `km-hps-files/scripts/km_usb31_device_mode.py` |
| Applicability | `fpga-sut-hps-git/.../test_configs/km/SIMICS_APPLICABILITY.md` |
| SOCAL | `socal/km_hps/gen/include/C/km_hps.h` |
