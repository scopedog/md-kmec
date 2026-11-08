# Out-of-tree build of dm-log-writes-ord for the running kernel:
#   make            -> dm-log-writes-ord.ko
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
