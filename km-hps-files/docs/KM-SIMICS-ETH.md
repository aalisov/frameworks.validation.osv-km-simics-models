# KM Simics Ethernet + host SSH (NAPT / port publish)

Canonical copy: see repository `docs/KM-SIMICS-ETH.md` (installed next to
this file under `~/km-hps/docs/` by `setup-into-simics-project.sh`).

## Quick host path

```bash
source ./scripts/host/km-simics-ssh-publish.sh --instance 0 --auto --firewall
./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE
# guest: setup-simics-eth.sh
# remote: ssh -p 4022 root@$HOST_BIND_IP
./scripts/host/km-simics-instances.sh status
```

Marvell PHY model AN/`mmd_default` fix: see full `docs/KM-SIMICS-ETH.md` and
`patches/0001-marvell_phy-an-stub-and-mmd_default-c22-forward.patch` (lives in
`applications.simulators.fpga.simics` working tree; symlink under
`~/km-hps/modules/marvell_phy`).
