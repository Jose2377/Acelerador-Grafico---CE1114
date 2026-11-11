# Buildroot (paquete gpu2d-driver) o scripts/04-compilar-modulo.sh llaman
# a este Makefile con KERNELDIR, ARCH y CROSS_COMPILE ya definidos.
ifneq ($(KERNELRELEASE),)
obj-m := gpu2d.o
else
KERNELDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KERNELDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(CURDIR) clean
endif
