# AIC8800 UART Bluetooth：TBoard 试验性接入

Ubuntu 22.04、Debian Bullseye 的构建流程会安装本目录的初始化工具、配置和
`aic8800-bluetooth.service`。当前只完成源码接入与模拟协议测试，**未上板验证**。
Buildroot 的资源及蓝牙启动流程没有改动。

## 工作顺序

1. 原 `wifibt-init.service` 加载 `aic8800_bsp` 和 `aic8800_fdrv`，BSP 通过 SDIO
   下载蓝牙 ADID/PATCH/TABLE 和 Wi-Fi 固件。
2. 独立服务等待 SDIO、Wi-Fi 模块和 `/dev/ttyS9` 就绪，再解除板级 `bt_default`
   rfkill 的软件阻塞。不会主动关闭共享电源或重载已运行的 Wi-Fi 驱动。
3. `/usr/bin/aic8800-bt-attach` 使用 1500000、8N1、RTS/CTS 与控制器通信，执行
   HCI Reset、读取版本和地址、必要时设置地址、配置厂商 PTA 共存参数。
4. 只有命令成功后，才以 `N_HCI` / H4 注册 Linux HCI 设备。前台进程保持 UART
   打开，退出时释放连接；BlueZ 负责后续扫描、配对和连接。

默认配置 `/etc/aic8800-bluetooth.conf` 与现有内核 BSP 匹配：

```ini
[aic8800]
device = /dev/ttyS9
baud = 1500000
command_timeout = 5
wait_seconds = 30
configure_pta = yes
bdaddr =
```

`baud` 必须与 BSP 的 `AICBT_UART_BAUD_DEFAULT` 一致；只改用户配置不会改变芯片端
波特率。程序使用显式端口，不会遍历串口尝试，也会拒绝使用内核 `console=` 指定的端口。
不要同时在 UART9 上运行 getty、`hciattach`、`btattach` 或其他串口程序。

空 `bdaddr` 保留有效控制器地址；全零、全 FF、厂商示例地址或非单播地址会替换为
根据板卡 serial-number（缺失时使用首启生成的 machine-id）派生的地址。
有正式分配的地址时可显式填写，每块板应唯一。工具不写入芯片 OTP。

## 构建与依赖

沿用原来的 Ubuntu / Debian rootfs 构建命令，不需要额外编译 Android 库。
两个系统显式安装 `python3`、BlueZ，工具只使用 Python 标准库。
需要完整的 `python3` 运行时，`python3-minimal` 单独安装可能缺少 `termios`。
SDK 后处理会用目标解释器运行 `--check-config` 检查依赖，不访问蓝牙硬件。

当前内核已经启用 `CONFIG_BT=y`、`CONFIG_BT_HCIUART=y`、
`CONFIG_BT_HCIUART_H4=y`，BSP 的 `CONFIG_SDIO_BT=n` 保持不变：这里是 UART H4，
不是 SDIO HCI。采用当前内核的板子通常只需更新 rootfs；若板上运行的内核不同，先确认：

```bash
zcat /proc/config.gz | grep -E 'CONFIG_BT(=|_HCIUART=|_HCIUART_H4=)'
```

服务会独立显示失败并有限次数重试，不以“有 bluetooth.service”或“加载了模块”作为
蓝牙可用的依据。Wi-Fi 服务不依赖这个蓝牙服务的成功状态。

## 板端测试

重新生成并烧录 rootfs 后，在板端执行：

```bash
sudo systemctl status aic8800-bluetooth.service --no-pager -l
sudo journalctl -b -u aic8800-bluetooth.service --no-pager
ls -l /sys/class/bluetooth/
sudo bluetoothctl list
sudo bluetoothctl
```

进入 `bluetoothctl` 后交互执行：

```text
power on
show
scan on
# 找到设备后
scan off
agent on
default-agent
pair XX:XX:XX:XX:XX:XX
trust XX:XX:XX:XX:XX:XX
connect XX:XX:XX:XX:XX:XX
quit
```

多蓝牙控制器时先在 `bluetoothctl` 中 `select <AIC控制器地址>`；不假定 AIC 一定是 hci0。
通过标准是：服务日志出现控制器版本、有效地址、`attached hciN`；BlueZ 能打开控制器，
扫描并实际连接目标设备。还应同时测试 Wi-Fi 联网时扫描/连接，确认共存效果。

