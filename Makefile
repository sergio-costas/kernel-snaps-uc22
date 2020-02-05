DPKG_ARCH := $(shell dpkg --print-architecture)
RELEASE := $(shell lsb_release -c -s)
ENV := DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANG=C

MIRROR := ftpmaster.internal/ubuntu

ifeq "$(strip $(KERNEL))" ""
$(error KERNEL package name is missing, abort)
endif

ABI := $(shell echo $(SNAPCRAFT_PROJECT_VERSION) | cut -f1-3 -d".")

# rewriting variables passed from the outside environment doesn't work in LP,
# so use KERNELDEB as a temporary local variable to hold the kernel pkg name
KERNELDEB := $(KERNEL)
KERNELPRE := linux-image-$(ABI)

# linux-pc-image is a meta package used to indicate linux-image-generic,
# depending on the building architecture (amd64 or i386), it's invalid kernel
# name for any other arch
ifneq (,$(findstring linux-pc-image,$(KERNELDEB)))
ifneq (,$(filter amd64 i386 armhf arm64,$(DPKG_ARCH)))
KERNELDEB := $(subst linux-pc-image,linux-image-generic,$(KERNELDEB))
else
$(error linux-pc-image is a meta package only used in i386, amd64, armhf or arm64 abort)
endif
endif

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

version-check: KERNELMETAEQ=$(shell for meta in $$(chroot chroot apt-cache show $(KERNELDEB) | awk '/Package:/ {package=$$2} /Version:/ {print package "=" $$2}'); do chroot chroot apt-cache depends $$meta | awk '/$(KERNELPRE)/ {print "'"$$meta"'"}'; done)
version-check: KIMGDEB = $(shell chroot chroot apt-cache depends $(KERNELMETAEQ) | awk '/$(KERNELPRE)/ {print $$2}')
install : KVERS = $(shell ls -1 chroot/boot/vmlinuz-*| tail -1 |sed 's/^.*vmlinuz-//;s/.efi.signed$$//')

all: version-check

prepare-chroot:
	debootstrap --variant=minbase $(RELEASE) chroot
	$(ENV) chroot chroot apt-get -y update

	mount --bind /proc chroot/proc
	mount --bind /sys chroot/sys

	# Enable ppa:snappy-dev/image inside of the chroot and add the PPA's
	# public signing key to apt:
	cp snappy-dev-image.asc chroot/etc/apt/trusted.gpg.d/
	# Copy in the sources.list just before modifying it (on build envs this already
	# seems to be present, otherwise those would not fail).
	cp /etc/apt/sources.list chroot/etc/apt/sources.list
	echo "deb http://ppa.launchpad.net/snappy-dev/image/ubuntu $(RELEASE) main" >> chroot/etc/apt/sources.list

	# install all updates
	$(ENV) chroot chroot apt-get -y update
	$(ENV) chroot chroot apt-get -y upgrade

	if [ "$(PROPOSED)" = "true" ]; then \
	  echo "deb http://$(MIRROR) $(RELEASE)-proposed main restricted" >> chroot/etc/apt/sources.list; \
	  echo "deb http://$(MIRROR) $(RELEASE)-proposed universe" >> chroot/etc/apt/sources.list; \
	  echo "$${APTPREF}" > chroot/etc/apt/preferences.d/01proposedkernel; \
	fi

	$(ENV) chroot chroot apt-get -y update;\
	$(ENV) chroot chroot apt-get -y install ubuntu-core-initramfs linux-firmware

prepare-kernel: prepare-chroot
	# linux-firmware-raspi2 wants a /boot/firmware directory
ifneq (,$(filter linux-firmware-raspi2,$(PKGS)))
	mkdir -p chroot/boot/firmware
endif
	$(ENV) chroot chroot apt-get -y install $(KERNELMETAEQ) $(PKGS)
	umount chroot/sys
	umount chroot/proc

install:
	mkdir -p $(DESTDIR)/lib $(DESTDIR)/meta $(DESTDIR)/firmware $(DESTDIR)/modules
	if [ -f chroot/boot/kernel.efi-* ]; then \
	  mv chroot/boot/kernel.efi-* $(DESTDIR)/kernel.efi; \
	else \
	  mv chroot/boot/vmlinu?-* $(DESTDIR)/kernel.img; \
	  mv chroot/boot/ubuntu-core-initramfs.img-* $(DESTDIR)/initrd.img; \
	fi
	# Copy meta data into the snap. The ABI file itself actually was
	# not used for anything and just done for completeness. Since new
	# kernel builds move this into a separate package which is not
	# installed by default we need to ignore the case when is not
	# found in the old location.
	if [ -f chroot/boot/abi-* ]; then \
	  cp -ar chroot/boot/abi-* $(DESTDIR)/; \
	fi
	cp -ar chroot/boot/System.map-* chroot/boot/config-* $(DESTDIR)/
	# arch dependant stuff
	# TODO: match against the name in snapcraft.yaml too so we have more fine grained
	# subarch handling
	if [ "$(DPKG_ARCH)" = "arm64" ]; then \
	  mkdir -p $(DESTDIR)/dtbs; \
	  cp -a chroot/lib/firmware/$(KVERS)/device-tree/* $(DESTDIR)/dtbs/; \
	  mkdir -p $(DESTDIR)/firmware/wlan; \
	  ln -s /run/macaddr0 $(DESTDIR)/firmware/wlan/; \
	fi
	if [ "$(DPKG_ARCH)" = "armhf" ]; then \
	  mkdir -p $(DESTDIR)/dtbs; \
	  cp -a chroot/lib/firmware/$(KVERS)/device-tree/* $(DESTDIR)/dtbs/; \
	  tar -C $(DESTDIR)/dtbs -f $(DESTDIR)/dtbs/overlays.tgz -czv overlays; \
	  rm -rf $(DESTDIR)/dtbs/overlays; \
	  if [ -d chroot/usr/share/doc/raspberrypi-wireless-firmware ]; then \
	    mv chroot/usr/share/doc/raspberrypi-wireless-firmware $(DESTDIR)/firmware/rpi-wlanfw-licenses; \
	  fi; \
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

version-check: prepare-kernel
	{ \
	set -e; \
	echo $(KIMGDEB); \
	[ ! $(KIMGDEB) ] && echo "Unable to extract KIMGDEB, exit" && exit 1; \
	KIMGVER="$$(dpkg --root=chroot -l | awk '/$(KIMGDEB)/ {print $$3}')"; \
	echo $$KIMGVER; \
	[ ! $$KIMGVER ] && echo "Unable to extract KIMGVER, exit" && exit 1; \
	case "$$KIMGVER" in \
	$(SNAPCRAFT_PROJECT_VERSION)|$(SNAPCRAFT_PROJECT_VERSION)+*) ;; \
	*)	echo "Version mismatch:\nInstalled: $$KIMGVER Requested: $(SNAPCRAFT_PROJECT_VERSION)"; \
		exit 1; \
	esac; \
	}
