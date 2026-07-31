#!/bin/bash

set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

EXP_SRC="$SCRIPT_DIR/exp.c"
EXP_BIN="$SCRIPT_DIR/exp"

ROOTFS_FILE=""
ROOTFS_TYPE=""

# 使用虚拟机本地文件系统作为工作目录，避免 Lima 共享目录不支持
# 符号链接、硬链接、设备文件或 Linux 权限的问题。
PROJECT_ID="$(printf '%s' "$SCRIPT_DIR" | cksum | awk '{print $1}')"
WORK_DIR="/tmp/msh-rootfs-$(id -u)-${PROJECT_ID}"
MNT="$WORK_DIR/mnt"

NBD_STATE="$WORK_DIR/nbd-device"
QCOW2_MOUNT_STATE="$WORK_DIR/qcow2-mount-device"

usage() {
    echo "用法: $0 <1|2>"
    echo "  1 - 自动识别镜像格式，编译并放入 exp"
    echo "  2 - 卸载 ext3/qcow2，或重新打包 cpio/cpio.gz"
    echo
    echo "支持的文件格式："
    echo "  *.ext3"
    echo "  *.cpio"
    echo "  *.cpio.gz"
    echo "  *.qcow2"
    echo
    echo "脚本目录中必须且只能存在一个候选镜像。"
    echo
    echo "多分区 qcow2 可通过以下方式指定根分区："
    echo "  QCOW2_PARTITION=2 $0 1"
}

