DPKG_ARCH := $(shell dpkg --print-architecture)
HOST_RELEASE := $(shell lsb_release -c -s)
RELEASE := $(shell echo $(KERNEL_SOURCE) | awk -F : '{print $$1}')
ENV := DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANG=C
MIRROR := ftpmaster.internal/ubuntu

ifeq "$(strip $(KERNEL))" ""
$(error KERNEL package name is missing, abort)
endif

ABI := $(shell echo $(SNAPCRAFT_PROJECT_VERSION) | cut -f1-3 -d".")

define APTPREF
Package: linux-firmware
Pin: release a=$(RELEASE)-updates
Pin-Priority: 720

Package: linux-firmware
Pin: release a=$(RELEASE)-security
Pin-Priority: 710

Package: linux-firmware
Pin: release a=$(RELEASE)-proposed
Pin-Priority: 400

Package: linux-*
Pin: release a=$(RELEASE)-proposed
Pin-Priority: 750

Package: *
Pin: origin "ppa.launchpad.net"
Pin-Priority: 720

Package: *
Pin: release a=$(RELEASE)-updates
Pin-Priority: 720

Package: *
Pin: release a=$(RELEASE)-security
Pin-Priority: 710

Package: *
Pin: release a=$(RELEASE)-proposed
Pin-Priority: 400

Package: *
Pin: release a=$(RELEASE)*
Pin-Priority: 700
endef
export APTPREF

all: version-check

KERNEL_IMAGE_FORMAT ?= vmlinuz
ifeq ($(KERNEL_IMAGE_FORMAT),efi)
include Makefile.efi
else ifeq ($(KERNEL_IMAGE_FORMAT),vmlinuz)
include Makefile.vmlinuz
else
$(error Unknown image format $(KERNEL_IMAGE_FORMAT), abort)
endif
