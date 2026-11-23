#!/usr/bin/env python3
"""scripts/release_cartridge.py: release notes keep what players notice (games, display, controls, sound, Cartridge), put Players: trailers first and count the rest; a release never goes
backwards (newest_build)."""
import importlib.util, unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('release_cartridge', Path(__file__).resolve().parents[3] / 'scripts/release_cartridge.py')
assert spec and spec.loader
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)


class Notes(unittest.TestCase):
    def test_groups(self):
        notes = rc.player_notes(['game: support XCOM 2 Collection on the Mac', 'host/audio: recover from stalls after an output route change',
                                 'gfx/vi: a Switch 2 display at 120 Hz', 'launcher: updates every few hours', 'nvn/vertex: bind the mapped bytes',
                                 'opengl/shaders: omit inactive uniforms', 'merge upstream nxnative main (6 commits) into launcher',
                                 'nvn/residency: Kirby Air Riders stops flickering'], ['Kirby Air Riders'])
        self.assertIn('Games:\n- game: support XCOM 2 Collection on the Mac\n- nvn/residency: Kirby Air Riders stops flickering', notes)
        self.assertIn('Display, controls and sound:\n- host/audio: recover from stalls after an output route change\n- gfx/vi: a Switch 2 display at 120 Hz', notes)
        self.assertIn('Cartridge:\n- launcher: updates every few hours', notes)
        self.assertIn('And 2 other engine changes', notes)
        self.assertNotIn('merge upstream', notes)

    def test_nothing_noticeable(self):
        self.assertEqual(rc.player_notes(['nvn/vertex: x']), 'And 1 other engine change (shaders, memory, services, tools).')
        self.assertEqual(rc.player_notes([]), 'No changes players notice.')

    def test_players_trailers_first(self):
        notes = rc.player_notes(['tools/rewriter: bake mods' + "'" + ' code patches'], [], ['Rebuild games with code mods.', '', 'Rebuild games with code mods.'])
        self.assertTrue(notes.startswith('What to do:\n- Rebuild games with code mods.\n\nAnd 1 other engine change'))

    def test_game_names_from_the_table(self):
        self.assertIn('Super Mario Bros. Wonder', rc.game_names())


class Backwards(unittest.TestCase):
    def test_newest_build(self):
        self.assertEqual(rc.newest_build(['cartridge-1844', 'cartridge-2038', 'v1.0', 'cartridge-x']), 2038)
        self.assertEqual(rc.newest_build([]), 0)


if __name__ == '__main__':
    unittest.main()
