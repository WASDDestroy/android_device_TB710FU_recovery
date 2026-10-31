#!/system/bin/sh
# Shared helpers for ksu_oneroot (unlocked and locked flows).
#
# POSIX sh, toybox-sh compatible: no arrays, no [[ ]], no `local`.
# The caller sets LOG, BIN_DIR and (for the locked flow) AVB_WS/IMGDIR.

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
PKG=me.weishu.kernelsu
PINNED_TAG=v3.3.1
PINNED_APK_NAME=KernelSU_v3.3.1_32680-release.apk
PINNED_APK_URL="https://github.com/tiann/KernelSU/releases/download/v3.3.1/$PINNED_APK_NAME"
PINNED_APK_SIZE=13637206
PINNED_APK_SHA=b4a059ace71de2fa65cc7f12b1c58d55fc23ab25e057ee4230ce779742abe450

# The bundled ABL is an ELF32 ARM image of exactly one MiB.
BUNDLED_ABL_SHA=6cfa16e65c2dadd0fc557dd356e6c383c693b4c3b7f0a651d92bb9f6e38b74a8
ABL_SIZE=1048576

TARGET_IMAGES="boot dtbo init_boot pvmfw recovery vbmeta vbmeta_system vendor_boot"
HASH_IMAGES="boot dtbo init_boot pvmfw recovery vendor_boot"
FLASH_ORDER="dtbo init_boot pvmfw vendor_boot boot recovery vbmeta_system vbmeta"

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
LOG=${LOG:-/tmp/oneroot.log}
log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG" 2>/dev/null || true
}
step() { log "[STEP] $*"; }
ok() { log "[OK] $*"; }
warn() { log "[WARN] $*"; }
alert() { log "[ALERT] $*"; }
fail() {
  log "[ERROR] $*"
  log "[ERROR] Aborting."
  exit 1
}

# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------
find_avbpt_root() {
  if [ -n "${AVBPT_ROOT:-}" ] && [ -x "$AVBPT_ROOT/py/python" ]; then
    return 0
  fi
  for _d in /avbpowertool /customzip/avbpowertool; do
    if [ -x "$_d/py/python" ]; then
      AVBPT_ROOT=$_d
      return 0
    fi
  done
  return 1
}

init_tools() {
  find_avbpt_root || fail "avbpowertool payload not found (py/python missing)"
  AVBPT_BIN=/sbin/avbpt
  if [ ! -x "$AVBPT_BIN" ]; then
    AVBPT_BIN=$(command -v avbpt 2>/dev/null) || fail "avbpt launcher not found"
  fi
  MAGISKBOOT=/system/bin/magiskboot
  [ -x "$MAGISKBOOT" ] || fail "magiskboot is missing from this recovery build"
  CURL=/system/bin/curl
  [ -x "$CURL" ] || fail "curl is missing from this recovery build"
  command -v bootctl >/dev/null 2>&1 || fail "bootctl is missing from this recovery build"
  command -v unzip >/dev/null 2>&1 || fail "unzip is missing from this recovery build"
  command -v toybox >/dev/null 2>&1 || fail "toybox is missing from this recovery build"
  log "payload root: $AVBPT_ROOT"
  log "avbpt: $AVBPT_BIN"
}

avbpt_run() {
  [ -n "${AVB_WS:-}" ] || fail "internal error: AVB_WS is not set"
  "$AVBPT_BIN" --workspace "$AVB_WS" --no-warn "$@"
}

avbpy() {
  AVB_CRYPTO_BACKEND=openssl \
  PYTHONDONTWRITEBYTECODE=1 \
  PYTHONHOME="$AVBPT_ROOT/py" \
  LD_LIBRARY_PATH="$AVBPT_ROOT/py:/system/lib64:${LD_LIBRARY_PATH:-}" \
  PYTHONPATH="$AVBPT_ROOT/compat:$AVBPT_ROOT/app:$AVBPT_ROOT/stdlib/python312.zip:$AVBPT_ROOT/pylib" \
  PATH="$AVBPT_ROOT/bin:${PATH:-/system/bin}" \
  "$AVBPT_ROOT/py/python" "$@"
}

