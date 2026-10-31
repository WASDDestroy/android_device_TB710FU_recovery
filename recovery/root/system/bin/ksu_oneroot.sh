#!/system/bin/sh
# One-click KernelSU root for Lenovo TB710FU (topaz) inside TWRP/YARP.
#
# Two flows:
#   unlocked bootloader : patch init_boot and flash it directly
#   locked bootloader   : rebuild a testkey AVB trust chain with avbpowertool,
#                         patch init_boot, sign eight images, flash them and
#                         (for ZUXOS >= 1.5.04.445) restore the old ABL.
#
# The locked flow is documented in docs/NO_UNLOCK_ROOT_PLAN.md.
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

LOG=/tmp/oneroot.log
: > "$LOG" 2>/dev/null || true

. "$BIN_DIR/oneroot_common.sh"
. "$BIN_DIR/oneroot_locked.sh"

DRY_RUN=0
ASSUME_YES=0
MODE_OVERRIDE=""
ABL_MODE=auto
BACKUP_BASE=""
RESTORE_DIR=""

usage() {
  cat <<'EOF'
Usage: ksu_oneroot.sh [options]

  --yes                 skip the interactive confirmation (locked flow)
  --dry-run             locked flow only: read/config/backup/patch/sign, no flash
  --mode MODE           auto | locked | unlocked (default: auto)
  --abl MODE            auto | force | skip (default: auto)
  --backup-dir DIR      locked flow backup directory
  --restore DIR         restore a backup made by the locked flow
  -h, --help            show this help

Unlocked flow: patch init_boot and flash it.
Locked flow:   rebuild a testkey AVB chain, sign 8 images, flash them,
               and restore the old ABL when ZUXOS >= 1.5.04.445.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --mode)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      MODE_OVERRIDE=$1
      ;;
    --mode=*) MODE_OVERRIDE=${1#*=} ;;
    --abl)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      ABL_MODE=$1
      ;;
    --abl=*) ABL_MODE=${1#*=} ;;
    --backup-dir)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      BACKUP_BASE=$1
      ;;
    --backup-dir=*) BACKUP_BASE=${1#*=} ;;
    --restore)
      shift
      [ $# -gt 0 ] || { usage >&2; exit 2; }
      RESTORE_DIR=$1
      ;;
    --restore=*) RESTORE_DIR=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$ABL_MODE" in
  auto|force|skip) ;;
  *) echo "invalid --abl: $ABL_MODE" >&2; exit 2 ;;
esac

case "$MODE_OVERRIDE" in
  ''|auto|locked|unlocked) ;;
  *) echo "invalid --mode: $MODE_OVERRIDE" >&2; exit 2 ;;
esac

init_tools

# ---------------------------------------------------------------------------
# restore mode: no bootloader/data/OTA checks, just write the backup back
# ---------------------------------------------------------------------------
if [ -n "$RESTORE_DIR" ]; then
  [ -d "$RESTORE_DIR" ] || fail "restore directory not found: $RESTORE_DIR"
  detect_slot
  WORK=/tmp/oneroot_restore
  rm -rf "$WORK" || fail "cannot clear $WORK"
  mkdir -p "$WORK" || fail "cannot create $WORK"
  restore_from_backup "$RESTORE_DIR"
  exit 0
fi

require_data
detect_slot
ota_guard
detect_mode

if [ -n "$MODE_OVERRIDE" ] && [ "$MODE_OVERRIDE" != auto ]; then
  case "$MODE_OVERRIDE" in
    locked)
      if [ "$ACTUAL_MODE" = unlocked ] && [ "$DRY_RUN" != 1 ]; then
        fail "--mode locked on an unlocked device requires --dry-run"
      fi
      MODE=locked
      ;;
    unlocked)
      if [ "$ACTUAL_MODE" = locked ]; then
        fail "refusing --mode unlocked on a locked device"
      fi
      MODE=unlocked
      ;;
  esac
  if [ "$ACTUAL_MODE" = unknown ]; then
    warn "bootloader state is unknown; using --mode $MODE"
  fi
else
  case "$ACTUAL_MODE" in
    locked|unlocked) MODE=$ACTUAL_MODE ;;
    *) fail "unable to determine bootloader state; pass --mode locked|unlocked" ;;
  esac
fi

if [ "$MODE" = unlocked ] && [ "$DRY_RUN" = 1 ]; then
  fail "--dry-run is only supported for the locked flow (use --mode locked --dry-run)"
fi

[ -n "$BACKUP_BASE" ] || BACKUP_BASE=/sdcard/Download/twrp_no_unlocking
prepare_work

