#!/usr/bin/env bash
# ================================================================
# scripts/post-build.sh —— 固件后置处理：扩容 rootfs_data(/overlay) 分区
#
# 【工作原理】
#   ImmortalWrt 的 x86_64 squashfs combined 镜像出厂只包含 2 个分区：
#     p1 = 引导分区（GRUB + 内核），p2 = squashfs 只读根分区。
#   系统首次启动时，fstools 的 rootdisk 驱动会在 p2 内 squashfs 数据
#   结束处（64KB 对齐）创建 loop 设备，其后剩余空间即 rootfs_data
#   （/overlay）可写分区，并自动格式化为 f2fs。
#   因此：扩容 rootfs_data 至 2048MiB = 将第 2 分区（根分区）尾部扩大，
#   使（分区大小 - squashfs 实际占用）≥ 2048MiB。
#
# 【脚本功能】
#   1. 自动识别 MBR（BIOS）与 GPT（UEFI）两种 combined 镜像；
#   2. 定位 squashfs 根分区，读取 squashfs 实际占用（bytes_used）；
#   3. 扩大根分区，使 rootfs_data 可写空间 ≥ 指定大小（默认 2048MiB）；
#   4. GPT 镜像同步更新备份 GPT 表并重算 CRC32 校验；
#      原镜像无备份 GPT 表时（ptgen 默认省略 alternate 表），按规范补建；
#   5. 完整保留镜像尾部 fwtool 元数据（sysupgrade 校验依赖，处理后回填）；
#   6. 纯 python3 实现分区表操作，不依赖 fdisk/parted/sgdisk 等工具。
#
# 【用法】
#   post-build.sh <镜像文件.img> [rootfs_data 目标大小, 单位 MiB, 默认 2048]
#
# 【安全机制】
#   - set -euo pipefail：任何错误立即终止；
#   - 根分区必须是最后一个分区，否则拒绝扩容（避免覆盖其他分区）；
#   - 扩容前校验 GPT CRC，扩容后保持分区 256KB 对齐（与 ptgen 一致）。
# ================================================================
set -euo pipefail

IMG="${1:-}"
DATA_MB="${2:-2048}"

# ---------- 参数校验 ----------
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  echo "用法: $0 <镜像文件.img> [rootfs_data 目标大小, 单位 MiB, 默认 2048]" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 未找到 python3, 无法处理分区表" >&2
  exit 1
fi
case "$DATA_MB" in
  ''|*[!0-9]*)
    echo "错误: 大小参数必须为正整数(MiB): $DATA_MB" >&2
    exit 1
  ;;
esac
if [ "$DATA_MB" -lt 1 ]; then
  echo "错误: 大小参数必须为正整数(MiB): $DATA_MB" >&2
  exit 1
fi

echo "==> [post-build] 处理镜像: $IMG"
echo "==> [post-build] 目标 rootfs_data 大小: ${DATA_MB} MiB"

# ---------- 核心逻辑：python3 分区表手术 ----------
python3 - "$IMG" "$DATA_MB" <<'PYEOF'
import os
import struct
import sys
import zlib

IMG, DATA_MB = sys.argv[1], int(sys.argv[2])
SECT = 512
TARGET = DATA_MB * 1024 * 1024      # rootfs_data 目标字节数
ALIGN_DATA = 64 * 1024             # fstools rootdisk 的 64KB 对齐
ALIGN_PART = 256 * 1024            # ptgen 分区 256KB 对齐，扩容后保持一致
FW_MAGIC = 0x46577830              # fwtool 尾部元数据魔数 "FWx0"


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(1)


def align_up(x, a):
    return (x + a - 1) & ~(a - 1)


f = open(IMG, "r+b")
file_size = os.fstat(f.fileno()).st_size

# ---------- 第一步：剥离镜像尾部 fwtool 元数据（处理完成后原样回填） ----------
# append-metadata 会在镜像文件末尾追加 fwtool 分块（sysupgrade 校验依赖），
# 每个分块以 16 字节大端 trailer 结束:
#   magic(4)=0x46577830("FWx0"), crc32(4), type(1), pad(3), size(4)=分块总长
chunks = []
end = file_size
while end >= 16:
    f.seek(end - 16)
    magic, crc32, ctype, size = struct.unpack(">II B 3x I", f.read(16))
    if magic != FW_MAGIC or size < 16 or size > end:
        break
    f.seek(end - size)
    chunks.append(f.read(size))
    end -= size
table_end = end  # 镜像本体（分区表数据）结束位置
if chunks:
    print("    已剥离尾部 fwtool 元数据 %d 段, 共 %d 字节（处理后回填）"
          % (len(chunks), file_size - table_end))

# ---------- 第二步：识别分区表类型（GPT / MBR） ----------
f.seek(0)
lba0 = f.read(512)
if lba0[510:512] != b"\x55\xaa":
    die("镜像缺少 55AA 签名, 不是有效的 MBR/GPT 镜像")
