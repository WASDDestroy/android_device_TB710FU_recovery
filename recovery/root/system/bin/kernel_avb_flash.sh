#!/system/bin/sh
# Rebuild the testkey AVB trust chain around a repacked boot image and flash it.
#
# This is the GUI2 "Advanced -> Install Kernel" backend for a locked bootloader.
# The image is repacked by twrpRepacker first; this script then reads the eight
# topaz partitions, verifies the current chain, generates a testkey profile,
# backs everything up, stages the new boot image, signs all eight images,
# flashes them and restores the bundled old ABL when the firmware needs it.
# It mirrors the locked flow of ksu_oneroot.sh (docs/NO_UNLOCK_ROOT_PLAN.md)
# without touching init_boot or KernelSU.
#
# Usage:
#   kernel_avb_flash.sh --image FILE [--yes] [--dry-run] [--force-locked]
#   kernel_avb_flash.sh --restore DIR
#
#   --image FILE     repacked boot image produced by twrpRepacker
#   --yes            skip the interactive confirmation (GUI2 has no TTY)
#   --dry-run        read/verify/backup/sign only, write no partition
#   --force-locked   testing only: run the locked rebuild even when the
#                    bootloader reports unlocked or unknown; the chain checks
#                    become warnings and an unknown ABL target is skipped
#   --restore DIR    restore a backup made by this script or ksu_oneroot.sh
#
# Exit codes: 0 success, 1 failure/refusal, 2 usage.
#
# English-only output: the TWRP console cannot render CJK wide characters.

set -u
umask 022

_self=$0
if command -v readlink >/dev/null 2>&1; then
  _r=$(readlink -f "$0" 2>/dev/null) && [ -n "$_r" ] && _self=$_r
fi
BIN_DIR=$(cd "$(dirname "$_self")" 2>/dev/null && pwd)
[ -n "$BIN_DIR" ] || BIN_DIR=/system/bin

LOG=/tmp/kernel_avb.log
: > "$LOG" 2>/dev/null || true

# Backups made here restore through this script, not through ksu_oneroot.
RESTORE_ENTRY=/system/bin/kernel_avb_flash.sh
BACKUP_BASE=/sdcard/Download/twrp_no_unlocking

. "$BIN_DIR/oneroot_common.sh"

IMAGE=""
RESTORE_DIR=""
DRY_RUN=0
ASSUME_YES=0
FORCE_LOCKED=0
WORK=""

usage() {
  cat <<'EOF'
Usage: kernel_avb_flash.sh --image FILE [options]
       kernel_avb_flash.sh --restore DIR

  --image FILE     repacked boot image produced by twrpRepacker
  --yes            skip the interactive confirmation (locked flow)
  --dry-run        read/config/backup/sign, no flash
  --force-locked   testing only: rebuild the chain on an unlocked device
                   (chain checks become warnings)
  --restore DIR    restore a backup made by this script
  -h, --help       show this help

Locked flow: rebuild a testkey AVB chain, sign 8 images, flash them and
restore the old ABL when ZUXOS >= 1.5.04.445.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      IMAGE=$1
      ;;
    --image=*) IMAGE=${1#*=} ;;
    --restore)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      RESTORE_DIR=$1
      ;;
    --restore=*) RESTORE_DIR=${1#*=} ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force-locked) FORCE_LOCKED=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

init_tools

# ---------------------------------------------------------------------------
# restore mode: no bootloader/data/OTA checks, just write the backup back
# ---------------------------------------------------------------------------
if [ -n "$RESTORE_DIR" ]; then
  [ -d "$RESTORE_DIR" ] || fail "restore directory not found: $RESTORE_DIR"
  detect_slot
  WORK=/data/local/tmp/kernel_avb_restore
  rm -rf "$WORK" || fail "cannot clear $WORK"
  mkdir -p "$WORK" || fail "cannot create $WORK"
  restore_from_backup "$RESTORE_DIR"
  exit 0
fi

[ -n "$IMAGE" ] || { usage >&2; exit 2; }
[ -f "$IMAGE" ] || fail "repacked boot image not found: $IMAGE"

require_data
detect_slot
ota_guard
detect_mode

case "$ACTUAL_MODE" in
  locked)
    MODE=locked
    ;;
  unlocked)
    if [ "$FORCE_LOCKED" = 1 ]; then
      MODE=locked
      warn "bootloader is unlocked; --force-locked continues anyway (testing)"
    else
      fail "bootloader is unlocked; the unlocked flow does not rebuild the chain"
    fi
    ;;
  *)
    if [ "$FORCE_LOCKED" = 1 ]; then
      MODE=locked
      warn "bootloader state is unknown; --force-locked continues anyway (testing)"
    else
      fail "unable to determine bootloader state; refusing to write partitions"
    fi
    ;;
