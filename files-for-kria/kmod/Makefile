# Out-of-tree build of the IMX519 sensor driver for the Kria KV260.
# Neither mainline nor linux-xlnx ships imx519.c; this pulls the
# raspberrypi/linux copy and patches it to build against a Xilinx kernel.
obj-m := imx519.o
ccflags-y += -include $(src)/compat.h

KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)

all: imx519.c
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install: all
	sudo $(MAKE) -C $(KDIR) M=$(PWD) modules_install
	sudo depmod -a

clean:
	@ $(MAKE) -C $(KDIR) M=$(PWD) clean
