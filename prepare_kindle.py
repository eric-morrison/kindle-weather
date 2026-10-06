"""Stage the official WB2 payload and temporary update-prevention filler.

Default is inspection only. --apply writes only two new directories to Kindle.
Run on the Mac; never execute downloaded jailbreak code on the Mac.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent
VOLUME = Path('/Volumes/Kindle')
ARCHIVE = ROOT / 'downloads/wb2-v1.1.0.zip'
BACKUP = ROOT / 'backups/2026-10-06-before-jailbreak'
EXPECTED_SHA256 = '9e85970902a1f2af6b4c3243755d80595dd36404b85083f8be8c65a69d04cfdf'
MIB = 1024 * 1024
RESERVE = 75 * MIB


def free_bytes():
    stat = os.statvfs(VOLUME)
    return stat.f_bavail * stat.f_frsize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not VOLUME.is_mount() or VOLUME.is_symlink():
        raise SystemExit('Kindle is not mounted at the expected path.')
    usb = subprocess.check_output(
        ['/usr/sbin/ioreg', '-r', '-c', 'IOUSBHostDevice', '-l', '-w', '0'], text=True)
    if not re.search(r'"USB Serial Number" = "G090G105[^\"]*"', usb):
        raise SystemExit('The expected Paperwhite 3 is not connected.')
    for name in ('documents', 'system', 'fonts', '.active_content_sandbox'):
        if not (VOLUME / name).is_dir() or not (BACKUP / name).is_dir():
            raise SystemExit('Expected Kindle directories or backup are missing.')
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != EXPECTED_SHA256:
        raise SystemExit('Downloaded archive hash changed; inspect it again.')
    for name in ('winterbreak2', 'fill_disk'):
        if (VOLUME / name).exists():
            raise SystemExit(f'{name} already exists; will not overwrite it.')
    if any(p.name.endswith(('.bin', '.partial', '.bin.tmp')) for p in VOLUME.iterdir()):
        raise SystemExit('An existing update file needs inspection before proceeding.')
    with zipfile.ZipFile(ARCHIVE) as archive:
        if set(archive.namelist()) != {'winterbreak2/', 'winterbreak2/dialoger.html'}:
            raise SystemExit('Unexpected archive contents; inspect before proceeding.')
        payload = archive.read('winterbreak2/dialoger.html')
    print(f'Expected Paperwhite 3 detected. Free: {free_bytes() / MIB:.1f} MiB.', flush=True)
    print('Official WB2 v1.1.0 payload verified; accessible-storage backup present.', flush=True)
    if not args.apply:
        print('Inspection only. --apply copies the payload and creates temporary filler.')
        return
    if free_bytes() < 100 * MIB:
        raise SystemExit('Not enough room to prepare safely.')
    target = VOLUME / 'winterbreak2'
    target.mkdir()
    (target / 'dialoger.html').write_bytes(payload)
    if (target / 'dialoger.html').read_bytes() != payload:
        raise SystemExit('Payload verification failed.')
    filler = VOLUME / 'fill_disk'
    filler.mkdir()
    block = bytes(MIB)
    total = 0
    index = 0
    while free_bytes() > RESERVE + MIB:
        size = min(64 * MIB, free_bytes() - RESERVE)
        path = filler / f'paperwhite-filler-{index:03d}.bin'
        with path.open('xb') as stream:
            remaining = size
            while remaining:
                written = stream.write(block[:min(len(block), remaining)])
                if not written:
                    raise OSError('No progress writing filler.')
                remaining -= written
            stream.flush()
            os.fsync(stream.fileno())
        total += size
        index += 1
        print(f'Filler written: {total / MIB:.0f} MiB; free: {free_bytes() / MIB:.1f} MiB.', flush=True)
    free = free_bytes()
    if not 50 * MIB <= free <= 90 * MIB:
        raise SystemExit('Free space is outside the guide range; leave Airplane Mode on.')
    result = {
        'model': 'Paperwhite 3 (7th generation)',
        'firmware_from_photo': '5.16.2.1.1',
        'release': 'WinterBreak2 v1.1.0',
        'archive_sha256': EXPECTED_SHA256,
        'payload_sha256': hashlib.sha256(payload).hexdigest(),
        'filler_bytes': total,
        'free_bytes': free,
        'status': 'USB preparation verified; jailbreak has not been triggered',
        'guide': 'https://kindlemodding.org/jailbreaking/WinterBreak2/',
    }
    (ROOT / 'device-preparation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    main()
