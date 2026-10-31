#!/system/bin/sh
# Generate a topaz testkey AVB profile from the images already in
# <workspace>/Images.  This is the shell counterpart of the PowerShell
# plugin's testkey_config_gen, reduced to the topaz target table.
#
#   avbpt-config-gen.sh --workspace DIR --id ID --name NAME \
#       [--images LIST] [--key-dir DIR] \
#       [--recovery-ri N] [--vs-alg ALG] [--vs-key KEY] [--avbpt PATH]
#
# Exit codes: 0 success, 1 failure, 2 usage.

set -u

WS=""
ID=""
NAME=""
IMAGES="boot,dtbo,init_boot,pvmfw,recovery,vbmeta,vbmeta_system,vendor_boot"
KEYDIR=/avbpowertool/tools
RECOVERY_RI=1
VS_ALG=SHA256_RSA2048
VS_KEY=testkey_rsa2048
AVBPT=avbpt

usage() {
  cat <<'EOF'
Usage: avbpt-config-gen.sh --workspace DIR --id ID [options]

  --workspace DIR    avbpt workspace containing Images/
  --id ID            profile id (letters, digits, _ - .)
  --name NAME        profile display name (default: id)
  --images LIST      comma-separated image names
  --key-dir DIR      directory with testkey_rsa4096.pem / testkey_rsa2048.pem
  --recovery-ri N    recovery rollback index (default 1)
  --vs-alg ALG       vbmeta_system algorithm (SHA256_RSA2048/4096)
  --vs-key KEY       vbmeta_system testkey id (testkey_rsa2048/4096)
  --avbpt PATH       avbpt launcher (default: avbpt from PATH)
  -h, --help         show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; WS=$1 ;;
    --workspace=*) WS=${1#*=} ;;
    --id) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; ID=$1 ;;
    --id=*) ID=${1#*=} ;;
    --name) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; NAME=$1 ;;
    --name=*) NAME=${1#*=} ;;
    --images) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; IMAGES=$1 ;;
    --images=*) IMAGES=${1#*=} ;;
    --key-dir) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; KEYDIR=$1 ;;
    --key-dir=*) KEYDIR=${1#*=} ;;
    --recovery-ri) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; RECOVERY_RI=$1 ;;
    --recovery-ri=*) RECOVERY_RI=${1#*=} ;;
    --vs-alg) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; VS_ALG=$1 ;;
    --vs-alg=*) VS_ALG=${1#*=} ;;
    --vs-key) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; VS_KEY=$1 ;;
    --vs-key=*) VS_KEY=${1#*=} ;;
    --avbpt) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; AVBPT=$1 ;;
    --avbpt=*) AVBPT=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say() { printf '[cfg] %s\n' "$*"; }
die() { printf '[cfg][ERROR] %s\n' "$*" >&2; exit 1; }

[ -n "$WS" ] || { usage >&2; exit 2; }
[ -n "$ID" ] || { usage >&2; exit 2; }
[ -n "$NAME" ] || NAME=$ID

[ -d "$WS/Images" ] || die "workspace Images directory missing: $WS/Images"
[ -d "$KEYDIR" ] || die "key directory missing: $KEYDIR"
[ -f "$KEYDIR/testkey_rsa4096.pem" ] || die "missing $KEYDIR/testkey_rsa4096.pem"
[ -f "$KEYDIR/testkey_rsa2048.pem" ] || die "missing $KEYDIR/testkey_rsa2048.pem"
command -v "$AVBPT" >/dev/null 2>&1 || die "avbpt launcher not found: $AVBPT"

case "$RECOVERY_RI" in
  ''|*[!0-9]*) die "recovery rollback index is not numeric: $RECOVERY_RI" ;;
esac
[ "$RECOVERY_RI" -ge 1 ] || RECOVERY_RI=1

case "$VS_ALG" in
  SHA256_RSA2048) VS_KEY=${VS_KEY:-testkey_rsa2048} ;;
  SHA256_RSA4096) VS_KEY=${VS_KEY:-testkey_rsa4096} ;;
  *) die "unsupported vbmeta_system algorithm: $VS_ALG" ;;
esac
case "$VS_KEY" in
  testkey_rsa2048)
    [ "$VS_ALG" = SHA256_RSA2048 ] || die "--vs-key/--vs-alg mismatch"
    ;;
  testkey_rsa4096)
    [ "$VS_ALG" = SHA256_RSA4096 ] || die "--vs-key/--vs-alg mismatch"
    ;;
  *) die "unsupported vbmeta_system key: $VS_KEY" ;;
esac

avb() {
  "$AVBPT" --workspace "$WS" --no-warn "$@"
}

run_or_die() {
  _what=$1
  shift
  say "$_what"
  avb "$@" || die "$_what failed"
}

say "workspace=$WS id=$ID recovery_ri=$RECOVERY_RI vs=$VS_ALG/$VS_KEY"

run_or_die "config create (empty)" \
  config create --id "$ID" --name "$NAME" --allow-empty --json

mkdir -p "$WS/profiles/$ID/keys" || die "cannot create keys directory"
cp -f "$KEYDIR/testkey_rsa4096.pem" "$KEYDIR/testkey_rsa2048.pem" \
  "$WS/profiles/$ID/keys/" || die "cannot copy test keys"

run_or_die "keys discover" keys discover --profile "$ID" --json
run_or_die "keys ensure-public" keys ensure-public --profile "$ID" --json

run_or_die "config create (from images)" \
  config create --id "$ID" --name "$NAME" --from-images "$WS/Images" \
  --overwrite --images "$IMAGES" --json

run_or_die "config edit vbmeta" \
  config edit vbmeta --profile "$ID" \
  --set flags=1 \
  --set included_partitions=dtbo,init_boot,vendor_boot \
  --set "chain_partitions=boot:3:testkey_rsa4096.pem.bin,recovery:1:testkey_rsa4096.pem.bin,vbmeta_system:2:${VS_KEY}.pem.bin" \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096 --json

run_or_die "config edit boot" \
  config edit boot --profile "$ID" \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096 --json

run_or_die "config edit recovery" \
  config edit recovery --profile "$ID" \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096 \
  --set "rollback_index=$RECOVERY_RI" --json

run_or_die "config edit vbmeta_system" \
  config edit vbmeta_system --profile "$ID" \
  --set "key_id=$VS_KEY" --set "algorithm=$VS_ALG" \
  --set included_partitions=pvmfw --json

for _p in dtbo init_boot pvmfw vendor_boot; do
  run_or_die "config edit $_p" \
    config edit "$_p" --profile "$ID" \
    --set key_id=testkey_rsa4096 --set algorithm=NONE --json
done

run_or_die "config validate" config validate --profile "$ID" --json
run_or_die "config check-chains" config check-chains --profile "$ID" --json
run_or_die "config activate" config activate "$ID" --json

say "profile ready: $ID"
exit 0
