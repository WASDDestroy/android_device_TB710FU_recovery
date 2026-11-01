#
# Copyright (C) 2025 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Building with minimal manifest
TARGET_FS_CONFIG_GEN += device/lenovo/topaz/fs_config/android_files
ALLOW_MISSING_DEPENDENCIES                      := true
BUILD_BROKEN_DUP_RULES                          := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES    := true

BUILD_BROKEN_NINJA_USES_ENV_VARS    += RTIC_MPGEN
BUILD_BROKEN_PLUGIN_VALIDATION      := soong-libaosprecovery_defaults soong-libguitwrp_defaults soong-libminuitwrp_defaults soong-vold_defaults

# Architecture
TARGET_ARCH                 := arm64
TARGET_ARCH_VARIANT         := armv8-a
TARGET_CPU_ABI              := arm64-v8a
TARGET_CPU_VARIANT          := kryo

# A/B
AB_OTA_PARTITIONS := \
    boot \
    init_boot \
    vendor_boot \
    dtbo \
    odm \
    product \
    system \
    system_ext \
    system_dlkm \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    vendor \
    vendor_dlkm

# Bootloader
PRODUCT_PLATFORM                := pineapple
TARGET_BOOTLOADER_BOARD_NAME    := pineapple

# Crypto
BOARD_USES_METADATA_PARTITION   := true
TW_INCLUDE_CRYPTO               := true

# Debug
TARGET_USES_LOGD                := true
TWRP_INCLUDE_LOGCAT             := true
TARGET_RECOVERY_DEVICE_MODULES  += debuggerd
TARGET_RECOVERY_DEVICE_MODULES  += strace
RECOVERY_BINARY_SOURCE_FILES    += $(TARGET_OUT_EXECUTABLES)/debuggerd
RECOVERY_BINARY_SOURCE_FILES    += $(TARGET_OUT_EXECUTABLES)/strace

# File systems
TARGET_USERIMAGES_USE_F2FS := true
TW_USE_DMCTL               := true

# Kernel
BOARD_KERNEL_IMAGE_NAME     := Image
BOARD_BOOT_HEADER_VERSION   := 4
BOARD_KERNEL_PAGESIZE       := 4096
BOARD_MKBOOTIMG_ARGS        += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS        += --pagesize $(BOARD_KERNEL_PAGESIZE)

BOARD_RAMDISK_USE_LZ4       := true

# Partitions
BOARD_PROPERTY_OVERRIDES_SPLIT_ENABLED  := true
BOARD_RECOVERYIMAGE_PARTITION_SIZE      := 104857600

# Dynamic Partition
BOARD_SUPER_PARTITION_SIZE := 20401094656
BOARD_SUPER_PARTITION_GROUPS := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE := 19318964224
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := \
	system system_ext product vendor vendor_dlkm odm

BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_ODM             := odm
TARGET_COPY_OUT_VENDOR          := vendor

# Platform
TARGET_BOARD_PLATFORM   := pineapple
QCOM_BOARD_PLATFORMS    += pineapple

# Recovery
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE    := true
TARGET_RECOVERY_PIXEL_FORMAT                := RGBX_8888
TW_INCLUDE_FASTBOOTD                        := true

# Tool
TW_ENABLE_ALL_PARTITION_TOOLS := true
TW_INCLUDE_7ZA                := true
TW_INCLUDE_REPACKTOOLS        := true
TW_INCLUDE_RESETPROP          := true
TW_USE_TOOLBOX                := true
TW_INCLUDE_ZSTD               := true

# NOTE: never ship files under recovery/root/sbin. bootable/recovery/etc/init.rc
# replaces /sbin with a symlink to /system/bin, and a non-empty /sbin makes that
# rmdir+symlink fail, leaving no /sbin/sh. Vendor OTA updater scripts commonly
# start with #!/sbin/sh and then die with "Can't execute '/tmp/updater'".
# Put recovery tools in recovery/root/system/bin instead.
BOARD_RECOVERY_IMAGE_PREPARE += \
    rm -f $(PRODUCT_OUT)/recovery/root/system/bin/unzip && \
    cp $(TARGET_DEVICE_DIR)/recovery/root/system/bin/unzip7za $(PRODUCT_OUT)/recovery/root/system/bin/unzip

# TWRP display
TW_BRIGHTNESS_PATH      := /sys/class/backlight/panel0-backlight/brightness
TW_DEFAULT_BRIGHTNESS   := 2048
TW_FRAMERATE            := 120
TW_MAX_BRIGHTNESS       := 4095
TW_SCREEN_BLANK_ON_BOOT := true
TW_INPUT_BLACKLIST := "hbtp_vm"
TW_THEME := landscape_hdpi #portrait_hdpi
TW_ROTATION := 0
RECOVERY_TOUCHSCREEN_SWAP_XY := true
RECOVERY_TOUCHSCREEN_FLIP_Y := true

# TWRP file system
RECOVERY_SDCARD_ON_DATA     := true
TARGET_USES_MKE2FS          := true
TW_ENABLE_FS_COMPRESSION    := true
TW_INCLUDE_FUSE_EXFAT       := true
TW_INCLUDE_FUSE_NTFS        := true
TW_INCLUDE_NTFS_3G          := true
TW_NO_EXFAT_FUSE            := true

# Version
PLATFORM_VERSION                := 99.87.36
PLATFORM_VERSION_LAST_STABLE    := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH         := 2099-12-31
VENDOR_SECURITY_PATCH           := $(PLATFORM_SECURITY_PATCH)
BOOT_SECURITY_PATCH             := $(PLATFORM_SECURITY_PATCH)
TW_DEVICE_VERSION               := Lenovo Xiaoxin Pad Pro GT

# Verified Boot
BOARD_AVB_ENABLE := true
BOARD_AVB_ALGORITHM := SHA256_RSA4096
BOARD_AVB_KEY_PATH := device/lenovo/topaz/recovery/root/avbpowertool/tools/testkey_rsa4096.pem

# Other TWRP Configurations
TW_INCLUDE_WIFI := true
TW_NO_HAPTICS := true
TARGET_RECOVERY_QCOM_RTC_FIX            := true
TW_CUSTOM_CPU_TEMP_PATH                 := "/sys/class/thermal/thermal_zone48/temp"
TW_EXCLUDE_APEX                         := true
TW_EXCLUDE_DEFAULT_USB_INIT             := true
TW_EXTRA_LANGUAGES                      := true
TW_LOAD_VENDOR_MODULES                  := "adsp_loader_dlkm.ko stm_st54se_gpio.ko cnss_prealloc.ko cnss_utils.ko cnss_nl.ko \
    wlan_firmware_service.ko cnss_plat_ipc_qmi_svc.ko cnss2.ko cfg80211.ko"
TW_LOAD_VENDOR_MODULES_EXCLUDE_GKI      := true
#TW_NO_SCREEN_BLANK                     := true
TW_USE_SERIALNO_PROPERTY_FOR_DEVICE_ID  := true
TW_HAS_EDL_MODE                         := true

