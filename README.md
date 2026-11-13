# frameworks.validation.osv-km-simics-models

Standalone Simics 7 device models for Kinneloa Mesa (`agilex72-universal`) OSBV / emul validation.

**Interconnect / AXI modeling:** see [`docs/KM-SIMICS-AXI.md`](docs/KM-SIMICS-AXI.md)
(memory-mapped NOC graph — not wire-level AXI4 channels).

**USB31 gadget Phase 4 (Variant S USBIP):** see [`docs/KM-SIMICS-USBIP.md`](docs/KM-SIMICS-USBIP.md)
— `./scripts/run-osbv-smp-usb31-usbip.sh` + host `scripts/host/km-usbip-attach.sh`
(bridge **model** still a product dependency).

**Ethernet + SSH via host NIC (NAPT port-in):** see [`docs/KM-SIMICS-ETH.md`](docs/KM-SIMICS-ETH.md)
— `source scripts/host/km-simics-ssh-publish.sh --auto --firewall` then
`run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE`; guest `setup-simics-eth.sh`.

| Module | Description |
|--------|-------------|
| `vsip-memsrc/` | VSIP memory traffic generator (mem_source functional model). CPU MMIO @ `0xF9000000`. |
| `vsip-memsink/` | VSIP memory traffic checker (mem_sink). Control @ `0xF9040000`, H2F tgt @ `0xC0000000`. |
| `p3t1755/` | NXP P3T1755 I3C temperature sensor (OSBV `i3cdev` / DT `236152A0090`). |

Each module ships **`board_hooks.py`** — the supported way to instantiate and wire devices onto a KM board component.

Validated with supersmasher `sample-vsip-memsrc-km.cfg` → **PASS** on KM OSBV Simics (SMP+SVE).

## Install into a Simics project (new Simics / fresh km-hps)

This repo is the **Simics-host kit**: device models **and** mainline km-hps scripts
(`stage-artifact`, `run-*-smp`, `fetch-km-artifacts`, `set_simics_env_main.sh`, …).

Boot binaries stay on the HTTP/NFS share (published from Yocto `scripts/artifacts/`).

```bash
git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
cd frameworks.validation.osv-km-simics-models
./setup-into-simics-project.sh -p ~/km-hps --force
```

The script:

1. Copies `km-hps-files/` → project root + `scripts/` (env, stage, run, fetch)
2. Symlinks (or `--copy`) `vsip-memsrc`, `vsip-memsink`, and `p3t1755` into `PROJECT/modules/`
3. Sources `set_simics_env_main.sh` and builds the modules (`make`)

Useful flags: `--force`, `--copy`, `--no-build`, `--scripts-only`, `--models-only`, `--env-script FILE`.

### Stage + run after install

```bash
cd ~/km-hps && source ./set_simics_env_main.sh
./scripts/stage-artifact.sh osbv --from http://alisubun1.sj.altera.com/osbv-yo/KM --date latest
./scripts/run-osbv-smp.sh
telnet 127.0.0.1 9123
```

Build-host **collect/publish** scripts are also in this repo:
`km-hps-files/scripts/artifacts/{collect,publish}-km-artifacts.sh`.

See `km-hps-files/scripts/README.main-smp.md` for SMP/SVE details.

## Use in km-hps (manual)

```bash
cd ~/km-hps
source ./set_simics_env_main.sh
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/vsip-memsrc modules/vsip-memsrc
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/vsip-memsink modules/vsip-memsink
ln -sfn /path/to/frameworks.validation.osv-km-simics-models/p3t1755 modules/p3t1755
make
```

### Board integration (automatic)

`./setup-into-simics-project.sh -p ~/km-hps --force` imports
`km-universal-board-comp` from `$SIMICS_FPGA_ROOT/platforms/agilex72-universal/modules/`
and applies `patches/0001-…-VSIP-P3T1755.patch` plus `patches/0002-…-memsink.patch` so the board:

1. Instantiates `vsip_memsrc_0` (`create_vsip_memsrc=True`)
2. Maps memsrc MMIO at `0xF9000000` and routes F2 → `hps.apu.phys_mem`
3. Instantiates `vsip_memsink_0` (ctl `0xF9040000`, tgt `0xC0000000`)
4. Adds `p3t1755_0` on I3C0

Without that board rebuild, `SIM_object_iterator` shows no `vsip*` objects and
supersmasher reports 0% efficiency.

Manual equivalent (if you already imported the board module):

```python
# add_objects()
from simmod.vsip_memsrc.board_hooks import add_vsip_memsrc
from simmod.vsip_memsink.board_hooks import add_vsip_memsink
from simmod.p3t1755.board_hooks import add_p3t1755, connect_p3t1755

if self.create_vsip_memsrc.val:
    add_vsip_memsrc(self, base=self.vsip_memsrc_base.val)
if self.create_vsip_memsink.val:
    add_vsip_memsink(self)

add_p3t1755(self)
connect_p3t1755(self, i3c_bus_dev_slot="i3c_bus[0].dev_slot[4]")

# component.post_instantiate()
from simmod.vsip_memsrc.board_hooks import wire_vsip_memsrc
from simmod.vsip_memsink.board_hooks import wire_vsip_memsink

if self._up.create_vsip_memsrc.val:
    wire_vsip_memsrc(self._up, base=self._up.vsip_memsrc_base.val)
if self._up.create_vsip_memsink.val:
    wire_vsip_memsink(self._up)
```

`wire_vsip_memsrc` does both:

1. Map VSIP MMIO into `fpga.hps.apu.phys_mem` at `0xF9000000` (256 KiB)
2. Route F2 master to the **same** `phys_mem` (required for supersmasher DRAM addresses)

`wire_vsip_memsink` maps control MMIO (`0xF9040000`, 256 KiB) and the H2F
target window (`0xC0000000`, 16 KiB) into the same `phys_mem`.

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
supersmasher -c sample-vsip-memsink-km.cfg -t 30
```

Do **not** use SM `allocate_mem_targets -A` (`0xbc800000`) on KM for memsrc DRAM carveouts;
DMA/stress cases that need g0/g1 DRAM still use `allocate_mem_targets -A` on KM.

## License

CLOSED / internal validation models unless otherwise noted.
