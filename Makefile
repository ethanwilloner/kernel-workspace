SHELL := /bin/bash
DIR=$(shell pwd)
ARCH?=x86_64
MAKE=make -j$(shell nproc --ignore=1)
TAG=master

#### Makefile standard commands
.PHONY: clean

all: kernel busybox driver initramfs
clean: kernel_clean driver_clean busybox_clean initramfs_clean
clean_sources:
	rm -rf busybox/ busybox-snapshot.tar.bz2 linux/

#### Dependencies
install_deps:
	sudo dnf group install "C Development Tools and Libraries"
	sudo dnf install glibc-static kernel-devel openssl-devel elfutils-libelf-devel

#### Sources
linux/:
	git clone --depth=1 https://github.com/torvalds/linux.git --tag $(TAG)
	mv $(TAG) linux

busybox-snapshot.tar.bz2:
	wget https://busybox.net/downloads/busybox-snapshot.tar.bz2

busybox/: busybox-snapshot.tar.bz2 
	tar xf busybox-snapshot.tar.bz2

#### Linux Kernel
.PHONY: kernel kernel_clean

linux/arch/$(ARCH)/boot/bzImage:

linux/Makefile: linux/
	@echo "Required: Linux kernel source in $(DIR)/linux"

linux/.config: linux/Makefile
	make -C linux defconfig

kernel_defconfig: linux/Makefile
	make -C linux defconfig

kernel_menuconfig: linux/Makefile
	make -C linux menuconfig

kernel_kallsyms_all: linux/.config
	(cd linux && scripts/config -e KALLSYMS_ALL)

kernel_kallsyms_all_clean: linux/.config
	(cd linux && scripts/config -d KALLSYMS_ALL)

kernel_randomization_disable: linux/.config
	(cd linux && scripts/config -d RANDOMIZE_BASE -d RANDOMIZE_MEMORY)

kernel_randomization_disable_clean: linux/.config
	(cd linux && scripts/config -e RANDOMIZE_BASE -e RANDOMIZE_MEMORY)

#TODO: test CONFIG_UNWINDER_FRAME_POINTER
kernel_debug: linux/.config
	(cd linux && scripts/config -e DEBUG_INFO -e GDB_SCRIPTS -e KGDB -e KGDB_SERIAL_CONSOLE -e KGDB_KDB)

kernel_debug_clean: linux/.config
	(cd linux && scripts/config -d DEBUG_INFO -d GDB_SCRIPTS -d KGDB -d KGDB_SERIAL_CONSOLE -d KGDB_KDB)

kernel_bzImage: linux/.config
	$(MAKE) -C linux bzImage

kernel_driver: linux/drivers/Makefile
	make -C linux drivers

kernel_cscope:
	make -C linux ARCH=$(ARCH) cscope tags

kernel_clean:
	make -C linux clean

kernel: kernel_bzImage 

#### Driver
.PHONY: driver
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
.PHONY: busybox_clean

busybox/Makefile: busybox/
	@echo "Required: busybox source in $(DIR)/busybox"

busybox_defconfig: busybox/Makefile
	make -C busybox defconfig

busybox/.config: busybox_defconfig

busybox: busybox/.config busybox/Makefile
	$(MAKE) CONFIG_STATIC=y -C busybox

busybox/busybox:
busybox/_install: busybox/busybox
	$(MAKE) CONFIG_STATIC=y -C busybox install

busybox_clean:
	make -C busybox clean

#### Initramfs
.PHONY: initramfs/ 

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
	#echo 0 > /proc/sys/kernel/randomize_va_space
	/bin/busybox --install -s
	#insmod /$(DRIVER).ko
	#clear
	exec sh
	EOF
	chmod +x initramfs/init

main: main.c
	gcc -static -o main main.c

initramfs/main: main
	cp main initramfs/main

initramfs.gz: driver/$(DRIVER).ko initramfs/init initramfs/main
	cd initramfs
	find . | cpio -oHnewc | gzip > ../initramfs.gz

initramfs/bin/busybox: busybox/_install
	cp -u -r busybox/_install/* initramfs/
	chmod +x initramfs/bin/busybox

initramfs: initramfs/ initramfs/init initramfs/main initramfs/bin/busybox initramfs.gz

initramfs_clean:
	rm -rf initramfs/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys}
	rm -rf initramfs.gz

#### Qemu
KERNEL_PARAMS=\"console=ttyS0 quiet nokaslr nosmap nosmep mitigations=off\"
.ONESHELL:
qemurun: initramfs.gz
	tmux=''
	#if [ "$$TERM" = "screen-256color" ] && [ -n "$$TMUX" ]; then
		# TODO: -h split option
	#	tmux='tmux split-window -h'
	#fi
	# Use Ctrl-q x to kill qemu session from echr 17
	eval $$tmux qemu-system-x86_64 \
		-s \
		-enable-kvm \
		-m 128 \
		-nographic \
		-echr 17 \
		-kernel linux/arch/$(ARCH)/boot/bzImage \
		-initrd initramfs.gz \
		-serial mon:stdio \
		-append $(KERNEL_PARAMS) 

.ONESHELL:
qemugdb: linux/arch/$(ARCH)/boot/bzImage initramfs.gz
	tmux=''
	if [ "$$TERM" = "screen-256color" ] && [ -n "$$TMUX" ]; then
		# TODO: -h split option
		tmux='tmux split-window'
	fi
	# Idea taken from ciro, not functional now but will work once I
	# break these shells out into proper bash scripts instead of makefile hacks
	if [ "$#" -gt 0 ]; then
	  brk="-ex 'break $1'"
	else
	  brk=""
	fi
	# symlink needed because gdb won't find vmlinux-gdb.py without it.
	# I nearly threw my computer out the window while debugging this...
	ln -s $(shell pwd)/linux/scripts/gdb/vmlinux-gdb.py linux/.
	eval $$tmux qemu-system-x86_64 \
		-s -S \
		-enable-kvm \
		-m 128 \
		-nographic \
		-echr 17 \
		-kernel linux/arch/$(ARCH)/boot/bzImage \
		-initrd initramfs.gz \
		-serial mon:stdio \
		-append $(KERNEL_PARAMS)
	gdb \
    -ex "add-auto-load-safe-path $(shell pwd)/linux" \
    -ex "file $(shell pwd)/linux/vmlinux" \
    -ex "set arch i386:x86-64:intel" \
    -ex "target remote localhost:1234" \
    -ex $$brk \
	-ex 'continue' \
	-ex 'disconnect' \
	-ex 'set arch i386:x86-64' \
	-ex 'target remote localhost:1234' \
	-ex "lx-symbols driver/"
