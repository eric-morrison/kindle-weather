"""Build the Weather scriptlet and fresh-install ZIP.

Only packages our app, licensed fonts and notices. Never includes device state
or third-party executables. Install kTerm separately from its official release.
"""
import argparse
import base64
import gzip
import hashlib
import io
from pathlib import Path
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent
def package_files():
    files = {}
    for path in sorted((ROOT / 'kindle-weather').rglob('*')):
        relative = path.relative_to(ROOT / 'kindle-weather')
        if 'state' in relative.parts:
            continue
        if path.is_symlink():
            raise ValueError(f'Symlinks are not packaged: {relative}')
        if path.is_file():
            files['weather/' + relative.as_posix()] = (path.read_bytes(), 0o644)
    for name in ('Weather.sh', 'Weather Settings.sh', 'Weather instructions.txt'):
        files['documents/' + name] = ((ROOT / 'kindle-weather' / name).read_bytes(), 0o644)
    for name in ('LICENSE', 'THIRD_PARTY.md'):
        files['weather/licenses/' + name] = ((ROOT / name).read_bytes(), 0o644)
    for name in ('paperwhite-weather-LICENSE',):
        files['weather/licenses/' + name] = ((ROOT / 'third_party' / name).read_bytes(), 0o644)
    return files


def payload_bytes(files):
    # Stable timestamps/owners make rebuilds byte-for-byte reproducible.
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, (data, mode) in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), mode, 0
            info.uid = info.gid = 0
            archive.addfile(info, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), mtime=0)


def build():
    files = package_files()
    core = (ROOT / 'installer/install.sh').read_bytes()
    payload = payload_bytes({**files, 'install.sh': (core, 0o644)})
    sha = hashlib.sha256(payload).hexdigest()
    header = (ROOT / 'installer/entry.sh').read_text().replace('__PAYLOAD_SHA256__', sha)
    installer = ROOT / 'Weather Installer.sh'
    installer.write_bytes(header.encode() + base64.encodebytes(payload))
    archive = ROOT / 'PaperWhite-weather-fresh-install.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        for name, (data, mode) in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 6, 0, 0, 0))
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(info, data)
    (ROOT / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n'
        for path in (installer, archive)))
    print(f'Built {installer.name} ({installer.stat().st_size:,} bytes) and {archive.name}.')
    return installer, archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    build()


if __name__ == '__main__':
    main()