esac

WORK=/data/local/tmp/kernel_avb
rm -rf "$WORK" || fail "cannot clear $WORK"
mkdir -p "$WORK" || fail "cannot create $WORK"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
abort_run() {
  log "[ERROR] $*"
  if [ "${WRITES_DONE:-0}" = 1 ]; then
    alert "a partition write failed; restoring the backup"
    restore_all || true
  fi
  log "[ERROR] Aborting."
  exit 1
}

verify_signed_images() {
  _keys=$AVB_WS/profiles/$ID/keys

  avbpy "$AVBPT_ROOT/app/avbtool.py" verify_image \
    --image "$IMGDIR/boot.img" --key "$_keys/testkey_rsa4096.pem" >/dev/null ||
    return 1
  avbpy "$AVBPT_ROOT/app/avbtool.py" verify_image \
    --image "$IMGDIR/recovery.img" --key "$_keys/testkey_rsa4096.pem" >/dev/null ||
    return 1
  avbpy "$AVBPT_ROOT/app/avbtool.py" verify_image \
    --image "$IMGDIR/vbmeta.img" --key "$_keys/testkey_rsa4096.pem" \
    --expected_chain_partition "boot:3:$_keys/testkey_rsa4096.pem.bin" \
    --expected_chain_partition "recovery:1:$_keys/testkey_rsa4096.pem.bin" \
    --expected_chain_partition "vbmeta_system:2:$_keys/$VS_KEY.pem.bin" >/dev/null ||
    return 1
  avbpy "$AVBPT_ROOT/app/avbtool.py" verify_image \
    --image "$IMGDIR/vbmeta_system.img" --key "$_keys/$VS_KEY.pem" >/dev/null ||
    return 1

  for _p in dtbo init_boot pvmfw vendor_boot; do
    avbpy "$AVBPT_ROOT/app/avbtool.py" verify_image \
      --image "$IMGDIR/$_p.img" >/dev/null || return 1
  done
  return 0
}

trim_repacked_boot() {
  _magic=$(od -An -c -N8 "$IMAGE" | tr -d ' \n')
  [ "$_magic" = "ANDROID!" ] || abort_run "the repacked image has no ANDROID! magic"

  rm -rf "$WORK/unpack_kernel"
  mkdir -p "$WORK/unpack_kernel" || abort_run "cannot create $WORK/unpack_kernel"
  ( cd "$WORK/unpack_kernel" && "$MAGISKBOOT" unpack "$IMAGE" \
      > "$WORK/unpack_kernel/unpack.log" 2>&1 )
  _rc=$?
  # RETURN_VENDOR (3) is not a failure, and a GKI boot image without a ramdisk
  # is still a valid boot image.
  [ "$_rc" = 0 ] || [ "$_rc" = 3 ] ||
    abort_run "cannot unpack the repacked boot image (rc=$_rc)"

  _page=$(sed -n 's/^PAGESIZE *\[\([0-9][0-9]*\)\].*/\1/p' \
    "$WORK/unpack_kernel/unpack.log" | head -n1)
  [ -n "$_page" ] || _page=4096

  _payload=$(avbpy "$BIN_DIR/oneroot_bootimg.py" --page "$_page" "$IMAGE") ||
    abort_run "cannot determine the repacked boot payload size"
  _part_size=$(blockdev --getsize64 "/dev/block/by-name/boot$SLOT") ||
    abort_run "cannot query the boot partition size"
  _file_size=$(stat -c %s "$IMAGE") || abort_run "cannot stat the repacked image"
  log "repacked boot: packed=$_payload file=$_file_size partition=$_part_size"
  [ "$_payload" -gt 0 ] || abort_run "the repacked boot payload is empty"
  [ "$_payload" -lt "$_part_size" ] ||
    abort_run "the packed boot image fills the partition; no room for an AVB footer"

  head -c "$_payload" "$IMAGE" > "$IMGDIR/boot.img" ||
    abort_run "cannot trim the repacked boot image"
  ok "boot image staged ($_payload bytes, page $_page)"
}

