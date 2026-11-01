# Recovery ramdisk file modes.
#
# mkbootfs is invoked as `mkbootfs -d $(TARGET_OUT) $(TARGET_RECOVERY_ROOT_OUT)`.
# In that mode libcutils fs_config() first looks for
#   $(TARGET_OUT)/etc/fs_config_files  / fs_config_dirs
# and only then falls back to its built-in table. Anything not found is forced to
# 0644 (files) / 0755 (dirs), which is why recovery/root payloads outside the
# built-in table (e.g. /avbpowertool/*) lose their executable bit.
#
# Those two files are generated from TARGET_FS_CONFIG_GEN, but they are installed
# as part of the system-partition install step, which `m recoveryimage` never
# builds. Depend on them from the ramdisk staging step so they always exist
# before mkbootfs runs.
RECOVERY_RAMDISK_FS_CONFIG := \
    $(TARGET_OUT)/etc/fs_config_files \
    $(TARGET_OUT)/etc/fs_config_dirs

$(call intermediates-dir-for,PACKAGING,recovery)/ramdisk_files-timestamp: \
    $(RECOVERY_RAMDISK_FS_CONFIG)
