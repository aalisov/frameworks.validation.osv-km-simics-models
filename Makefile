# Build KM Simics device models (requires SIMICS_PROJECT with module Makefile rules).
#
#   cd ~/km-hps && source ./set_simics_env_main.sh
#   ln -sf /path/to/km-simics-device-models/vsip-memsrc modules/vsip-memsrc
#   ln -sf /path/to/km-simics-device-models/p3t1755 modules/p3t1755
#   make -C modules/vsip-memsrc && make -C modules/p3t1755

MODULES := vsip-memsrc p3t1755

.PHONY: all clean $(MODULES)

all: $(MODULES)

$(MODULES):
	$(MAKE) -C $@

clean:
	for d in $(MODULES); do $(MAKE) -C $$d clean 2>/dev/null || true; done
