# KM artifact collect / publish (build host)

Mirrored here so the Simics-models kit carries the full share pipeline.
Canonical Yocto tree copy: `frameworks.validation.osv-yocto` → `scripts/artifacts/`.

```
bitbake → collect-km-artifacts → publish-km-artifacts (--dest local or NFS)
                                      ↓
                         osbv-yo/KM/YYYY-MM-DD/{emul,osbv_sdmmc}/
                                      ↓
         (Simics host) stage-artifact --from → run-*-smp
```

## Build host

```bash
# From this repo (after clone), or from the Yocto framework copy:
./km-hps-files/scripts/artifacts/collect-km-artifacts.sh both \
  --collect-root "$HOME/WORK/KM/yocto/build/collected-binaries"

./km-hps-files/scripts/artifacts/publish-km-artifacts.sh both \
  --dest /DISK1/nfs/webdata/osbv-yo/KM --latest \
  --collect-root "$HOME/WORK/KM/yocto/build/collected-binaries"
```

Publish writes only to a **local or NFS-mounted** directory (no SSH/HTTP upload).
Use `--latest` so HTTP clients can resolve `latest` (or stage with an explicit `--date`).

## Simics host

```bash
./scripts/stage-artifact.sh osbv \
  --from http://alisubun1.sj.altera.com/osbv-yo/KM --date latest
# or direct drop:
# --from http://alisubun1.sj.altera.com/osbv-yo/KM/2026-11-12/osbv_sdmmc/
./scripts/run-osbv-smp.sh
```

`fetch-km-artifacts.sh` also lives under `../` (Simics stage path) and in this
directory (same script).

## Allowlists

Curated in `collect-km-artifacts.sh` for Simics boot (Image, FIT, SPL, DTB, initrd/WIC, bl31*).
Collect fails if required files are missing.
