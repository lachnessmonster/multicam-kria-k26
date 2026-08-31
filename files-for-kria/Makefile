obj-m := imx519.o imx708.o
ccflags-y += -include $(src)/compat.h

KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)

all: imx519.c imx708.c
	$(MAKE) -C $(KDIR) M=$(PWD)/software modules

install: all
	sudo $(MAKE) -C $(KDIR) M=$(PWD)/software modules_install
	sudo depmod -a

clean:
	@ $(MAKE) -C $(KDIR) M=$(PWD) clean
