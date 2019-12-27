DIR=$(shell pwd)
ARCH?=x86_64
MAKE=make -j$(shell nproc --ignore=1)

.PHONY: kernel driver busybox initramfs kernel_clean busybox_clean clean

install_deps:
	sudo dnf group install "C Development Tools and Libraries"
	sudo dnf install glibc-static kernel-devel openssl-devel elfutils-libelf-devel

#### Sources
kernel_get:
	git clone --depth=1 https://github.com/torvalds/linux.git

linux/: kernel_get

busybox_get:
	wget https://busybox.net/downloads/busybox-snapshot.tar.bz2
	tar xf busybox-snapshot.tar.bz2

busybox/: busybox_get

#### Linux Kernel
kernel_defconfig: linux/Makefile
	make -C linux defconfig

kernel_menuconfig: linux/Makefile
	make -C linux menuconfig

linux/Makefile:
	@echo "Required: Linux kernel source in $(DIR)/linux"

linux/.config: kernel_defconfig

kernel_bzImage: linux/.config 
	make -C linux -j $(nproc) bzImage

kernel_driver: linux/drivers/Makefile
	make -C linux drivers

kernel_cscope:
	make -C linux cscope

kernel_clean:
	make -C linux clean

kernel: driver initramfs kernel_bzImage

#### Driver
DRIVER=driver
driver: initramfs/
	echo "obj-m += $(DRIVER).o" > driver/Makefile
	make -C linux M=$(PWD)/driver modules
	cp driver/$(DRIVER).ko initramfs/

driver_strip: driver
	strip --strip-debug driver/$(DRIVER).ko

driver_clean:
	make -C linux M=$(PWD)/driver clean
	rm -f driver/Makefile

#### Busybox
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
initramfs/:
	mkdir -p initramfs/

.ONESHELL:
initramfs/init: initramfs/
# Help and information from:
# https://jootamam.net/howto-initramfs-image.htm
# https://git.2f30.org/scripts/file/busybox-initramfs.html
	cat > initramfs/init << EOF
	#!/bin/sh
	busybox mount -t proc proc /proc
	busybox mount -o remount,rw /
	/bin/busybox --install -s
	insmod /$(DRIVER).ko
	echo 1 > /proc/sys/kernel/printk
	#clear
	exec sh
	EOF

initramfs: initramfs/init main.c
	mkdir -p initramfs/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys}
	cp -u -r busybox/_install/* initramfs/
	chmod +x initramfs/bin/busybox
	chmod +x initramfs/init
	gcc -static -o initramfs/main main.c
	cd initramfs
	find . | cpio -oHnewc | gzip > ../initramfs.gz

initramfs_clean:
	rm -rf initramfs/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys}
	rm -rf initramfs.gz

#### Qemu
.ONESHELL:
qemurun: linux/arch/$(ARCH)/boot/bzImage initramfs.gz
	tmux=''
	if [ "$$TERM" = "screen-256color" ] && [ -n "$$TMUX" ]; then
		tmux='tmux split-window'
	fi
	eval $$tmux qemu-system-x86_64 \
		-enable-kvm \
		-m 128 \
		-nographic \
		-kernel linux/arch/$(ARCH)/boot/bzImage \
		-initrd initramfs.gz \
		-append "nokaslr" \
		-append "console=ttyS0" \
		-serial mon:stdio

#### Makefile standard commands
all: kernel_get busybox_get kernel driver busybox initramfs
clean: kernel_clean driver_clean busybox_clean initramfs_clean
clean_sources:
	rm -rf busybox/ busybox-snapshot.tar.bz2 linux/