只测试串口通信、暂不注册 HCI，可在停止服务后执行：

```bash
sudo systemctl stop aic8800-bluetooth.service
sudo /usr/bin/aic8800-bt-attach --probe-only
sudo systemctl start aic8800-bluetooth.service
```

`--probe-only` 仍会执行 HCI Reset，不能与正在使用的蓝牙连接并行。
修改配置后执行 `sudo systemctl restart aic8800-bluetooth.service`。
重试次数用尽后先 `sudo systemctl reset-failed aic8800-bluetooth.service` 再启动。

## 已烧录系统快速试验

不必为了首次验证重做镜像。先将本目录中的以下文件复制到板端 `/tmp/aic-bt/`，保持
`scripts/` 这一层目录；以 root 或 sudo 执行下面命令。此操作会结束已有蓝牙连接。

```bash
sudo apt-get update
sudo apt-get install -y python3 bluez
sudo systemctl stop aic8800-bluetooth.service 2>/dev/null || true
sudo install -m 0755 /tmp/aic-bt/scripts/aic8800-bt-attach /usr/bin/
sudo install -m 0644 /tmp/aic-bt/aic8800-bluetooth.conf /etc/
sudo install -m 0644 /tmp/aic-bt/aic8800-bluetooth.service /lib/systemd/system/
sudo /usr/bin/aic8800-bt-attach --check-config
sudo systemctl daemon-reload
sudo systemctl enable --now aic8800-bluetooth.service
sudo systemctl restart bluetooth.service
```

首次成功后，再同步两个 `wifibt-*.sh` 初始化/睡眠脚本，或重建 rootfs，以获得
完整的停止、重启和休眠恢复流程。快速试验本身不会更新这些流程。
撤回试验可执行 `sudo systemctl disable --now aic8800-bluetooth.service`。

## 失败定位和验证范围

```bash
sudo dmesg | grep -Ei 'aic|bt patch|btenable|bluetooth|ttyS9|rfkill'
sudo journalctl -b -u wifibt-init.service -u aic8800-bluetooth.service -u bluetooth.service --no-pager
rfkill list
ls -l /dev/ttyS9
```

- 等待 SDIO/模块超时：先恢复 Wi-Fi 固件加载与模块初始化。
- HCI 应答超时或 H4 帧异常：核对实际芯片、BT 供电、UART9 引脚和 RTS/CTS、波特率；
  AIC8800DW 或日志 `btenable=0` 可能表示当前芯片没有可用的蓝牙功能。
- `0xfc72` 返回错误：保留完整日志；可临时配置 `configure_pta = no` 区分 UART/HCI
  与共存参数兼容性，但这不能作为 Wi-Fi/BT 共存已验证的依据。
- UART HCI 注册失败：核对内核 HCIUART/H4 配置和 UART 是否被占用。

本实现移植厂商默认的“不重新配置 RF 寄存器”路径，没有移植 Android 音频栈、
PCM/I2S SCO、厂商低功耗/深度休眠及特殊 RF 测试模式。基础扫描、配对、连接以及
休眠恢复都仍需实测；内置蓝牙音频和低功耗不能据此声称已适配完成。

## 来源和本机检查

参数和时序参考 `/home/lyh/lyh_disk/coolpi/aic8800/src/SDIO/driver_fw/aic/libbt/8800/`：
`bt_vendor_aicbt.c`、`aic_hardware.c`、`userial_vendor.c`。原厂代码为 Apache-2.0，
许可副本在 `LICENSE.aic-bluetooth`；运行镜像保留对应版权文件。
原 Android PTA 命令声明长 36 字节，有效字段为 26 字节；本实现将剩余 10 字节清零。
不依赖 `coolpi/` 或 Android 源码参与后续 rootfs 构建。

在 SDK 根目录运行只读/模拟测试，不需要硬件：

```bash
# 把 ubuntu 换成 debian 可检查另一份独立资源
python3 -B ubuntu/bsp/wifibt/tests/test_aic8800_bt.py
ubuntu/bsp/wifibt/scripts/aic8800-bt-attach --check-config \
    --config ubuntu/bsp/wifibt/aic8800-bluetooth.conf
```
