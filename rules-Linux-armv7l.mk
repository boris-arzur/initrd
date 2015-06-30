S3_TARGET ?=		s3://$(shell whoami)/
KERNEL_URL ?=		http://ports.ubuntu.com/ubuntu-ports/dists/lucid/main/installer-armel/current/images/versatile/netboot/vmlinuz
MKIMAGE_OPTS ?=		-A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs
DEPENDENCIES ?=	\
	/bin/busybox \
	/etc/udhcpc/default.script \
	/lib/arm-linux-gnueabihf/libnss_dns.so.2 \
	/lib/arm-linux-gnueabihf/libnss_files.so.2 \
	/sbin/mkfs.ext4 \
	/sbin/parted \
	/usr/bin/curl \
	/usr/lib/klibc/bin/ipconfig \
	/usr/sbin/ntpdate
DOCKER_DEPENDENCIES ?=	armbuild/initrd-dependencies
CMDLINE ?=		ip=dhcp root=/dev/nbd0 nbd.max_parts=8 boot=local nousb noplymouth
QEMU_OPTIONS ?=		-M versatilepb -cpu cortex-a9 -m 256 -no-reboot
INITRD_DEBUG ?=		0
TARGET = Linux-armv7l
MAKE = make -f rules-$(TARGET).mk
HOST_ARCH ?=		$(shell uname -m)
PUBLISH_FILES ?=	uInitrd-Linux-armv7l initrd-Linux-armv7l.gz

.PHONY: publish_on_s3 qemu dist dist_do dist_teardown all travis dependencies-shell uInitrd-shell


# Phonies
all:	uInitrd


travis:
	bash -n output-Linux-armv7l/init output-Linux-armv7l/shutdown output-Linux-armv7l/functions output-Linux-armv7l/boot-*


qemu:
	$(MAKE) qemu-docker-text || $(MAKE) qemu-local-text


qemu-local-text:	vmlinuz initrd-Linux-armv7l.gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE) INITRD_DEBUG=$(INITRD_DEBUG)" \
		-kernel ./vmlinuz \
		-initrd ./initrd-Linux-armv7l.gz \
		-nographic -monitor null


qemu-local-vga:	vmlinuz initrd-Linux-armv7l.gz
	qemu-system-arm \
		$(QEMU_OPTIONS) \
		-append "$(CMDLINE)  INITRD_DEBUG=$(INITRD_DEBUG)" \
		-kernel ./vmlinuz \
		-initrd ./initrd-Linux-armv7l.gz \
		-monitor stdio


qemu-docker qemu-docker-text:	vmlinuz initrd-Linux-armv7l.gz
	cd qemu; -docker-compose kill metadata
	cd qemu; docker-compose run initrd /bin/bash -xc ' \
		qemu-system-arm \
		  -net nic -net user \
		  $(QEMU_OPTIONS) \
		  -append "console=ttyAMA0 earlyprink=ttyAMA0 $(CMDLINE) INITRD_DEBUG=$(INITRD_DEBUG) METADATA_IP=$$METADATA_PORT_80_TCP_ADDR" \
		  -kernel /boot/vmlinuz \
		  -initrd /boot/initrd-Linux-armv7l.gz \
		  -nographic -monitor null \
		'


qemu-docker-rescue:	metadata_mock/static/minirootfs.tar
	$(MAKE) qemu-docker-text CMDLINE='boot=rescue rescue_image=http://metadata.local/static/$(shell basename $<)'


publish_on_s3:	$(PUBLISH_FILES)
	for file in $(PUBLISH_FILES); do \
	  s3cmd put --acl-public $$file $(S3_TARGET); \
	done


dist:
	$(MAKE) dist_do || $(MAKE) dist_teardown


dist_do:
	-git branch -D dist-Linux-armv7l || true
	git checkout -b dist-Linux-armv7l
	-$(MAKE) dependencies-Linux-armv7l.tar.gz && git add -f dependencies-Linux-armv7l.tar.gz
	-$(MAKE) uInitrd-Linux-armv7l && git add -f uInitrd-Linux-armv7l initrd-Linux-armv7l.gz output-Linux-armv7l
	git commit -am ":ship: dist"
	git push -u origin dist-Linux-armv7l -f
	$(MAKE) dist_teardown


dist_teardown:
	git checkout master


# Files
vmlinuz:
	-rm -f $@ $@.tmp
	wget -O $@.tmp $(KERNEL_URL)
	mv $@.tmp $@


uInitrd:	uInitrd-Linux-armv7l


uInitrd-Linux-armv7l:	initrd-Linux-armv7l.gz
	$(MAKE) uInitrd-local || $(MAKE) uInitrd-docker


uInitrd-local:	initrd-Linux-armv7l.gz
	mkimage $(MKIMAGE_OPTS) -d initrd-Linux-armv7l.gz uInitrd-Linux-armv7l
	touch uInitrd-Linux-armv7l


uInitrd-docker:	initrd-Linux-armv7l.gz
	docker run \
		-it --rm \
		-v $(PWD):/host \
		-w /tmp \
		moul/u-boot-tools \
		/bin/bash -xec \
		' \
		  cp /host/initrd-Linux-armv7l.gz . && \
		  mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs -d ./initrd-Linux-armv7l.gz ./uInitrd && \
		  cp uInitrd /host/ \
		'
	mv uInitrd uInitrd-Linux-armv7l
	touch uInitrd-Linux-armv7l