# ---------------------------------------------------------------------------
# unlocked flow
# ---------------------------------------------------------------------------
run_unlocked() {
  trap 'log "[ERROR] Interrupted"; exit 1' INT TERM

  step "1/9 bootloader state"
  ok "bootloader is unlocked"

  step "2/9 /data decryption"
  ok "/data is decrypted"

  step "3/9 reading boot/init_boot and checking root state"
  STOCK=$WORK/init_boot_stock.img
  BOOTIMG=$WORK/boot_stock.img
  DEV=/dev/block/by-name/init_boot$SLOT
  read_partition init_boot "$STOCK" || fail "cannot read $DEV"
  read_partition boot "$BOOTIMG" || fail "cannot read boot$SLOT"

  magic=$(od -An -c -N8 "$STOCK" | tr -d ' \n')
  [ "$magic" = "ANDROID!" ] || fail "init_boot image has no ANDROID! magic"

  part_size=$(blockdev --getsize64 "$DEV" 2>/dev/null) || fail "cannot query $DEV size"
  stock_size=$(stat -c %s "$STOCK" 2>/dev/null) || fail "cannot stat $STOCK"
  [ "$stock_size" = "$part_size" ] ||
    fail "readback size $stock_size != partition size $part_size"
  STOCK_SHA1=$(sha1sum "$STOCK" | cut -d' ' -f1)
  ok "init_boot$SLOT: $stock_size bytes, sha1=$STOCK_SHA1"

  detect_root_state "$BOOTIMG" "$STOCK"

  step "4/9 checking network connectivity"
  check_network

  step "5/9 acquiring KernelSU APK"
  acquire_apk || fail "no usable KernelSU APK (no network and no installed package)"
  ok "KernelSU APK: $APK"

  step "6/9 extracting ksud and installing userspace"
  extract_ksud || fail "cannot extract ksud from $APK"
  install_ksud_userspace || fail "ksud install failed"

  step "7/9 backing up stock image and patching"
  mkdir -p /data/adb/ksu || fail "cannot create /data/adb/ksu"
  chmod 700 /data/adb/ksu 2>/dev/null || true
  BACKUP="/data/adb/ksu/ksu_backup_$STOCK_SHA1"
  [ -f "$BACKUP" ] && log "existing KernelSU backup will be reused: $BACKUP"

  PATCHED=$WORK/init_boot_patched.img
  rm -f "$PATCHED"
  "$KSUD" boot-patch -b "$STOCK" --backup -o "$WORK" \
    --out-name init_boot_patched.img --partition init_boot ||
    fail "ksud boot-patch failed"
  [ -f "$PATCHED" ] || fail "patched image was not created"

  patched_size=$(stat -c %s "$PATCHED" 2>/dev/null) || fail "cannot stat patched image"
  [ "$patched_size" = "$part_size" ] ||
    fail "patched image size $patched_size != $part_size"

  [ -f "$BACKUP" ] || fail "KernelSU backup was not created: $BACKUP"
  backup_size=$(stat -c %s "$BACKUP" 2>/dev/null)
  [ "$backup_size" = "$part_size" ] || fail "backup size $backup_size != $part_size"
  backup_sha1=$(sha1sum "$BACKUP" | cut -d' ' -f1)
  [ "$backup_sha1" = "$STOCK_SHA1" ] || fail "backup sha1 mismatch"
  ok "stock image backed up to $BACKUP"

  unpack_listing "$PATCHED" patched || fail "cannot unpack the patched image"
  grep -Fqx "kernelsu.ko" "$WORK/unpack_patched/listing.txt" ||
    fail "patched image does not contain kernelsu.ko"
  ok "patched image contains kernelsu.ko"

  step "8/9 flashing patched init_boot and verifying"
  flash_partition init_boot "$PATCHED" || fail "cannot write/verify $DEV"
  ok "flash verified"

  step "9/9 delivering APK, backup copy and log"
  download_dir
  APK_COPY=$APK
  if [ -d "${DOWNLOAD:-}" ]; then
    if [ "$TAG" = installed ]; then
      APK_COPY=$DOWNLOAD/KernelSU-installed.apk
    else
      APK_COPY=$DOWNLOAD/KernelSU-$TAG.apk
    fi
    if cp -f "$APK" "$APK_COPY" 2>/dev/null; then
      chmod 644 "$APK_COPY" 2>/dev/null || true
      ok "APK copied to $APK_COPY"
    else
      warn "cannot copy APK to $APK_COPY"
      APK_COPY=$APK
    fi

    mkdir -p "$DOWNLOAD/KernelSU-backup" 2>/dev/null || true
    BACKUP_COPY="$DOWNLOAD/KernelSU-backup/init_boot${SLOT}_${STOCK_SHA1}.img"
    if cp -f "$STOCK" "$BACKUP_COPY" 2>/dev/null; then
      sync
      ok "stock image copy: $BACKUP_COPY"
    else
      warn "cannot copy stock image to $BACKUP_COPY"
    fi
    copy_log
  fi

  log "KernelSU root installed successfully on init_boot$SLOT."
  log "Backup: $BACKUP"
  log "Log: $LOG"
  [ -n "${BACKUP_COPY:-}" ] && log "Extra stock copy: $BACKUP_COPY"
  alert "ACTION REQUIRED: after booting Android, install the KernelSU APK from"
  alert "  $APK_COPY"
  alert "Then open KernelSU once so it can finish the userspace setup."
  alert "Do not format /data before keeping a copy of the stock image."
  ok "all steps completed. Reboot to system when ready."
  exit 0
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
if [ "$MODE" = locked ]; then
  trap 'locked_abort "interrupted"' INT TERM
  run_locked
else
  run_unlocked
fi
