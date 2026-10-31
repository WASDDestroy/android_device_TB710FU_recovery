# TWRP device tree for Lenovo Xiaoxin Pad Pro GT

TB710FU (codenamed _"topaz"_) is a smart tablet from Lenovo.

## Build it yourself?

```
mkdir twrp && cd twrp
repo init --depth=1 -u https://github.com/TWRP-Test/platform_manifest_twrp_aosp.git -b twrp-16.0
repo sync
git clone --depth=1 https://github.com/morannlx/adnroid_device_TB710FU_recovery.git device/lenovo/topaz
```

```
source build/envsetup.sh
lunch twrp_topaz
make recoveryimage
```

If there is no error, recovery.img will be found in out/target/product/topaz/recovery.img  


## Features
Not works:
- Unknown

Works:
- [X] ADB
- [X] Display
- [X] Decryption
- [X] Fasbootd
- [X] Flashing
- [X] MTP
- [X] Sideload
- [X] USB OTG
- [X] WLAN / HTTPS downloads (`curl` with a CA bundle)

## Prebuilt binaries

`recovery/root/system/` carries binaries that are **not** built from this tree.
Their digests are pinned here so a rebuild can be verified:

| Path | Size (B) | SHA-256 | Origin |
| --- | ---: | --- | --- |
| `system/bin/openssl` | 891,696 | `875850936b661e54e52532e001dca2eb373431828d77b7c0bdaac286d6619957` | OpenSSL 3.3.2 CLI |
| `system/lib64/libssl.so.3` | 818,880 | `faeb213eae8ef1fd582ff13701d3f52b3c92cbc125458cf908951613e028e371` | OpenSSL 3.3.2 runtime |
| `system/lib64/libcrypto.so.3` | 4,440,456 | `c331b952015b4a460230988a972627c925a18614ab9df278ec9614ec82bc8432` | OpenSSL 3.3.2 runtime |
| `system/bin/curl` | 1,056,808 | `6df0021c007dad573d2ca54a5f6ba81ef8e14596c3ac052f2635efc7966de933` | built from curl 8.23.0, see below |
| `system/etc/security/cacert.pem` | 200,116 | `796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe` | Mozilla CA bundle from curl.se |

### curl

`curl 8.23.0` built with NDK r29 (API 34). libcurl is static, but TLS comes from
the OpenSSL 3.3.2 runtime **already shipped in this ramdisk** — that is why it is
~1 MB rather than ~5 MB with a bundled static OpenSSL.

The CA bundle path is baked in at configure time
(`--with-ca-bundle=/system/etc/security/cacert.pem`), so plain `curl https://...`
verifies certificates with no extra flags. Only `libssl.so.3`, `libcrypto.so.3`,
`libdl.so` and `libc.so` are needed at runtime; all are in the ramdisk.

Rebuild with `tools/build-curl.sh`. It regenerates the sysroot from the two `.so`
files in this tree, so the output always matches the shipped OpenSSL:

```
tools/build-curl.sh                       # writes recovery/root/system/bin/curl
```
Requires a Linux host or WSL plus Android NDK r29 in `$HOME/ndk/android-ndk-r29`
(override with `NDK=`). Verify the result against the pinned SHA-256 above.

### cacert.pem

Mozilla trust store, 118 certificates, copied verbatim from
<https://curl.se/ca/cacert.pem>. Refresh with:

```
curl -fsSL https://curl.se/ca/cacert.pem -o recovery/root/system/etc/security/cacert.pem
grep -c 'BEGIN CERTIFICATE' recovery/root/system/etc/security/cacert.pem   # expect >= 118
```

Note that the bundle is frozen at build time. For long-lived installs, a newer
bundle can be dropped at runtime and used via `curl --cacert`, without rebuilding
the recovery image.

## To use it:

```
fastboot flash recovery recovery.img
or
fastboot flash recovery_a recovery.img
fastboot flash recovery_b recovery.img
```

## One-click KernelSU root

`recovery/root/system/bin/ksu_oneroot.sh` runs inside TWRP and supports both
bootloader states:

- **Unlocked** — patches the active slot's `init_boot` with KernelSU and
  flashes it directly.
- **Locked (no-unlock)** — rebuilds the testkey AVB trust chain with the
  bundled `avbpowertool`: reads the eight partitions into a workspace,
  verifies the current chain, generates a profile, backs everything up,
  patches `init_boot`, signs `boot/dtbo/init_boot/pvmfw/recovery/vbmeta/
  vbmeta_system/vendor_boot`, flashes them and (only for ZUXOS >=
  1.5.04.445) restores the bundled old ABL that trusts the AOSP testkey.

Requirements: `/data` decrypted, `/sdcard` writable, at least ~1 GiB free.

```sh
# terminal in TWRP
ksu_oneroot.sh                      # interactive; asks for YES
ksu_oneroot.sh --yes                # no prompt
ksu_oneroot.sh --mode locked --dry-run --yes   # read/config/backup/sign only
ksu_oneroot.sh --restore /sdcard/Download/twrp_no_unlocking/<stamp>
```

The locked flow refuses to run when KernelSU/Magisk is already present, when
an OTA is pending, or when the current eight partitions no longer form a
bootable chain. A failed flash triggers an automatic restore from the backup;
the backup directory also contains `restore.sh` and `SHA256SUMS`.

GUI2: **Advanced -> One-click Root** runs the same auto-detecting flow.
The item passes `--mode auto --yes` because the GUI has no terminal; its
swipe confirmation is the safety gate, and the script output streams to the
console.

Design notes: [docs/NO_UNLOCK_ROOT_PLAN.md](docs/NO_UNLOCK_ROOT_PLAN.md).
