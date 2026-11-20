#!/usr/bin/env bash
set -e

echo "==> 1. 安装必要工具..."
apt update
apt install -y systemd-zram-generator util-linux

echo "==> 2. 写入 zram 配置..."
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

echo "==> 3. 调整内核参数 (swappiness=100)..."
cat > /etc/sysctl.d/99-zram.conf << 'EOF'
vm.swappiness = 100
vm.page-cluster = 0
EOF
sysctl --system

echo "==> 4. 重启 zram 服务..."
systemctl daemon-reload
systemctl restart systemd-zram-setup@zram0.service || echo "⚠ 服务重启失败，可能需要重启系统"

echo "==> 5. 关闭并禁用旧的 /swap.img..."
if swapon --show | grep -q '/swap.img'; then
    swapoff /swap.img || true
fi
sed -i '/\/swap\.img/ { /^#/! s/^/#/ }' /etc/fstab
rm -f /swap.img

echo "==> 6. 创建根目录 4G swap 文件 (/swapfile)..."
# 如果已存在，先关闭并删除
if swapon --show | grep -q '/swapfile'; then
    swapoff /swapfile || true
fi
rm -f /swapfile
# 创建 4G 文件（优先 fallocate，失败则用 dd）
fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1G count=4 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon -p -2 /swapfile

echo "==> 7. 写入 fstab 确保开机自动挂载 (/swapfile)..."
# 注释掉旧的 /swapfile 行，防止重复
sed -i '/\/swapfile/ { /^#/! s/^/#/ }' /etc/fstab
# 追加新行（优先级 -2）
echo '/swapfile none swap sw,pri=-2 0 0' >> /etc/fstab

echo "==> 8. 验证结果..."
echo "--- zramctl ---"
zramctl
echo "--- swapon --show ---"
swapon --show

echo "✅ 全部完成！如果 zram 未显示，请执行 reboot 重启。"
