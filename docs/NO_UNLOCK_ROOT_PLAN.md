# TB710FU（topaz）免解锁一键 Root —— 最终实施方案

> 目标：在 **Bootloader 已锁定**、已通过 Testkey 漏洞 + EDL 刷入 TWRP 的设备上，
> 用 `avbpowertool` 重建 testkey 信任链并刷入 KernelSU 补丁，同时提供可回滚的备份。
> 本文是设计文档；实现位于 recovery/root/system/bin/。

---

## 0. 结论

方案可闭环，且不再依赖任何“待定”项。两个实机口径已经确认：

- `boot` / `recovery` 都是 **`SHA256_RSA4096`**；
- `vbmeta_system` 的密钥长度随系统版本变化：`<1.5.04.384` 为 4096（testkey）、
  `1.5.04.384–444` 为 2048（testkey）、`>=1.5.04.445` 为 4096（联想自有密钥）。
  本方案不硬编码版本号，而是**继承当前镜像的算法长度**，再换成同长度的 testkey：
  4096→`testkey_rsa4096`，2048→`testkey_rsa2048`。这样三个版本区间自动正确。

---

## 1. 事实基线（均已核实）

| 项 | 结论 | 来源 |
|---|---|---|
| `/sbin/avbpt` + `/avbpowertool` | 构建产物中存在，`py/python` 为 0755 | `out/target/product/topaz/recovery/root` |
| 板端 CLI | 具备 `config create --from-images/--activate`、`config edit --set/--append`、`keys ensure-public`、`image sign --execute --yes --remove-footers` | `presentation/cli/parser.py` |
| testkey | `/avbpowertool/tools/testkey_rsa{2048,4096}.pem` 与插件 keys 为同一密钥 | PEM 规范化比对 |
| `abl.img` | ELF32 ARM、静态链接、**恰好 1,048,576 字节**、尾部补零、无 AVB footer；SHA-256 `6CFA16E6…B74A8` | `avbpowertool/tools/abl.img` |
| TWRP recovery 构建产物 | `Algorithm: NONE`、`Rollback Index: 0`（未签名） | `avbtool info_image out/.../recovery.img` |
| ksud 行为 | `boot-patch` 会 `mv init init.real`、写入 `init`（ksuinit）、写入 `kernelsu.ko`；`android_bootimg` 会**保留并重写 AVB footer** | KernelSU `boot_patch.rs`、`android_bootimg/patcher.rs` |
| ksud `boot-info` | 只有 `current-kmi/supported-kmis/is-ab-device/default-partition/available-partitions/slot-suffix`，**不能判断是否已 patch** | 真机输出 |
| GUI2 Terminal | 真正 PTY（`initPty`），`[ -t 0 ]` 为真 | `gui2/backend/terminal_engine.cpp` |
| GUI2 命令入口 | `TWFunc::ExecCmd` 一次性执行，无 PTY | `gui2/backend/twrp_tools_backend.cpp` |
| GUI2 音量键 | `KEY_VOLUMEDOWN` 在输入层被截获，不会进入终端 | `gui2/gui2_input.cpp:203-244` |
| 锁定 testkey 设备的 verified boot | **GREEN**（联想老构建系统把 testkey 当成了 release key）；orange/yellow **不是**解锁信号 | 实机 |
| `bootctl` | 真机可用：`get-current-slot=1`、`get-active-boot-slot=1`、`get-snapshot-merge-status=none` | 真机输出 |
| 519/470 profile | 桌面从 OEM 镜像生成；recovery 条目是 OEM 的 4096/RI1，**不代表设备上的 TWRP** | `profiles/…/profile.json` |

---

## 2. 模式判定（修正原脚本的一个真实缺陷）

原脚本把 `ro.boot.verifiedbootstate=orange` 当作“已解锁”。但本机型的实际情况是：

- 免解锁设备用 testkey 启动时是 **GREEN**（联想老版本构建系统把 testkey 用作了 release key）；
- `orange` 只表示“用了非 OEM 密钥”，既可能出现在解锁设备，也可能出现在被改过密钥的锁定设备；
- `green` 既可能出现在原厂锁定设备，也可能出现在 testkey 免解锁设备。

因此 **`verifiedbootstate` 不能参与解锁判定**。必须按锁定状态判定：

