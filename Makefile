DPKG_ARCH := $(shell dpkg --print-architecture)
HOST_RELEASE := $(shell lsb_release -c -s)
RELEASE := $(shell echo $(KERNEL_SOURCE) | awk -F : '{print $$1}')
ENV := DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANG=C
MIRROR := ftpmaster.internal/ubuntu

ifeq "$(strip $(KERNEL))" ""
$(error KERNEL package name is missing, abort)
endif

# Determine flavour. Usually the last part of the kernel package name,
# except for the special liux-pc-image which is based on the generic
# flavour.
ifneq (,$(findstring linux-pc-image,$(KERNEL)))
FLAVOUR := generic
else
FLAVOUR := $(shell echo "$(KERNEL)" | sed -e 's/.*-\([^-]\+\)$$/\1/')
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

install: install-image
	mkdir -p $(DESTDIR)/lib $(DESTDIR)/meta $(DESTDIR)/firmware $(DESTDIR)/modules
	# Copy meta data into the snap. The ABI file itself actually was
	# not used for anything and just done for completeness. Since new
	# kernel builds move this into a separate package which is not
	# installed by default we need to ignore the case when is not
	# found in the old location.
	if [ -f chroot/boot/abi-* ]; then \
	  cp -ar chroot/boot/abi-* $(DESTDIR)/; \
	fi
	cp -ar chroot/boot/System.map-* chroot/boot/config-* $(DESTDIR)/
	# Add DTBs
	if [ -d chroot/lib/firmware/$(ABI)-$(FLAVOUR)/device-tree ]; then \
	  mkdir -p $(DESTDIR)/dtbs; \
	  cp -a chroot/lib/firmware/$(ABI)-$(FLAVOUR)/device-tree/* $(DESTDIR)/dtbs/; \
	fi
	# Add kernel.yaml
	if [ "$(KERNEL_ASSETS)" = "true" ]; then \
	  mkdir -p $(DESTDIR)/meta; \
	  cp -a kernel.yaml $(DESTDIR)/meta/; \
	fi
	# copy modules and firmware
	cp -a chroot/lib/modules/* $(DESTDIR)/modules/
	cp -a chroot/lib/firmware/* $(DESTDIR)/firmware/
	# if we ship the rpi3 wlan firmware, copy it to the right dir
	if [ -d chroot/lib/firmware/brcm80211/brcm ]; then \
	  mv chroot/lib/firmware/brcm80211/brcm/* $(DESTDIR)/firmware/brcm; \
	  rm -rf chroot/lib/firmware/brcm80211; \
	fi
	# copy all licenses into the snap
	cp /usr/share/common-licenses/GPL-2 $(DESTDIR)/
	mv chroot/usr/share/doc/linux-firmware/copyright $(DESTDIR)/firmware/
	mv chroot/usr/share/doc/linux-firmware/licenses $(DESTDIR)/firmware/
	# create all links
	cd $(DESTDIR)/lib; ln -s ../firmware .
	cd $(DESTDIR)/lib; ln -s ../modules .
	# Remove unnecessary firmwares
	if [ "$(TRIM_FIRMWARE)" = "true" ]; then \
	  ./trim-firmware "$(DESTDIR)"; \
	fi