# ---------------------------------------------------------------------------
# mode, slot, OTA
# ---------------------------------------------------------------------------
detect_mode() {
  ACTUAL_MODE=unknown
  _ds=$(getprop ro.boot.vbmeta.device_state 2>/dev/null || true)
  _fl=$(getprop ro.boot.flash.locked 2>/dev/null || true)
  _vb=$(getprop ro.boot.verifiedbootstate 2>/dev/null || true)
  log "device_state=${_ds:-<empty>} flash.locked=${_fl:-<empty>} verifiedbootstate=${_vb:-<empty>}"
  if [ "$_ds" = locked ] || [ "$_fl" = 1 ]; then
    ACTUAL_MODE=locked
  elif [ "$_ds" = unlocked ] || [ "$_fl" = 0 ]; then
    ACTUAL_MODE=unlocked
  fi
  log "actual bootloader mode: $ACTUAL_MODE"
}

detect_slot() {
  SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null || true)
  case "$SLOT" in
    _a|_b) ;;
    *) fail "unexpected or empty slot suffix: '${SLOT:-<empty>}'" ;;
  esac
  if [ "$SLOT" = _a ]; then SLOT_NUM=0; else SLOT_NUM=1; fi
  log "active slot: $SLOT (slot $SLOT_NUM)"
}