f.seek(512)
hdr1 = f.read(512)
is_gpt = hdr1[:8] == b"EFI PART"


def squashfs_used(start_byte):
    """读取分区起始处 squashfs 超级块, 返回 bytes_used; 非 squashfs 返回 None"""
    f.seek(start_byte)
    sb = f.read(64)
    if len(sb) < 64 or sb[:4] != b"hsqs":
        return None
    return struct.unpack_from("<Q", sb, 40)[0] or None


# ---------- 第三步：定位 squashfs 根分区, 计算扩容参数 ----------
max_end_lba = 0
if is_gpt:
    hdr = bytearray(hdr1)
    ent_lba = struct.unpack_from("<Q", hdr, 72)[0]
    ent_cnt = struct.unpack_from("<I", hdr, 80)[0]
    ent_sz = struct.unpack_from("<I", hdr, 84)[0]
    f.seek(ent_lba * SECT)
    entries = bytearray(f.read(ent_cnt * ent_sz))
    if zlib.crc32(bytes(entries)) & 0xFFFFFFFF != struct.unpack_from("<I", hdr, 88)[0]:
        die("GPT 分区表项 CRC32 校验失败, 镜像可能损坏")
    hit = None
    for i in range(ent_cnt):
        first, last = struct.unpack_from("<QQ", entries, i * ent_sz + 32)
        if first == 0 or last < first:
            continue
        max_end_lba = max(max_end_lba, last)
        used = squashfs_used(first * SECT)
        if used is not None:
            if hit is not None:
                die("发现多个 squashfs 分区, 无法判断根分区")
            hit = (i, first, last, used)
    if hit is None:
        die("GPT 镜像中未找到 squashfs 根分区")
    idx, first_lba, last_lba, used = hit
    part_size = (last_lba - first_lba + 1) * SECT
    if last_lba != max_end_lba:
        die("根分区不是最后一个分区, 拒绝扩容（避免覆盖其他分区）")
else:
    hit = None
    for i in range(4):
        off = 446 + i * 16
        start_lba, cnt = struct.unpack_from("<II", lba0, off + 8)
        if cnt == 0:
            continue
        max_end_lba = max(max_end_lba, start_lba + cnt - 1)
        used = squashfs_used(start_lba * SECT)
        if used is not None:
            if hit is not None:
                die("发现多个 squashfs 分区, 无法判断根分区")
            hit = (i, start_lba, cnt, used)
    if hit is None:
        die("MBR 镜像中未找到 squashfs 根分区")
    idx, first_lba, cnt, used = hit
    part_size = cnt * SECT
    if first_lba + cnt - 1 != max_end_lba:
        die("根分区不是最后一个分区, 拒绝扩容（避免覆盖其他分区）")

if used > part_size:
    die("squashfs 占用大于根分区, 镜像数据异常")
data_off = align_up(used, ALIGN_DATA)   # rootfs_data 在根分区内的起始偏移
cur_data = part_size - data_off
if cur_data >= TARGET:
    print("    rootfs_data 当前空间 %.2f MiB, 已达到目标 %.2f MiB, 无需扩容"
          % (cur_data / 1048576, TARGET / 1048576))
    sys.exit(0)

new_part = align_up(data_off + TARGET, ALIGN_PART)  # 新根分区大小（保持 256KB 对齐）
delta = new_part - part_size
if delta <= 0 or delta % SECT:
    die("内部错误: 扩容增量计算异常")

print("    分区表类型: %s" % ("GPT (UEFI)" if is_gpt else "MBR (BIOS)"))
print("    squashfs 实际占用: %.2f MiB" % (used / 1048576))
print("    rootfs_data 当前空间: %.2f MiB" % (cur_data / 1048576))
print("    根分区将由 %.2f MiB 扩大至 %.2f MiB (+%.2f MiB)"
      % (part_size / 1048576, new_part / 1048576, delta / 1048576))

# ---------- 第四步：先截掉元数据尾部, 再修改分区表 ----------
if chunks:
    f.truncate(table_end)

