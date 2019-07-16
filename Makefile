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

versioncheck: KIMGDEB = $(shell chroot chroot apt-cache depends $(KERNELDEB) | awk '/$(KERNELPRE)/ {print $$2}')
install : KVERS = $(shell ls -1 chroot/boot/vmlinuz-*| tail -1 |sed 's/^.*vmlinuz-//;s/.efi.signed$$//')

all:
	debootstrap --variant=minbase $(RELEASE) chroot
	$(ENV) chroot chroot apt-get -y update

	mount --bind /proc chroot/proc
	mount --bind /sys chroot/sys

	# Enable ppa:snappy-dev/image inside of the chroot and add the PPA's
	# public signing key to apt:
	# - gnugpg is required by apt-key
	# - gnugpg 2.x requires gpg-agent to be running
	# - procfs must be bind-mounted for gpg-agent
	# - running apt-key as a child process of gpg-agent --daemon stops the
	#   agent shortly after apt-key executes
	$(ENV) chroot chroot apt-get -y install gnupg
	mkdir --mode=0600 chroot/tmp/gnupg-home
	cat snappy-dev-image.asc | $(ENV) chroot chroot gpg-agent --homedir /tmp/gnupg-home --daemon apt-key add -
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
	mkdir -p chroot/etc/initramfs-tools/conf.d
	echo "COMPRESS=lzma" >chroot/etc/initramfs-tools/conf.d/ubuntu-core.conf
	# LP1794279: vc4-kms-v3d and hardware accelerated framebuffer support
	echo "i2c-bcm2708" > chroot/etc/initramfs-tools/modules
	if [ "$(DPKG_ARCH)" = "amd64" ]; then \
	  echo "nvme" >> chroot/etc/initramfs-tools/modules; \
	  echo "usbhid" >> chroot/etc/initramfs-tools/modules; \
	  echo "hid-generic" >> chroot/etc/initramfs-tools/modules; \
	fi
	$(ENV) chroot chroot apt-get -y update;\
	$(ENV) chroot chroot apt-get -y install initramfs-tools-ubuntu-core linux-firmware xz-utils
	$(ENV) chroot chroot apt-get -y install $(KERNELDEB) $(PKGS)
	umount chroot/sys
	umount chroot/proc

install: versioncheck
	mkdir -p $(DESTDIR)/lib $(DESTDIR)/meta $(DESTDIR)/firmware $(DESTDIR)/modules
	if [ -f chroot/boot/vmlinu?-*.signed ]; then \
	  mv chroot/boot/vmlinu?-*.signed $(DESTDIR)/kernel.img; \
	else \
	  mv chroot/boot/vmlinu?-* $(DESTDIR)/kernel.img; \
	fi
	mv chroot/boot/initrd.img-* $(DESTDIR)/initrd.img
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
	cd $(DESTDIR); ln -s kernel.img vmlinuz-$(KVERS)
	cd $(DESTDIR); ln -s kernel.img vmlinuz
	cd $(DESTDIR); ln -s initrd.img initrd.img-$(KVERS)

versioncheck:
	{ \
	set -e; \
	echo $(KIMGDEB); \
	[ ! $(KIMGDEB) ] && echo "Unable to extract KIMGDEB, exit" && exit 1; \
	KIMGVER="$$(dpkg --root=chroot -l | awk '/$(KIMGDEB)/ {print $$3}')"; \
	echo $$KIMGVER; \
	[ ! $$KIMGVER ] && echo "Unable to extract KIMGVER, exit" && exit 1; \
	if [ $$KIMGVER != $(SNAPCRAFT_PROJECT_VERSION) ]; then \
	  echo "Version mismatch:\nInstalled: $$KIMGVER Requested: $(SNAPCRAFT_PROJECT_VERSION)"; \
	  exit 1; \
	fi; \
	}
