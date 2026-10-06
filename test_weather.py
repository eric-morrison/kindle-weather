"""Verify settings, offline data, API parsing and DST schedules without Kindle writes."""
import copy
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'kindle-weather'
LOCATION = {'places': [{'latitude': '47.717', 'longitude': '-122.3015',
                        'place name': 'Seattle', 'state abbreviation': 'WA'}]}
FORECAST = {
    'utc_offset_seconds': -25200, 'timezone': 'America/Los_Angeles',
    'daily_units': {'temperature_2m_max': '°F', 'temperature_2m_min': '°F',
                    'precipitation_sum': 'inch'},
    'daily': {'time': ['2026-10-06'], 'weather_code': [3],
              'temperature_2m_max': [64.2], 'temperature_2m_min': [50.8],
              'precipitation_probability_max': [0], 'precipitation_sum': [0.0]},
    'current_units': {'temperature_2m': '°F'},
    'current': {'temperature_2m': 60.1, 'weather_code': 3, 'time': '2026-10-06T12:30'},
    'hourly_units': {'temperature_2m': '°F', 'precipitation_probability': '%'},
    'hourly': {
        'time': [(datetime(2026, 10, 6, 12) + timedelta(hours=i)).isoformat(timespec='minutes') for i in range(7)],
        'temperature_2m': [60, 61, 62, 63, 64, 65, 66],
        'weather_code': [0, 1, 2, 3, 61, 71, 95],
        'precipitation_probability': [0, 0, 5, 10, 50, 60, 80],
        'is_day': [1] * 7,
    },
}
ALERTS = {'type': 'FeatureCollection', 'features': []}


def parse(mode, payload):
    return subprocess.run(['awk', '-v', f'mode={mode}', '-f',
                           str(APP / 'weather-json.awk')],
                          input=payload, text=True, capture_output=True,
                          env={**os.environ, 'LC_ALL': 'C'})