```sh
device_state=$(getprop ro.boot.vbmeta.device_state)
flash_locked=$(getprop ro.boot.flash.locked)

if [ "$device_state" = locked ] || [ "$flash_locked" = 1 ]; then
    MODE=locked
elif [ "$device_state" = unlocked ] || [ "$flash_locked" = 0 ]; then
    MODE=unlocked
else
    MODE=unknown
fi
```

- `MODE=unknown` 且未显式 `--mode` → 退出 1。
- `verifiedbootstate`（green/orange/yellow）只记录到日志，不参与模式判定。
- `--mode` 只用于测试，且不允许把锁定设备带到解锁路径：
  - 实际 locked + `--mode unlocked` → **拒绝（exit 1）**，无论是否有 `--yes`；
  - 实际 unlocked + `--mode locked` → 只允许配合 `--dry-run`，否则拒绝。

---

## 3. 前置闸门（任何写盘之前）

### 3.1 环境

| 检查 | 失败动作 |
|---|---|
| `/data` 已解密且可写（`mountpoint -q /data` + `/data/system/packages.xml` 可读） | 退出 1 |
| `/sdcard`（`/data/media/0`）可写 | 退出 1 |
| `/sbin/avbpt`、`/avbpowertool/py/python`、`/system/bin/magiskboot`、`unzip`、`toybox cpio` 存在 | 退出 1 |
| 活动槽 `ro.boot.slot_suffix` ∈ `_a/_b` | 退出 1 |
| 8 个分区节点 `boot/dtbo/init_boot/pvmfw/recovery/vbmeta/vbmeta_system/vendor_boot` + 活动槽存在 | 退出 1 |
| `abl$slot`（或 `abl`）存在，且 `blockdev --getsize64 == 1048576` | 退出 1（不支持的分区布局） |
| `/data` 剩余空间 ≥ `2.6 × 8 镜像总大小 + 64 MiB` | 退出 1 |

### 3.2 OTA 闸门（解锁/锁定模式都执行）

```sh
cur=$(bootctl get-current-slot)        || refuse
act=$(bootctl get-active-boot-slot)    || refuse
merge=$(bootctl get-snapshot-merge-status) || refuse

[ "$cur" = "$act" ]            || refuse "pending slot switch"
[ "$merge" = none ]            || refuse "virtual A/B merge in progress"

suffix=$(getprop ro.boot.slot_suffix)
expect=$([ "$cur" = 0 ] && echo _a || echo _b)
[ "$suffix" = "$expect" ]      || refuse "slot/suffix mismatch"
```

`bootctl` 任一命令失败都视为“无法证明没有待生效 OTA”，直接拒绝。

### 3.3 已 root 闸门（退出 1）

用 `magiskboot unpack` 解开 `boot` 与 `init_boot`，检查 ramdisk cpio：

| 标记 | 含义 |
|---|---|
| `kernelsu.ko` | 已打 KernelSU（LKM 或 GKI 补丁都会写入） |
| `init.real` | 已打 KernelSU（GKI/LKM 都会把原 init 改名） |
| `.magisk` / `magisk64` 等 | 已打 Magisk（`ksud` 也拒绝，提前拦下） |

任一命中 → `[ERROR] already patched/rooted; refusing` → exit 1。
`/data/adb/ksud` 只作为提示，不作为判据。

> 这一条同时替换原解锁脚本第 3 步的“只看 init_boot 的 kernelsu.ko”，
> 从而覆盖 boot 集成（GKI）的情况。

### 3.4 信任链闸门（仅 `MODE=locked` 严格）

先读 8 个分区到工作区，然后：

```sh
avbpt --workspace "$WS/avb" --no-warn image inspect \
  boot dtbo init_boot pvmfw recovery vbmeta vbmeta_system vendor_boot \
  --json > "$WS/inspect.json"

STRICT=$([ "$MODE" = locked ] && [ "$DRY_RUN" = 0 ] && echo strict || echo warn)
avbpy /system/bin/oneroot_preflight.py "$WS/inspect.json" "$STRICT"
```

校验项（任一失败 → 退出 1，不写盘）：

1. 8 张镜像 `descriptor != null`（都存在 AVB 结构）。
2. `boot`、`recovery`、`vbmeta_system`、`vbmeta` 的 `algorithm != NONE`。
3. `vbmeta.chain_partitions` 恰好覆盖 `boot`、`recovery`、`vbmeta_system`，
   且 `rollback_index_location` 分别为 `3`、`1`、`2`。
