#!/usr/bin/env python3
"""dm/tools/md_merge.py, the Markdown merge driver of Cartridge's fork (.gitattributes): a paragraph upstream rewrote beside one the fork added keeps upstream's
version once and the fork's addition; additions on both sides at the same place keep both, upstream's first."""
import subprocess, sys, tempfile, unittest
from pathlib import Path

DRIVER = Path(__file__).resolve().parents[1] / 'md_merge.py'


def merge(base, ours, theirs):
    with tempfile.TemporaryDirectory() as d:
        o, a, b = (Path(d) / n for n in 'OAB')
        o.write_text(base); a.write_text(ours); b.write_text(theirs)
        r = subprocess.run([sys.executable, DRIVER, o, a, b])
        assert r.returncode == 0
        return a.read_text()


class MdMerge(unittest.TestCase):
    def test_rewritten_beside_an_addition(self):
        base = 'Intro.\n\nController old.\n\nTail.\n'
        ours = 'Intro.\n\nKeyboard (fork).\n\nController old.\n\nTail.\n'
        theirs = 'Intro.\n\nController new.\n\nTail.\n'
        self.assertEqual(merge(base, ours, theirs), 'Intro.\n\nKeyboard (fork).\n\nController new.\n\nTail.\n')

    def test_both_added(self):
        base = '## A\n\nx\n'
        ours = '## A\n\nx\n\n## Fork\n\nmine\n'
        theirs = '## A\n\nx\n\n### Upstream\n\ntheirs\n'
        out = merge(base, ours, theirs)
        self.assertLess(out.index('### Upstream'), out.index('## Fork'))
        self.assertEqual(out.count('mine'), 1); self.assertEqual(out.count('theirs'), 1)
        self.assertNotIn('<<<<<<<', out)

    def test_no_conflict(self):
        self.assertEqual(merge('a\n\nb\n', 'a\n\nb\n\nc\n', 'z\n\na\n\nb\n'), 'z\n\na\n\nb\n\nc\n')


if __name__ == '__main__':
    unittest.main()
