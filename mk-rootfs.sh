#!/bin/bash
# Internal privileged stage, called by build.sh in a private mount namespace.
set -euo pipefail

[[ $EUID == 0 && $# == 1 ]] || {
	echo "Use ubuntu22.04/build.sh or the SDK's ./build.sh ubuntu" >&2
	exit 1
}

SCRIPT_DIR=$(dirname "$(realpath "$0")")
SDK_DIR=$(dirname "$SCRIPT_DIR")
IMAGE_DIR=$1
RELEASE=${RELEASE:-jammy}
[[ "$RELEASE" == jammy ]] || {
    echo "Only Ubuntu 22.04 (jammy) is supported." >&2
    exit 1
}
FLAVOR=${FLAVOR:-server}
case "$FLAVOR" in
	server | desktop) ;;
	*) echo "Invalid Ubuntu edition: $FLAVOR" >&2; exit 1 ;;
esac
# Model-based hostname (TBoard-R5A for the r5a board); set via build.sh or env.
UBUNTU_HOSTNAME=${UBUNTU_HOSTNAME:-TBoard-R5A}
mkdir -p "$SCRIPT_DIR/work" "$SCRIPT_DIR/cache" "$IMAGE_DIR"
exec 9>"$SCRIPT_DIR/work/build.lock"
flock -n 9 || { echo "Another Ubuntu build is running." >&2; exit 1; }

# Keep each rootfs for inspection; never delete an existing user rootfs.
ROOTFS=$(mktemp -d "$SCRIPT_DIR/work/rootfs.$RELEASE.$FLAVOR.XXXXXXXX")
# mke2fs -d preserves source metadata, including the root directory permissions.
chmod 0755 "$ROOTFS"
MOUNTS=()
IMAGE_TMP=

