#!/usr/bin/env python3
"""Render the offline-installed MOTD template using the running board's data."""
from pathlib import Path
from collections import Counter
import json
import os
import re
import shlex
import socket
import subprocess
import unicodedata


def read(path):
    try:
        return Path(path).read_text(encoding='UTF-8', errors='replace').strip()
    except OSError:
        return ''


def command(args):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                universal_newlines=True, timeout=2, check=False)
        return result.stdout if result.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


def system_name():
    for path in ['/etc/os-release', '/usr/lib/os-release']:
        data = read(path)
        if data:
            for line in data.splitlines():
                if line.startswith('PRETTY_NAME='):
                    try:
                        return shlex.split(line.split('=', 1)[1])[0]
                    except (ValueError, IndexError):
                        pass
    return 'GNU/Linux'


def cpu():
    text = read('/proc/cpuinfo')
    if not text:
        return 'N/A'
    cores = len(re.findall(r'^processor\s*:', text, re.M))
    parts = Counter(re.findall(r'^CPU part\s*:\s*(\S+)', text, re.M))
    names = {'0xd05': 'Cortex-A55', '0xd0b': 'Cortex-A76'}
    if parts:
        model = ' + '.join('{}x {}'.format(count, names.get(part.lower(), 'ARM ' + part))
                           for part, count in parts.items())
    else:
        match = re.search(r'^model name\s*:\s*(.+)', text, re.M)
        model = match.group(1) if match else ('{} cores'.format(cores) if cores else 'N/A')
    frequencies = []
    for path in Path('/sys/devices/system/cpu/cpufreq').glob('policy*/cpuinfo_max_freq'):
        try:
            frequencies.append(int(read(path)))
        except ValueError:
            pass
    if frequencies:
        model += ' (max {:.2f} GHz)'.format(max(frequencies) / 1000000)
    return model


def gpu():
    paths = list(Path('/sys/class/misc').glob('mali*/device/gpuinfo'))
    paths += list(Path('/sys/devices/platform').glob('*gpu*/gpuinfo'))
    for path in paths:
        info = read(path)
        if info:
            return info.splitlines()[0]
    return 'N/A (driver info unavailable)'


def memory():
    values = {}
    for line in read('/proc/meminfo').splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            values[parts[0].rstrip(':')] = int(parts[1])
    total = values.get('MemTotal', 0)
    if not total:
        return 'N/A'
    available = values.get('MemAvailable')
    if available is None:
        available = sum(values.get(key, 0) for key in ['MemFree', 'Buffers', 'Cached', 'SReclaimable']) - values.get('Shmem', 0)
    used = total - max(0, min(total, available))
    return '{:.1f} / {:.1f} GiB ({:.0f}%)'.format(used / 1048576, total / 1048576, used * 100 / total)


def disk():
    # MMC identifies eMMC; SD cards and mmcblk*boot*/rpmb are excluded.
    devices = []
    for path in sorted(Path('/sys/class/block').glob('mmcblk*')):
        if re.fullmatch(r'mmcblk\d+', path.name) and read(path / 'device/type') == 'MMC':
            devices.append(path)
    if not devices:
        return 'N/A (eMMC not found)'
    try:
        root_dev = os.stat('/').st_dev
        root_id = '{}:{}'.format(os.major(root_dev), os.minor(root_dev))
    except OSError:
        root_id = ''
    # Prefer the eMMC containing / if more than one MMC device is present.
    selected = devices[0]
    for device in devices:
        partitions = list(device.glob(device.name + 'p*'))
        if root_id and root_id in [read(path / 'dev') for path in [device] + partitions]:
            selected = device
            break
    try:
        # Linux exports block-device capacity in 512-byte sectors.
        total = int(read(selected / 'size')) * 512
    except ValueError:
        return 'N/A (eMMC size unreadable)'
    if total <= 0:
        return 'N/A (eMMC size unreadable)'
    ids = {read(path / 'dev') for path in [selected] + list(selected.glob(selected.name + 'p*'))}
    ids.discard('')
    seen, used, incomplete = set(), 0, False
    for line in read('/proc/self/mountinfo').splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[2] not in ids or fields[2] in seen:
            continue
        # mountinfo escapes whitespace and backslashes as octal sequences.
        mountpoint = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match.group(1), 8)), fields[4])
        try:
            info = os.statvfs(mountpoint)
        except OSError:
            incomplete = True
            continue
        seen.add(fields[2])
        used += max(0, info.f_blocks - info.f_bfree) * info.f_frsize
    if not seen or incomplete:
        return 'N/A / {:.1f} GiB'.format(total / 1073741824)
    # Usage covers mounted filesystems only, not raw firmware/unmounted areas.
    return '{:.1f} / {:.1f} GiB ({:.0f}%)'.format(used / 1073741824, total / 1073741824, used * 100 / total)