new_table_end = 0
if is_gpt:
    # 4.1 更新分区项 last_lba, 重算分区表项 CRC32
    new_last_lba = first_lba + new_part // SECT - 1
    struct.pack_into("<Q", entries, idx * ent_sz + 40, new_last_lba)
    ecrc = zlib.crc32(bytes(entries)) & 0xFFFFFFFF

    old_backup_lba = struct.unpack_from("<Q", hdr, 32)[0]
    d = delta // SECT  # 扩容扇区数
    new_backup_lba = old_backup_lba + d

    # 尝试读取原备份 GPT 头：
    #   注意: OpenWrt 的 ptgen 默认省略备份 GPT 表（alternate 分区表不写入镜像,
    #   见 ptgen.c "The alternate partition table (We omit it by default)"）,
    #   备份头可能不存在, 甚至位置超出物理文件末尾, 均按"缺失"处理。
    f.seek(old_backup_lba * SECT)
    bh_raw = f.read(512)
    has_backup = len(bh_raw) == 512 and bh_raw[:8] == b"EFI PART"
    if has_backup:
        bh = bytearray(bh_raw)
        old_b_ent_lba = struct.unpack_from("<Q", bh, 72)[0]

    def fix_header_crc(h):
        """按 GPT 规范重算头 CRC32（校验字段本身清零后计算）"""
        hs = struct.unpack_from("<I", h, 12)[0]
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<I", h, 16, zlib.crc32(bytes(h[:hs])) & 0xFFFFFFFF)

    # 4.2 更新主 GPT 头: 备份头位置/最后可用 LBA/表项 CRC
    struct.pack_into("<Q", hdr, 32, new_backup_lba)
    struct.pack_into("<Q", hdr, 48, struct.unpack_from("<Q", hdr, 48)[0] + d)
    struct.pack_into("<I", hdr, 88, ecrc)
    fix_header_crc(hdr)

    ent_sectors = ent_cnt * ent_sz // SECT  # 表项区占用扇区数(128项×128B=32扇区)

    if has_backup:
        # 4.3a 原备份头存在 → 更新字段并整体迁移到新文件末尾
        struct.pack_into("<Q", bh, 24, new_backup_lba)
        struct.pack_into("<Q", bh, 48, struct.unpack_from("<Q", bh, 48)[0] + d)
        struct.pack_into("<Q", bh, 72, old_b_ent_lba + d)
        struct.pack_into("<I", bh, 88, ecrc)
        fix_header_crc(bh)
        f.seek((old_b_ent_lba + d) * SECT)
        f.write(entries)
        f.seek(new_backup_lba * SECT)
        f.write(bh)
        print("    已更新 GPT 分区表, 迁移备份表头并重算 CRC32")
    else:
        # 4.3b 原备份 GPT 表缺失（ptgen 默认省略）→ 按 GPT 规范在扩容后的
        #      文件末尾补建完整备份结构（备份表项区 + 备份 GPT 头）,
        #      使固件拥有标准 GPT 双表布局, 工具与内核读取更友好。
        bh = bytearray(hdr)                                   # 基于更新后的主头
        struct.pack_into("<Q", bh, 24, new_backup_lba)        # 备份头自身 LBA
        struct.pack_into("<Q", bh, 32, 1)                     # alternate 指回主头(LBA1)
        struct.pack_into("<Q", bh, 72, new_backup_lba - ent_sectors)  # 备份表项区起始
        # entry_crc32(88) 与主头一致(已随 hdr 复制), 重算头 CRC
        fix_header_crc(bh)
        f.seek((new_backup_lba - ent_sectors) * SECT)
        f.write(entries)
        f.seek(new_backup_lba * SECT)
        f.write(bh)
        print("    已更新 GPT 分区表; 原镜像无备份 GPT 表(ptgen 默认省略), "
              "已按规范补建备份表项区与备份头")

    # 4.4 写回: 主表项区 / 主 GPT 头
    f.seek(ent_lba * SECT)
    f.write(entries)
    f.seek(SECT)
    f.write(hdr)
    new_table_end = (new_backup_lba + 1) * SECT
    # 4.5 同步保护 MBR（0xEE 项）的容量字段与 CHS 上限
    new_total_sect = new_table_end // SECT
    f.seek(446 + 12)
    f.write(struct.pack("<I", min(0xFFFFFFFF, new_total_sect - 1)))
    f.seek(446 + 5)
    f.write(bytes([0xFE, 0xFF, 0xFF]))
    print("    已同步 GPT 保护 MBR 容量字段")
else:
    # MBR: 更新分区项扇区数, CHS 结束地址置为上限(FE FF FF)
    new_cnt = new_part // SECT
    off = 446 + idx * 16
    f.seek(off + 12)
    f.write(struct.pack("<I", new_cnt))
    f.seek(off + 5)
    f.write(bytes([0xFE, 0xFF, 0xFF]))
    new_table_end = (first_lba + new_cnt) * SECT
    print("    已更新 MBR 分区表（根分区扩大 %d 个扇区）" % (new_cnt - part_size // SECT))

# ---------- 第五步：扩容文件并回填 fwtool 元数据 ----------
f.truncate(new_table_end)
f.seek(new_table_end)
for c in reversed(chunks):  # 按原始顺序回填
    f.write(c)
f.close()

final_size = new_table_end + sum(len(c) for c in chunks)
print("    镜像大小: %.2f MiB -> %.2f MiB" % (file_size / 1048576, final_size / 1048576))
print("    rootfs_data(/overlay) 可写空间: %.2f MiB（首次启动自动格式化为 f2fs）"
      % ((new_part - data_off) / 1048576))
print("==> [post-build] 扩容完成: %s" % IMG)
PYEOF