# ---------------------------------------------------------------------------
# locked flow
# ---------------------------------------------------------------------------
run_locked() {
  trap 'abort_run "interrupted"' INT TERM

  AVB_WS=$WORK/avb
  rm -rf "$AVB_WS" || abort_run "cannot clear $AVB_WS"
  mkdir -p "$AVB_WS" || abort_run "cannot create $AVB_WS"
  avbpt_run config list --json >/dev/null 2>&1 ||
    abort_run "cannot initialise the avbpt workspace"
  IMGDIR=$AVB_WS/Images
  [ -d "$IMGDIR" ] || mkdir -p "$IMGDIR" || abort_run "cannot create $IMGDIR"

  # ------------------------------------------------------------------
  step "1/9 reading the eight partitions and abl"
  read_all_images || abort_run "cannot read one of the eight partitions"
  resolve_abl_dev || abort_run "abl partition not found"
  read_partition_raw "$ABLDEV" "$WORK/abl.img" || abort_run "cannot read abl"
  [ "$(stat -c %s "$WORK/abl.img")" = "$ABL_SIZE" ] ||
    abort_run "abl is not exactly 1 MiB"
  ok "read 8 partitions + abl"

  # ------------------------------------------------------------------
  step "2/9 verifying the current AVB trust chain"
  # Dry runs and --force-locked are test paths: keep the chain checks
  # advisory so that they can still exercise a stock unlocked device.
  if [ "$DRY_RUN" = 1 ] || [ "$FORCE_LOCKED" = 1 ]; then
    _strict=warn
  else
    _strict=strict
  fi
  avbpt_run image inspect boot dtbo init_boot pvmfw recovery \
    vbmeta vbmeta_system vendor_boot --json > "$WORK/inspect.json" ||
    abort_run "image inspect failed"
  if ! avbpy "$BIN_DIR/oneroot_preflight.py" "$WORK/inspect.json" \
    "$_strict" "$WORK/preflight.env"; then
    abort_run "current partition set does not form a bootable trust chain"
  fi
  . "$WORK/preflight.env"
  ok "targets: recovery_ri=$RECOVERY_RI vs=$VS_ALG zuxos=${ZUXOS:-?} abl=$ABL_NEEDED"

  case "$ABL_NEEDED" in
    yes) ABL_WRITE=1 ;;
    no) ABL_WRITE=0 ;;
    *)
      if [ "$DRY_RUN" = 1 ] || [ "$FORCE_LOCKED" = 1 ]; then
        warn "ZUXOS unknown; abl will not be written"
        ABL_WRITE=0
      else
        abort_run "ZUXOS unknown; refusing to guess the ABL target"
      fi
      ;;
  esac

  # ------------------------------------------------------------------
  step "3/9 generating the testkey profile"
  ID="kernelavb_$(date +%Y%m%d_%H%M%S)"
  NAME="TB710FU kernel AVB $ID"
  "$BIN_DIR/avbpt-config-gen.sh" --workspace "$AVB_WS" --id "$ID" --name "$NAME" \
    --key-dir "$AVBPT_ROOT/tools" --recovery-ri "$RECOVERY_RI" \
    --vs-alg "$VS_ALG" --vs-key "$VS_KEY" --avbpt "$AVBPT_BIN" ||
    abort_run "profile generation failed"
  ok "profile: $ID"

  # ------------------------------------------------------------------
  step "4/9 backing up the current partition set"
  require_space || abort_run "not enough free space on /data"
  if [ ! -d /sdcard ] || [ ! -w /sdcard ]; then
    abort_run "/sdcard is not writable; the backup must be written there"
  fi
  mkdir -p "$BACKUP_BASE" || abort_run "cannot create $BACKUP_BASE"
  backup_set || abort_run "backup failed; nothing has been written"
  ok "backup: $BK"

  print_plan
  if [ "$DRY_RUN" != 1 ]; then
    confirm_or_abort
  fi

  # ------------------------------------------------------------------
  step "5/9 installing the repacked boot image"
  trim_repacked_boot

  # ------------------------------------------------------------------
  step "6/9 signing the eight images"
  avbpt_run image sign boot dtbo init_boot pvmfw recovery \
    vbmeta vbmeta_system vendor_boot --profile "$ID" \
    --execute --yes --remove-footers --json ||
    abort_run "image sign failed"
  verify_signed_images || abort_run "post-sign verification failed"
  ok "all signed images verified"

  if [ "$DRY_RUN" = 1 ]; then
    ok "dry-run complete; no partition was written"
    ok "images are in $IMGDIR"
    trap - INT TERM
    exit 0
  fi

  # ------------------------------------------------------------------
  step "7/9 flashing the eight images"
  WRITES_DONE=1
  for _p in $FLASH_ORDER; do
    flash_partition "$_p" "$IMGDIR/$_p.img" ||
      abort_run "flash/verify failed for $_p"
    ok "flashed $_p"
  done

  # ------------------------------------------------------------------
  step "8/9 checking abl"
  write_abl

  # ------------------------------------------------------------------
  step "9/9 delivering the log"
  download_dir
  if [ -d "${DOWNLOAD:-}" ]; then
    cp -f "$LOG" "$DOWNLOAD/kernel_avb.log" 2>/dev/null && ok "log: $DOWNLOAD/kernel_avb.log"
  fi

  ok "kernel installed on boot$SLOT with a rebuilt testkey AVB chain"
  alert "backup: $BK"
  alert "restore: sh $BK/restore.sh   (or: kernel_avb_flash.sh --restore \"$BK\")"
  if [ "$ABL_WRITTEN" = 1 ]; then
    alert "abl was replaced: the other slot's OEM images will not boot"
    alert "do not reboot repeatedly if boot fails; restore from TWRP first"
  fi
  ok "all steps completed. Reboot to system when ready."
  trap - INT TERM
}