def temperature():
    readings = []
    for path in sorted(Path('/sys/class/thermal').glob('thermal_zone*')):
        kind = read(path / 'type')
        try:
            value = int(read(path / 'temp')) / 1000
        except ValueError:
            continue
        if -40 <= value <= 150 and any(name in kind.lower() for name in ['soc', 'cpu', 'package']):
            readings.append((kind, value))
    if not readings:
        return 'N/A'
    kind, value = max(readings, key=lambda entry: entry[1])
    return '{:.1f}°C ({})'.format(value, kind)


def uptime():
    try:
        minutes = int(float(read('/proc/uptime').split()[0])) // 60
    except (ValueError, IndexError):
        return 'N/A'
    days, minutes = divmod(minutes, 1440)
    hours, minutes = divmod(minutes, 60)
    return '{}d {:02d}:{:02d}'.format(days, hours, minutes)


def network():
    try:
        interfaces = json.loads(command(['ip', '-j', '-4', 'address', 'show']))
    except (ValueError, TypeError):
        return 'N/A'
    values = []
    for interface in interfaces:
        name = interface.get('ifname', '')
        if name == 'lo' or not name:
            continue
        addresses = ['{}/{}'.format(addr['local'], addr['prefixlen'])
                     for addr in interface.get('addr_info', []) if addr.get('family') == 'inet']
        values.append('{} {}'.format(name, ', '.join(addresses) if addresses else 'no IPv4'))
    return '  '.join(values) if values else 'no IPv4 interfaces'


def width(text):
    return sum(0 if unicodedata.combining(char) else
               2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1 for char in text)


def wrap(text, columns):
    lines, line = [], ''
    # Collapse controls/newlines from system data before rendering the terminal.
    text = ''.join(char if char.isprintable() else ' ' for char in str(text))
    for word in text.split():
        if line and width(line + ' ' + word) > columns:
            lines.append(line)
            line = ''
        for char in (' ' if line else '') + word:
            if width(line + char) > columns:
                lines.append(line)
                line = ''
            line += char
    lines.append(line)
    return lines


def render(template, values):
    borders = [width(line) - 2 for line in template.splitlines() if line.startswith(('╔', '╠', '╚'))]
    interior = borders[0] if borders else 62
    output = []
    for line in template.splitlines():
        fields = list(re.finditer(r'([A-Za-z][A-Za-z ]*:\s*)(@[A-Z_]+@)', line)) if line.startswith('║') else []
        if fields:
            cell_width = (interior - 2) // len(fields)
            cells = []
            for field in fields:
                label = field.group(1).lstrip()
                value = values.get(field.group(2), 'N/A')
                chunks = wrap(value, max(1, cell_width - width(label) - 1))
                cells.append([label + chunks[0]] + [' ' * width(label) + chunk for chunk in chunks[1:]])
            for index in range(max(len(cell) for cell in cells)):
                body = '  '
                for cell in cells:
                    text = cell[index] if index < len(cell) else ''
                    body += text + ' ' * max(0, cell_width - width(text))
                output.append('║' + body + ' ' * max(0, interior - width(body)) + '║')
        else:
            for token, value in values.items():
                line = line.replace(token, str(value))
            output.append(line)
    return '\n'.join(output) + '\n'


def main():
    info = os.uname()
    values = {'@PLATFORM@': 'TBoard', '@KERNEL@': info.release,
              '@SYSTEM@': system_name(), '@UPTIME@': uptime(), '@HOST@': socket.gethostname(),
              '@LOAD@': ' '.join(read('/proc/loadavg').split()[:3]) or 'N/A',
              '@CPU@': cpu(), '@GPU@': gpu(), '@MEMORY@': memory(), '@DISK@': disk(),
              '@TEMP@': temperature(), '@NETWORK@': network()}
    template = Path('/etc/motd.template').read_text(encoding='UTF-8')
    print(render(template, values), end='')


if __name__ == '__main__':
    main()
