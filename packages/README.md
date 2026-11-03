# Ubuntu ARM64 预编译图形包

GNOME Desktop 选择 `UBUNTU_DESKTOP_GPU=mali` 时安装以下预编译资源，
通过定制 Xorg 和 Mutter 的 GLES2/X11 EGL 后端使用 Mali。
22.04 默认选 Mali，SDK menuconfig 可切换软件渲染，实际加速需上板验证。

Ubuntu 22.04 的 Xorg 与 libmali 保存在本目录，构建不从 Debian 或 external 目录取包。

| 目录 | Xorg 来源 | libc / nettle |
| --- | --- | --- |
| jammy/arm64 | 已有 `rootfs.jammy.desktop.bEV78Tsm` 的 `/opt/rockchip/xserver` | libc6 >= 2.35 / libnettle8 |

Xorg 1.20.11 原始代码来自 SDK Rockchip 定制版本。jammy 产物包含
`glxdri2.c` 头文件顺序修复。此次仅导出已编译文件，没有编译代码或上板测试新包。
包中仅保留运行文件，包含版权声明及 `export-info.json`（原构建信息、文件 SHA256）。
`xserver-COPYING` 为导出工具使用的版权声明副本。
Mali 包最初取自 SDK Debian 同名 G610 g24p0 包，现为 Ubuntu 独立副本；
它自身带有版权信息，运行依赖仍由对应 Ubuntu 的 apt 检查。

导出新的包之前，先在对应发行版中完成定制 Xorg 编译与验证，然后执行：

```bash
# 在 SDK 根目录执行；此命令仅导出已有文件，不编译。
python3 ubuntu/package-xserver.py /path/to/previously-built-rootfs
# 替换包后更新 jammy 校验清单。
(cd ubuntu/packages/jammy/arm64 && find xserver libmali -name '*.deb' -type f -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
```

不要直接放入另一个发行版的 Xorg。导出工具只接受 Ubuntu 22.04 (jammy) 的 ARM64
二进制，不能替代编译和硬件验证。若后续修改包版本号，还需同步 `build.sh` 的选择路径。