ota_guard() {
  _cur=$(bootctl get-current-slot 2>/dev/null) || fail "bootctl get-current-slot failed"
  _act=$(bootctl get-active-boot-slot 2>/dev/null) || fail "bootctl get-active-boot-slot failed"
  _merge=$(bootctl get-snapshot-merge-status 2>/dev/null) ||
    fail "bootctl get-snapshot-merge-status failed"
  log "bootctl: current=$_cur active=$_act merge=$_merge"
  [ "$_cur" = "$_act" ] || fail "OTA pending: the next boot would switch slots"
  [ "$_merge" = none ] || fail "virtual A/B merge in progress: $_merge"
  [ "$_cur" = "$SLOT_NUM" ] ||
    fail "slot/suffix mismatch: bootctl=$_cur suffix=$SLOT"
  ok "no pending OTA or slot switch"
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
require_data() {
  _u=$(getprop twrp.user.0.decrypt 2>/dev/null || true)
  _a=$(getprop twrp.all.users.decrypted 2>/dev/null || true)
  log "twrp.user.0.decrypt=${_u:-<empty>} twrp.all.users.decrypted=${_a:-<empty>}"
  if [ "$_u" = 1 ] && mountpoint -q /data && [ -r /data/system/packages.xml ]; then
    ok "IS_FBE_DECRYPTED=1 (/data is mounted and readable)"
  else
    warn "/data is not decrypted"
    warn "TWRP: Mount -> Decrypt Data, then run this tool again."
    fail "/data must be decrypted before running this tool"
  fi
  [ -d /data/adb ] || mkdir -p /data/adb || fail "cannot create /data/adb"
  [ -w /data/adb ] || fail "/data/adb is not writable"
}

prepare_work() {
  WORK=/data/local/tmp/oneroot
  rm -rf "$WORK" || fail "cannot clear $WORK"
  mkdir -p "$WORK" || fail "cannot create $WORK"
  ok "work directory: $WORK"
}

require_space() {
  _total=0
  for _p in $TARGET_IMAGES; do
    _sz=$(stat -c %s "$IMGDIR/$_p.img" 2>/dev/null) || return 1
    _total=$((_total + _sz))
  done
  _need_kb=$((_total / 1024 * 26 / 10 + 65536))
  _avail_kb=$(df -k /data | tail -n 1 | awk '{print $4}')
  [ -n "$_avail_kb" ] || return 1
  log "images=$_total bytes need~${_need_kb}KiB available=${_avail_kb}KiB"
  [ "$_avail_kb" -ge "$_need_kb" ] || return 1
}

# ---------------------------------------------------------------------------
# block devices
# ---------------------------------------------------------------------------
read_partition_raw() {
  _dev=$1
  _dst=$2
  _size=$(blockdev --getsize64 "$_dev" 2>/dev/null) || return 1
  dd if="$_dev" of="$_dst" bs=1M 2>"$WORK/dd.err" || return 1
  sync
  _got=$(stat -c %s "$_dst" 2>/dev/null) || return 1
  [ "$_got" = "$_size" ] || return 1
  return 0
}

read_partition() {
  _p=$1
  _dst=$2
  _dev=/dev/block/by-name/${_p}${SLOT}
  [ -e "$_dev" ] || return 1
  read_partition_raw "$_dev" "$_dst"
}

resolve_abl_dev() {
  ABLDEV=/dev/block/by-name/abl${SLOT}
  [ -e "$ABLDEV" ] || ABLDEV=/dev/block/by-name/abl
  [ -e "$ABLDEV" ] || return 1
  return 0
}

read_all_images() {
  for _p in $TARGET_IMAGES; do
    _dev=/dev/block/by-name/${_p}${SLOT}
    [ -e "$_dev" ] || return 1
    read_partition "$_p" "$IMGDIR/$_p.img" || return 1
    log "  $_p: $(stat -c %s "$IMGDIR/$_p.img") bytes"
  done
  return 0
}

# Writes an image and verifies the bytes actually stored in the partition.
# The image may be shorter than the partition (vbmeta); only the image
# length is compared, never the stale tail.
flash_partition() {
  _p=$1
  _img=$2
  _dev=/dev/block/by-name/${_p}${SLOT}
  [ -e "$_dev" ] || return 1
  _size=$(blockdev --getsize64 "$_dev" 2>/dev/null) || return 1
  _isz=$(stat -c %s "$_img" 2>/dev/null) || return 1
  [ "$_isz" -gt 0 ] || return 1
  [ "$_isz" -le "$_size" ] || return 1
  dd if="$_img" of="$_dev" bs=1M 2>"$WORK/dd.err" || return 1
  sync
  _want=$(sha256sum "$_img" | cut -d' ' -f1)
  _got=$(head -c "$_isz" "$_dev" | sha256sum | cut -d' ' -f1)
  [ "$_want" = "$_got" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# root state
# ---------------------------------------------------------------------------
unpack_listing() {
  _img=$1
  _tag=$2
  _dir=$WORK/unpack_$_tag
  rm -rf "$_dir" || return 1
  mkdir -p "$_dir" || return 1
  ( cd "$_dir" && "$MAGISKBOOT" unpack "$_img" >/dev/null 2>&1 ) || return 1
  [ -f "$_dir/ramdisk.cpio" ] || return 1
  toybox cpio -it < "$_dir/ramdisk.cpio" > "$_dir/listing.txt" 2>/dev/null || return 1
  return 0
}

detect_root_state() {
  _boot_img=$1
  _init_img=$2

  unpack_listing "$_init_img" init || fail "cannot unpack init_boot"
  if grep -Fqx "kernelsu.ko" "$WORK/unpack_init/listing.txt"; then
    fail "init_boot is already patched by KernelSU; refusing to run again"
  fi
  if grep -Fq ".backup/.magisk" "$WORK/unpack_init/listing.txt"; then
    fail "init_boot is already patched by Magisk; refusing"
  fi

  unpack_listing "$_boot_img" boot || fail "cannot unpack boot"
  if grep -Fqx "kernelsu.ko" "$WORK/unpack_boot/listing.txt"; then
    fail "boot is already patched by KernelSU (GKI); refusing to run again"
  fi
  if grep -Fqx "init.real" "$WORK/unpack_boot/listing.txt"; then
    fail "boot is already patched by KernelSU (init.real); refusing to run again"
  fi
  if grep -Fq ".backup/.magisk" "$WORK/unpack_boot/listing.txt"; then
    fail "boot is already patched by Magisk; refusing"
  fi
  ok "boot and init_boot are not patched"
}

# ---------------------------------------------------------------------------
# network + KernelSU APK (ported from the original one-click script)
# ---------------------------------------------------------------------------
IS_INTERNET_AVAILABLE=0

ping_ok() {
  timeout 3 ping -c 1 -q "$1" >/dev/null 2>&1
}
https_ok() {
  "$CURL" -fsSI --connect-timeout 4 --max-time 6 "https://$1" >/dev/null 2>&1
}

check_network() {
  IS_INTERNET_AVAILABLE=0
  for _host in www.baidu.com cn.bing.com github.com; do
    if ping_ok "$_host"; then
      IS_INTERNET_AVAILABLE=1
      ok "network available (ping $_host)"
      return 0
    fi
    log "ping failed: $_host"
  done
  for _host in www.baidu.com cn.bing.com github.com; do
    if https_ok "$_host"; then
      IS_INTERNET_AVAILABLE=1
      ok "network available (HTTPS $_host)"
      return 0
    fi
    log "HTTPS probe failed: $_host"
  done
  warn "no usable network"
  return 0
}

apk_resolve_latest() {
  _api="https://api.github.com/repos/tiann/KernelSU/releases/latest"
  _json="$WORK/latest.json"
  rm -f "$_json"
  if ! "$CURL" -fsSL --connect-timeout 8 --max-time 20 -o "$_json" "$_api"; then
    warn "GitHub API request failed"
    return 1
  fi
  _tag=$(grep -o '"tag_name": *"[^"]*"' "$_json" 2>/dev/null | head -n1 |
    sed 's/.*"\([^"]*\)"$/\1/')
  _name=$(grep -F '"name": "KernelSU_v' "$_json" 2>/dev/null | head -n1 |
    sed 's/.*"name": *"\([^"]*\)".*/\1/')
  if [ -n "$_name" ]; then
    _start=$(grep -n -F "\"name\": \"$_name\"" "$_json" 2>/dev/null | head -n1 | cut -d: -f1)
  else
    _start=""
  fi
  if [ -n "$_start" ]; then
    _block=$(tail -n +"$_start" "$_json" | head -n 60)
  else
    _block=""
  fi
  _url=$(printf '%s\n' "$_block" | grep -o 'https://[^"]*' | grep 'release.apk' | head -n1)
  _size=$(printf '%s\n' "$_block" | grep -o '"size": *[0-9]*' | head -n1 | tr -cd '0-9')
  _sha=$(printf '%s\n' "$_block" | grep -o '"digest": *"sha256:[0-9a-f]*"' | head -n1 |
    sed 's/.*sha256://; s/"//g')
  if [ -z "$_tag" ] || [ -z "$_name" ] || [ -z "$_url" ] || [ -z "$_size" ]; then
    warn "unable to parse latest release metadata"
    return 1
  fi
  TAG=$_tag
  APK_NAME=$_name
  APK_URL=$_url
  APK_SIZE=$_size
  APK_SHA=$_sha
  ok "latest KernelSU release: $TAG ($APK_NAME, $APK_SIZE bytes)"
  return 0
}

apk_use_pinned() {
  TAG=$PINNED_TAG
  APK_NAME=$PINNED_APK_NAME
  APK_URL=$PINNED_APK_URL
  APK_SIZE=$PINNED_APK_SIZE
  APK_SHA=$PINNED_APK_SHA
  warn "falling back to pinned KernelSU $TAG"
}

apk_valid() {
  _file=$1
  [ -f "$_file" ] || return 1
  _asz=$(stat -c %s "$_file" 2>/dev/null) || return 1
  [ "$_asz" = "$APK_SIZE" ] || return 1
  _magic=$(od -An -tx1 -N2 "$_file" 2>/dev/null | tr -d ' \n')
  [ "$_magic" = "504b" ] || return 1
  if [ -n "$APK_SHA" ]; then
    _asha=$(sha256sum "$_file" 2>/dev/null | cut -d' ' -f1)
    [ "$_asha" = "$APK_SHA" ] || return 1
  fi
  return 0
}

apk_seed_partial() {
  _part=$1
  [ -f "$_part" ] && return 0
  _best=""
  _best_size=0
  for _cand in "$WORK"/KernelSU.apk.*.part; do
    [ -f "$_cand" ] || continue
    _csize=$(stat -c %s "$_cand" 2>/dev/null) || continue
    if [ "$_csize" -gt "$_best_size" ] && [ "$_csize" -lt "$APK_SIZE" ]; then
      _best=$_cand
      _best_size=$_csize
    fi
  done
  if [ -n "$_best" ]; then
    mv -f "$_best" "$_part" || return 1
    log "  resuming partial download from $_best_size bytes"
  fi
  return 0
}

apk_tier_url() {
  case "$1" in
    1) [ -n "${KSU_T1-https://ghfast.top}" ] && printf '%s/%s\n' "${KSU_T1-https://ghfast.top}" "$APK_URL" ;;
    2) [ -n "${KSU_T2-https://gh-proxy.com}" ] && printf '%s/%s\n' "${KSU_T2-https://gh-proxy.com}" "$APK_URL" ;;
    3)
      if [ -n "${KSU_T3-}" ]; then
        printf '%s/%s\n' "${KSU_T3-}" "$APK_URL"
      else
        printf '%s\n' "$APK_URL"
      fi
      ;;
  esac
}

