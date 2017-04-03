DPKG_ARCH := $(shell dpkg --print-architecture)
RELEASE := $(shell lsb_release -c -s)
ENV := DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANG=C

MIRROR := ftpmaster.internal/ubuntu

ifneq (,$(findstring amd64,$(DPKG_ARCH)))
PACKAGE := linux-signed-generic
else ifneq (,$(findstring i386,$(DPKG_ARCH)))
PACKAGE := linux-generic
else ifneq (,$(findstring armhf,$(DPKG_ARCH)))
PACKAGE := linux-image-raspi2 raspberrypi-wireless-firmware bluez-firmware
else ifneq (,$(findstring arm64,$(DPKG_ARCH)))
PACKAGE := linux-image-snapdragon linux-firmware-snapdragon
endif

install : KVERS = $(shell ls -1 chroot/boot/vmlinuz-*| tail -1 |sed 's/^.*vmlinuz-//;s/.efi.signed$$//')

all:
	debootstrap --variant=minbase $(RELEASE) chroot
	cp /etc/apt/sources.list chroot/etc/apt/sources.list
	if [ "$(PROPOSED)" = "true" ]; then \
	  echo "deb http://$(MIRROR) $(RELEASE)-proposed main restricted" >> chroot/etc/apt/sources.list; \
	  echo "deb http://$(MIRROR) $(RELEASE)-proposed universe" >> chroot/etc/apt/sources.list; \
	fi
	mkdir -p chroot/etc/initramfs-tools/conf.d
	echo "COMPRESS=lzma" >chroot/etc/initramfs-tools/conf.d/ubuntu-core.conf
	$(ENV) chroot chroot apt-get -y update
	$(ENV) chroot chroot apt-get -y --allow-unauthenticated install initramfs-tools-ubuntu-core linux-firmware xz-utils
	mount --bind /proc chroot/proc
	mount --bind /sys chroot/sys
	$(ENV) chroot chroot apt-get -y --allow-unauthenticated install $(PACKAGE)
	umount chroot/sys
	umount chroot/proc

install:
	mkdir -p $(DESTDIR)/lib $(DESTDIR)/meta $(DESTDIR)/firmware $(DESTDIR)/modules
	if [ -f chroot/boot/vmlinu?-*.signed ]; then \
	  mv chroot/boot/vmlinu?-*.signed $(DESTDIR)/kernel.img; \
	else \
	  mv chroot/boot/vmlinu?-* $(DESTDIR)/kernel.img; \
	fi
	mv chroot/boot/initrd.img-* $(DESTDIR)/initrd.img
	# copy meta data into the snap
	cp -ar chroot/boot/abi-* chroot/boot/System.map-* chroot/boot/config-* $(DESTDIR)/
	# arch dependant stuff
	# TODO: match against the name in snapcraft.yaml too so we have more fine grained
	# subarch handling
	if [ "$(DPKG_ARCH)" = "arm64" ]; then \
	  mkdir -p $(DESTDIR)/dtbs; \
	  cp -a chroot/lib/firmware/$(KVERS)/device-tree/* $(DESTDIR)/dtbs/; \
	  cp chroot/lib/firmware/$(KVERS)/device-tree/qcom/apq8016-sbc-snappy.dtb $(DESTDIR)/dtbs/apq8016-sbc.dtb; \
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
