# zram-swap-kit

Ubuntu 24.04–26.04 交互式 zram + 磁盘 swap 工具：启动先输出当前系统状态，菜单中可一键安装配置，也可单独修改 zram、swap 文件和 swap 积极性。

## 兼容性

| 系统 | systemd-zram-generator | 服务 |
|---|---|---|
| 24.04 | 1.1.2 | `systemd-zram-setup@zram0.service` |
| 26.04 | 1.2.1 | `systemd-zram-setup@zram0.service` |

要求：root 权限、可联网、根文件系统为 ext4（btrfs 上 `/swapfile` 不能直接当 swap 用）。`systemd-zram-generator` 位于 universe 组件，需要已启用。

## 使用

```bash
sudo bash zram.sh
# 或
chmod +x zram.sh && sudo ./zram.sh
```

启动后先输出当前状态（`/dev/zram0`、swap 列表、`vm.swappiness`、`/swapfile` 大小、现有 zram 配置），然后进入菜单：

| 选项 | 功能 |
|---|---|
| 1 | 一键安装并配置 zram + swap |
| 2 | 只修改 zram（大小/算法/优先级），重启服务生效 |
| 3 | 只修改 swap 文件（重建 `/swapfile` 并更新 fstab） |
| 4 | 只修改 swap 积极性（`vm.swappiness`） |
| 0 | 退出 |

菜单 2–4 的默认值取自当前配置，直接回车保留原值；菜单 2 需要先执行过菜单 1。

## 菜单 1 的流程

1. 检查已启用的 swap，全部 `swapoff`；注释 fstab 中所有 swap 行；删除 `/swap.img`。
2. `apt update`，安装 `systemd-zram-generator`、`util-linux`。
3. 交互询问配置项（见下表）。
4. 统一写入 `/etc/systemd/zram-generator.conf` 和 `/etc/sysctl.d/99-zram.conf`。
5. `daemon-reload`、`sysctl --system`，重启 `systemd-zram-setup@zram0.service`。
6. 创建 `/swapfile`（优先 fallocate，失败则 dd），`chmod 600`、`mkswap`、`swapon -p -2`。
7. 追加 fstab 条目，输出 `zramctl` 与 `swapon --show` 供验证。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| zram 大小 | `ram / 2` | 支持表达式或 `2G` 这类写法 |
| 压缩算法 | `zstd` | 可选 zstd/lz4/lzo-rle |
| zram 优先级 | `100` | 高于磁盘 swap |
| swap 积极性 | `100` | `vm.swappiness`，0–200 |
| 兜底 swap 文件 | `4G` | 创建为 `/swapfile` |

磁盘 swap 的优先级低于 zram 的 100：`pri=-2` 在 util-linux 中被当作"未指定优先级"，实际使用内核默认的最低优先级，效果符合预期（zram 优先）。

## 验证

```bash
zramctl                     # /dev/zram0：ALGORITHM 为所选算法，DISKSIZE 符合设定，MOUNTPOINT=[SWAP]
swapon --show               # zram0 PRIO=100，/swapfile PRIO 更低
cat /proc/sys/vm/swappiness # 所选值
```

重启后再执行一遍，确认开机自动生效。

## 注意事项

- 菜单 1 会关闭现有 swap、删除 `/swap.img` 并重建 `/swapfile`，执行前确认根分区放得下所选空间。
- 菜单 3 会删除并重建 `/swapfile`，进行中的 swap 会被关闭。
- 重复执行是安全的：会重新关闭旧 swap、覆盖配置并重建 `/swapfile`。
- 26.04 的 coreutils 已换成 rust-coreutils，dd 兜底路径的 `status=progress` 已确认支持；`fallocate` 属于 util-linux，不受影响。

## 回滚

```bash
sudo systemctl stop systemd-zram-setup@zram0.service
sudo rm -f /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload

sudo rm -f /etc/sysctl.d/99-zram.conf
sudo swapoff /swapfile 2>/dev/null || true
sudo rm -f /swapfile
sudo sed -i '/\/swapfile/d' /etc/fstab
```

回滚后如需恢复安装器默认的 `/swap.img`，重建并写回 fstab 即可。

## AI 辅助声明

本项目由 AI 辅助创建：脚本和文档初稿由 AI 生成，AI 工具不主张版权。项目按 MIT 协议"按原样"（AS IS）提供，使用风险自负。

## 许可证

[MIT](LICENSE) © 2026 jntm667