apk_fetch_tier() {
  _tier=$1
  _url=$2
  _part="$WORK/KernelSU.apk.tier$_tier.part"
  case "$_tier" in
    3) _max_time=35; _retries=0 ;;
    *) _max_time=170; _retries=2 ;;
  esac
  apk_seed_partial "$_part"
  if [ -f "$_part" ]; then
    _cur=$(stat -c %s "$_part" 2>/dev/null || echo 0)
    [ "$_cur" -gt "$APK_SIZE" ] && rm -f "$_part"
  fi
  _err="$WORK/curl.tier$_tier.err"
  _start=$(date +%s)
  "$CURL" -fsSL --connect-timeout 10 --max-time "$_max_time" \
    --retry "$_retries" --retry-all-errors --retry-delay 2 \
    --speed-limit 4096 --speed-time 25 \
    -C - -o "$_part" "$_url" 2>"$_err"
  _rc=$?
  if [ "$_rc" -ne 0 ] && [ -s "$_part" ] && [ "$_tier" != 3 ]; then
    log "  tier$_tier interrupted; retrying from scratch once"
    rm -f "$_part"
    "$CURL" -fsSL --connect-timeout 10 --max-time "$_max_time" \
      --retry 1 --retry-all-errors --retry-delay 2 \
      --speed-limit 4096 --speed-time 25 \
      -o "$_part" "$_url" 2>>"$_err"
    _rc=$?
  fi
  _elapsed=$(( $(date +%s) - _start ))
  _cur=$(stat -c %s "$_part" 2>/dev/null || echo 0)
  log "  tier$_tier: rc=$_rc bytes=$_cur elapsed=${_elapsed}s"
  if [ "$_rc" -eq 0 ] && apk_valid "$_part"; then
    mv -f "$_part" "$WORK/KernelSU.apk"
    return 0
  fi
  if [ -s "$_err" ]; then
    log "  tier$_tier error: $(tail -n 1 "$_err" 2>/dev/null)"
  fi
  return 1
}

