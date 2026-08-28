# KM emul initrd (SVE + nosve)

Two ramdisk images are built from Yocto:

| Deploy artifact | Recipe | Use |
|-----------------|--------|-----|
| `initrd_emul.uboot` | `km-emul-initrd` | SMP+SVE default (`run-emul-smp.sh`) |
| `initrd_emul_nosve.uboot` | `km-emul-initrd-nosve` | `EMUL_NOSVE=1` (`arm64.nosve` bootarg) |

Both use `/init` with `#!/bin/sh`, devtmpfs mount, and `exec /bin/sh`.

## Rebuild

```bash
cd ~/WORK/KM/yocto && source set_build_env0.sh
bitbake mc:km_emul:km-emul-initrd mc:km_emul:km-emul-initrd-nosve
# collect + stage
./setup/workspace/.vscode/collect-km-artifacts.sh emul
~/km-hps/scripts/stage-artifact.sh emul --deploy ~/WORK/KM/yocto/build/collected-binaries/emul --initrd both
```

## Boot

```bash
source ~/km-hps/set_simics_env_main.sh
./scripts/run-emul-smp.sh              # SVE initrd
EMUL_NOSVE=1 ./scripts/run-emul-smp.sh # nosve initrd
```

Legacy `--fix-initrd` in `stage-artifact.sh` only patches old initrds missing a shebang.
