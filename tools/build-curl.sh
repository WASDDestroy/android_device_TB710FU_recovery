#!/bin/bash
# Rebuild recovery/root/system/bin/curl
#
# The resulting binary is dynamically linked against the OpenSSL 3.3.2 runtime
# that already ships in this ramdisk (system/lib64/libssl.so.3, libcrypto.so.3).
# That keeps curl at ~1 MB instead of ~5 MB with a static OpenSSL.
#
# Requirements: Linux or WSL, Android NDK r29 (linux-x86_64 prebuilt), network access.
# usage: tools/build-curl.sh [outfile]
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$TOP/recovery/root/system/bin/curl}
NDK=${NDK:-$HOME/ndk/android-ndk-r29}
CURL_VER=${CURL_VER:-8.23.0}
OPENSSL_VER=${OPENSSL_VER:-3.3.2}

WORK=${WORK:-$PWD/out-curl}
SYS="$WORK/sysroot"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TC/bin/aarch64-linux-android34-clang"
[ -x "$CC" ] || { echo "NDK r29 not found at $NDK (set NDK=...)"; exit 1; }

mkdir -p "$WORK/src" "$SYS/usr/include" "$SYS/usr/lib"

# 1. sysroot: the exact libraries this tree ships
cp "$TOP/recovery/root/system/lib64/libssl.so.3" "$TOP/recovery/root/system/lib64/libcrypto.so.3" "$SYS/usr/lib/"
ln -sf libssl.so.3 "$SYS/usr/lib/libssl.so"
ln -sf libcrypto.so.3 "$SYS/usr/lib/libcrypto.so"

# 2. headers: only headers are needed, so the matching upstream release is
#    configured as linux-aarch64 (same LP64 ABI). The android-arm64 target would
#    additionally demand a full NDK layout check for <triple>-gcc, which is
#    pointless when no libcrypto is compiled.
cd "$WORK/src"
[ -d "openssl-$OPENSSL_VER" ] || curl -sSLO "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" && tar xf "openssl-$OPENSSL_VER.tar.gz"
cd "openssl-$OPENSSL_VER"
[ -f Makefile ] || ./Configure linux-aarch64 no-tests no-apps no-docs >/dev/null
[ -f include/openssl/opensslv.h ] || make build_generated >/dev/null
rm -rf "$SYS/usr/include/openssl"
cp -r include/openssl "$SYS/usr/include/"

# 3. curl
cd "$WORK/src"
[ -d "curl-$CURL_VER" ] || curl -sSLO "https://curl.se/download/curl-$CURL_VER.tar.xz" && tar xf "curl-$CURL_VER.tar.xz"
cd "curl-$CURL_VER"
./configure --host=aarch64-linux-android \
  --with-openssl="$SYS/usr" \
  --with-ca-bundle=/system/etc/security/cacert.pem \
  --disable-shared --enable-static \
  --without-zlib --without-brotli --without-zstd --without-libidn2 \
  --without-nghttp2 --without-ngtcp2 --without-nghttp3 --without-quiche \
  --without-libpsl --without-libssh2 \
  --disable-ldap --disable-ldaps --disable-file --disable-ftp --disable-telnet \
  --disable-tftp --disable-dict --disable-gopher --disable-imap --disable-pop3 \
  --disable-smtp --disable-rtsp --disable-mqtt \
  --enable-ipv6 --enable-threaded-resolver \
  CC="$CC" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip" \
  CFLAGS="-O2 -ffunction-sections -fdata-sections" \
  LDFLAGS="-Wl,--gc-sections"
make -j"$(nproc)"

"$TC/bin/llvm-strip" --strip-all src/curl
cp src/curl "$OUT"
echo "built: $OUT"
ls -l "$OUT"
"$TC/bin/llvm-readelf" -d "$OUT" | grep NEEDED
echo "expected sha256: 6df0021c007dad573d2ca54a5f6ba81ef8e14596c3ac052f2635efc7966de933"
sha256sum "$OUT"