class ParserTests(unittest.TestCase):
    def test_zip_coordinates_checked_numerically(self):
        result = parse('location', json.dumps(LOCATION, indent=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '47.717\n-122.3015\nSeattle, WA\n')
        bad = copy.deepcopy(LOCATION)
        bad['places'][0]['longitude'] = '-181'
        self.assertNotEqual(parse('location', json.dumps(bad)).returncode, 0)

    def test_today_high_low_zero_precip_without_current_field(self):
        forecast = copy.deepcopy(FORECAST)
        del forecast['current']
        result = parse('forecast', json.dumps(forecast, ensure_ascii=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TODAY  2026-10-06', result.stdout)
        self.assertIn('High:  64 F', result.stdout)
        self.assertIn('Low:   51 F', result.stdout)
        self.assertIn('Precip chance: 0%', result.stdout)
        self.assertIn('Precip total:  0.00 in', result.stdout)
        self.assertNotIn('Now:', result.stdout)

    def test_hourly_negative_temperature(self):
        forecast = copy.deepcopy(FORECAST)
        forecast['current']['temperature_2m'] = -5.2
        result = parse('current', json.dumps(forecast, ensure_ascii=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Now: -5 F', result.stdout)
        self.assertIn('2026-10-06 12:30', result.stdout)

    def test_six_future_hours_cross_midnight_and_missing_data_is_rejected(self):
        forecast = copy.deepcopy(FORECAST)
        forecast['current']['time'] = '2026-10-06T23:30'
        forecast['hourly']['time'] = [(datetime(2026, 10, 6, 23) + timedelta(hours=i)).isoformat(timespec='minutes') for i in range(7)]
        forecast['hourly']['is_day'] = [0] * 7
        result = parse('hourly', json.dumps(forecast, ensure_ascii=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = result.stdout.splitlines()
        self.assertEqual(len(rows), 6)
        self.assertTrue(rows[0].startswith('12am|61|'))
        self.assertTrue(rows[-1].startswith('5am|66|'))
        self.assertIn('◐', rows[0])
        self.assertIn('🌧', rows[3])
        forecast['hourly']['temperature_2m'][-1] = None
        self.assertNotEqual(parse('hourly', json.dumps(forecast, ensure_ascii=False)).returncode, 0)

    def test_wrong_units_and_malformed_forecasts_rejected(self):
        forecast = copy.deepcopy(FORECAST)
        forecast['daily_units']['temperature_2m_max'] = '°C'
        for text in (json.dumps(forecast, ensure_ascii=False), '{}', '{',
                     json.dumps(FORECAST, ensure_ascii=False) + 'garbage'):
            with self.subTest(text=text[:40]):
                self.assertNotEqual(parse('forecast', text).returncode, 0)

    def test_no_alerts_requires_a_real_empty_feature_collection(self):
        result = parse('alerts', json.dumps(ALERTS))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No active weather alerts', result.stdout)
        for bad in ({}, {'type': 'FeatureCollection'},
                    {'type': 'FeatureCollection', 'features': None}):
            self.assertNotEqual(parse('alerts', json.dumps(bad)).returncode, 0)

    def test_alerts_display_events_and_deduplicate(self):
        alerts = copy.deepcopy(ALERTS)
        alerts['features'] = [{'properties': {'event': event}} for event in
                              ('Flood Watch', 'Flood Watch', 'High Wind Warning')]
        result = parse('alerts', json.dumps(alerts))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'Flood Watch\nHigh Wind Warning\n')


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name) / 'weather'
        shutil.copytree(APP, self.base)
        (self.base / 'state').mkdir()
        (self.base / 'state/zip').write_text('98125\n')
        self.bin = Path(self.temp.name) / 'bin'
        self.bin.mkdir()
        for name, data in [('location', LOCATION), ('forecast', FORECAST), ('alerts', ALERTS)]:
            (self.base / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False))
        mock = self.bin / 'curl'
        mock.write_text('''#!/bin/sh
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
printf '%s\\n' "$url" >> "$WEATHER_BASE/requests.txt"
case "$url" in
  */us/00000) exit 22 ;;
  *zippopotam*) cp "$WEATHER_BASE/location.json" "$out" ;;
  *open-meteo*)
    [ "${WEATHER_TEST_OFFLINE:-}" = 1 ] && exit 22
    cp "$WEATHER_BASE/forecast.json" "$out" ;;
  *weather.gov*)
    [ "${WEATHER_TEST_ALERTS_FAIL:-}" = 1 ] && exit 22
    cp "$WEATHER_BASE/alerts.json" "$out" ;;
  *) exit 1 ;;
esac
''')
        mock.chmod(0o755)
        # Exercise the production shell schedule with GNU/BusyBox date syntax
        # on macOS. Real bundled TZif files determine DST, not canned epochs.
        date_mock = self.bin / 'date'
        date_mock.write_text(f'#!{sys.executable}\n' + '''
import os, sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
args=sys.argv[1:]
zone=os.environ.get('TZ', 'UTC').lstrip(':')
if zone.startswith('/'):
    with open(zone, 'rb') as f: tz=ZoneInfo.from_file(f)
else: tz=ZoneInfo(zone)
if args and args[0] == '-u':
    tz=timezone.utc; args=args[1:]
if args and args[0] == '-d':
    value=args[1]; args=args[2:]
    if value.startswith('@'): value=datetime.fromtimestamp(int(value[1:]),tz)
    else: value=datetime.strptime(value, '%Y-%m-%d %H:%M:%S').replace(tzinfo=tz)
else: value=datetime.now(tz)
fmt=args[0].lstrip('+') if args else '%c'
print(int(value.timestamp()) if fmt == '%s' else value.strftime(fmt))
''')
        date_mock.chmod(0o755)
        self.env = {**os.environ, 'WEATHER_BASE': str(self.base),
                    'PATH': str(self.bin) + ':' + os.environ['PATH']}

    def tearDown(self):
        self.temp.cleanup()

    def app(self, command='--print', **extra):
        return subprocess.run(['sh', str(self.base / 'dashboard.sh'), command],
                              capture_output=True, text=True, timeout=5,
                              env={**self.env, **extra})

    def settings(self, text, setup=False):
        return subprocess.run(['sh', str(self.base / 'settings.sh')] + (['--setup'] if setup else []), input=text,
                              capture_output=True, text=True, timeout=5, env=self.env)

    def test_zip_persists_and_hourly_setting_is_removed(self):
        result = self.settings('1\n10001\nQ\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'state/zip').read_text(), '10001\n')
        next_launch = self.settings('Q\n').stdout
        self.assertIn('ZIP: 10001', next_launch)
        self.assertNotIn('Toggle hourly', next_launch)

    def test_first_setup_has_no_default_zip_and_saves_only_valid_input(self):
        (self.base / 'state/zip').unlink()
        result = self.settings('Q\n', setup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('WEATHER SETUP', result.stdout)
        self.assertFalse((self.base / 'state/zip').exists())
        result = self.settings('bad\n00000\n10001\n', setup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ZIP lookup failed', result.stdout)
        self.assertEqual((self.base / 'state/zip').read_text(), '10001\n')

    def test_bad_zip_keeps_saved_location_and_rejects_shell_text(self):
        self.settings('1\n98125\nQ\n')
        result = self.settings('1\n00000\n1\n98125;echo BAD\nQ\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'state/zip').read_text(), '98125\n')
        self.assertIn('ZIP lookup failed', result.stdout)
        self.assertIn('five-digit', result.stdout)

    def test_current_and_six_hour_forecast_always_requested(self):
        result = self.app()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Currently Overcast\n60\n', result.stdout)
        self.assertIn('current=temperature_2m', (self.base / 'requests.txt').read_text())
        self.assertIn('1pm|61|', result.stdout)
        self.assertIn('6pm|66|', result.stdout)

    def test_current_condition_is_independent_of_daily_forecast(self):
        forecast = copy.deepcopy(FORECAST)
        forecast['current']['weather_code'] = 0
        (self.base / 'forecast.json').write_text(json.dumps(forecast, ensure_ascii=False))
        result = self.app()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Currently Clear\n60\n', result.stdout)
        self.assertIn('Overcast', (self.base / 'state/forecast.txt').read_text())

    def test_failed_updates_preserve_cache_and_failure_state(self):
        self.app()
        old = (self.base / 'state/forecast.txt').read_text()
        result = self.app(WEATHER_TEST_OFFLINE='1', WEATHER_TEST_ALERTS_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Update failed', result.stdout)
        self.assertEqual((self.base / 'state/forecast.txt').read_text(), old)
        self.assertTrue((self.base / 'state/alerts-failed').exists())

    def test_low_battery_threshold_and_invalid_readings(self):
        self.app()
        reading = self.base / 'state/battery-percent'
        for value in ('0', '5', '19'):
            reading.write_text(value + '\n')
            self.assertIn(f'Low battery — {value}%', self.app('--cached').stdout)
        for value in ('20', '21', '100', '', 'unavailable', '-1'):
            reading.write_text(value + '\n')
            self.assertNotIn('Low battery', self.app('--cached').stdout)

    def test_active_alert_survives_failed_check_but_empty_alerts_are_hidden(self):
        self.assertNotIn('No active weather alerts', self.app().stdout)
        alerts = copy.deepcopy(ALERTS)
        alerts['features'] = [{'properties': {'event': 'Flood Watch'}}]
        (self.base / 'alerts.json').write_text(json.dumps(alerts))
        self.assertIn('Flood Watch', self.app().stdout)
        self.assertIn('Flood Watch', self.app(WEATHER_TEST_ALERTS_FAIL='1').stdout)

    def test_concurrent_exit_restores_framework_once_before_radio(self):
        state = self.base / 'state'
        state.mkdir(exist_ok=True)
        (state / 'framework-stopped').touch()
        (state / 'old-wireless').write_text('1\n')
        (state / 'old-light').write_text('0\n')
        (state / 'old-screensaver').write_text('0\n')
        for name, body in {
            'start': 'printf "framework\\n" >> "$WEATHER_BASE/calls"\nsleep 0.2\n',
            'lipc-set-prop': 'printf "%s\\n" "$*" >> "$WEATHER_BASE/calls"\n',
        }.items():
            command = self.bin / name
            command.write_text('#!/bin/sh\n' + body)
            command.chmod(0o755)
        # Exercise the production restoration function with a temporary alarm
        # file and mock platform commands; no Mac or Kindle power writes.
        source = (self.base / 'runtime.sh').read_text().rsplit('\ncase "${1:-}" in\n', 1)[0]
        script = source + '\nRTC="$STATE/mock-alarm"\nrestore &\nrestore\nwait\n'
        result = subprocess.run(['sh'], input=script, capture_output=True,
                                text=True, timeout=5, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.base / 'calls').read_text().splitlines()
        self.assertEqual(calls.count('framework'), 1)
        self.assertEqual(calls[0], 'framework')
        self.assertIn('com.lab126.cmd wirelessEnable 1', calls)
        self.assertFalse((state / 'framework-stopped').exists())
        self.assertFalse((state / 'restoring').exists())

    def schedule(self, local_time):
        state = self.base / 'state'
        state.mkdir(exist_ok=True)
        (state / 'clock.txt').write_text('-25200\nAmerica/Los_Angeles\n')
        epoch = int(local_time.timestamp())
        result = subprocess.run(['sh', str(self.base / 'runtime.sh'), '--schedule', str(epoch)],
                                capture_output=True, text=True, timeout=5, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout)

    def test_next_hour_across_both_dst_transitions(self):
        tz = ZoneInfo('America/Los_Angeles')
        for day in ('2026-10-06', '2026-11-01', '2027-03-14'):
            at = datetime.fromisoformat(day).replace(hour=1, minute=37, tzinfo=tz)
            expected = (int(at.timestamp()) // 3600 + 1) * 3600
            with self.subTest(day=day):
                self.assertEqual(self.schedule(at), expected)

    def test_hourly_is_next_clock_hour(self):
        tz = ZoneInfo('America/Los_Angeles')
        at = datetime(2026, 10, 6, 12, 37, 15, tzinfo=tz)
        self.assertEqual(self.schedule(at),
                         int(at.replace(hour=13, minute=0, second=0).timestamp()))

    def test_boot_launches_once_per_kernel_boot_and_library_exit_stays_out(self):
        state = self.base / 'state'
        state.mkdir(exist_ok=True)
        (state / 'mock-boot-id').write_text('aabb-1122\n')
        (self.base / 'runtime.sh').write_text('printf "started\\n" >> "$WEATHER_BASE/state/boot-launches"\n')
        source = (self.base / 'autostart.sh').read_text().rsplit('\ncase "${1:-}" in\n', 1)[0]
        script = source + '''
BOOT_ID_FILE="$STATE/mock-boot-id"
sleep() { :; }
boot
boot
printf 'ccdd-3344\\n' > "$BOOT_ID_FILE"
boot
boot
'''
        result = subprocess.run(['sh'], input=script, capture_output=True, text=True, timeout=5, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((state / 'boot-launches').read_text().splitlines(), ['started', 'started'])


if __name__ == '__main__':
    unittest.main()