uInitrd-shell: output-Linux-armv7l/.deps
	test $(HOST_ARCH) = armv7l
	docker run \
		-it --rm \
		-v $(PWD)/output-Linux-armv7l:/chroot \
		-w /tmp \
		armbuild/busybox \
		chroot /chroot /bin/sh


output-Linux-armv7l/usr/bin/oc-metadata:
	mkdir -p $(shell dirname $@)


initrd.gz:	initrd-Linux-armv7l.gz

initrd-Linux-armv7l.gz:	output-Linux-armv7l/.deps
	cd output-Linux-armv7l && find . -print0 | cpio --null -o --format=newc | gzip -9 > $(PWD)/$@


output-Linux-armv7l/.deps:	dependencies-Linux-armv7l.tar.gz tree-Linux-armv7l/usr/sbin/xnbd-client tree-Linux-armv7l/usr/bin/oc-metadata Makefile $(shell find tree-Linux-armv7l -type f)
	rm -rf output-Linux-armv7l
	mkdir -p output-Linux-armv7l
	tar -m -C output-Linux-armv7l/ -xzf dependencies-Linux-armv7l.tar.gz
	rsync -az tree-Linux-armv7l/ output-Linux-armv7l
	touch $@


output-Linux-armv7l/.clean:
	find output-Linux-armv7l \( -name "*~" -or -name ".??*~" -or -name "#*#" -or -name ".#*" \) -delete
	touch $@


tree-Linux-armv7l/usr/bin/oc-metadata:
	mkdir -p tree-Linux-armv7l/usr/bin
	wget https://raw.githubusercontent.com/scaleway/image-tools/master/skeleton-common/usr/local/bin/oc-metadata -O $@
	chmod +x $@


tree-Linux-armv7l/usr/sbin/xnbd-client:
	mkdir -p tree-Linux-armv7l/usr/sbin
	wget https://github.com/aimxhaisse/xnbd-client-static/raw/dist/bin/xnbd-client-static -O $@
	chmod +x $@
	ln -sf xnbd-client tree-Linux-armv7l/usr/sbin/@xnbd-client


dependencies.tar.gz:	dependencies-Linux-armv7l.tar.gz


dependencies-Linux-armv7l.tar.gz:	dependencies-Linux-armv7l/Dockerfile
	$(MAKE) dependencies-Linux-armv7l.tar.gz-armhf || $(MAKE) dependencies-Linux-armv7l.tar.gz-dist
	tar tvzf $@ | grep bin/busybox || rm -f $@
	@test -f $@ || echo $@ is broken
	@test -f $@ || exit 1


dependencies-shell:
	test $(HOST_ARCH) = armv7l
	docker build -q -t $(DOCKER_DEPENDENCIES) ./dependencies-Linux-armv7l/
	docker run -it $(DOCKER_DEPENDENCIES) /bin/bash


dependencies-Linux-armv7l.tar.gz-armhf:
	test $(HOST_ARCH) = armv7l
	docker build -q -t $(DOCKER_DEPENDENCIES) ./dependencies-Linux-armv7l/
	docker run -it $(DOCKER_DEPENDENCIES) export-assets $(DEPENDENCIES)
	docker cp `docker ps -lq`:/tmp/dependencies.tar $(PWD)/
	mv dependencies.tar dependencies-Linux-armv7l.tar
	docker rm `docker ps -lq`
	rm -f dependencies-Linux-armv7l.tar.gz
	@ls -lah dependencies-Linux-armv7l.tar
	gzip dependencies-Linux-armv7l.tar
	@ls -lah dependencies-Linux-armv7l.tar.gz


dependencies-Linux-armv7l.tar.gz-dist:
	-git fetch origin
	git checkout origin/dist-Linux-armv7l -- dependencies-Linux-armv7l.tar.gz
	git reset HEAD dependencies-Linux-armv7l.tar.gz


minirootfs:
	rm -rf $@ $@.tmp export.tar
	docker rm initrd-minirootfs 2>/dev/null || true
	docker run --name initrd-minirootfs --entrypoint /donotexists armbuild/busybox 2>&1 | grep -v "stat /donotexists: no such file" || true
	docker export initrd-minirootfs > export.tar
	docker rm initrd-minirootfs
	mkdir -p $@.tmp
	tar -C $@.tmp -xf export.tar
	rm -f $@.tmp/.dockerenv $@.tmp/.dockerinit
	-chmod 1777 $@.tmp/tmp
	-chmod 755 $@.tmp/etc $@.tmp/usr $@.tmp/usr/local $@.tmp/usr/sbin
	-chmod 555 $@.tmp/sys
	#echo 127.0.1.1       server >> $@.tmp/etc/hosts
	#echo 127.0.0.1       localhost server >> $@.tmp/etc/hosts
	#echo ::1             localhost ip6-localhost ip6-loopback >> $@.tmp/etc/hosts
	#echo ff02::1         ip6-allnodes >> $@.tmp/etc/hosts
	#echo ff02::2         ip6-allrouters >> $@.tmp/etc/hosts
	mv $@.tmp $@


metadata_mock/static/minirootfs.tar:	minirootfs.tar
	mkdir -p $(shell dirname $@)
	cp $< $@


minirootfs.tar:	minirootfs
	tar --format=gnu -C $< -cf $@.tmp . 2>/dev/null || tar --format=pax -C $< -cf $@.tmp . 2>/dev/null
	mv $@.tmp $@
