"""Exercise real installer file transactions in temporary directories only."""
import base64
import hashlib
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

import build_installer

ROOT = Path(__file__).resolve().parent
CORE = ROOT / 'installer/install.sh'
INSTALLER = ROOT / 'Weather Installer.sh'


def decoded_payload():
    header, encoded = INSTALLER.read_bytes().split(b'__WEATHER_PAYLOAD__\n', 1)
    payload = base64.b64decode(encoded)
    digest = re.search(rb'^PAYLOAD_SHA256=([0-9a-f]{64})$', header, re.M).group(1).decode()
    return header, payload, digest


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.root = self.folder / 'kindle'
        self.stage = self.folder / 'stage'
        self.root.mkdir()
        (self.root / 'documents').mkdir()
        (self.root / 'documents/book.txt').write_text('Keep my book.')
        self.kterm = self.root / 'extensions/kterm'
        (self.kterm / 'bin').mkdir(parents=True)
        (self.kterm / 'bin/kterm').write_text('existing keyboard')
        (self.kterm / 'bin/kterm').chmod(0o755)
        (self.kterm / 'layouts').mkdir()
        (self.kterm / 'layouts/keyboard-300dpi.xml').write_text('custom layout')
        (self.kterm / 'vte/terminfo').mkdir(parents=True)
        self.stage.mkdir()
        _, payload, _ = decoded_payload()
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            archive.extractall(self.stage, filter='data')

    def run_core(self, function='install_payload', answer='', env=None):
        return subprocess.run(['sh', '-c', '. "$1"; "$2" "$3" "$4"',
                               'test', str(CORE), function, str(self.root), str(self.stage)],
                              input=answer, text=True, capture_output=True,
                              env={**os.environ, **(env or {})})

    def previous_install(self):
        state = self.root / 'weather/state'
        state.mkdir(parents=True)
        (state / 'zip').write_text('10001\n')
        (state / 'cached-data').write_text('previous forecast')
        (state / 'hardware-verified').write_text('Keep device verification.')
        (self.root / 'weather/runtime.sh').write_text('old runtime')
        for name in ('Weather.sh', 'Weather Settings.sh', 'Weather instructions.txt'):
            (self.root / 'documents' / name).write_text('old ' + name)

    def failure_environment(self, tool):
        folder = self.folder / 'bin'
        folder.mkdir()
        wrapper = folder / tool
        if tool == 'cp':
            check = 'case "$1" in */documents/Weather\\ Settings.sh) exit 71 ;; esac\n'
        else:
            check = 'if [ "$1" = "$FAIL_OLD_DOCUMENT" ]; then exit 71; fi\n'
        wrapper.write_text('#!/bin/sh\n' + check + 'exec /bin/' + tool + ' "$@"\n')
        wrapper.chmod(0o755)
        return {'PATH': str(folder) + ':' + os.environ['PATH'],
                'FAIL_OLD_DOCUMENT': str(self.root / 'documents/Weather Settings.sh')}

    def assert_old_restored(self):
        self.assertEqual((self.root / 'weather/runtime.sh').read_text(), 'old runtime')
        self.assertEqual((self.root / 'weather/state/zip').read_text(), '10001\n')
        for name in ('Weather.sh', 'Weather Settings.sh', 'Weather instructions.txt'):
            self.assertEqual((self.root / 'documents' / name).read_text(), 'old ' + name)
        self.assertEqual((self.root / 'documents/book.txt').read_text(), 'Keep my book.')

    def test_fresh_install_has_no_zip_and_preserves_unrelated_documents(self):
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'weather/state').exists())
        self.assertTrue((self.root / 'extensions/kterm/bin/kterm').stat().st_mode & 0o111)
        self.assertEqual((self.root / 'weather/runtime.sh').read_bytes(), (ROOT / 'kindle-weather/runtime.sh').read_bytes())
        self.assertEqual((self.root / 'documents/book.txt').read_text(), 'Keep my book.')

    def test_update_preserves_settings_and_existing_keyboard_and_makes_backup(self):
        self.previous_install()
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'weather/state/zip').read_text(), '10001\n')
        self.assertEqual((self.root / 'weather/state/cached-data').read_text(), 'previous forecast')
        self.assertEqual((self.kterm / 'layouts/keyboard-300dpi.xml').read_text(), 'custom layout')
        self.assertEqual((self.kterm / 'bin/kterm').read_text(), 'existing keyboard')
        backup, = (self.root / 'weather-backups').iterdir()
        self.assertEqual((backup / 'weather/runtime.sh').read_text(), 'old runtime')
        self.assertEqual((backup / 'documents/Weather.sh').read_text(), 'old Weather.sh')

    def test_cancel_and_eof_write_no_installation_files(self):
        for answer in ('NO\n', ''):
            result = self.run_core('confirm_install', answer)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.root / 'weather').exists())
            self.assertFalse((self.root / 'weather-backups').exists())
            self.assertFalse((self.stage / 'result').exists())

    def test_failed_copy_restores_previous_installation(self):
        self.previous_install()
        result = self.run_core(env=self.failure_environment('cp'))
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_restored()
        self.assertEqual((self.kterm / 'bin/kterm').read_text(), 'existing keyboard')

    def test_failed_backup_move_keeps_original_document(self):
        self.previous_install()
        result = self.run_core(env=self.failure_environment('mv'))
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_restored()

    def test_failed_fresh_install_removes_partially_installed_app(self):
        result = self.run_core(env=self.failure_environment('cp'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'weather').exists())
        self.assertEqual((self.kterm / 'bin/kterm').read_text(), 'existing keyboard')
        self.assertFalse((self.root / 'documents/Weather.sh').exists())
        self.assertEqual((self.root / 'documents/book.txt').read_text(), 'Keep my book.')

    def test_symlink_and_incomplete_keyboard_are_kept_untouched(self):
        outside = self.folder / 'other'
        outside.mkdir()
        (outside / 'data').write_text('keep')
        (self.root / 'weather').symlink_to(outside)
        self.assertNotEqual(self.run_core().returncode, 0)
        self.assertEqual((outside / 'data').read_text(), 'keep')
        (self.root / 'weather').unlink()
        (self.kterm / 'bin/kterm').unlink()
        self.assertNotEqual(self.run_core().returncode, 0)
        self.assertFalse((self.root / 'weather').exists())
        self.assertFalse((self.root / 'weather-backups').exists())

    def test_missing_keyboard_stops_before_changing_previous_app(self):
        self.previous_install()
        shutil.rmtree(self.kterm)
        result = self.run_core()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Install official kTerm', result.stderr)
        self.assert_old_restored()
        self.assertFalse((self.root / 'weather-backups').exists())

    def test_generated_installer_checksum_and_zip_match_sources_without_state(self):
        _, payload, expected = decoded_payload()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)
        with zipfile.ZipFile(ROOT / 'PaperWhite-weather-fresh-install.zip') as package:
            self.assertIsNone(package.testzip())
            names = package.namelist()
            self.assertFalse(any('/state/' in name for name in names))
            self.assertFalse(any(name.startswith('extensions/') or 'kterm' in name.lower() for name in names))
            for name in ('weather/licenses/LICENSE', 'weather/licenses/THIRD_PARTY.md',
                         'weather/licenses/paperwhite-weather-LICENSE',
                         'weather/fonts/LICENSE', 'weather/fonts/Noto-LICENSE'):
                self.assertIn(name, names)
            self.assertFalse(any(package.read(name).startswith(b'\x7fELF') for name in names))
            for path in (ROOT / 'kindle-weather').rglob('*'):
                if path.is_file() and 'state' not in path.relative_to(ROOT / 'kindle-weather').parts:
                    name = 'weather/' + path.relative_to(ROOT / 'kindle-weather').as_posix()
                    self.assertEqual(package.read(name), path.read_bytes(), name)
            files = {item.filename: (package.read(item), (item.external_attr >> 16) & 0o777)
                     for item in package.infolist()}
        files['install.sh'] = (CORE.read_bytes(), 0o644)
        self.assertEqual(build_installer.payload_bytes(files), payload)

    def test_corrupted_payload_is_rejected_before_any_payload_file_is_unpacked(self):
        header, payload, _ = decoded_payload()
        damaged = bytes([payload[0] ^ 1]) + payload[1:]
        bad = self.folder / 'damaged.sh'
        bad.write_bytes(header + b'__WEATHER_PAYLOAD__\n' + base64.encodebytes(damaged))
        functions = self.folder / 'entry-functions.sh'
        functions.write_bytes(header.split(b'\nmain\nexit $?\n')[0] + b'\n')
        unpacked = self.folder / 'unpacked'
        unpacked.mkdir()
        result = subprocess.run(['sh', '-c', '. "$1"; INSTALL_ROOT="$2"; FBINK=/nonexistent; unpack_payload "$3" "$4"',
                                 'test', str(functions), str(self.root), str(bad), str(unpacked)],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('verification failed', result.stderr)
        self.assertFalse((unpacked / 'install.sh').exists())
        self.assertFalse((self.root / 'weather').exists())

    def test_valid_payload_unpacks_and_model_guard_uses_structured_fbink_output(self):
        header, _, _ = decoded_payload()
        functions = self.folder / 'entry-functions.sh'
        functions.write_bytes(header.split(b'\nmain\nexit $?\n')[0] + b'\n')
        unpacked = self.folder / 'unpacked'
        unpacked.mkdir()
        result = subprocess.run(['sh', '-c', '. "$1"; INSTALL_ROOT="$2"; FBINK=/nonexistent; unpack_payload "$3" "$4"',
                                 'test', str(functions), str(self.root), str(INSTALLER), str(unpacked)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((unpacked / 'install.sh').read_bytes(), CORE.read_bytes())
        for model, allowed in [('PaperWhite 3', True), ('PaperWhite 2', False), ('PaperWhite 4', False)]:
            result = subprocess.run(['sh', '-c', '. "$1"; supported_model "$2"', 'test',
                                     str(functions), f"screenWidth=1072;deviceName='{model}';deviceId=513;"],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, allowed, model)

    def test_installer_refuses_to_run_on_setup_computer(self):
        result = subprocess.run(['sh', str(INSTALLER)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Copy this file to documents', result.stderr)


if __name__ == '__main__':
    unittest.main()