4. 每条链的 `public_key_sha1` 等于对应分区镜像的 `public_key_sha1`。
5. 6 个 hash 分区（不含 `vbmeta`/`vbmeta_system`）的 `partition_name` 与逻辑名一致。

helper 同时向 stdout 输出五行：

```text
recovery_ri=<n>
vs_alg=<SHA256_RSA2048|SHA256_RSA4096>
vs_key=<testkey_rsa2048|testkey_rsa4096>
zuxos=<x.y.z.w>            # 从 8 个镜像的 com.android.build.*.fingerprint props 解析（优先 boot）
abl_needed=<yes|no|unknown> # zuxos >= 1.5.04.445 -> yes；< -> no；解析失败 -> unknown
```

主脚本据此得到 `RECOVERY_RI=max(n,1)`（`n` 缺失按 0）、`VS_ALG`、`VS_KEY`、`ABL_NEEDED`。
`vs_alg` 的规则：继承当前 `vbmeta_system` 的算法长度；若当前是 `NONE` 或缺失，取
`SHA256_RSA2048` / `testkey_rsa2048`。
`abl_needed` 只影响 Step 9，不影响签名。

`MODE=unlocked` 或 `--dry-run` 时同样检查，但只打印 `[WARN]`，不阻断（用于开发机）。
这样既满足“用户可能先动过分区”的防护，又允许解锁设备做 dry-run。

---

## 4. 配置目标（唯一真值表）

| 分区 | 描述符 | algorithm | key_id | rollback_index | 链位置 |
|---|---|---|---|---|---|
| `boot` | hash | `SHA256_RSA4096` | `testkey_rsa4096` | **保留当前值** | 3 |
| `recovery` | hash | `SHA256_RSA4096` | `testkey_rsa4096` | `max(当前值,1)` | 1 |
| `vbmeta_system` | vbmeta | **`$VS_ALG`**（继承当前长度） | **`$VS_KEY`** | **保留当前值** | 2 |
| `vbmeta` | vbmeta | `SHA256_RSA4096` | `testkey_rsa4096` | **保留当前值** | — |
| `dtbo` | hash | `NONE` | `testkey_rsa4096` | 保留 | — |
| `init_boot` | hash | `NONE` | `testkey_rsa4096` | 保留 | — |
| `pvmfw` | hash | `NONE` | `testkey_rsa4096` | 保留 | — |
| `vendor_boot` | hash | `NONE` | `testkey_rsa4096` | 保留 | — |

`vbmeta_system` 的版本映射（由“继承当前长度”自动覆盖，不需要读系统版本号）：

| 系统版本 | 当前 vbmeta_system | 目标 |
|---|---|---|
| `<1.5.04.384` | `SHA256_RSA4096`（testkey） | `SHA256_RSA4096` + `testkey_rsa4096` |
| `1.5.04.384–444` | `SHA256_RSA2048`（testkey） | `SHA256_RSA2048` + `testkey_rsa2048` |
| `>=1.5.04.445` | `SHA256_RSA4096`（联想密钥） | `SHA256_RSA4096` + `testkey_rsa4096` |

> 上表是“原厂初始状态”。如果设备已被上一版免解锁工具改过，当前长度就是上一版工具选的长度；
> 继承它同样成立，因为第 4 节会把 `vbmeta` 的链重写成同长度的 testkey。
> 真正不可协商的是**顶层 `vbmeta` 必须 4096 testkey**（ABL 的 release key）。

固定项：

```text
vbmeta.flags = 1
vbmeta.included_partitions = dtbo,init_boot,vendor_boot
vbmeta_system.included_partitions = pvmfw
vbmeta.chain_partitions =
    boot:3:testkey_rsa4096.pem.bin,
    recovery:1:testkey_rsa4096.pem.bin,
    vbmeta_system:2:<VS_KEY>.pem.bin
```

> `included_partitions` 采用**强制覆盖**而不是从镜像剪枝，强制集合与 470/519 两份 profile 一致。
> `vbmeta_system` 里原有的 `system/product/system_ext` 描述符会被有意丢弃（`flags=1` 关闭 hashtree）。
> 若固件变体的**链位置或链公钥**不同，第 3.4 节会拒绝；included 集合的差异只记录 warning。

