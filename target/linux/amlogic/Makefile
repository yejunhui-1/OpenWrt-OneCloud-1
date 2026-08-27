# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2006-2013 OpenWrt.org

include $(TOPDIR)/rules.mk

ARCH:=arm
BOARD:=amlogic
BOARDNAME:=Amlogic Meson family
FEATURES:=boot-part ext4 fpu legacy-sdcard squashfs usbgadget
SUBTARGETS:=meson8b

KERNEL_PATCHVER:=6.6
# 对齐 dl.openwrt.ai kwrt_core 源的内核版本（24.10 默认已是 6.6.151，这里强制钉到 6.6.102）
override LINUX_VERSION-6.6 = .102
LINUX_KERNEL_HASH-6.6.102 = 80d2feb7334c30bacbe1e7dafa9ea415efb2c0ea4f4740ecbd1467cf5d94de5c

define Target/Description
	Build firmware image for Amlogic Meson SoC devices.
	Currently produces Amlogic Burn Image.
endef

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += \
	e2fsprogs \
	mkf2fs \
	automount \
	resize2fs \
	partx-utils \
	losetup

KERNELNAME:=Image dtbs

$(eval $(call BuildTarget))