apk_download() {
  log "downloading $APK_NAME ($APK_SIZE bytes)"
  for _tier in 1 2 3; do
    _url=$(apk_tier_url "$_tier")
    if [ -z "$_url" ]; then
      log "  tier$_tier disabled"
      continue
    fi
    log "  tier$_tier: $_url"
    if apk_fetch_tier "$_tier" "$_url"; then
      APK="$WORK/KernelSU.apk"
      ok "APK downloaded and verified (tier$_tier)"
      return 0
    fi
  done
  return 1
}

apk_locate_installed() {
  _dir=$(grep -a -o "/data/app/[!-~]*${PKG}[!-~]*/" /data/system/packages.xml 2>/dev/null |
    head -n1)
  if [ -n "$_dir" ] && [ -f "${_dir}base.apk" ]; then
    APK="${_dir}base.apk"
    return 0
  fi
  for _cand in /data/app/*/${PKG}-*/base.apk; do
    if [ -f "$_cand" ]; then
      APK=$_cand
      return 0
    fi
  done
  grep -q "^${PKG} " /data/system/packages.list 2>/dev/null || return 1
  for _dir in /system/priv-app /system/app /product/priv-app /product/app \
    /system_ext/priv-app /system_ext/app; do
    [ -d "$_dir" ] || continue
    for _cand in "$_dir"/*/*.apk "$_dir"/*.apk; do
      [ -f "$_cand" ] || continue
      if unzip -p "$_cand" AndroidManifest.xml 2>/dev/null | grep -aq "$PKG"; then
        APK=$_cand
        return 0
      fi
    done
  done
  return 1
}

acquire_apk() {
  APK=""
  APK_NAME=""
  APK_URL=""
  APK_SIZE=""
  APK_SHA=""
  TAG=""

  if [ "$IS_INTERNET_AVAILABLE" = 1 ]; then
    if ! apk_resolve_latest; then
      apk_use_pinned
    fi
    if ! apk_download; then
      if [ "$APK_SHA" != "$PINNED_APK_SHA" ]; then
        warn "latest APK download failed; retrying pinned $PINNED_TAG"
        apk_use_pinned
        apk_download || warn "pinned APK download failed"
      fi
    fi
  fi

  if [ -z "$APK" ]; then
    if [ "$IS_INTERNET_AVAILABLE" = 1 ]; then
      warn "all download tiers failed; looking for the installed KernelSU package"
    else
      log "no internet; looking for the installed KernelSU package"
    fi
    if apk_locate_installed; then
      ok "using installed APK: $APK"
      APK_NAME=$(basename "$APK")
      TAG=installed
    else
      return 1
    fi
  fi
  [ -f "$APK" ] || return 1
  return 0
}

extract_ksud() {
  rm -rf "$WORK/apk" || return 1
  mkdir -p "$WORK/apk" || return 1
  unzip -o "$APK" "lib/arm64-v8a/libksud.so" -d "$WORK/apk" >/dev/null 2>&1 || return 1
  KSUD="$WORK/ksud"
  mv -f "$WORK/apk/lib/arm64-v8a/libksud.so" "$KSUD" || return 1
  chmod 755 "$KSUD" || return 1
  _ver=$("$KSUD" -V 2>&1) || return 1
  ok "extracted $_ver"
  return 0
}

install_ksud_userspace() {
  "$KSUD" install || return 1
  [ -x /data/adb/ksud ] || return 1
  [ -e /data/adb/ksu/bin/ksud ] || warn "/data/adb/ksu/bin/ksud symlink is missing"
  ok "KernelSU userspace installed: /data/adb/ksud"
  return 0
}

# ---------------------------------------------------------------------------
# delivery
# ---------------------------------------------------------------------------
download_dir() {
  if [ -d /data/media/0 ]; then
    DOWNLOAD=/data/media/0/Download
  else
    DOWNLOAD=/sdcard/Download
  fi
  mkdir -p "$DOWNLOAD" 2>/dev/null || warn "cannot create $DOWNLOAD"
}

copy_log() {
  [ -n "${DOWNLOAD:-}" ] || return 0
  [ -d "$DOWNLOAD" ] || return 0
  cp -f "$LOG" "$DOWNLOAD/oneroot.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# confirmation
# ---------------------------------------------------------------------------
confirm_or_abort() {
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  if [ ! -t 0 ]; then
    fail "non-interactive environment; pass --yes to continue"
  fi
  printf '\nType YES to continue: '
  read -r _answer || true
  [ "${_answer:-}" = YES ] || fail "aborted by user"
  return 0
}

# ---------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------
backup_set() {
  _stamp=$(date +%Y%m%d_%H%M%S)
  BK="$BACKUP_BASE/$_stamp"
  mkdir -p "$BK/images" "$BK/profile" || return 1
  for _p in $TARGET_IMAGES; do
    cp -f "$IMGDIR/$_p.img" "$BK/images/" || return 1
  done
  cp -f "$WORK/abl.img" "$BK/images/abl.img" || return 1
  cp -rf "$AVB_WS/profiles/$ID/." "$BK/profile/" || return 1
  ( cd "$BK/images" && sha256sum *.img > "$BK/SHA256SUMS" ) || return 1
  printf 'SLOT=%s\nABL_NAME=%s\n' "$SLOT" "$(basename "$ABLDEV")" > "$BK/meta.env" || return 1
  {
    printf '#!/system/bin/sh\n'
    printf 'DIR=$(cd "$(dirname "$0")" && pwd)\n'
    printf 'exec /system/bin/ksu_oneroot.sh --restore "$DIR"\n'
  } > "$BK/restore.sh" || return 1
  chmod 755 "$BK/restore.sh" 2>/dev/null || true
  sync
  verify_sums "$BK" || return 1
  ok "backup written: $BK"
  return 0
}

# Verify a backup's SHA256SUMS without relying on `sha256sum -c`
# (keeps the script compatible with smaller toybox builds).
verify_sums() {
  _dir=$1
  [ -f "$_dir/SHA256SUMS" ] || return 1
  while read -r _hash _file; do
    [ -n "$_hash" ] || continue
    [ -n "$_file" ] || return 1
    _actual=$(sha256sum "$_dir/images/$_file" 2>/dev/null | cut -d' ' -f1) || return 1
    [ "$_actual" = "$_hash" ] || return 1
  done < "$_dir/SHA256SUMS"
  return 0
}

restore_from_backup() {
  _dir=$1
  [ -d "$_dir/images" ] || fail "backup images directory missing: $_dir/images"
  [ -f "$_dir/SHA256SUMS" ] || fail "backup SHA256SUMS missing"
  [ -f "$_dir/meta.env" ] || fail "backup meta.env missing"
  . "$_dir/meta.env"
  [ "${SLOT:-}" = "$(getprop ro.boot.slot_suffix 2>/dev/null || true)" ] ||
    fail "backup was taken for slot ${SLOT:-?}, current slot differs"
  verify_sums "$_dir" || fail "backup checksum verification failed"
  for _p in $FLASH_ORDER; do
    [ -f "$_dir/images/$_p.img" ] || fail "backup is missing $_p.img"
    flash_partition "$_p" "$_dir/images/$_p.img" || fail "restore failed for $_p"
    ok "restored $_p"
  done
  [ -f "$_dir/images/abl.img" ] || fail "backup is missing abl.img"
  resolve_abl_dev || fail "abl partition not found"
  dd if="$_dir/images/abl.img" of="$ABLDEV" bs=1M 2>"$WORK/dd.err" || fail "abl restore failed"
  sync
  cmp "$_dir/images/abl.img" "$ABLDEV" || fail "abl readback mismatch"
  ok "restored abl"
  ok "restore complete"
}

restore_all() {
  alert "restoring the pre-run partition set from $BK"
  if [ -f "$BK/restore.sh" ] && sh "$BK/restore.sh"; then
    ok "restore complete"
    return 0
  fi
  alert "RESTORE FAILED"
  alert "DO NOT REBOOT. The backup is at: $BK"
  alert "Manual restore: sh /system/bin/ksu_oneroot.sh --restore \"$BK\""
  return 1
}
