# RK3588S TBoard Ubuntu 根文件系统

本目录构建 TBoard (RK3588S) 的 Ubuntu 22.04 (jammy) ARM64 根文件系统，
提供 Server、Desktop 两种形态，共用 SDK 的 U-Boot、内核（Linux 5.10.226）和 `rk3588s-TBoard-R5A.dts`。

| 形态 | 内容 | 默认启动目标 |
| --- | --- | --- |
| Server | 无桌面基础系统，串口、SSH、NetworkManager、蓝牙工具 | `multi-user.target` |
| Desktop | Server 基础上增加 Ubuntu GNOME、GDM3、Xorg；默认 Mali GLES2 加速，可选软件渲染 | `graphical.target` |

两版默认简体中文 locale，预装 `build-essential`、`alsa-utils`；Desktop 另装
PulseAudio、pavucontrol、gnome-control-center 等。板载 AIC8800 SDIO WiFi，
试验性 UART H4 蓝牙见 [bsp/wifibt/README.bluetooth.md](bsp/wifibt/README.bluetooth.md)。

## 构建

推荐从 SDK 根目录构建（切换 defconfig 会重置 SDK 配置，已有自定义设置先备份 `output/.config`）：

    # Ubuntu 22.04 Server / GNOME Desktop
    ./build.sh tboard-r5a_rk3588s_ubuntu_server_defconfig
    ./build.sh tboard-r5a_rk3588s_ubuntu_gnome_defconfig

    ./build.sh ubuntu-server    # 或 ubuntu-desktop（显式命令切换形态）
    ./build.sh firmware
    # 或选好配置后一键完整构建
    ./build.sh all

在 ubuntu22.04/ 目录内直接构建（读同一份 config.local，不读 SDK menuconfig 选择）：

    cp config.example config.local    # 按需修改，如 UBUNTU_CONSOLE、UBUNTU_DESKTOP_GPU
    ./mk-image.sh --check             # 只读环境检查
    RK_UBUNTU_VERSION=jammy RK_UBUNTU_FLAVOR=desktop ./mk-image.sh
    # 不带环境变量时默认构建 22.04 Server

宿主机依赖（Ubuntu 20.04/22.04 x86_64 或 arm64）：

    sudo apt-get install -y debootstrap ubuntu-keyring qemu-user-static \
        binfmt-support e2fsprogs util-linux rsync ca-certificates
    # x86_64 主机还需: sudo update-binfmts --enable qemu-aarch64
    # 构 jammy 需 debootstrap 带 jammy 脚本，--check 可提前发现

构建需要网络、sudo；软件源默认 `https://ports.ubuntu.com/ubuntu-ports`，
可在 SDK `./build.sh menuconfig` 的 Ubuntu 菜单更换。

## 产物

    output/ubuntu-jammy-server/images/rootfs.ext4    22.04 Server
    output/ubuntu-jammy-desktop/images/rootfs.ext4   22.04 Desktop
    output/firmware/rootfs.img                       当前构建版本的镜像链接
    rockdev/update.img                               最近打包的完整固件

Server、Desktop 的 rootfs 分目录保存，互不覆盖；需保留多份完整固件时，切换版本前先复制 `update.img`。
注意：独立运行 `ubuntu22.04/mk-image.sh` 不会更新 `output/firmware/rootfs.img` 链接，
打包前用 `readlink -f output/firmware/rootfs.img` 确认指向；走 SDK 的
`./build.sh ubuntu-desktop` 构建则会同步该链接。
构建中间目录在 `ubuntu22.04/work/`，下载缓存在 `ubuntu22.04/cache/`；
确认无构建运行时可 `rm -rf ubuntu22.04/work ubuntu22.04/cache` 清理。

## 默认账号

- `root` / `root`（串口、su、SSH、GDM3 桌面密码登录均可用；桌面登录界面选"未列出？"输入 root）
- `tboard` / `tboard`（sudo 用户；Desktop 经 GDM3 登录，不自动登录）

## 自定义

- 公共文件放 `ubuntu22.04/overlay/`，版本专属放 `overlay-server/`、`overlay-desktop/`（目录结构与目标根目录一致，复制顺序：SDK 后处理 → 共用 → 版本专属）
- 欢迎横幅模板：`overlay/etc/motd.template`；主机名跟随所选 defconfig 的型号前缀（`tboard-r5a_...` → `TBoard-R5A`），可用 `UBUNTU_HOSTNAME` 覆盖
- 镜像容量按内容自动计算，需能放入 `parameter-tboard.txt` 的 rootfs 分区（14 GiB）

## 上板快速检查

    cat /etc/os-release            # Server: VARIANT_ID=server, Desktop: VARIANT_ID=desktop
    uname -r
    systemctl --failed
    nmcli device status
    df -h /                        # 首次启动应由 resize-all.service 扩容

Desktop 应出现 GDM3 登录界面；若未出现，从串口检查 `systemctl status gdm3`、
`journalctl -b -u gdm3`。旧镜像若只出现文字登录，通常是缺少
`display-manager.service` 链接（GDM unit 为静态单元，`systemctl enable gdm3` 无效）：

    ln -sfn "$(readlink -f /lib/systemd/system/gdm3.service)" /etc/systemd/system/display-manager.service
    systemctl daemon-reload && systemctl set-default graphical.target
    systemctl start display-manager.service

当前构建已显式创建该链接并在后处理中核验。

## Mali 加速（GNOME Xorg，默认启用）

Desktop 默认安装定制 Xorg、G610 Mali EGL/GLES 库（g24p0）和 `glmark2-es2`，
并配置 GLES2 渲染环境。渲染方式可在 `./build.sh menuconfig` 的
Ubuntu → Ubuntu desktop renderer 中选择 Mali 或 Software（SDK 菜单优先于
`config.local`；独立构建用 `UBUNTU_DESKTOP_GPU=mali|software`）。

板端验证（HDMI 桌面终端）：

    rk3588-desktop-renderer status
    rk3588-render-env glmark2-es2     # GL_RENDERER 应含 Mali-G610；llvmpipe 表示仍在软件渲染

注意：厂商库仅提供 EGL/OpenGL ES，不含桌面 OpenGL/GLX，不能用 `glxinfo` 单独判断。
若登录黑屏，从串口以 root 切回软件渲染并重启：`rk3588-desktop-renderer software && reboot`。
