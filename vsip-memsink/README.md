# VSIP mem_sink

Functional Simics model for VSIP **mem_sink** RTL
(`rtls.fpga.validation.hps-vsip-memsink`).

| Region | Address (KM) | Size | Banks |
|--------|--------------|------|-------|
| Control / ref / err | `0xF9040000` | 256 KiB | `+0x0` control, `+0x10000` refdata, `+0x20000` errors |
| H2F target window | `0xC0000000` | 16 KiB | compare vs ref when `CONF_RUN\|CONF_ERROR` |

## Behaviour (matches supersmasher `vsip-memsink-simple-cpu`)

1. Guest writes reference pattern into refdata (`dwcount` dwords).
2. Guest sets `range_l` to target PA and `config |= CONF_RUN|CONF_ERROR`.
3. Guest writes the target window; mismatches log `memsink_error_t` and bump status.
4. Guest clears `CONF_RUN` and checks `status & STAT_ERRCNT_MASK`.

## Board wiring

```python
from simmod.vsip_memsink.board_hooks import add_vsip_memsink, wire_vsip_memsink

# add_objects()
add_vsip_memsink(self)

# post_instantiate()
wire_vsip_memsink(self._up)
```

Or re-run `./setup-into-simics-project.sh -p ~/km-hps --force` after pulling
this module (installs `patches/0002-…-memsink.patch`).

## Guest smoke

```bash
osvloaddtoverlay km-simics-vsip   # or overlay that publishes memsink ctl/tgt
allocate_mem_targets -A           # if other tests need DRAM
supersmasher -c /usr/share/supersmasher/sample-vsip-memsink-km.cfg -t 30
```
