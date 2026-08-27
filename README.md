# frameworks.validation.osv-km-simics-models

Standalone Simics 7 device models for Kinneloa Mesa (`agilex72-universal`) OSBV / emul validation.

| Module | Description |
|--------|-------------|
| `vsip-memsrc/` | VSIP memory traffic generator (mem_source functional model). CPU MMIO @ `0xF9000000`. |
| `p3t1755/` | NXP P3T1755 I3C temperature sensor (OSBV `i3cdev` / DT `236152A0090`). |

Each module ships **`board_hooks.py`** — the supported way to instantiate and wire devices onto a KM board component.

Validated with supersmasher `sample-vsip-memsrc-km.cfg` → **PASS** on KM OSBV Simics (SMP+SVE).

## Install into a Simics project (new Simics / fresh km-hps)

```bash
git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
cd frameworks.validation.osv-km-simics-models
./setup-into-simics-project.sh                  # → ~/km-hps by default
# or:
./setup-into-simics-project.sh -p /path/to/simics-project --force
```

The script:

1. Symlinks (or `--copy`) `vsip-memsrc` and `p3t1755` into `PROJECT/modules/`
2. Sources `set_simics_env_main.sh` when present
3. Builds the modules (`make`)

Useful flags: `--force` (replace existing), `--copy`, `--no-build`, `--env-script FILE`.

## Use in km-hps (manual)

```bash
cd ~/km-hps
source ./set_simics_env_main.sh
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/vsip-memsrc modules/vsip-memsrc
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/p3t1755 modules/p3t1755
make
```

### Board integration (via board_hooks)

In `km-universal-board-comp` (or your board):

```python
# add_objects()
from simmod.vsip_memsrc.board_hooks import add_vsip_memsrc
from simmod.p3t1755.board_hooks import add_p3t1755, connect_p3t1755

if self.create_vsip_memsrc.val:
    add_vsip_memsrc(self, base=self.vsip_memsrc_base.val)

add_p3t1755(self)
connect_p3t1755(self, i3c_bus_dev_slot="i3c_bus[0].dev_slot[4]")

# component.post_instantiate()
from simmod.vsip_memsrc.board_hooks import wire_vsip_memsrc

if self._up.create_vsip_memsrc.val:
    wire_vsip_memsrc(self._up, base=self._up.vsip_memsrc_base.val)
```

`wire_vsip_memsrc` does both:

1. Map VSIP MMIO into `fpga.hps.apu.phys_mem` at `0xF9000000` (256 KiB)
2. Route F2 master to the **same** `phys_mem` (required for supersmasher DRAM addresses)

### Model details (vsip-memsrc)

- Nested `mmio` banks use **relative** offsets `0 / 0x10000 / 0x20000`
- `num_loops` honored for finite runs; `CONF_LOOP` = infinite
- Perf counters: one AW/AR per burst, one W/R per beat; cleared each RUN

## OSBV device tree / DRAM carveout

```bash
osvloaddtoverlay km-simics-vsip
modprobe HWAPIMod
allocate_mem_targets -s 0xf0000000 -e 0xf2000000   # needs bootargs mem=1792M
cd /usr/share/supersmasher
supersmasher -c sample-vsip-memsrc-km.cfg
```

Do **not** use SM `allocate_mem_targets -A` (`0xbc800000`) on KM.

## License

CLOSED / internal validation models unless otherwise noted.
