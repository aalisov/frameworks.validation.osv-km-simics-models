# frameworks.validation.osv-km-simics-models

Standalone Simics 7 device models for Kinneloa Mesa (`agilex72-universal`) OSBV / emul validation.

| Module | Description |
|--------|-------------|
| `vsip-memsrc/` | VSIP memory traffic generator (mem_source functional model). CPU MMIO @ `0xF9000000` (control / vectors / errors). |
| `p3t1755/` | NXP P3T1755 I3C temperature sensor (OSBV `i3cdev` / DT `236152A0090`). |

Validated with supersmasher `sample-vsip-memsrc-km.cfg` → **PASS** on KM OSBV Simics (SMP+SVE).

## Use in km-hps

```bash
cd ~/km-hps
source ./set_simics_env_main.sh
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/vsip-memsrc modules/vsip-memsrc
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/p3t1755 modules/p3t1755
make
```

### Board integration (required for VSIP PASS)

`km-universal-board-comp` must:

1. Map VSIP MMIO into `fpga.hps.apu.phys_mem` at `0xF9000000` (256 KiB).
2. Wire the device F2 master to **`phys_mem`** (same PA space as CPU DRAM), not a private stub RAM:

```python
vsip_memsrc_0.dev.f2_mem = fpga.hps.apu.phys_mem
```

Without (2), supersmasher reports `rvalid=0` / transaction errors because vector addresses (e.g. `0xf0000000`) miss the stub.

### Model details (vsip-memsrc)

- Nested `mmio` banks use **relative** offsets `0 / 0x10000 / 0x20000` (phys_mem maps the window at base).
- `num_loops` is honored for finite runs; `CONF_LOOP` means infinite.
- Perf counters: one AW/AR per burst, one W/R per beat; cleared each RUN.

## OSBV device tree / DRAM carveout

VSIP nodes come from Yocto `km-simics-dtbo` overlays (not base DTB):

```bash
osvloaddtoverlay km-simics-vsip
# DRAM for vecscripts (boot with mem=1792M):
modprobe HWAPIMod
allocate_mem_targets -s 0xf0000000 -e 0xf2000000
cd /usr/share/supersmasher
supersmasher -c sample-vsip-memsrc-km.cfg
```

Do **not** use SM `allocate_mem_targets -A` (`0xbc800000`) on KM.

## License

CLOSED / internal validation models unless otherwise noted.