detect_rootfs() {
    local candidates=()
    local file

    shopt -s nullglob

    candidates+=(
        "$SCRIPT_DIR"/*.ext3
        "$SCRIPT_DIR"/*.cpio
        "$SCRIPT_DIR"/*.cpio.gz
        "$SCRIPT_DIR"/*.qcow2
    )

    shopt -u nullglob

    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "未找到受支持的 rootfs/initramfs 文件。" >&2
        echo "支持：*.ext3、*.cpio、*.cpio.gz、*.qcow2" >&2
        return 1
    fi

    if [ "${#candidates[@]}" -gt 1 ]; then
        echo "同时发现多个候选镜像：" >&2

        for file in "${candidates[@]}"; do
            echo "  $(basename -- "$file")" >&2
        done

        echo "请移走不需要处理的文件后再执行。" >&2
        return 1
    fi

    ROOTFS_FILE="${candidates[0]}"

    case "$ROOTFS_FILE" in
        *.cpio.gz)
            ROOTFS_TYPE="cpio.gz"
            ;;
        *.cpio)
            ROOTFS_TYPE="cpio"
            ;;
        *.ext3)
            ROOTFS_TYPE="ext3"
            ;;
        *.qcow2)
            ROOTFS_TYPE="qcow2"
            ;;
        *)
            echo "无法识别文件格式：$ROOTFS_FILE" >&2
            return 1
            ;;
    esac
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "缺少所需命令：$1" >&2
        return 1
    fi
}

compile_exp() {
    if [ ! -f "$EXP_SRC" ]; then
        echo "找不到 $EXP_SRC"
        return 1
    fi

    require_command gcc || return 1

    echo "正在静态编译 exp.c ..."

    if ! gcc -static -o "$EXP_BIN" "$EXP_SRC"; then
        echo "编译失败！"
        return 1
    fi

    echo "exp 编译成功：$EXP_BIN"
}

prepare_work_dir() {
    if mountpoint -q "$MNT"; then
        echo "$MNT 当前是挂载点，拒绝清理。"
        return 1
    fi

    echo "正在准备虚拟机本地工作目录：$WORK_DIR"

    if ! sudo rm -rf -- "$WORK_DIR"; then
        echo "清理旧工作目录失败！"
        return 1
    fi

    if ! mkdir -p "$MNT"; then
        echo "创建工作目录失败！"
        return 1
    fi
}

cleanup_work_dir() {
    if mountpoint -q "$MNT"; then
        echo "警告：$MNT 仍是挂载点，拒绝清理。"
        return 1
    fi

    if [ ! -e "$WORK_DIR" ]; then
        return 0
    fi

    echo "正在清理临时工作目录：$WORK_DIR"

    if ! sudo rm -rf -- "$WORK_DIR"; then
        echo "警告：临时工作目录清理失败：$WORK_DIR"
        return 1
    fi
}

copy_exp_to_rootfs() {
    echo "正在复制 exp 到镜像文件系统 ..."

    if ! sudo rm -f -- "$MNT/exp" ||
       ! sudo cp -- "$EXP_BIN" "$MNT/exp" ||
       ! sudo chmod 755 "$MNT/exp"; then
        echo "复制 exp 失败！"
        return 1
    fi
}

install_to_ext3() {
    echo "检测到 ext3 镜像：$(basename -- "$ROOTFS_FILE")"

    if mountpoint -q "$MNT"; then
        echo "$MNT 已经挂载，继续使用当前挂载点。"
    else
        prepare_work_dir || return 1

        echo "正在挂载 $(basename -- "$ROOTFS_FILE") ..."

        if ! sudo mount -o loop "$ROOTFS_FILE" "$MNT"; then
            echo "挂载失败！"
            return 1
        fi
    fi

    copy_exp_to_rootfs || return 1

    sync

    echo "操作成功！"
    echo "镜像类型：ext3"
    echo "镜像文件：$ROOTFS_FILE"
    echo "挂载目录：$MNT"
    echo "完成其他修改后运行：$0 2"
}

finish_ext3() {
    if ! mountpoint -q "$MNT"; then
        echo "$MNT 当前没有挂载。"
        echo "可能已经卸载，或者虚拟机重启后工作目录已丢失。"
        return 1
    fi

    echo "正在同步文件 ..."
    sync

    echo "正在卸载 $MNT ..."

    if ! sudo umount "$MNT"; then
        echo "卸载失败，目录可能正被其他进程占用。"
        echo "可以使用以下命令检查："
        echo "  sudo fuser -vm \"$MNT\""
        return 1
    fi

    cleanup_work_dir || return 1

    echo "ext3 卸载成功！"
}

validate_cpio() {
    local archive="$1"
    local compression="$2"

    if [ "$compression" = "gzip" ]; then
        gzip -dc -- "$archive" |
            cpio -it >/dev/null 2>&1
    else
        cpio -it < "$archive" >/dev/null 2>&1
    fi
}

extract_cpio() {
    local archive="$1"
    local compression="$2"

    if [ "$compression" = "gzip" ]; then
        gzip -dc -- "$archive" |
            (
                cd "$MNT" || exit 1
                sudo cpio -idm --no-absolute-filenames
            )
    else
        (
            cd "$MNT" || exit 1
            sudo cpio -idm --no-absolute-filenames < "$archive"
        )
    fi
}

install_to_cpio() {
    local archive="$1"
    local compression="$2"
    local label="$3"
    local archive_name

    archive_name="$(basename -- "$archive")"

    require_command cpio || return 1

    if [ "$compression" = "gzip" ]; then
        require_command gzip || return 1
    fi

    echo "检测到 $label 镜像：$archive_name"
    echo "正在校验 $archive_name ..."

    if ! validate_cpio "$archive" "$compression"; then
        echo "$archive_name 校验失败！"
        return 1
    fi

    prepare_work_dir || return 1

    echo "正在解包 $archive_name 到虚拟机本地目录 ..."

    if ! extract_cpio "$archive" "$compression"; then
        echo "解包失败！"
        echo "工作目录已保留：$MNT"
        return 1
    fi

    if ! copy_exp_to_rootfs; then
        echo "工作目录已保留：$MNT"
        return 1
    fi

    echo "操作成功！"
    echo "镜像类型：$label"
    echo "镜像文件：$archive"
    echo "解包目录：$MNT"
    echo "完成其他修改后运行：$0 2"
}

pack_cpio() {
    local output="$1"
    local compression="$2"

    if [ "$compression" = "gzip" ]; then
        (
            cd "$MNT" || exit 1
            sudo find . -print0 |
                sudo cpio --null -o --format=newc
        ) | gzip -9 > "$output"
    else
        (
            cd "$MNT" || exit 1
            sudo find . -print0 |
                sudo cpio --null -o --format=newc
        ) > "$output"
    fi
}

finish_cpio() {
    local archive="$1"
    local compression="$2"
    local label="$3"
    local tmp_archive="${archive}.tmp"
    local backup="${archive}.bak"
    local archive_name

    archive_name="$(basename -- "$archive")"

    require_command cpio || return 1

    if [ "$compression" = "gzip" ]; then
        require_command gzip || return 1
    fi

    if [ ! -d "$MNT" ]; then
        echo "找不到解包目录：$MNT"
        echo "请先运行：$0 1"
        return 1
    fi

    if mountpoint -q "$MNT"; then
        echo "$MNT 当前是挂载点，不能按 $label 格式打包。"
        return 1
    fi

    echo "正在重新打包 $archive_name ..."

    rm -f -- "$tmp_archive"

    if ! pack_cpio "$tmp_archive" "$compression"; then
        echo "打包失败！"
        rm -f -- "$tmp_archive"
        echo "工作目录已保留：$MNT"
        return 1
    fi

    echo "正在校验新生成的 $archive_name ..."

    if ! validate_cpio "$tmp_archive" "$compression"; then
        echo "新生成的 $archive_name 校验失败！"
        rm -f -- "$tmp_archive"
        echo "工作目录已保留：$MNT"
        return 1
    fi

    echo "正在备份原 $archive_name ..."

    if ! cp -f -- "$archive" "$backup"; then
        echo "备份失败，原文件不会被覆盖。"
        rm -f -- "$tmp_archive"
        echo "工作目录已保留：$MNT"
        return 1
    fi

    echo "正在替换 $archive_name ..."

    if ! mv -f -- "$tmp_archive" "$archive"; then
        echo "替换 $archive_name 失败！"
        rm -f -- "$tmp_archive"
        echo "工作目录已保留：$MNT"
        return 1
    fi

    echo "$label 打包成功！"
    echo "新文件：$archive"
    echo "原文件备份：$backup"

    cleanup_work_dir
}

find_free_nbd() {
    local sys_device
    local device

    for sys_device in /sys/class/block/nbd*; do
        [ -e "$sys_device" ] || continue

        device="/dev/$(basename -- "$sys_device")"

        if [ ! -s "$sys_device/pid" ]; then
            echo "$device"
            return 0
        fi
    done

    return 1
}

disconnect_nbd() {
    local nbd_device="$1"

    [ -n "$nbd_device" ] || return 0

    echo "正在断开 $nbd_device ..."

    sudo qemu-nbd --disconnect "$nbd_device"
}

choose_qcow2_mount_device() {
    local nbd_device="$1"
    local requested_partition="${QCOW2_PARTITION:-}"
    local candidate
    local fstype
    local size
    local best_device=""
    local best_size=0
    local candidates=()

    if [ -n "$requested_partition" ]; then
        if [[ "$requested_partition" =~ ^[0-9]+$ ]]; then
            requested_partition="${nbd_device}p${requested_partition}"
        fi

        case "$requested_partition" in
            "$nbd_device"|"${nbd_device}"p[0-9]*)
                ;;
            *)
                echo "QCOW2_PARTITION 必须是分区编号、$nbd_device 或其分区。" >&2
                return 1
                ;;
        esac

        if [ ! -b "$requested_partition" ]; then
            echo "指定的 qcow2 分区不存在：$requested_partition" >&2
            return 1
        fi

        echo "$requested_partition"
        return 0
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] && candidates+=("$candidate")
    done < <(
        lsblk -nrpo NAME,TYPE "$nbd_device" |
            awk '$2 == "part" {print $1}'
    )

    if [ "${#candidates[@]}" -eq 0 ]; then
        candidates=("$nbd_device")
    fi

    for candidate in "${candidates[@]}"; do
        fstype="$(
            sudo blkid -s TYPE -o value "$candidate" 2>/dev/null ||
                true
        )"

        case "$fstype" in
            ""|swap|LVM2_member|crypto_LUKS|linux_raid_member)
                continue
                ;;
        esac

        size="$(
            sudo blockdev --getsize64 "$candidate" 2>/dev/null ||
                echo 0
        )"

        if [ "$size" -gt "$best_size" ]; then
            best_size="$size"
            best_device="$candidate"
        fi
    done

    if [ -z "$best_device" ]; then
        echo "没有在 $nbd_device 中找到可直接挂载的文件系统。" >&2
        echo "暂不支持自动挂载 LVM、LUKS 或软件 RAID 镜像。" >&2
        return 1
    fi

    echo "$best_device"
}

install_to_qcow2() {
    local nbd_device
    local mount_device
    local stale_nbd
    local check_status

    echo "检测到 qcow2 镜像：$(basename -- "$ROOTFS_FILE")"

    require_command qemu-img || return 1
    require_command qemu-nbd || return 1
    require_command lsblk || return 1
    require_command blkid || return 1
    require_command blockdev || return 1
    require_command findmnt || return 1
    require_command modprobe || return 1

    if [ -f "$NBD_STATE" ]; then
        stale_nbd="$(sed -n '1p' "$NBD_STATE")"

        if [ -n "$stale_nbd" ] &&
           [ -s "/sys/class/block/$(basename -- "$stale_nbd")/pid" ]; then
            echo "发现尚未断开的 NBD 设备：$stale_nbd"
            echo "请先运行：$0 2"
            return 1
        fi
    fi

    echo "正在校验 $(basename -- "$ROOTFS_FILE") ..."

    qemu-img check -f qcow2 "$ROOTFS_FILE"
    check_status=$?

    case "$check_status" in
        0)
            ;;
        3)
            echo "警告：qcow2 存在泄漏的簇，但未发现结构损坏。"
            ;;
        *)
            echo "$(basename -- "$ROOTFS_FILE") 校验失败！"
            return 1
            ;;
    esac

    prepare_work_dir || return 1

    echo "正在加载 nbd 内核模块 ..."

    if ! sudo modprobe nbd max_part=16; then
        echo "加载 nbd 内核模块失败！"
        return 1
    fi

    nbd_device="$(find_free_nbd)"

    if [ -z "$nbd_device" ]; then
        echo "没有可用的 NBD 设备。"
        return 1
    fi

    echo "正在将 $(basename -- "$ROOTFS_FILE") 连接到 $nbd_device ..."

    if ! sudo qemu-nbd \
        --connect="$nbd_device" \
        --format=qcow2 \
        "$ROOTFS_FILE"; then
        echo "连接 qcow2 失败！"
        return 1
    fi

    if ! printf '%s\n' "$nbd_device" > "$NBD_STATE"; then
        echo "写入 NBD 状态失败！"
        disconnect_nbd "$nbd_device" || true
        return 1
    fi

    if command -v partprobe >/dev/null 2>&1; then
        sudo partprobe "$nbd_device" >/dev/null 2>&1 || true
    fi

    if command -v udevadm >/dev/null 2>&1; then
        sudo udevadm settle || true
    fi

    mount_device="$(choose_qcow2_mount_device "$nbd_device")"

    if [ -z "$mount_device" ]; then
        disconnect_nbd "$nbd_device" || true
        return 1
    fi

    echo "正在挂载 $mount_device ..."

    if ! sudo mount "$mount_device" "$MNT"; then
        echo "挂载 qcow2 文件系统失败！"
        disconnect_nbd "$nbd_device" || true
        return 1
    fi

    if ! printf '%s\n' "$mount_device" > "$QCOW2_MOUNT_STATE"; then
        echo "写入 qcow2 挂载状态失败！"
        sudo umount "$MNT" || true
        disconnect_nbd "$nbd_device" || true
        return 1
    fi

    if ! copy_exp_to_rootfs; then
        echo "qcow2 仍挂载在：$MNT"
        echo "处理完成后请运行：$0 2"
        return 1
    fi

    sync

    echo "操作成功！"
    echo "镜像类型：qcow2"
    echo "镜像文件：$ROOTFS_FILE"
    echo "NBD 设备：$nbd_device"
    echo "挂载设备：$mount_device"
    echo "挂载目录：$MNT"
    echo "完成其他修改后运行：$0 2"
}

finish_qcow2() {
    local nbd_device
    local expected_mount_device
    local actual_mount_device

    require_command qemu-nbd || return 1
    require_command findmnt || return 1

    if [ ! -f "$NBD_STATE" ]; then
        echo "找不到 qcow2 的 NBD 状态文件：$NBD_STATE"
        echo "请先运行：$0 1"
        return 1
    fi

    nbd_device="$(sed -n '1p' "$NBD_STATE")"

    if [ -z "$nbd_device" ]; then
        echo "NBD 状态文件为空，拒绝继续。"
        return 1
    fi

    if ! mountpoint -q "$MNT"; then
        echo "$MNT 当前没有挂载。"
        echo "为避免断开错误的设备，请检查 $nbd_device 后手工清理。"
        return 1
    fi

    if [ ! -f "$QCOW2_MOUNT_STATE" ]; then
        echo "找不到 qcow2 的挂载设备状态文件：$QCOW2_MOUNT_STATE"
        return 1
    fi

    expected_mount_device="$(
        sed -n '1p' "$QCOW2_MOUNT_STATE"
    )"

    actual_mount_device="$(
        findmnt -n -o SOURCE --target "$MNT"
    )"

    if [ -z "$expected_mount_device" ] ||
       [ "$actual_mount_device" != "$expected_mount_device" ]; then
        echo "挂载设备与状态记录不一致，拒绝卸载。"
        echo "状态记录：${expected_mount_device:-<空>}"
        echo "实际挂载：${actual_mount_device:-<空>}"
        return 1
    fi

    echo "正在同步文件 ..."
    sync

    echo "正在卸载 $MNT ..."

    if ! sudo umount "$MNT"; then
        echo "卸载失败，目录可能正被其他进程占用。"
        echo "可以使用以下命令检查："
        echo "  sudo fuser -vm \"$MNT\""
        return 1
    fi

    if ! disconnect_nbd "$nbd_device"; then
        echo "NBD 设备断开失败：$nbd_device"
        echo "状态目录已保留：$WORK_DIR"
        return 1
    fi

    cleanup_work_dir || return 1

    echo "qcow2 卸载并断开成功！"
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

detect_rootfs || exit 1

echo "检测到镜像文件：$(basename -- "$ROOTFS_FILE")"
echo "检测到镜像类型：$ROOTFS_TYPE"

case "$1" in
    1)
        compile_exp || exit 1

        case "$ROOTFS_TYPE" in
            ext3)
                install_to_ext3 || exit 1
                ;;
            cpio)
                install_to_cpio \
                    "$ROOTFS_FILE" \
                    "none" \
                    "cpio" ||
                    exit 1
                ;;
            cpio.gz)
                install_to_cpio \
                    "$ROOTFS_FILE" \
                    "gzip" \
                    "cpio.gz" ||
                    exit 1
                ;;
            qcow2)
                install_to_qcow2 || exit 1
                ;;
        esac
        ;;

    2)
        case "$ROOTFS_TYPE" in
            ext3)
                finish_ext3 || exit 1
                ;;
            cpio)
                finish_cpio \
                    "$ROOTFS_FILE" \
                    "none" \
                    "cpio" ||
                    exit 1
                ;;
            cpio.gz)
                finish_cpio \
                    "$ROOTFS_FILE" \
                    "gzip" \
                    "cpio.gz" ||
                    exit 1
                ;;
            qcow2)
                finish_qcow2 || exit 1
                ;;
        esac
        ;;

    *)
        echo "无效参数：$1"
        usage
        exit 1
        ;;
esac