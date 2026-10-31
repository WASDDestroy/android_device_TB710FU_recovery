#!/system/bin/sh
# Locked-bootloader flow for ksu_oneroot.  Sourced by ksu_oneroot.sh.
#
# Requires from the caller: LOG, BIN_DIR, WORK, IMGDIR, AVB_WS, SLOT,
# BACKUP_BASE, AVBPT_ROOT, AVBPT_BIN, DRY_RUN, ASSUME_YES, ABL_MODE.

locked_abort() {
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

print_locked_plan() {
  alert "mode: locked (slot $SLOT)"
  alert "will flash: $FLASH_ORDER"
  if [ "$ABL_WRITE" = 1 ]; then
    alert "will ensure the bundled old ABL (needed=$ABL_NEEDED)"
  else
    alert "will NOT write abl (needed=$ABL_NEEDED, mode=$ABL_MODE)"
  fi
  alert "backup: $BK"
  alert "do not reboot until this script reports success"
}

run_locked() {
  step "locked-bootloader one-click root"

  AVB_WS=$WORK/avb
  rm -rf "$AVB_WS" || locked_abort "cannot clear $AVB_WS"
  mkdir -p "$AVB_WS" || locked_abort "cannot create $AVB_WS"
  avbpt_run config list --json >/dev/null 2>&1 ||
    locked_abort "cannot initialise the avbpt workspace"
  IMGDIR=$AVB_WS/Images
  [ -d "$IMGDIR" ] || mkdir -p "$IMGDIR" || locked_abort "cannot create $IMGDIR"

  # ------------------------------------------------------------------
  step "1/10 reading the eight partitions and abl"
  for _p in $TARGET_IMAGES; do
    rm -f "$IMGDIR/$_p.img"
  done
  read_all_images || locked_abort "cannot read one of the eight partitions"
  resolve_abl_dev || locked_abort "abl partition not found"
  read_partition_raw "$ABLDEV" "$WORK/abl.img" || locked_abort "cannot read abl"
  [ "$(stat -c %s "$WORK/abl.img")" = "$ABL_SIZE" ] ||
    locked_abort "abl is not exactly 1 MiB"
  ok "read 8 partitions + abl"

  # ------------------------------------------------------------------
  step "2/10 checking existing root state"
  detect_root_state "$IMGDIR/boot.img" "$IMGDIR/init_boot.img" ||
    locked_abort "cannot determine the current root state"

  # ------------------------------------------------------------------
  step "3/10 verifying the current AVB trust chain"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    _strict=warn
  else
    _strict=strict
  fi
  avbpt_run image inspect boot dtbo init_boot pvmfw recovery \
    vbmeta vbmeta_system vendor_boot --json > "$WORK/inspect.json" ||
    locked_abort "image inspect failed"
  if ! avbpy "$BIN_DIR/oneroot_preflight.py" "$WORK/inspect.json" \
    "$_strict" "$WORK/preflight.env"; then
    locked_abort "current partition set does not form a bootable trust chain"
  fi
  . "$WORK/preflight.env"
  ok "targets: recovery_ri=$RECOVERY_RI vs=$VS_ALG zuxos=${ZUXOS:-?} abl=$ABL_NEEDED"

  case "$ABL_MODE" in
    force) ABL_WRITE=1 ;;
    skip) ABL_WRITE=0 ;;
    auto)
      case "$ABL_NEEDED" in
        yes) ABL_WRITE=1 ;;
        no) ABL_WRITE=0 ;;
        *)
          if [ "${DRY_RUN:-0}" = 1 ]; then
            warn "ZUXOS unknown; abl will not be written (dry-run)"
            ABL_WRITE=0
          else
            locked_abort "ZUXOS unknown; pass --abl=force or --abl=skip"
          fi
          ;;
      esac
      ;;
    *) locked_abort "invalid abl mode: $ABL_MODE" ;;
  esac

  # ------------------------------------------------------------------
  step "4/10 generating the testkey profile"
  ID="oneroot_$(date +%Y%m%d_%H%M%S)"
  NAME="TB710FU oneroot $ID"
  "$BIN_DIR/avbpt-config-gen.sh" --workspace "$AVB_WS" --id "$ID" --name "$NAME" \
    --key-dir "$AVBPT_ROOT/tools" --recovery-ri "$RECOVERY_RI" \
    --vs-alg "$VS_ALG" --vs-key "$VS_KEY" --avbpt "$AVBPT_BIN" ||
    locked_abort "profile generation failed"
  ok "profile: $ID"

  # ------------------------------------------------------------------
  step "5/10 backing up the current partition set"
  require_space || locked_abort "not enough free space on /data"
  if [ ! -d /sdcard ] || [ ! -w /sdcard ]; then
    locked_abort "/sdcard is not writable; the backup must be written there"
  fi
  mkdir -p "$BACKUP_BASE" || locked_abort "cannot create $BACKUP_BASE"
  backup_set || locked_abort "backup failed; nothing has been written"
  ok "backup: $BK"

  print_locked_plan
  if [ "${DRY_RUN:-0}" != 1 ]; then
    confirm_or_abort
  fi

  # ------------------------------------------------------------------
  step "6/10 acquiring KernelSU and patching init_boot"
  check_network
  acquire_apk || locked_abort "no usable KernelSU APK"
  ok "APK: $APK ($TAG)"
  extract_ksud || locked_abort "cannot extract ksud"
  install_ksud_userspace || locked_abort "ksud install failed"

  rm -f "$WORK/init_boot_patched.img"
  "$KSUD" boot-patch -b "$IMGDIR/init_boot.img" --backup \
    -o "$WORK" --out-name init_boot_patched.img --partition init_boot ||
    locked_abort "ksud boot-patch failed"
  PATCHED=$WORK/init_boot_patched.img
  [ -f "$PATCHED" ] || locked_abort "patched init_boot was not created"

  _init_size=$(blockdev --getsize64 "/dev/block/by-name/init_boot$SLOT") ||
    locked_abort "cannot query init_boot size"
  _patched_size=$(stat -c %s "$PATCHED") || locked_abort "cannot stat patched image"
  [ "$_patched_size" -le "$_init_size" ] ||
    locked_abort "patched init_boot ($_patched_size) exceeds the partition ($_init_size)"

  unpack_listing "$PATCHED" patched || locked_abort "cannot unpack the patched image"
  grep -Fqx "kernelsu.ko" "$WORK/unpack_patched/listing.txt" ||
    locked_abort "patched init_boot does not contain kernelsu.ko"

  mv -f "$PATCHED" "$IMGDIR/init_boot.img" || locked_abort "cannot replace init_boot.img"
  if ! avbpt_run image inspect init_boot 2>/dev/null | grep -q "Hash descriptor"; then
    locked_abort "patched init_boot lost its AVB footer"
  fi
  ok "init_boot patched ($_patched_size bytes)"

  # ------------------------------------------------------------------
  step "7/10 signing the eight images"
  avbpt_run image sign boot dtbo init_boot pvmfw recovery \
    vbmeta vbmeta_system vendor_boot --profile "$ID" \
    --execute --yes --remove-footers --json ||
    locked_abort "image sign failed"
  verify_signed_images || locked_abort "post-sign verification failed"
  ok "all signed images verified"

  if [ "${DRY_RUN:-0}" = 1 ]; then
    ok "dry-run complete; no partition was written"
    ok "images are in $IMGDIR"
    trap - INT TERM
    exit 0
  fi

  # ------------------------------------------------------------------
  step "8/10 flashing the eight images"
  WRITES_DONE=1
  for _p in $FLASH_ORDER; do
    flash_partition "$_p" "$IMGDIR/$_p.img" ||
      locked_abort "flash/verify failed for $_p"
    ok "flashed $_p"
  done

  # ------------------------------------------------------------------
  step "9/10 checking abl"
  if [ "$ABL_WRITE" = 1 ]; then
    _cur=$(sha256sum "$ABLDEV" | cut -d' ' -f1)
    if [ "$_cur" = "$BUNDLED_ABL_SHA" ]; then
      ok "abl already matches the bundled image; not rewritten"
      ABL_WRITTEN=0
    else
      _abl=$AVBPT_ROOT/tools/abl.img
      [ "$(stat -c %s "$_abl")" = "$ABL_SIZE" ] ||
        locked_abort "bundled abl size is not 1 MiB"
      [ "$(od -An -tx1 -N4 "$_abl" | tr -d ' \n')" = "7f454c46" ] ||
        locked_abort "bundled abl is not an ELF image"
      [ "$(sha256sum "$_abl" | cut -d' ' -f1)" = "$BUNDLED_ABL_SHA" ] ||
        locked_abort "bundled abl checksum mismatch"
      dd if="$_abl" of="$ABLDEV" bs=1M 2>"$WORK/dd.err" ||
        locked_abort "abl write failed"
      sync
      cmp "$_abl" "$ABLDEV" || locked_abort "abl readback mismatch"
      ABL_WRITTEN=1
      ok "abl replaced with the bundled image"
    fi
  else
    ABL_WRITTEN=0
    ok "abl not written (needed=$ABL_NEEDED mode=$ABL_MODE)"
  fi
  trap - INT TERM

  # ------------------------------------------------------------------
  step "10/10 delivering APK and log"
  download_dir
  if [ -d "${DOWNLOAD:-}" ]; then
    if [ "$TAG" = installed ]; then
      _apk_copy=$DOWNLOAD/KernelSU-installed.apk
    else
      _apk_copy=$DOWNLOAD/KernelSU-$TAG.apk
    fi
    if cp -f "$APK" "$_apk_copy" 2>/dev/null; then
      chmod 644 "$_apk_copy" 2>/dev/null || true
      ok "APK copied to $_apk_copy"
    else
      warn "cannot copy APK to $_apk_copy"
      _apk_copy=$APK
    fi
    copy_log
  else
    _apk_copy=$APK
    warn "cannot access Download; APK remains at $APK"
  fi

  ok "KernelSU root installed on init_boot$SLOT"
  alert "backup: $BK"
  alert "restore: sh $BK/restore.sh   (or: ksu_oneroot.sh --restore \"$BK\")"
  if [ "$ABL_WRITTEN" = 1 ]; then
    alert "abl was replaced: the other slot's OEM images will not boot"
    alert "do not reboot repeatedly if boot fails; restore from TWRP first"
  fi
  alert "ACTION REQUIRED: after booting Android, install the KernelSU APK from"
  alert "  $_apk_copy"
  alert "Then open KernelSU once so it can finish the userspace setup."
  ok "all steps completed. Reboot to system when ready."
}
