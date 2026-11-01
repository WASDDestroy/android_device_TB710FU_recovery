#!/system/bin/sh
# Bring WLAN up in one shot, run as a oneshot init service.
#
# Everything is done here instead of in init commands because "exec" in an init
# action starts an asynchronous service: the following commands would run
# before the module loader finished, which made fs_ready/insmod fail.

log() { echo "wifi-up: $*"; }

# 1) kernel modules for the running kernel (see load-wlan-modules.sh)
/system/bin/sh /system/bin/load-wlan-modules.sh || { log "module loader failed"; exit 1; }
MODDIR=/lib/modules/wlan/current
[ -f "$MODDIR/qca_cld3_kiwi_v2.ko" ] || { log "no qca_cld3 in $MODDIR"; exit 1; }
log "modules from $(readlink -f "$MODDIR" 2>/dev/null || echo "$MODDIR")"

# 2) wait for init.recovery.qcom.rc to mount the modem image, then expose the
#    path firmware_class.path looks at: /vendor/firmware_mnt/image/kiwi/*
i=0
while [ ! -d /firmware/image/kiwi ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
mkdir -p /vendor/firmware_mnt/image
mount -o bind /firmware/image /vendor/firmware_mnt/image
log "firmware bind: $?"

# 3) wlan_mac.bin: expose persist's kiwi_v2 where the driver looks for it
mkdir -p /tmp/wifi_persist
mount -t ext4 -o ro /dev/block/bootdevice/by-name/persist /tmp/wifi_persist 2>/dev/null
mkdir -p /mnt/vendor/persist/kiwi_v2
mount -o bind /tmp/wifi_persist/kiwi_v2 /mnt/vendor/persist/kiwi_v2 2>/dev/null

# 4) cnss firmware file-system handshake
FS=/sys/devices/platform/soc/b0000000.qcom,cnss-kiwi/fs_ready
i=0
while [ ! -e "$FS" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
if [ -e "$FS" ]; then
  echo 1 > "$FS"
  log "fs_ready: $?"
else
  log "fs_ready node missing (cnss2 not bound)"
fi

# 5) the WLAN driver itself
/system/bin/insmod "$MODDIR/qca_cld3_kiwi_v2.ko"
log "qca_cld3 insmod: $?"

# 6) wait for wlan0 and hand over to wpa_supplicant
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i+1)); done
if [ -e /sys/class/net/wlan0 ]; then
  log "wlan0 is up"
  setprop twrp.wifi.driver.ready true
else
  log "wlan0 did not appear"
fi
