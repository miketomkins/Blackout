"""Real executable parsing and read-only producer acceptance; no simulated output."""
import ctypes
import json
from pathlib import Path
import subprocess
import unittest

APP = Path(__file__).resolve().parents[1] / 'build/Blackout.app/Contents/MacOS/Blackout'

class CLITests(unittest.TestCase):
    def call(self, *args):
        return subprocess.run([str(APP), *args], capture_output=True, text=True, timeout=5)

    def test_help_returns_without_launching_gui(self):
        p = self.call('--help')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('Blackout 1.0.0', p.stdout)

    def test_incomplete_mutation_is_rejected_not_launched(self):
        p = self.call('--connect')
        self.assertEqual(p.returncode, 2)

    def test_unknown_flags_cannot_turn_into_gui_or_inventory(self):
        p = self.call('--unknown', '--list')
        self.assertEqual(p.returncode, 2)

    def test_malformed_identifier_is_rejected(self):
        p = self.call('--toggle', 'not-a-uuid')
        self.assertEqual(p.returncode, 1)
        self.assertIn('UUID', p.stderr)

    def test_unknown_uuid_is_rejected(self):
        p = self.call('--connect', '00000000-0000-0000-0000-000000000001')
        self.assertEqual(p.returncode, 1)
        self.assertIn('not known', p.stderr)

    def test_real_producer_matches_independent_os_active_inventory(self):
        p = self.call('--list')
        self.assertEqual(p.returncode, 0, p.stderr)
        items = json.loads(p.stdout)
        g = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        ids = (ctypes.c_uint32 * 64)()
        count = ctypes.c_uint32()
        self.assertEqual(g.CGGetActiveDisplayList(64, ids, ctypes.byref(count)), 0)
        actual = set(ids[:count.value])
        self.assertEqual({d['id'] for d in items if d['active']}, actual)
        self.assertTrue(all(isinstance(d['active'], bool) and len(d['uuid']) == 36 for d in items))

    def test_diagnostics_are_readable_json(self):
        p = self.call('--diagnostics')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)['preferenceDomain'], 'com.miketomkins.Blackout.preferences')

if __name__ == '__main__':
    unittest.main()