---

## 5. 工作区与备份布局

```text
/data/local/tmp/oneroot/                 # 工作区（每次运行前清空）
├── avb/                                 # avbpt --workspace
│   ├── Images/                          # ← 8 个镜像直接读到这里（唯一的镜像目录）
│   └── profiles/<id>/                   # profile.json + keys/
├── unpack_boot/ unpack_init_boot/       # magiskboot 检查用
├── init_boot_patched.img
├── oneroot.log

/sdcard/Download/twrp_no_unlocking/<UTC>/
├── images/boot.img … vendor_boot.img    # 8 个“本次运行前”的镜像
├── images/abl.img                       # 当前活动槽 abl
├── profile/                             # profiles/<id>/（profile.json + keys/）
├── SHA256SUMS
├── restore.sh                           # 自带 sha 校验的恢复脚本
└── oneroot.log
```

`restore.sh` 由主脚本生成，恢复顺序：非 vbmeta → `vbmeta_system` → `vbmeta` → `abl`。
每个文件恢复前校验 `SHA256SUMS`，恢复后回读 `cmp`。生成时把 `slot` 写死；
恢复时若 `ro.boot.slot_suffix` 不同则拒绝执行。

---

## 6. Locked 模式详细流程

### Step 0 —— 闸门
第 3.1/3.2/3.3 节全部通过。若 `--dry-run`，后续只到 **Step 7**（签名并校验），不写任何分区。

### Step 1 —— 读分区
```sh
WS=/data/local/tmp/oneroot
rm -rf "$WS"; mkdir -p "$WS"

# 先让 avbpt 建好 workspace 骨架（Images/、profiles/、.active-profile）
avbpt --workspace "$WS/avb" --no-warn config list --json >/dev/null
IMGDIR="$WS/avb/Images"          # image sign 只认这个目录

for p in boot dtbo init_boot pvmfw recovery vbmeta vbmeta_system vendor_boot; do
    dd if=/dev/block/by-name/${p}${slot} of=$IMGDIR/$p.img bs=1M
    [ "$(stat -c %s $IMGDIR/$p.img)" = "$(blockdev --getsize64 /dev/block/by-name/${p}${slot})" ]
done

# abl 不能放进 Images/，否则会被 image inspect / --from-images 当成分区扫描
dd if=$ABLDEV of=$WS/abl.img bs=1M
```
任何短读/大小不符 → 退出 1。

### Step 2 —— 已 root 检查
第 3.3 节；命中退出 1。

### Step 3 —— 信任链预检
第 3.4 节；`MODE=locked` 严格。

### Step 4 —— 生成配置
> 下文的 `avbpt …` 均指 `avbpt --workspace "$WS/avb" --no-warn`。

```sh
avbpt --workspace "$WS/avb" --no-warn config create \
  --id "$ID" --name "$NAME" --allow-empty --json

mkdir -p "$WS/avb/profiles/$ID/keys"
cp /avbpowertool/tools/testkey_rsa4096.pem \
   /avbpowertool/tools/testkey_rsa2048.pem "$WS/avb/profiles/$ID/keys/"

avbpt … keys discover      --profile "$ID" --json
avbpt … keys ensure-public --profile "$ID" --json

avbpt … config create --id "$ID" --name "$NAME" \
  --from-images "$IMGDIR" --overwrite \
  --images boot,dtbo,init_boot,pvmfw,recovery,vbmeta,vbmeta_system,vendor_boot --json
```

然后按第 4 节逐项 `config edit`（`RECOVERY_RI` / `VS_ALG` / `VS_KEY` 来自第 3.4 节预检 helper）：

