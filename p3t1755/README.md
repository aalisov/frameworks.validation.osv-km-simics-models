# Minimal P3T1755 I3C temperature sensor (KM Simics)

Implements pointer + Temp / Conf / TLOW / THIGH for NXP P3T1755-style access.
Enough for Driver/DT: `I3C_DEVICE(0x11B, 0x152a)` and `sensor@0,236152A0090`.

## Build

```bash
cd ~/km-hps && source ./set_simics_env.sh && make p3t1755 km-universal-board-comp
```

## Board wiring

`km_universal_board_comp` adds `p3t1755_0` on I3C0 `dev_slot[4]`.

## Runtime

```tcl
# change simulated temperature (Celsius, integer)
@conf.system.board.p3t1755_0.target.temperature_c = 40
```

## Not modeled

IBI / alert, conversion timing, one-shot quirks — private SDR/I2C register R/W only.
