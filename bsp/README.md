# Distribution-owned Rockchip resources

This directory is an independent snapshot used by this distribution's SDK
post-rootfs hooks. No symlinks to another distro or external/ are required.

- rkscript/: system scripts, init services and udev rules from SDK rkscript.
- wifibt/: vendor initialization/configuration scripts; current support is AIC8800 SDIO Wi-Fi and experimental UART H4 Bluetooth.
- ../overlay-firmware/lib/firmware/aic8800/: flat AIC8800 firmware layout expected
  by the current in-kernel driver. Source revision and notices are retained there.

The SDK still builds matching AIC8800 modules from kernel/. Other Wi-Fi chip
families must be integrated here explicitly; do not silently use external/.
Buildroot continues to use its existing resources.

Changes here are intentionally independent of the other distribution's copy.
Update SHA256SUMS when replacing resources, and retain the license notices.

Snapshot origins (SDK-local copies; retained licenses apply):
- rkscript: commit 28a65621b0c0f1ccfad9d4ee600c0a035ed21956.
- rkwifibt scripts/config: commit c9bd0f7d46a4fe6195b0b05b2967cab9b90ce06f,
  including the SDK's existing local AIC8800 initialization changes.
- AIC8800 firmware: radxa-pkg/aic8800 revision
  75fd5545a3e7a8ec2c2b022f0088cc352ad2b623 (see firmware README).

These source identifiers describe the snapshot origins. SHA256SUMS records
its actual file contents, including local SDK modifications.

Bluetooth setup, vendor-source attribution, limitations and board tests:
see [wifibt/README.bluetooth.md](wifibt/README.bluetooth.md).
