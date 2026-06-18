KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# md-kmec depends on isal_lib.ko's exported symbols. Point MDRAID_BUILD at a
# built mdraid tree (https://github.com/scopedog/mdraid) to pick up
# its isa-l/Module.symvers; default looks for a sibling checkout.
MDRAID_BUILD ?= $(CURDIR)/../mdraid

EXTRA_SYMS :=
ifneq ($(wildcard $(MDRAID_BUILD)/Module.symvers),)
EXTRA_SYMS := $(MDRAID_BUILD)/Module.symvers
endif

# Build target selects the md ABI/compat the sources are built against:
#   rhel10  - RHEL 10.2 builtin md core (struct mddev 2080); md headers from
#             the mdraid fork; compat/compat-rhel10.h.
#   vanilla - mainline / Debian 6.12 md core (struct mddev 2336); vendored
#             md-vanilla/ headers; compat/compat-vanilla.h.
# Auto-detected from the kernel release (".el" => RHEL); override with TARGET=.
TARGET ?= $(if $(findstring .el,$(KVER)),rhel10,vanilla)

ifeq ($(TARGET),vanilla)
COMPAT_HDR := $(CURDIR)/compat/compat-vanilla.h
MD_HDRS    := $(CURDIR)/md-vanilla
else
COMPAT_HDR := $(CURDIR)/compat/compat-rhel10.h
MD_HDRS    := $(MDRAID_BUILD)/md
endif

# Override to point the struct-mddev ABI check at a target kernel's BTF/vmlinux
# (default: the running kernel's /sys/kernel/btf/vmlinux).
BTF_VMLINUX ?=

all: md isa-l abi-check
	@echo "raidkm: building for TARGET=$(TARGET) (compat=$(notdir $(COMPAT_HDR)))"
	$(MAKE) -C $(KDIR) M=$(CURDIR) \
		EXTRA_CFLAGS="-include $(COMPAT_HDR)" \
		KBUILD_EXTRA_SYMBOLS="$(EXTRA_SYMS)" \
		KBUILD_MODPOST_WARN=1 modules

# Verify the builtin kernel's struct mddev layout matches what raidkm.ko is
# compiled against (BTF-based). Fails the build only on a confirmed mismatch;
# skips with a warning if pahole / kernel BTF is unavailable. Pairs with the
# BUILD_BUG_ON in km/raid_km.c (which locks the fork's md.h side).
abi-check:
	@BTF_VMLINUX="$(BTF_VMLINUX)" bash $(CURDIR)/tools/check-mddev-abi.sh $(KVER)

# kmec_main.c includes "../md/md.h" and "../isa-l/isa-l_ec.h";
# symlink mdraid's source dirs into our tree so the relative paths resolve.
md:
	@if [ ! -d "$(MD_HDRS)" ]; then \
		echo "error: md headers $(MD_HDRS) not found (TARGET=$(TARGET));"; \
		echo "       rhel10 needs a built mdraid tree (set MDRAID_BUILD); vanilla uses md-vanilla/"; \
		exit 1; \
	fi
	ln -sfn $(MD_HDRS) md

isa-l:
	@if [ ! -d "$(MDRAID_BUILD)/isa-l" ]; then \
		echo "error: $(MDRAID_BUILD)/isa-l not found — set MDRAID_BUILD to a built mdraid tree"; \
		exit 1; \
	fi
	ln -sfn $(MDRAID_BUILD)/isa-l isa-l

clean:
	-rm -f md isa-l
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
	depmod -a

.PHONY: all clean install abi-check
