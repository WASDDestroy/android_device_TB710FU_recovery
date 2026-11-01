#!/system/bin/sh
# Bring WLAN up in one shot, run as a oneshot init service.
#
# Everything is done here instead of in init commands because "exec" in an init
# action starts an asynchronous service: the following commands would run
# before the module loader finished, which made fs_ready/insmod fail.

log() { echo "wifi-up: $*"; }

is_mounted() { grep -q " $1 " /proc/mounts; }

VD=/tmp/vdlkm

# Every mount below only has to exist while the driver is being brought up: the
# firmware image and wlan_mac.bin are consumed during insmod. Leaving them
# mounted keeps the persist partition and the vendor_dlkm mapper busy, which
# makes "Wipe persist", "Remove Super Devices" and Format Data fail with EBUSY,
# so release them on every exit path.
release_mounts() {
  # init.recovery.qcom.rc bind-mounts /mnt/vendor/persist at /tmp/persist, so the
  # kiwi_v2 mount below can also show up as /tmp/persist/kiwi_v2; list both in
  # case the unmount is not propagated to the peer.
  for m in /vendor/firmware_mnt/image /mnt/vendor/persist/kiwi_v2 /tmp/persist/kiwi_v2 \
           /tmp/wifi_persist "$VD"; do
    is_mounted "$m" && umount "$m" 2>/dev/null && log "released $m"
  done
}
fail() {
  log "$1"
  release_mounts
  exit 1
}

# 1) kernel modules for the running kernel (see load-wlan-modules.sh)
/system/bin/sh /system/bin/load-wlan-modules.sh || fail "module loader failed"
MODDIR=/lib/modules/wlan/current
[ -f "$MODDIR/qca_cld3_kiwi_v2.ko" ] || { fail "no qca_cld3 in $MODDIR"; }
log "modules from $(readlink -f "$MODDIR" 2>/dev/null || echo "$MODDIR")"

# 2) wait for init.recovery.qcom.rc to mount the modem image, then expose the
#    path firmware_class.path looks at: /vendor/firmware_mnt/image/kiwi/*
i=0
while [ ! -d /firmware/image/kiwi ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
if ! is_mounted /vendor/firmware_mnt/image; then
  mkdir -p /vendor/firmware_mnt/image
  mount -o bind /firmware/image /vendor/firmware_mnt/image
  log "firmware bind: $?"
fi

# 3) wlan_mac.bin: expose persist's kiwi_v2 where the driver looks for it
if ! is_mounted /tmp/wifi_persist; then
  mkdir -p /tmp/wifi_persist
  mount -t ext4 -o ro /dev/block/bootdevice/by-name/persist /tmp/wifi_persist 2>/dev/null
  log "persist mount: $?"
fi
if ! is_mounted /mnt/vendor/persist/kiwi_v2; then
  mkdir -p /mnt/vendor/persist/kiwi_v2
  mount -o bind /tmp/wifi_persist/kiwi_v2 /mnt/vendor/persist/kiwi_v2 2>/dev/null
  log "mac bind: $?"
fi

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

# The driver owns the firmware and mac address now; drop the helper mounts.
release_mounts
