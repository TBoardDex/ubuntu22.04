#!/usr/bin/env python3
"""Apply TBoard login branding to an offline Ubuntu rootfs."""
from pathlib import Path
import re
import shutil
import sys

SCRIPT_DIR = Path(__file__).resolve().parent


def install(root, relative, mode):
    source = SCRIPT_DIR / 'overlay' / relative
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    # Ubuntu may ship /etc/motd as an absolute link into /run.
    if target.is_symlink():
        target.unlink()
    shutil.copyfile(str(source), str(target))
    target.chmod(mode)


def configure_gdm_password_login(root):
    path = root / 'etc/pam.d/gdm-password'
    if not path.is_file():
        return
    lines = path.read_text().splitlines()
    output = []
    for line in lines:
        words = line.split('#', 1)[0].split()
        root_denial = (len(words) >= 6 and words[0] == 'auth' and
                       words[1] in ('required', 'requisite') and
                       words[2] == 'pam_succeed_if.so' and
                       words[3:6] == ['user', '!=', 'root'] and
                       all(word in ('quiet', 'quiet_success', 'quiet_fail')
                           for word in words[6:]))
        if not root_denial:
            output.append(line)
    path.write_text('\n'.join(output) + '\n')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: setup-login.py <target rootfs>')
    root = Path(sys.argv[1]).resolve()
    if root == Path('/') or not (root / 'etc/passwd').is_file():
        raise SystemExit('Refusing an invalid target rootfs: {}'.format(root))
    # mk-rootfs.sh has already merged common and edition overlays.
    for relative, mode in [('etc/motd', 0o644), ('etc/motd.template', 0o644),
                           ('etc/update-motd.d/10-uname', 0o755),
                           ('usr/lib/tboard/motd.py', 0o644)]:
        target = root / relative
        if target.is_symlink():
            install(root, relative, mode)
        elif not target.is_file():
            install(root, relative, mode)
        else:
            target.chmod(mode)
    (root / 'etc/motd').write_text('')
    # Retain Ubuntu's vendor files but stop their duplicate welcome/news output.
    for path in (root / 'etc/update-motd.d').iterdir():
        if path.name != '10-uname' and path.is_file() and not path.is_symlink():
            path.chmod(path.stat().st_mode & ~0o111)

    # Standard PAM auth/account/session rules remain intact.
    for service in ['login', 'sshd']:
        path = root / 'etc/pam.d' / service
        if not path.is_file():
            raise SystemExit('Missing Ubuntu PAM configuration: {}'.format(path))
        lines = path.read_text().splitlines()
        output, inserted = [], False
        for line in lines:
            if re.match(r'^\s*session\s+', line) and re.search(r'\bpam_motd\.so\b', line):
                if not inserted:
                    output += ['session optional pam_motd.so motd=/run/motd.dynamic',
                               'session optional pam_motd.so noupdate']
                    inserted = True
            else:
                output.append(line)
        if not inserted:
            output += ['session optional pam_motd.so motd=/run/motd.dynamic',
                       'session optional pam_motd.so noupdate']
        path.write_text('\n'.join(output) + '\n')
    ssh = root / 'etc/ssh/sshd_config'
    if not ssh.is_file():
        raise SystemExit('Missing Ubuntu SSH configuration: {}'.format(ssh))
    text = re.sub(r'^# BEGIN TBOARD MOTD\n.*?^# END TBOARD MOTD\n?', '',
                  ssh.read_text(), flags=re.M | re.S)
    ssh.write_text('# BEGIN TBOARD MOTD\nUsePAM yes\nPrintMotd no\n'
                   '# END TBOARD MOTD\n' + text)
    # The shared account hook sets root/root, but GDM separately denies root
    # in its password PAM stack. Apply the desktop policy after all overlays.
    configure_gdm_password_login(root)
    # Match the hostname already installed by the common/edition overlay.
    hostname = (root / 'etc/hostname').read_text().strip()
    hosts = root / 'etc/hosts'
    lines = hosts.read_text().splitlines() if hosts.exists() else []
    lines = [line for line in lines if not re.match(r'^\s*127\.0\.1\.1\s', line)]
    lines.append('127.0.1.1\t' + hostname)
    hosts.write_text('\n'.join(lines) + '\n')
    cache = root / 'run/motd.dynamic'
    if cache.is_file() or cache.is_symlink():
        cache.unlink()
    print('Configured Ubuntu TBoard login welcome for serial and SSH.')


if __name__ == '__main__':
    main()
