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
#   rhel10     - RHEL 10 builtin md core (struct mddev 2080); md headers from
#                the mdraid fork; compat/compat-rhel10.h.
#   rhel9      - RHEL 9.7 builtin md core (5.14-el9, carries the 6.12-era md
#                backport: md_submodule + bitmap_ops + queue_limits); vendored
#                md-rhel9/ headers; compat/compat-rhel9.h.
#                On a .el9_8 kernel (RHEL 9.8): md-rhel98/ +
#                compat/compat-rhel98.h (9.8 moved struct mddev, renamed the
#                bitmap write ops and recovery_cp).
#   rhel98     - the RHEL 9.8 headers; detected from ".el9_8", or forced for
#                a 9.8-based kernel whose release does not say so (CentOS
#                Stream 9, a local build).
#   ubuntu2604 - Ubuntu 26.04 / kernel 7.0 builtin md core (struct mddev
#                1936); vendored md-ubuntu2604/ headers (stock 7.0.0-43);
#                compat/compat-ubuntu2604.h.
#   vanilla    - mainline / Debian 6.12 md core (struct mddev 2336); vendored
#                md-vanilla/ headers; compat/compat-vanilla.h.
# Detection is tools/detect-target.sh (the one map shared with the umbrella
# Makefile and check-mddev-abi.sh); override with TARGET=.
ifeq ($(origin TARGET),undefined)
TARGET := $(shell $(CURDIR)/tools/detect-target.sh $(KVER))
endif

ifeq ($(TARGET),vanilla)
COMPAT_HDR := $(CURDIR)/compat/compat-vanilla.h
MD_HDRS    := $(CURDIR)/md-vanilla
ABI_TARGET := vanilla
else ifeq ($(TARGET),rhel98)
COMPAT_HDR := $(CURDIR)/compat/compat-rhel98.h
MD_HDRS    := $(CURDIR)/md-rhel98
ABI_TARGET := rhel98
else ifeq ($(TARGET),rhel9)
# 9.8 changed md core's own layout (md-rhel98/README): its exact headers
# and shim, picked by the kernel release so a caller's TARGET=rhel9
# stays right for both (TARGET=rhel98 forces them)
ifneq ($(findstring .el9_8,$(KVER)),)
COMPAT_HDR := $(CURDIR)/compat/compat-rhel98.h
MD_HDRS    := $(CURDIR)/md-rhel98
ABI_TARGET := rhel98
else
COMPAT_HDR := $(CURDIR)/compat/compat-rhel9.h
MD_HDRS    := $(CURDIR)/md-rhel9
ABI_TARGET := rhel9
endif
else ifeq ($(TARGET),ubuntu2604)
# Ubuntu builds md core into vmlinux, so raidkm compiles against the stock
# 7.0 headers (md-ubuntu2604/README), never the fork's patched md/.
COMPAT_HDR := $(CURDIR)/compat/compat-ubuntu2604.h
MD_HDRS    := $(CURDIR)/md-ubuntu2604
ABI_TARGET := ubuntu2604
else ifeq ($(TARGET),rhel10)
COMPAT_HDR := $(CURDIR)/compat/compat-rhel10.h
MD_HDRS    := $(MDRAID_BUILD)/md
ABI_TARGET := rhel10
else ifeq ($(TARGET),unsupported)
ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
$(error kernel $(KVER) is not supported (tools/detect-target.sh))
endif
else
$(error unknown TARGET '$(TARGET)' (rhel10, rhel9, rhel98, ubuntu2604, vanilla))
endif

# Override to point the struct-mddev ABI check at a target kernel's BTF/vmlinux
# (default: the running kernel's /sys/kernel/btf/vmlinux).
BTF_VMLINUX ?=

all: md isa-l abi-check
	@echo "raidkm: building for TARGET=$(TARGET) (compat=$(notdir $(COMPAT_HDR)))"
	$(MAKE) -C $(KDIR) M=$(CURDIR) \
		KCPPFLAGS="-include $(COMPAT_HDR)" \
		KBUILD_EXTRA_SYMBOLS="$(EXTRA_SYMS)" \
		KBUILD_MODPOST_WARN=1 modules

# Verify the builtin kernel's struct mddev layout matches what raidkm.ko is
# compiled against (BTF-based). Fails the build only on a confirmed mismatch;
# skips with a warning if pahole / kernel BTF is unavailable. Pairs with the
# BUILD_BUG_ON in km/raid_km.c (which locks the fork's md.h side).
abi-check:
	@ABI_TARGET="$(ABI_TARGET)" BTF_VMLINUX="$(BTF_VMLINUX)" bash $(CURDIR)/tools/check-mddev-abi.sh $(KVER)

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
