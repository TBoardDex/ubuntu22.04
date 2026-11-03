#!/usr/bin/env python3
"""Export an already installed Ubuntu ARM64 Xorg; never compile source code."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("--output", type=Path, help="Default: packages/<release>/arm64/xserver")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = args.rootfs.resolve()
    release = dict(line.split("=", 1) for line in (root / "etc/os-release").read_text().splitlines()
                   if "=" in line and not line.startswith("#"))
    codename = release.get("VERSION_CODENAME", "").strip('"')
    if release.get("ID", "").strip('"') != "ubuntu" or codename != "jammy":
        parser.error("rootfs must be Ubuntu 22.04 (jammy)")
    prefix = Path("opt/rockchip/xserver")
    source = root / prefix
    binary = (source / "bin/Xorg").read_bytes()
    if binary[:6] != b"\x7fELF\x02\x01" or binary[18:20] != b"\xb7\x00":
        parser.error("Xorg must be a little-endian AArch64 ELF")
    output = args.output or here / "packages" / codename / "arm64/xserver"
    output.mkdir(parents=True, exist_ok=True)
    package = "tboard-xserver-rockchip"
    version = "1.20.11-1tboard1+" + codename
    nettle, libc = "libnettle8", "2.35"
    with tempfile.TemporaryDirectory(prefix="tboard-xserver-") as temp:
        stage = Path(temp)
        for entry in ("bin", "lib/xorg/modules", "share/X11/xorg.conf.d"):
            shutil.copytree(source / entry, stage / prefix / entry, symlinks=True)
        # Require the packaged distro input module/config; never embed a copy
        # of an input driver compiled against another Xorg ABI.
        link = stage / prefix / "share/X11/xorg.conf.d/40-libinput.conf"
        if not link.is_symlink() or os.readlink(link) != "/usr/share/X11/xorg.conf.d/40-libinput.conf":
            parser.error("missing libinput configuration symlink")
        doc = stage / "usr/share/doc" / package
        doc.mkdir(parents=True)
        shutil.copyfile(here / "packages/xserver-COPYING", doc / "copyright")
        files = {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in sorted((stage / prefix).rglob("*")) if p.is_file() and not p.is_symlink()}
        (doc / "export-info.json").write_text(json.dumps({
            "release": codename, "architecture": "arm64", "version": version,
            "origin": "Previously compiled SDK Rockchip Xorg 1.20.11 installed in Ubuntu rootfs",
            "rootfs_build_info": release.get("RK_BUILD_INFO", "unknown").strip('"'),
            "note": "Exported binaries only; packaging does not rebuild or hardware-test Xorg.",
            "sha256": files,
        }, indent=2) + "\n")
        control = stage / "DEBIAN"
        control.mkdir()
        deps = [f"libc6 (>= {libc})", nettle, "libxfont2", "libpixman-1-0", "libdrm2",
                "libepoxy0", "libgbm1", "libegl1", "libgl1", "libgles2", "libxshmfence1",
                "libbsd0", "libxau6", "libxdmcp6", "libudev1", "libdbus-1-3", "libpciaccess0",
                "xserver-xorg-input-libinput", "x11-xkb-utils", "xkb-data"]
        size = sum(p.stat().st_size for p in stage.rglob("*") if p.is_file() and not p.is_symlink())
        (control / "control").write_text(
            f"Package: {package}\nVersion: {version}\nArchitecture: arm64\n"
            "Maintainer: TBoard SDK maintainers <tboard@localhost>\nSection: x11\nPriority: optional\n"
            f"Installed-Size: {(size + 1023) // 1024}\nDepends: {', '.join(deps)}\n"
            f"Description: Rockchip Xorg for Ubuntu {codename} on RK3588\n"
            " Isolated Mali-compatible Xorg in /opt/rockchip/xserver.\n"
            " Ubuntu's stock Xorg remains available for software rendering.\n")
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(stage),
                        str(output / f"{package}_{version}_arm64.deb")], check=True)


if __name__ == "__main__":
    main()
