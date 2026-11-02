# KM Simics Ethernet + host SSH (NAPT / port publish)

## What works (2026-11-01)

- Guest eth0 (DT **gmac1** / EMAC1) pings Simics service-node `10.10.0.1`
  after durable Yocto kernel/DT fixes — no manual Register_LE pokes.
- Host SSH: Simics `connect-real-network` + `connect-real-network-port-in`
  maps **host TCP `4022+100*instance` → guest `:22`**.
- LAN laptop example: `ssh -p 4022 root@10.244.133.71` (host NIC `eno3`).

This is **port publishing**, not bridging the guest onto the host L2 LAN.

## Host: publish SSH on a network adapter

```bash
cd ~/km-hps   # after setup-into-simics-project.sh

# Pick default-route NIC, bind its IPv4, open firewall (optional)
source ./scripts/host/km-simics-ssh-publish.sh --instance 0 --auto --firewall

# Or explicit NIC:
# source ./scripts/host/km-simics-ssh-publish.sh --instance 0 --iface eno3 --firewall

./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE
# status: ./scripts/host/km-simics-instances.sh status
```

| Env / flag | Meaning |
|------------|---------|
| `--instance N` | `HOST_SSH_PORT=4022+100*N`, `TELNET_PORT=9123+N` |
| `--auto` | Use IPv4 default-route interface as `--iface` |
| `--iface IF` | Bind/advertise that NIC’s IPv4 as `HOST_BIND_IP` |
| `--firewall` | Open `HOST_SSH_PORT/tcp` (firewalld/ufw/iptables) |
| `GUEST_ETH_IP` | Always `10.10.0.100` per private Simics LAN (default) |

`km_simics_eth_host_fwd.py` (loaded from the boot `.simics` when
`create_hps_eth0_network=TRUE`) enables real-time mode, NAPT, and the
SSH port-in using those env vars.

## Guest (after Linux login)

```bash
setup-simics-eth.sh
# or: ip link set eth0 up; ip addr add 10.10.0.100/24 dev eth0; ping -c1 10.10.0.1
```

Yocto details / patches: `osv-yocto` →
`recipes-kernel/linux/files/README.KM-ETH.md` and
`recipes-content/km-pve-hps-content/docs/KM-SIMICS-ETH.md`.

## Marvell PHY model (`board.phy1`)

Stock `marvell_phy` left **auto-neg unimplemented** and **`mmd_default` C22**
as spec-viol zeros (Linux marvell/stmmac MDIO stalls). Local fix (still in
working tree of `applications.simulators.fpga.simics`, not the Yocto push):

| Change | Effect |
|--------|--------|
| AN stub on `an_restart` | Complete as **1000/full**, `link_up()` |
| `mmd_default` C22 → `mmd_phy` | Forward page≠copper MII instead of zero/spec-viol |
| Quiet MDIO45 stubs | Less log spam on unimplemented MMDs |

- Live tree: `~/simics_git/applications.simulators.fpga.simics/.../marvell_phy/`
- `~/km-hps/modules/marvell_phy` → symlink to that tree; rebuild with `make marvell_phy`
- Patch export: `patches/0001-marvell_phy-an-stub-and-mmd_default-c22-forward.patch`

Durable MAC/DT fixes alone are not enough if MDIO/AN still hangs the PHY path.

## Avoid

- Guest: `ethtool`, `ip link set eth0 down`, casual `ip route add` (wedge history)
- Assuming guest gets a DHCP address on the host LAN (it does not, with this path)