```sh
avbpt … config edit vbmeta --profile "$ID" \
  --set flags=1 \
  --set included_partitions=dtbo,init_boot,vendor_boot \
  --set chain_partitions=boot:3:testkey_rsa4096.pem.bin,recovery:1:testkey_rsa4096.pem.bin,vbmeta_system:2:${VS_KEY}.pem.bin \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096

avbpt … config edit boot --profile "$ID" \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096

avbpt … config edit recovery --profile "$ID" \
  --set key_id=testkey_rsa4096 --set algorithm=SHA256_RSA4096 \
  --set rollback_index=$RECOVERY_RI

avbpt … config edit vbmeta_system --profile "$ID" \
  --set key_id="$VS_KEY" --set algorithm="$VS_ALG" \
  --set included_partitions=pvmfw

for p in dtbo init_boot pvmfw vendor_boot; do
  avbpt … config edit "$p" --profile "$ID" \
    --set key_id=testkey_rsa4096 --set algorithm=NONE
done

avbpt … config validate     --profile "$ID" --json
avbpt … config check-chains --profile "$ID" --json
avbpt … config activate "$ID"
```

`RECOVERY_RI = max(当前 recovery 的 rollback_index, 1)`；`create` 读不到时取 1。
`VS_ALG` / `VS_KEY` 按第 3.4 节规则从当前 `vbmeta_system` 继承。
`boot`/`vbmeta_system`/`vbmeta` 的 RI 不改。

### Step 5 —— 全量备份（写盘前）
```sh
mkdir -p "$BK/images" "$BK/profile"
cp "$IMGDIR"/*.img "$BK/images/"
cp "$WS/abl.img"   "$BK/images/abl.img"
cp -a "$WS/avb/profiles/$ID/." "$BK/profile/"
( cd "$BK/images" && sha256sum *.img > "$BK/SHA256SUMS" )
gen_restore_sh > "$BK/restore.sh"
sync
```
备份失败/空间不足 → 退出 1，不做任何写操作。

### Step 6 —— 修补 init_boot
沿用原脚本的网络/本地 APK 获取 → 解压 `lib/arm64-v8a/libksud.so` → `ksud install`：

```sh
"$KSUD" install
[ -x /data/adb/ksud ]

"$KSUD" boot-patch -b "$IMGDIR/init_boot.img" --backup \
  -o "$WS" --out-name init_boot_patched.img --partition init_boot
```

校验：
- 输出存在，大小 ≤ 分区大小（8 MiB）；
- `magiskboot unpack` 后 cpio 含 `kernelsu.ko`；
- `avbpt … image inspect init_boot` 的 `descriptor` 非空
  （ksud 会保留 AVB footer；为空则说明版本行为变化，必须中止）。

通过后 `mv` 覆盖 `$IMGDIR/init_boot.img`。原始 init_boot 已在备份中。

### Step 7 —— 签名 8 个镜像
```sh
avbpt --workspace "$WS/avb" --no-warn image sign \
  boot dtbo init_boot pvmfw recovery vbmeta vbmeta_system vendor_boot \
  --profile "$ID" --execute --yes --remove-footers --json
```

`--remove-footers` 对 6 个 hash 镜像生效（含刚修补的 init_boot，footer 已被 ksud 保留）；
`_commit_staging` 会把结果写回 `$IMGDIR`，因此 Step 5 的备份必须已完成。

签名后校验：
```sh
avbpy /avbpowertool/app/avbtool.py verify_image --image $IMGDIR/boot.img \
      --key $WS/avb/profiles/$ID/keys/testkey_rsa4096.pem
# recovery 用 testkey_rsa4096.pem
# vbmeta_system 用与 VS_ALG 匹配的密钥（2048 或 4096）
# vbmeta 用 testkey_rsa4096.pem
# dtbo/init_boot/pvmfw/vendor_boot 不加 --key
```
任一失败 → 退出 1（尚未写分区）。

### Step 8 —— 刷入（先非 vbmeta，最后 vbmeta）
顺序：`dtbo, init_boot, pvmfw, vendor_boot, boot, recovery, vbmeta_system, vbmeta`。

每个分区：
```sh
dd if=$IMGDIR/$p.img of=$DEV bs=1M
n=$(stat -c %s "$IMGDIR/$p.img")
[ "$(head -c "$n" "$DEV" | sha256sum | cut -d' ' -f1)" = \
  "$(sha256sum "$IMGDIR/$p.img" | cut -d' ' -f1)" ]
```
hash 分区的 `n` 就是分区大小（整分区比较）；`vbmeta`/`vbmeta_system` 的 `n` 是镜像长度（前缀比较，
不能用 `cmp` 比较整分区，尾部仍是旧内容）。
校验失败 → 立即执行 **自动恢复**（第 8 节），退出 1。

### Step 9 —— abl（仅 `>=1.5.04.445` 需要）