cleanup()
{
	local result=$?
	trap - EXIT
	set +e
	for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
		umount "${MOUNTS[i]}"
	done
	[[ -z "$IMAGE_TMP" ]] || rm -f "$IMAGE_TMP"
	if (( result != 0 )); then
		echo "Ubuntu build failed; rootfs retained at $ROOTFS" >&2
	fi
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Building Ubuntu $RELEASE $FLAVOR arm64 in $ROOTFS"
debootstrap --arch=arm64 --foreign --variant=minbase \
	--include=ca-certificates,ubuntu-keyring \
	--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
	--cache-dir="$SCRIPT_DIR/cache" \
	"$RELEASE" "$ROOTFS" "$MIRROR"

if [[ $(uname -m) != aarch64 ]]; then
	install -m 0755 "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/"
fi
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

mount --bind /dev "$ROOTFS/dev"
MOUNTS+=("$ROOTFS/dev")
mount --bind /dev/pts "$ROOTFS/dev/pts"
MOUNTS+=("$ROOTFS/dev/pts")
mount -t proc proc "$ROOTFS/proc"
MOUNTS+=("$ROOTFS/proc")
mount -t sysfs sysfs "$ROOTFS/sys"
MOUNTS+=("$ROOTFS/sys")

# Dereference the host resolver (it may contain a local stub), but never use a
# host loopback resolver inside the target system after the build.
rm -f "$ROOTFS/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb $MIRROR $RELEASE-security main restricted universe multiverse
EOF

chroot "$ROOTFS" /bin/bash -s -- "$UBUNTU_USER" "$UBUNTU_CONSOLE" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
apt-get update
apt-get install -y --no-install-recommends \
    systemd systemd-sysv udev dbus openssh-server sudo locales \
    ca-certificates kmod e2fsprogs dosfstools parted util-linux \
    network-manager wpasupplicant rfkill bluez python3 \
    iproute2 iputils-ping net-tools ethtool iw \
    inotify-tools procps psmisc lsof less vim-tiny curl \
    language-pack-zh-hans build-essential alsa-utils
# Default to Simplified Chinese; keep English available for development tools.
sed -i -e 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    -e 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale --reset LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh:en_US:en
echo rk3588-ubuntu > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 rk3588-ubuntu\n::1 localhost ip6-localhost\n' > /etc/hosts
printf 'PARTLABEL=rootfs / ext4 defaults 0 1\n' > /etc/fstab
useradd -m -U -s /bin/bash -G sudo,adm,dialout,video,audio,plugdev,netdev "$1"
# Ubuntu's vendor NM configuration may leave Ethernet unmanaged without netplan.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf <<'NETWORK'
[keyfile]
unmanaged-devices=

[ifupdown]
managed=true
NETWORK
systemctl enable "serial-getty@$2.service" ssh.service NetworkManager.service
systemctl enable systemd-resolved.service bluetooth.service
apt-get clean
EOF

printf '%s:%s\n' "$UBUNTU_USER" "$UBUNTU_PASSWORD" | chroot "$ROOTFS" chpasswd

if [[ "$FLAVOR" == desktop ]]; then
	install -D -m 0755 "$SCRIPT_DIR/desktop/rk3588-desktop-renderer" "$ROOTFS/usr/local/sbin/rk3588-desktop-renderer"
	install -D -m 0755 "$SCRIPT_DIR/desktop/rk3588-xserver" "$ROOTFS/usr/local/bin/rk3588-xserver"
	install -D -m 0755 "$SCRIPT_DIR/desktop/rk3588-render-env" "$ROOTFS/usr/local/bin/rk3588-render-env"
	install -D -m 0644 "$SCRIPT_DIR/desktop/render-env.sh" "$ROOTFS/usr/local/lib/tboard/render-env.sh"
	# Establish the stock GNOME/software baseline before installing Mali.
	chroot "$ROOTFS" /bin/bash -s -- software < "$SCRIPT_DIR/setup-desktop.sh"
	if [[ "$UBUNTU_DESKTOP_GPU" == mali ]]; then
		GPU_PACKAGES="$SCRIPT_DIR/packages/$RELEASE/arm64"
		(cd "$GPU_PACKAGES" && sha256sum --check --quiet SHA256SUMS)
		install -D -m 0644 "$GPU_PACKAGES/xserver/tboard-xserver-rockchip_1.20.11-1tboard1+$RELEASE"_arm64.deb "$ROOTFS/tmp/rk3588-gpu/xserver.deb"
		install -D -m 0644 "$GPU_PACKAGES/libmali/libmali-valhall-g610-g24p0-x11-gbm_1.9-1_arm64.deb" "$ROOTFS/tmp/rk3588-gpu/libmali.deb"
		chroot "$ROOTFS" /bin/bash -s < "$SCRIPT_DIR/setup-gpu.sh"
	fi
else
	chroot "$ROOTFS" systemctl set-default multi-user.target
fi

# Include SDK Wi-Fi/BT, modules, firmware, partition handling and common overlays.
# The board defconfig controls module installation; no distro kernel is installed.
"$SDK_DIR/device/rockchip/common/scripts/post-rootfs.sh" "$ROOTFS" ubuntu systemd

# User overlays take precedence over the SDK overlays. Keep private permissions,
# for example those on NetworkManager connections and SSH configuration.
rsync -a --chown=0:0 --exclude=.empty "$SCRIPT_DIR/overlay/" "$ROOTFS/"
rsync -a --chown=0:0 --exclude=.empty "$SCRIPT_DIR/overlay-$FLAVOR/" "$ROOTFS/"

# Model-based hostname, applied after all overlays so it wins over the static
# overlay and the SDK's <chip>-<os> default; setup-login.py syncs /etc/hosts.
printf '%s\n' "$UBUNTU_HOSTNAME" > "$ROOTFS/etc/hostname"

# Finalize branding after both overlays; never render the MOTD on the host.
python3 "$SCRIPT_DIR/setup-login.py" "$ROOTFS"

chroot "$ROOTFS" /bin/bash -s -- "$FLAVOR" "$UBUNTU_DESKTOP_GPU" <<'EOF'
set -euo pipefail
# Do not publish an image if account post-processing was skipped or an overlay
# locked a required login. In particular, debootstrap initially locks root.
for user in root tboard; do
    status=$(passwd -S "$user")
    [[ "$status" == "$user P "* ]] || {
        echo "Required login account $user has no usable password: $status" >&2
        exit 1
    }
done
# SDK post-processing and overlays must not leave a desktop image without
# the display-manager alias required by graphical.target.
if [[ "$1" == desktop ]]; then
    [[ -L /etc/systemd/system/display-manager.service &&
       -r /lib/systemd/system/gdm3.service &&
       "$(readlink -f /etc/systemd/system/display-manager.service)" == "$(readlink -f /lib/systemd/system/gdm3.service)" ]] || {
        echo "Desktop image has no valid GDM display-manager.service link." >&2
        exit 1
    }
    [[ $(systemctl get-default) == graphical.target ]] || {
        echo "Desktop image does not boot graphical.target." >&2
        exit 1
    }
    [[ -r /etc/pam.d/gdm-password ]]
    if grep -Eq '^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_succeed_if\.so[[:space:]]+user[[:space:]]+!=[[:space:]]+root([[:space:]]|$)' /etc/pam.d/gdm-password; then
        echo "GDM password login still denies the root account." >&2
        exit 1
    fi
    [[ $(cat /etc/rockchip-desktop-renderer) == "$2" ]] || {
        echo "Desktop renderer was changed during post-processing." >&2
        exit 1
    }
    if [[ "$2" == mali ]]; then
        cmp -s /usr/bin/Xorg /usr/local/bin/rk3588-xserver
        [[ -x /usr/bin/Xorg.distrib ]]
        /usr/local/bin/rk3588-render-env /bin/sh -c '
            [ "$COGL_DRIVER" = gles2 ] && [ "$COGL_RENDERER" = EGL_XLIB ] &&
            [ "$LD_LIBRARY_PATH" = /usr/lib/aarch64-linux-gnu/mali ] &&
            [ -z "${LIBGL_ALWAYS_SOFTWARE:-}" ] && [ -z "${GALLIUM_DRIVER:-}" ]'
    fi
    for package in gdm3 gnome-shell ubuntu-session gnome-control-center; do
        [[ $(dpkg-query -W -f='${Status}' "$package") == 'install ok installed' ]] || {
            echo "Required GNOME package is not configured: $package" >&2
            exit 1
        }
    done
fi
sed -i '/^VARIANT=/d; /^VARIANT_ID=/d' /etc/os-release
printf 'VARIANT="%s"\nVARIANT_ID=%s\n' "$1" "$1" >> /etc/os-release
ldconfig
for directory in /lib/modules/*; do
    if [[ -d "$directory" && -f "$directory/modules.order" ]]; then
        depmod -a "${directory##*/}"
    fi
