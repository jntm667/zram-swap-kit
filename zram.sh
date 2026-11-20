#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行：sudo bash zram.sh" >&2
    exit 1
fi

ask() {
    local prompt="$1" default="$2" answer
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

ask_swapfile_size() {
    local default="$1" size
    while true; do
        size=$(ask "swap 文件大小（如 4G、2G）" "$default")
        if [[ "$size" =~ ^[0-9]+[GgMm]$ ]]; then
            echo "$size"
            return
        fi
        echo "格式应为数字加 G/M，例如 4G" >&2
    done
}

ask_swappiness() {
    local default="$1" value
    while true; do
        value=$(ask "swap 积极性 vm.swappiness（0-200）" "$default")
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -le 200 ]; then
            echo "$value"
            return
        fi
        echo "请输入 0-200 的整数" >&2
    done
}

to_mb() {
    case "$1" in
        *[gG]) echo $(( ${1%[gG]} * 1024 ));;
        *[mM]) echo "${1%[mM]}";;
    esac
}

conf_value() {
    [ -f /etc/systemd/zram-generator.conf ] || return 0
    sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" /etc/systemd/zram-generator.conf | head -n1
}

current_swapfile_size() {
    if [ -f /swapfile ]; then
        local mb
        mb=$(du -m /swapfile | cut -f1)
        if [ $((mb % 1024)) -eq 0 ]; then
            echo "$((mb / 1024))G"
        else
            echo "${mb}M"
        fi
    else
        echo "4G"
    fi
}

show_status() {
    echo "===== 当前系统状态 ====="
    echo "--- zram (/dev/zram0) ---"
    if [ -b /dev/zram0 ]; then
        zramctl /dev/zram0
    else
        echo "未启用"
    fi
    echo "--- swap ---"
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        swapon --show
    else
        echo "未启用"
    fi
    echo "--- swappiness ---"
    sysctl -n vm.swappiness
    echo "--- /swapfile ---"
    if [ -f /swapfile ]; then
        du -h /swapfile | cut -f1
    else
        echo "不存在"
    fi
    if [ -f /etc/systemd/zram-generator.conf ]; then
        echo "--- /etc/systemd/zram-generator.conf ---"
        cat /etc/systemd/zram-generator.conf
    fi
}

write_zram_config() {
    cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = $1
compression-algorithm = $2
swap-priority = $3
EOF
}

write_swapfile() {
    local size="$1" size_mb
    size_mb=$(to_mb "$size")
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
        swapoff /swapfile
    fi
    rm -f /swapfile
    fallocate -l "$size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon -p -2 /swapfile
}

install_all() {
    echo "==> 1. 检查并禁用系统自带的 swap..."
    local found
    found=$(swapon --show --noheadings --output NAME || true)
    if [ -n "$found" ]; then
        echo "发现以下已启用的 swap，将全部关闭："
        echo "$found"
        swapoff -a
    else
        echo "未发现已启用的 swap"
    fi
    # 注释 fstab 中所有 swap 行，防止开机自动挂载
    sed -i -E 's/^([^#].*[[:space:]]swap[[:space:]].*)$/#\1/' /etc/fstab
    rm -f /swap.img

    echo "==> 2. 更新软件源并安装工具..."
    apt update
    apt install -y systemd-zram-generator util-linux

    echo "==> 3. 询问配置（直接回车使用默认值）..."
    local size algo prio swappiness swapfile_size
    size=$(ask "zram 大小（如 ram / 2、2G）" "ram / 2")
    algo=$(ask "压缩算法（zstd/lz4/lzo-rle）" "zstd")
    prio=$(ask "zram swap 优先级" "100")
    swappiness=$(ask_swappiness "100")
    swapfile_size=$(ask_swapfile_size "$(current_swapfile_size)")

    echo "==> 4. 统一写入配置文件..."
    write_zram_config "$size" "$algo" "$prio"
    cat > /etc/sysctl.d/99-zram.conf << EOF
vm.swappiness = ${swappiness}
vm.page-cluster = 0
EOF

    echo "==> 5. 重启 zram 服务并应用内核参数..."
    systemctl daemon-reload
    sysctl --system
    systemctl restart systemd-zram-setup@zram0.service || echo "⚠ 服务重启失败，可能需要重启系统"

    echo "==> 6. 创建 ${swapfile_size} 兜底 swap 文件 (/swapfile)..."
    write_swapfile "$swapfile_size"

    echo "==> 7. 写入 fstab 确保开机自动挂载 (/swapfile)..."
    echo '/swapfile none swap sw,pri=-2 0 0' >> /etc/fstab

    echo "==> 8. 验证结果..."
    zramctl /dev/zram0
    swapon --show
    echo "✅ 全部完成！如果 zram 未显示，请执行 reboot 重启。"
}

config_zram() {
    if ! dpkg -s systemd-zram-generator >/dev/null 2>&1; then
        echo "未安装 systemd-zram-generator，请先执行菜单 1。" >&2
        return 0
    fi
    echo "==> 修改 zram 配置（直接回车保留当前值）..."
    local size algo prio default_size default_algo default_prio
    default_size=$(conf_value zram-size)
    default_size=${default_size:-ram / 2}
    default_algo=$(conf_value compression-algorithm)
    default_algo=${default_algo:-zstd}
    default_prio=$(conf_value swap-priority)
    default_prio=${default_prio:-100}
    size=$(ask "zram 大小（如 ram / 2、2G）" "$default_size")
    algo=$(ask "压缩算法（zstd/lz4/lzo-rle）" "$default_algo")
    prio=$(ask "zram swap 优先级" "$default_prio")
    write_zram_config "$size" "$algo" "$prio"
    systemctl daemon-reload
    systemctl restart systemd-zram-setup@zram0.service || echo "⚠ 服务重启失败，可能需要重启系统"
    echo "--- zramctl ---"
    zramctl /dev/zram0
}

config_swapfile() {
    echo "==> 修改 swap 文件（直接回车保留当前大小）..."
    local size
    size=$(ask_swapfile_size "$(current_swapfile_size)")
    write_swapfile "$size"
    sed -i -E 's|^([^#].*[[:space:]]/swapfile[[:space:]].*)$|#\1|' /etc/fstab
    echo '/swapfile none swap sw,pri=-2 0 0' >> /etc/fstab
    echo "--- swapon --show ---"
    swapon --show
}

config_swappiness() {
    echo "==> 修改 swap 积极性..."
    local value
    value=$(ask_swappiness "$(sysctl -n vm.swappiness)")
    if [ -f /etc/sysctl.d/99-zram.conf ] && grep -qE '^[[:space:]]*vm\.swappiness' /etc/sysctl.d/99-zram.conf; then
        sed -i -E "s|^[[:space:]]*vm\.swappiness.*|vm.swappiness = ${value}|" /etc/sysctl.d/99-zram.conf
    else
        echo "vm.swappiness = ${value}" >> /etc/sysctl.d/99-zram.conf
    fi
    sysctl -w "vm.swappiness=${value}"
}

show_status
while true; do
    echo
    echo "===== 菜单 ====="
    echo "1) 一键安装并配置 zram + swap"
    echo "2) 只修改 zram（大小/算法/优先级）"
    echo "3) 只修改 swap 文件（/swapfile）"
    echo "4) 只修改 swap 积极性（vm.swappiness）"
    echo "0) 退出"
    read -r -p "请选择 [0-4]: " choice
    case "$choice" in
        1) install_all ;;
        2) config_zram ;;
        3) config_swapfile ;;
        4) config_swappiness ;;
        0) break ;;
        *) echo "无效选项，请输入 0-4" ;;
    esac
done