写入 abl 是**版本相关**的：`<445` 的 release key 本来就是 testkey，不需要替换；
`>=445` 的 release key 是联想密钥，必须换成内置旧 abl 才能让 testkey 链恢复 GREEN。

`--abl=auto|force|skip`（默认 `auto`）：

| 条件 | 动作 |
|---|---|
| `ABL_NEEDED=yes`（auto） | 确保内置 abl |
| `ABL_NEEDED=no`（auto） | 只备份，不写 |
| `ABL_NEEDED=unknown`（auto，locked） | 拒绝，要求显式 `--abl=force` 或 `--abl=skip` |
| `ABL_NEEDED=unknown`（auto，unlocked/dry-run） | 只备份，不写，`[WARN]` |
| `--abl=force` | 不看版本，确保内置 abl |
| `--abl=skip` | 不写 abl（仍备份） |

“确保内置 abl”：

```sh
cur_sha=$(sha256sum "$ABLDEV" | cut -d' ' -f1)
if [ "$cur_sha" = "$BUNDLED_ABL_SHA" ]; then
    log "abl already matches bundled image; skip write"
else
    [ "$(stat -c %s /avbpowertool/tools/abl.img)" = 1048576 ]
    [ "$(od -An -tx1 -N4 /avbpowertool/tools/abl.img | tr -d ' \n')" = 7f454c46 ]
    [ "$(sha256sum /avbpowertool/tools/abl.img | cut -d' ' -f1)" = "$BUNDLED_ABL_SHA" ]
    dd if=/avbpowertool/tools/abl.img of="$ABLDEV" bs=1M
    cmp /avbpowertool/tools/abl.img "$ABLDEV"
fi
```
失败 → 自动恢复 abl（必要时恢复全部），退出 1。
写入后**不自动重启**。

### Step 10 —— 交付
- 复制 APK 到 `$DOWNLOAD/KernelSU-<tag>.apk`；
- 复制日志与备份路径提示；
- 打印：
  - 备份目录、`restore.sh` 用法；
  - 仅当本次确实写了 abl：“abl 已替换信任锚，另一槽的 OEM 镜像不可启动；若启动失败不要反复重启，直接进 TWRP 恢复或 EDL”；
  - “首次进系统后安装 KernelSU APK”。

---

## 7. Unlocked 模式

保留原脚本行为，只替换/新增：

1. 模式判定按第 2 节；
2. 新增 OTA 闸门（第 3.2 节）；
3. 已 root 检查改为同时检查 `boot` 与 `init_boot`（第 3.3 节）；
4. 其余（读 init_boot、下载 APK、`ksud install`、patch、备份、dd 刷入、回读校验、交付）不变。

---

## 8. 失败处理与恢复

| 阶段 | 动作 |
|---|---|
| Step 0–7 任一失败 | 退出 1；**分区未动**，无需恢复 |
| Step 8 任一写/校验失败 | `restore_all`：按备份恢复 8 镜像 + abl，逐个校验；成功 → 退出 1；失败 → 打印 `DO NOT REBOOT` + EDL 指引 |
| Step 9 写/校验失败 | 先恢复 abl；若仍失败，恢复全部 |
| `restore_all` 自身失败 | 不重启、不退出到系统；保持 TWRP，打印备份绝对路径与手动 dd 命令 |

`restore_all` 的顺序与刷入一致（非 vbmeta → vbmeta_system → vbmeta → abl）。

---

## 9. 交互与退出码

- `[ -t 0 ]` 为假且没有 `--yes` → 打印“非交互环境，默认终止” → exit 1。
- TTY 下打印摘要（槽位、8 分区、abl 是否写入、备份路径），要求输入 `YES`；其它输入 → exit 1。
- `--yes` 跳过确认；`--dry-run` 到 Step 7 结束；`--abl=auto|force|skip` 控制 abl。
- GUI2 的 **Advanced → One-click Root** 入口固定传 `--mode auto --yes`（`popen` 没有 TTY）；安全性由 GUI2 的 DANGER 滑动确认承担，脚本自身的 `YES` 提示被跳过。
- 退出码：`0` 成功；`1` 拒绝/失败；`2` 用法错误。
- 所有输出英文（TWRP 终端字体不含 CJK）；`avbpt` 默认 `en`，工作区固定为新建的 `$WS/avb`，不会带入 `settings.json=zh`。

