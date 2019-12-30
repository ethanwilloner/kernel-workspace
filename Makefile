SHELL := /bin/bash
DIR=$(shell pwd)
ARCH?=x86_64
MAKE=make -j$(shell nproc --ignore=1)
TAG=master
install_deps:
	sudo dnf group install "C Development Tools and Libraries"
	sudo dnf install glibc-static kernel-devel openssl-devel elfutils-libelf-devel

#### Sources
kernel_get:
	git clone --depth=1 https://github.com/torvalds/linux.git --tag $(TAG)
	mv $(TAG) linux

linux/: kernel_get

busybox-snapshot.tar.bz2:
	wget https://busybox.net/downloads/busybox-snapshot.tar.bz2

busybox_get: busybox-snapshot.tar.bz2  
	tar xf busybox-snapshot.tar.bz2

busybox/: busybox_get

#### Linux Kernel
.PHONY: kernel kernel_clean

kernel_defconfig: linux/Makefile
	make -C linux defconfig

kernel_menuconfig: linux/Makefile
	make -C linux menuconfig

kernel_kallsyms_all: linux/.config
	(cd linux && scripts/config -e KALLSYMS_ALL)

kernel_kallsyms_all_clean: linux/.config
	(cd linux && scripts/config -d KALLSYMS_ALL)

kernel_randomization_disable:
	(cd linux && scripts/config -d RANDOMIZE_BASE -d RANDOMIZE_MEMORY)

kernel_randomization_disable_clean:
	(cd linux && scripts/config -e RANDOMIZE_BASE -e RANDOMIZE_MEMORY)

linux/Makefile:
	@echo "Required: Linux kernel source in $(DIR)/linux"

linux/.config: linux/Makefile
	make -C linux defconfig

kernel_bzImage: linux/.config
	$(MAKE) -C linux bzImage

kernel_driver: linux/drivers/Makefile
	make -C linux drivers

kernel_cscope:
	make -C linux cscope

kernel_clean:
	make -C linux clean

kernel: driver initramfs kernel_bzImage

#### Driver
.PHONY:
DRIVER=driver

driver/Makefile:
	echo "obj-m += $(DRIVER).o" > driver/Makefile

driver/$(DRIVER).ko: driver/Makefile driver/$(DRIVER).c
	make -C linux M=$(PWD)/driver modules

driver: driver/$(DRIVER).ko
	cp driver/$(DRIVER).ko initramfs/
	@$(MAKE) initramfs

driver_strip: driver
	strip --strip-debug driver/$(DRIVER).ko

driver_clean:
	make -C linux M=$(PWD)/driver clean
	rm -f driver/Makefile

#### Busybox
.PHONY: busybox busybox_clean

busybox/Makefile:
	@echo "Required: busybox source in $(DIR)/busybox"

busybox_defconfig:
	make -C busybox defconfig

busybox/.config: busybox_defconfig

busybox: busybox/.config
	$(MAKE) CONFIG_STATIC=y -C busybox install

busybox_clean:
	make -C busybox clean

#### Initramfs
.PHONY: initramfs.gz

initramfs/:
	mkdir -p initramfs/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys}

.ONESHELL:
initramfs/init: initramfs/
# Help and information from:
# https://jootamam.net/howto-initramfs-image.htm
# https://git.2f30.org/scripts/file/busybox-initramfs.html
	cat > initramfs/init << EOF
	#!/bin/sh
	busybox mount -t proc proc /proc
	busybox mount -o remount,rw /
	echo 1 > /proc/sys/kernel/printk
	echo 0 > /proc/sys/kernel/randomize_va_space
	/bin/busybox --install -s
	#insmod /$(DRIVER).ko
	#clear
	exec sh
	EOF
	chmod +x initramfs/init

initramfs/main:
	gcc -static -o initramfs/main main.c

initramfs.gz:
	cd initramfs
	find . | cpio -oHnewc | gzip > ../initramfs.gz

initramfs/bin/busybox:
	cp -u -r busybox/_install/* initramfs/
	chmod +x initramfs/bin/busybox

initramfs: initramfs/init initramfs/main initramfs/bin/busybox initramfs.gz

initramfs_clean:
	rm -rf initramfs/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys}
	rm -rf initramfs.gz

#### Qemu
.ONESHELL:
qemurun: linux/arch/$(ARCH)/boot/bzImage initramfs.gz
	tmux=''
	if [ "$$TERM" = "screen-256color" ] && [ -n "$$TMUX" ]; then
		# TODO: -h split option
		tmux='tmux split-window'
	fi
	eval $$tmux qemu-system-x86_64 \
		-enable-kvm \
		-m 128 \
		-nographic \
		-kernel linux/arch/$(ARCH)/boot/bzImage \
		-initrd initramfs.gz \
		-serial mon:stdio \
		-append \"console=ttyS0 quiet nokaslr nosmap nosmep mitigations=off \"


#### Makefile standard commands
.PHONY: clean

all: busybox_get kernel driver busybox initramfs
clean: kernel_clean driver_clean busybox_clean initramfs_clean
clean_sources:
	rm -rf busybox/ busybox-snapshot.tar.bz2 linux/