print_plan() {
  alert "mode: locked, bootloader state: $ACTUAL_MODE (slot $SLOT)"
  alert "will flash: $FLASH_ORDER"
  if [ "$ABL_WRITE" = 1 ]; then
    alert "will ensure the bundled old ABL (needed=$ABL_NEEDED)"
  else
    alert "will NOT write abl (needed=$ABL_NEEDED)"
  fi
  alert "backup: $BK"
  alert "do not reboot until this script reports success"
}

write_abl() {
  if [ "$ABL_WRITE" = 1 ]; then
    _cur=$(sha256sum "$ABLDEV" | cut -d' ' -f1)
    if [ "$_cur" = "$BUNDLED_ABL_SHA" ]; then
      ok "abl already matches the bundled image; not rewritten"
      ABL_WRITTEN=0
    else
      _abl=$AVBPT_ROOT/tools/abl.img
      [ "$(stat -c %s "$_abl")" = "$ABL_SIZE" ] ||
        abort_run "bundled abl size is not 1 MiB"
      [ "$(od -An -tx1 -N4 "$_abl" | tr -d ' \n')" = "7f454c46" ] ||
        abort_run "bundled abl is not an ELF image"
      [ "$(sha256sum "$_abl" | cut -d' ' -f1)" = "$BUNDLED_ABL_SHA" ] ||
        abort_run "bundled abl checksum mismatch"
      dd if="$_abl" of="$ABLDEV" bs=1M 2>"$WORK/dd.err" ||
        abort_run "abl write failed"
      sync
      cmp "$_abl" "$ABLDEV" || abort_run "abl readback mismatch"
      ABL_WRITTEN=1
      ok "abl replaced with the bundled image"
    fi
  else
    ABL_WRITTEN=0
    ok "abl not written (needed=$ABL_NEEDED)"
  fi
}

run_locked
exit 0