---

## 10. 脚本拆分

| 文件 | 职责 |
|---|---|
| `system/bin/ksu_oneroot.sh` | 入口、参数、模式判定、调用 locked/unlocked |
| `system/bin/oneroot_common.sh` | 日志、slot、bootctl 闸门、分区读写/校验、APK/ksud、root 检查、备份/恢复、`avbpy` |
| `system/bin/oneroot_locked.sh` | 第 6 节 10 步 |
| `system/bin/avbpt-config-gen.sh` | 第 4 节配置生成（可后续合入 avbpowertool2） |
| `system/bin/oneroot_preflight.py` | 解析 `image inspect --json`，执行第 3.4 节校验 |

`avbpy`（放在 `oneroot_common.sh`，仅用于 `avbtool.py` 与预检 helper）：
```sh
avbpy() {
    PYTHONHOME=$AVBPT_ROOT/py \
    LD_LIBRARY_PATH=$AVBPT_ROOT/py:/system/lib64 \
    PYTHONPATH=$AVBPT_ROOT/compat:$AVBPT_ROOT/app:$AVBPT_ROOT/stdlib/python312.zip:$AVBPT_ROOT/pylib \
    "$AVBPT_ROOT/py/python" "$@"
}
```
`AVBPT_ROOT` 依次探测 `/avbpowertool`、`/customzip/avbpowertool`。

---

## 11. 验收测试

| # | 场景 | 期望 |
|---|---|---|
| 1 | 解锁机 `--mode locked --dry-run --yes` | 走完整 locked 流水线（预检降级为 WARN）；完成读/配置/备份/修补/签名；不写分区；`config check-chains` 通过；4 个签名镜像 `verify_image` 通过 |
| 2 | 同上，检查备份 | 9 个镜像 + profile + SHA256SUMS + restore.sh；`restore.sh` 在 dry-run 后可执行 |
| 3 | 再跑一次 | 命中 `kernelsu.ko` → exit 1 |
| 4 | OTA 待切槽（`get-active != get-current`） | exit 1，不写盘 |
| 5 | 锁定模式下把 boot 换成无 AVB 镜像 | 预检 `descriptor=null` → exit 1（dry-run 仅 WARN） |
| 6 | 锁定机完整跑（`>=445`） | 重启进系统，KernelSU 显示已安装；`init_boot` 含 `kernelsu.ko`，`vbmeta` 链为 testkey；abl 被写入（若原值不同） |
| 7 | 锁定机完整跑（`<445` 或 `--abl=skip`） | 正常 root；abl **未写**；另一槽行为不变 |
| 8 | 锁定机刷写中途拔电/失败注入 | 同会话内 `restore_all` 成功，回到运行前状态 |
| 9 | 从备份手动 `restore.sh` | 逐项 sha 校验通过，重启可进 TWRP |

---

## 12. 边界与假设

1. 顶层 `vbmeta` 由 **AOSP testkey_rsa4096** 签名时，ABL 接受；这是“Testkey 漏洞”的前提，
   也解释了免解锁设备 `verifiedbootstate=GREEN`：老版本联想构建系统把 testkey 当成了 release key。
2. 本机型链位置固定为 `boot:3 / recovery:1 / vbmeta_system:2`；其它布局由第 3.4 节拒绝。
   `vbmeta_system` 的密钥长度随系统版本变化，由“继承当前长度”规则自动覆盖。
3. 只刷活动槽；另一槽保持 OEM。`>=445` 写入旧 abl（**替换**信任锚）后，另一槽不可启动；
   `<445` 不写 abl，另一槽行为保持原样。因此备份仍应复制到**外部介质**（USB OTG/外置卡）。
4. `abl` 分区必须恰好 1 MiB；不是则该机型不支持本流程。
5. 不做自动重启；是否重启由用户决定。
6. OTA 后需重新运行本工具；OTA 可能覆盖 `boot/init_boot/vbmeta`。
7. `<1.5.04.445` 的链公钥本来就是 testkey，`config create` 可能直接解析成功；
   `>=1.5.04.445` 的链是联想密钥，解析会失败并记录 `chain_issues`。
   两种情况都由第 4 节的强制链覆盖，结果一致。
