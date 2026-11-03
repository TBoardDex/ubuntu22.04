#!/bin/bash
# Executed inside the Ubuntu arm64 chroot after GNOME is installed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $(dpkg --print-architecture) == arm64 ]] || exit 1
. /etc/os-release
[[ "$ID" == ubuntu ]] || exit 1
case "$VERSION_CODENAME" in
    jammy) ;;
    *) echo "Unsupported Ubuntu GPU release: $VERSION_CODENAME" >&2; exit 1 ;;
esac

# Check the installed Mutter, rather than assuming every build includes GLES2.
python3 - <<'PYTHON'
from pathlib import Path
libraries=list(Path('/usr/lib/aarch64-linux-gnu').glob('mutter-*/libmutter-cogl-*.so.0'))
if not any(all(token in p.read_bytes() for token in (b'gles2\0', b'COGL_DRIVER\0', b'EGL_XLIB\0')) for p in libraries):
    raise SystemExit('Installed Mutter lacks the GLES2/X11 EGL backend required by Mali.')
PYTHON

apt-get install -y --no-install-recommends /tmp/rk3588-gpu/xserver.deb glmark2-es2
# Keep the vendor EGL/GLES/GBM wrappers out of the global cache. This preserves
# Mesa and the stock Xorg for software recovery; GPU processes opt in via env.
dpkg-divert --local --rename --add /etc/ld.so.conf.d/00-aarch64-mali.conf
apt-get install -y --no-install-recommends /tmp/rk3588-gpu/libmali.deb
ldconfig
# Fail on unresolved ARM dependencies without exercising the host GPU.
for library in /opt/rockchip/xserver/bin/Xorg \
    /opt/rockchip/xserver/lib/xorg/modules/libglamoregl.so \
    /opt/rockchip/xserver/lib/xorg/modules/drivers/modesetting_drv.so \
    /usr/lib/aarch64-linux-gnu/mali/libEGL.so.1 \
    /usr/lib/aarch64-linux-gnu/mali/libGLESv2.so.2; do
    deps=$(LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali ldd "$library")
    if [[ "$deps" == *"not found"* ]]; then
        printf '%s\n' "$deps" >&2
        exit 1
    fi
done

getent group render >/dev/null || groupadd --system render
for user in gdm tboard; do
    id "$user" >/dev/null
    usermod -aG video,render "$user"
done
mkdir -p /etc/udev/rules.d /etc/X11/Xsession.d
cat > /etc/udev/rules.d/70-rk3588-mali.rules <<'UDEV'
KERNEL=="mali[0-9]*", GROUP="video", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660", TAG+="uaccess"
UDEV
# GDM hardcodes /usr/bin/Xorg. A LightDM xserver-command setting has no effect.
# Preserve dpkg ownership and the original distro launcher across upgrades.
dpkg-divert --local --rename --divert /usr/bin/Xorg.distrib --add /usr/bin/Xorg
install -m 0755 /usr/local/bin/rk3588-xserver /usr/bin/Xorg

cat > /etc/X11/Xsession.d/20-rk3588-software-rendering <<'SESSION'
# Sourced before dbus-update-activation-environment imports the login env.
. /usr/local/lib/tboard/render-env.sh
SESSION
cat > /etc/X11/Xsession.d/70-rk3588-session-renderer <<'SESSION'
# ssh-agent is setgid and clears LD_LIBRARY_PATH. Reapply it after the agent.
# Debian Xsession uses STARTUP; GDM's own Xsession uses command instead.
if [ -n "${STARTUP:-}" ]; then
    STARTUP="/usr/local/bin/rk3588-render-env $STARTUP"
fi
if [ -n "${command:-}" ]; then
    command="/usr/local/bin/rk3588-render-env $command"
fi
SESSION
for hook in /etc/X11/Xsession.d/20-rk3588-software-rendering \
    /etc/X11/Xsession.d/70-rk3588-session-renderer; do
    chmod 0644 "$hook"
    /bin/sh -n "$hook"
    run-parts --list /etc/X11/Xsession.d | grep -Fx "$hook" >/dev/null
done
# GNOME's --systemd session launches Shell outside Xsession's process tree.
# Cover both unit names used by supported Ubuntu GNOME releases.
SHELL_UNITS=0
for unit in gnome-shell-x11.service org.gnome.Shell@x11.service; do
    if [[ -r /usr/lib/systemd/user/$unit || -r /lib/systemd/user/$unit ]]; then
        mkdir -p "/etc/systemd/user/$unit.d"
        cat > "/etc/systemd/user/$unit.d/20-rockchip-renderer.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/local/bin/rk3588-render-env /usr/bin/gnome-shell
UNIT
        SHELL_UNITS=$((SHELL_UNITS + 1))
    fi
done
(( SHELL_UNITS > 0 )) || { echo 'GNOME Shell X11 service is missing.' >&2; exit 1; }
/usr/local/sbin/rk3588-desktop-renderer mali
apt-get clean
