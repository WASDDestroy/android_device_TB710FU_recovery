#!/system/bin/sh
# Load the WLAN kernel modules.
#
# TWRP borrows the kernel from the installed ROM's boot image
# (BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true).  Modules are therefore
# only usable when they come from the same kernel build:
#   * CONFIG_MODVERSIONS checks symbol CRCs;
#   * CONFIG_MODULE_SIG_PROTECT refuses modules that export a protected GKI
#     symbol (rfkill_alloc is one) unless they are signed with a key the
#     running kernel trusts.
# There is no way to bypass that from userspace (CONFIG_MODULE_FORCE_LOAD is
# not set and SIG_PROTECT is enabled), so the loader tries the ramdisk bundle
# first and falls back to the modules that the installed ROM itself ships.
#
# Resolution order for the module directory:
#   1. /lib/modules/wlan/$(uname -r)   bundled set (only valid for the exact
#                                      kernel build it was taken from)
#   2. modules already visible         /lib/modules, /tmp/vendor/lib/modules,
#                                      /vendor_dlkm, /vendor
#   3. mount vendor_dlkm read-only
# rfkill is a GKI module shipped in system_dlkm, so it is looked up there when
# the chosen directory does not contain it.

REL=$(uname -r)
DIR=/lib/modules/wlan/$REL
SYS=/tmp/sdlkm
VD=/tmp/vdlkm

try_mount() {
  # $1 = partition name, $2 = mount point
  for dev in /dev/block/by-name/$1 /dev/block/mapper/$1_a /dev/block/mapper/$1; do
    [ -e "$dev" ] || continue
    for t in erofs ext4; do
      mount -t $t -o ro "$dev" "$2" 2>/dev/null && return 0
    done
  done
  return 1
}

rfkill_loaded() {
  grep -q "^rfkill " /proc/modules
}

find_rfkill() {
  # try to load rfkill from $1, or from system_dlkm if it is not there
  RF=$1/rfkill.ko
  if [ ! -f "$RF" ]; then
    RF=$(ls /system_dlkm/lib/modules/*/kernel/net/rfkill/rfkill.ko 2>/dev/null | head -1)
  fi
  if [ -z "$RF" ] || [ ! -f "$RF" ]; then
    mkdir -p "$SYS"
    try_mount system_dlkm "$SYS"
    RF=$(ls $SYS/lib/modules/*/kernel/net/rfkill/rfkill.ko 2>/dev/null | head -1)
  fi
  [ -n "$RF" ] && [ -f "$RF" ] && /system/bin/insmod "$RF" 2>/dev/null
  # system_dlkm is only borrowed for rfkill. Leaving it mounted keeps its
  # device-mapper node busy, and dm then refuses to remove it ("Unable to unmap
  # dynamic partitions"). /tmp/vdlkm stays up for now because wifi-up.sh
  # insmods qca_cld3 from it, and is released once the driver is up.
  umount "$SYS" 2>/dev/null
}

SRC=

# 1) bundled set for this kernel release
if [ -d "$DIR" ]; then
  find_rfkill "$DIR"
  rfkill_loaded && SRC=$DIR
fi

# 2) module directories the ROM/TWRP already exposes
if [ -z "$SRC" ]; then
  for d in /lib/modules /tmp/vendor/lib/modules /vendor_dlkm/lib/modules /vendor/lib/modules; do
    [ -f "$d/qca_cld3_kiwi_v2.ko" ] || continue
    find_rfkill "$d"
    if rfkill_loaded; then
      SRC=$d
      break
    fi
  done
fi

# 3) mount vendor_dlkm ourselves
if [ -z "$SRC" ]; then
  mkdir -p "$VD"
  if try_mount vendor_dlkm "$VD" && [ -f "$VD/lib/modules/qca_cld3_kiwi_v2.ko" ]; then
    find_rfkill "$VD/lib/modules"
    rfkill_loaded && SRC=$VD/lib/modules
  fi
fi

if [ -z "$SRC" ]; then
  echo "no usable WLAN modules for kernel $REL"
  exit 1
fi

mkdir -p /lib/modules/wlan
ln -sfn "$SRC" /lib/modules/wlan/current

# cfg80211 needs rfkill, qca_cld3 needs ipam (ipa_*) plus the cnss/qmi stack.
for m in cfg80211 rmnet_mem gsim ipam \
         cnss_utils cnss_prealloc cnss_nl wlan_firmware_service \
         cnss_plat_ipc_qmi_svc cnss2; do
  [ -f "$SRC/$m.ko" ] && /system/bin/insmod "$SRC/$m.ko" 2>/dev/null
done

exit 0
