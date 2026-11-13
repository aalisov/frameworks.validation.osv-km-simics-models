# KM Simics — intel-fpga-main (default)

> **Source of truth:** this file and scripts are installed from
> [frameworks.validation.osv-km-simics-models](https://github.com/aalisov/frameworks.validation.osv-km-simics-models)
> via `./setup-into-simics-project.sh`. Yocto only collects/publishes boot binaries.


**Target:** `intel-fpga-main` + `km_hps_dsu_120`. Default boot: **SMP on + SVE on** (`maxcpus=4`, no `arm64.nosve`).

26.3 (`intel-fpga-ext`, nosmp) scripts are archived under `scripts/legacy-26.3/` — roll back Yocto/framework git commit if you need the old active tree.

## Quick start

```bash
# One-time: install scripts + models from this repo
./setup-into-simics-project.sh -p ~/km-hps --force

cd ~/km-hps
source ./set_simics_env_main.sh

# Stage from HTTP/NFS share (or local collect path)
./scripts/stage-artifact.sh osbv --from http://alisubun1.sj.altera.com/osbv-yo/KM --date 2026-11-12
./scripts/stage-artifact.sh osbv --from http://alisubun1.sj.altera.com/osbv-yo/KM --date latest
# or direct drop URL (date+flavor already in path):
# ./scripts/stage-artifact.sh osbv --from http://alisubun1.sj.altera.com/osbv-yo/KM/2026-11-12/osbv_sdmmc/
./scripts/stage-artifact.sh emul --from /var/www/html/osbv-yo/KM --date latest
# Same-host collect still works:
# ./scripts/stage-artifact.sh osbv --deploy ~/WORK/KM/yocto/build/collected-binaries/osbv_sdmmc

./scripts/run-osbv-smp.sh
./scripts/run-emul-smp.sh
telnet 127.0.0.1 9123

# USB3.1 gadget experiment (no host-port mass-storage; xDCI mapped):
./scripts/run-osbv-smp-usb31-device.sh
# guest: osvloaddtoverlay km-usb31-gadget && km-usb31-gadget-check.sh
# (USB2 DWC2 overlay remains km-usb-gadget — different name)

# Eth + SSH via host NIC (NAPT port-in — docs/KM-SIMICS-ETH.md):
source ./scripts/host/km-simics-ssh-publish.sh --auto --firewall
./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE
# guest: setup-simics-eth.sh
# remote: ssh -p 4022 root@$HOST_LAN_HINT
# status: ./scripts/host/km-simics-instances.sh status
# one-shot: KM_SIMICS_PUBLISH_SSH=1 KM_SIMICS_SSH_FIREWALL=1 ./scripts/run-osbv-smp-usb31-device.sh

# Variant S — same device boot + USBIP bridge hook (needs model; see docs/KM-SIMICS-USBIP.md):
./scripts/run-osbv-smp-usb31-usbip.sh
# guest: overlay + km-usb-gadget-setup.sh (no usbipd)
# host:  ./scripts/host/km-usbip-attach.sh   # after bridge listens on :3240

# VUDC → USBIP → host VHCI (SW path; no usb31 / no bridge model):
#   docs/KM-SIMICS-USBIP-VUDC.md
./scripts/run-osbv-smp.sh create_hps_eth0_network=TRUE uboot_menu=2
# guest: setup-simics-eth.sh; modprobe usbip-vudc; km-usb-gadget-setup.sh; usbipd -e -D
# host:  sudo usbip attach -r 127.0.0.1 -d usbip-vudc.0

# U-Boot console test suite plan (I2C/I3C/SPI/MMC/USB/MMIO/FDT + secondary CPU):
#   docs/KM-UBOOT-CONSOLE-TEST-PLAN.md
# ./scripts/run-osbv-smp.sh stop_at_uboot=TRUE
```


## Split-host artifacts (HTTP / NFS)

Yocto build host and Simics host may differ. Publish writes only to a **local or NFS-mounted** path; Simics pulls via HTTP or NFS.

**Build host:**

```bash
./scripts/artifacts/collect-km-artifacts.sh both
./scripts/artifacts/publish-km-artifacts.sh both \
  --dest /var/www/html/osbv-yo/KM --latest
```

**Simics host:**

```bash
./scripts/stage-artifact.sh osbv \
  --from http://alisubun1.sj.altera.com/osbv-yo/KM --date latest
# or: --from http://alisubun1.sj.altera.com/osbv-yo/KM/2026-11-12/osbv_sdmmc/
./scripts/stage-artifact.sh emul \
  --from /var/www/html/osbv-yo/KM --date 2026-11-12
source ./set_simics_env_main.sh && ./scripts/run-osbv-smp.sh
```


Build host collect/publish: Yocto `scripts/artifacts/`. Simics scripts: this models repo.

## Expect

| Target | CPUs | SVE in `/proc/cpuinfo` | Shell |
|--------|------|------------------------|-------|
| **osbv** | 4 | yes | WIC rootfs |
| **emul** | 4 | yes | `KM emul init OK` (~8 MiB SVE initrd) |

## Emul options (main only)

| Env | Effect |
|-----|--------|
| *(default)* | `maxcpus=4`, SVE userspace |
| `EMUL_NOSMP=1` | `nosmp` instead of `maxcpus=4` |
| `EMUL_NOSVE=1` | `arm64.nosve` — needs **~14 MiB nosve** initrd |
| `EMUL_NOSMP=1 EMUL_NOSVE=1` | 26.3-like on main (1 CPU, nosve) |

```bash
EMUL_NOSMP=1 ./scripts/run-emul-smp.sh
EMUL_NOSVE=1 ./scripts/run-emul-smp.sh   # restore 14MiB initrd first
```

## Staging

`stage-artifact.sh` copies SPL, FIT, Image, initrd/WIC from `collected-binaries/`. Emul initrd from collect is auto-patched (`/init` shebang + `/dev`).

**Emul FIT:** Yocto default `ATF_SVE_DEFAULT:km_emul = "sve"`. If FIT still embeds nosve:

```bash
# local.conf
ATF_SVE_DEFAULT:km_emul = "sve"

bitbake mc:km_emul:u-boot-socfpga
# recollect emul, restage, run
```

Or: `USE_HAMZA_ITB=1 ./scripts/stage-artifact.sh emul` (whole FIT copy — do not mkimage-repack).

**OSBV** FIT already embeds `bl31-sve` when built with default `ATF_SVE_DEFAULT:km_osbv_sdmmc=sve`.

## vs 26.3 (legacy / archived)

| | 26.3 ext | **main (default)** |
|--|----------|-------------------|
| Env | `scripts/legacy-26.3/set_simics_env.sh` | `set_simics_env_main.sh` |
| Scripts | `scripts/legacy-26.3/run-*-sve.sh` | `run-emul-smp.sh`, `run-osbv-smp.sh` |
| SMP | `nosmp` | `maxcpus=4` |
| DSU | stub PPU | real PPU + cluster poke |

## Scripts

| Script | Role |
|--------|------|
| `set_simics_env_main.sh` | main packages + launcher |
| `stage-artifact.sh` | collect/fetch → `images/{emul,osbv}` |
| `fetch-km-artifacts.sh` | HTTP/NFS pull into `~/km-hps/cache/KM/` |
| `scripts/artifacts/collect-km-artifacts.sh` | curated collect from Yocto deploy |
| `scripts/artifacts/publish-km-artifacts.sh` | publish to local/NFS share |
| `run-emul-smp.sh` / `run-emul.sh` | emul ramdisk boot |
| `run-osbv-smp.sh` / `run-osbv.sh` | osbv WIC boot |
| `run-osbv-smp-usb31-device.sh` | osbv + USB31 device; eth NAPT when `create_hps_eth0_network=TRUE` |
| `host/km-simics-ssh-publish.sh` | bind SSH port-in to host NIC (`--auto` / `--iface`) |
| `host/km-simics-instances.sh` | list live instances / SSH+telnet ports |
| `km_simics_eth_host_fwd.py` | Simics NAPT + `connect-real-network-port-in` for SSH |
| `km_ospi_combophy_deassert.py` | OSBV: deassert `ospi_combophy0` before `booti` (Cadence xSPI aux/PHY) |
| `run-km-generic-main.sh` | Hamza-style `km_generic.simics` |
| `BASELINE.main-smp.manifest` | fingerprints |
| `docs/KM-SIMICS-ETH.md` | guest eth + host SSH publish |

Do **not** `mkimage`/`/incbin/`-repack `u-boot.itb`.
