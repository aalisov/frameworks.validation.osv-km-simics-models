# Host-side U-Boot script snippets (legacy / paste mode)

The **default gate** does **not** paste these files. It loads the mkimage
scripts already on the SDMMC FAT partition:

```text
fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<name>.scr
source ${scriptaddr}
```

On current osbv images, `KM-TESTS/` contains:

| FAT file   | Marker on success      |
|------------|------------------------|
| `fdt.scr`  | `KM_TEST: fdt PASS`    |
| `i2c.scr`  | `KM_TEST: i2c PASS`    |
| `i3c.scr`  | `KM_TEST: i3c PASS`    |
| `usb.scr`  | `KM_TEST: usb PASS`    |
| `eth.scr`  | `KM_TEST: eth PASS`    |
| `spi.scr`  | `KM_TEST: spi PASS`    |

Plan name `dt.scr` maps to image `fdt.scr`.

These plain-text files are only used when `KM_CI_UBOOT_SCR_MODE=paste`.
