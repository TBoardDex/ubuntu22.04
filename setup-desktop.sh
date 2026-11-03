#!/bin/bash
# Executed inside the target chroot after the common Server packages are set up.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[[ "${1:-software}" == software ]] || {
    echo "setup-desktop.sh initializes the software baseline; use setup-gpu.sh to install the Mali backend." >&2
    exit 1
}
. /etc/os-release
case "$VERSION_CODENAME" in
    jammy) ICONS_PACKAGE=gnome-shell-extension-desktop-icons-ng ;;
    *) echo "Unsupported Ubuntu GNOME release: $VERSION_CODENAME" >&2; exit 1 ;;
esac

printf 'shared shared/default-x-display-manager select gdm3\n' | debconf-set-selections
# Install the Ubuntu GNOME session explicitly: no generic Ubuntu kernel or
# Xfce desktop. Recommends stay disabled, so list the desktop essentials here.
DESKTOP_PACKAGES=(
    ubuntu-session ubuntu-settings gnome-shell gnome-settings-daemon
    gdm3 accountsservice gnome-control-center gnome-terminal nautilus
    gnome-system-monitor gnome-disk-utility gnome-keyring seahorse
    gnome-shell-extension-ubuntu-dock gnome-shell-extension-appindicator
    "$ICONS_PACKAGE" ubuntu-wallpapers yaru-theme-gtk yaru-theme-icon
    yaru-theme-gnome-shell gsettings-desktop-schemas dconf-cli
    xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils
    dbus-x11 libpam-systemd policykit-1 network-manager-gnome
    xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal-gtk
    pulseaudio pulseaudio-utils pulseaudio-module-bluetooth
    pavucontrol dbus-user-session rtkit
    fonts-dejavu-core fonts-noto-cjk language-pack-gnome-zh-hans
    libgl1-mesa-dri libegl1-mesa mesa-utils
)

# A QEMU Python child can crash while py3compile feeds it filenames, leaving
# urllib3 half-configured and dependent printer/settings packages unconfigured.
# Retain live output and a diagnostic log; retry only this observed signature.
INSTALL_LOG=$(mktemp /var/log/gnome-package-install.XXXXXXXX.log)
set +e
apt-get install -y --no-install-recommends "${DESKTOP_PACKAGES[@]}" 2>&1 | tee "$INSTALL_LOG"
INSTALL_STATUS=${PIPESTATUS[0]}
set -e
if (( INSTALL_STATUS != 0 )); then
    if [[ -x /usr/bin/qemu-aarch64-static ]] &&
        grep -qi 'Segmentation fault' "$INSTALL_LOG" &&
        grep -q '/usr/bin/py3compile' "$INSTALL_LOG" &&
        grep -q 'BrokenPipeError' "$INSTALL_LOG"; then
        echo "QEMU Python byte-compilation crashed; retrying package configuration once. Log: $INSTALL_LOG"
        dpkg --configure -a
        # Ensure the full requested desktop set is installed, not just the
        # packages dpkg managed to unpack before the first failure.
        apt-get install -y --no-install-recommends "${DESKTOP_PACKAGES[@]}"
    else
        echo "GNOME package installation failed; see $INSTALL_LOG" >&2
        exit "$INSTALL_STATUS"
    fi
fi

# Establish a usable software baseline; setup-gpu.sh optionally installs and
# selects the Mali backend after these GNOME packages are configured.
mkdir -p /etc/gdm3 /etc/X11/xorg.conf.d /etc/systemd/system/gdm.service.d
cat > /etc/gdm3/custom.conf <<'GDM'
[daemon]
WaylandEnable=false
DefaultSession=ubuntu.desktop
GDM
/usr/local/sbin/rk3588-desktop-renderer software

# Keep Ubuntu's packaged theme and wallpaper; reduce software compositor work.
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat > /etc/dconf/profile/user <<'PROFILE'
user-db:user
system-db:local
PROFILE
cat > /etc/dconf/db/local.d/00-tboard-gnome <<'DCONF'
[org/gnome/desktop/interface]
enable-animations=false
DCONF
dconf update

# Select the Ubuntu GNOME Xorg session for the normal desktop account.
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/tboard <<'ACCOUNT'
[User]
Session=ubuntu
XSession=ubuntu
SystemAccount=false
Language=zh_CN.UTF-8
ACCOUNT
chmod 0600 /var/lib/AccountsService/users/tboard

# Fail during the build if a required desktop/session component is missing.
for executable in /usr/sbin/gdm3 /usr/bin/gnome-shell /usr/bin/gnome-session \
    /usr/bin/gnome-control-center /usr/bin/gnome-terminal /usr/bin/nautilus; do
    [[ -x "$executable" ]] || { echo "Missing GNOME component: $executable" >&2; exit 1; }
done
[[ -r /usr/share/xsessions/ubuntu.desktop ]] || {
    echo "Ubuntu GNOME Xorg session is missing." >&2
    exit 1
}
printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager
# Ubuntu's GDM unit is static (and gdm3.service may alias gdm.service).
# systemctl enable can succeed without creating the alias graphical.target
# needs. Select the installed unit explicitly, just as gdm3.postinst does.
[[ -r /lib/systemd/system/gdm3.service ]] || {
    echo "GDM systemd service is missing." >&2
    exit 1
}
GDM_UNIT=$(readlink -f /lib/systemd/system/gdm3.service)
ln -sfn "$GDM_UNIT" /etc/systemd/system/display-manager.service
systemctl set-default graphical.target
apt-get clean