done
# Generate SSH host keys on the board, before sshd validates its configuration.
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/10-host-keys.conf <<'UNIT'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
UNIT
rm -f /etc/ssh/ssh_host_* /var/lib/dbus/machine-id
: > /etc/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /usr/sbin/policy-rc.d
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
EOF

# Pack only the on-disk rootfs, after removing every bind mount.
for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
	umount "${MOUNTS[i]}"
done
MOUNTS=()
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

USED_MB=$(du --apparent-size -sm "$ROOTFS" | cut -f1)
FILE_COUNT=$(find "$ROOTFS" -xdev | wc -l)
# Match debian/mk-image.sh: apparent data size, worst-case 4 KiB file
# alignment, 64 MiB for the journal, then 10% extra space. Always calculate
# here after cleanup; stale SDK/environment size settings must not apply.
IMAGE_SIZE_MB=$(( (USED_MB + FILE_COUNT * 4 / 1024 + 64) * 110 / 100 ))
echo "Ubuntu image size: $IMAGE_SIZE_MB MiB (auto, rootfs data: $USED_MB MiB, files: $FILE_COUNT)."

IMAGE_TMP=$(mktemp "$IMAGE_DIR/.rootfs.ext4.XXXXXXXX")
truncate -s "${IMAGE_SIZE_MB}M" "$IMAGE_TMP"
# Disable newer host defaults that are unsupported by the SDK's Linux 5.10.
EXT4_OPTIONS=()
for feature in metadata_csum_seed orphan_file; do
	if grep -qw "$feature" /etc/mke2fs.conf; then
		EXT4_OPTIONS+=("^$feature")
	fi
done
if (( ${#EXT4_OPTIONS[@]} )); then
	FEATURES=$(IFS=,; echo "${EXT4_OPTIONS[*]}")
	EXT4_OPTIONS=(-O "$FEATURES")
fi
mkfs.ext4 -F -L rootfs "${EXT4_OPTIONS[@]}" -d "$ROOTFS" "$IMAGE_TMP"

OWNER_UID=$(stat -c %u "$SDK_DIR")
OWNER_GID=$(stat -c %g "$SDK_DIR")
chown "$OWNER_UID:$OWNER_GID" "$IMAGE_TMP"
mv -f "$IMAGE_TMP" "$IMAGE_DIR/rootfs.ext4"
IMAGE_TMP=
ln -sfn "$ROOTFS" "$SCRIPT_DIR/work/latest"
ln -sfn "$ROOTFS" "$SCRIPT_DIR/work/latest-$FLAVOR"
ln -sfn "$ROOTFS" "$SCRIPT_DIR/work/latest-$RELEASE-$FLAVOR"
echo "Ubuntu image: $IMAGE_DIR/rootfs.ext4"
echo "Rootfs retained: $ROOTFS"
