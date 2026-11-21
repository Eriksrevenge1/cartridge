#!/usr/bin/env python3
"""dm/tools/upstream_status.py: a forwarded change lands by upstream's commit title or a merge, a closed pull request is declined only when it says so, the table
round-trips, and docs/upstream.tsv parses with the statuses the script knows. gh is mocked: no network."""
import sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import upstream_status as us   # noqa: E402

ROW = {'id': 'x', 'title': 't', 'status': 'forwarded seedds/nxnative#42', 'branch': '-', 'base': '-', 'fork_commits': '-', 'notes': ''}
LOG = ['a' * 40 + '\thost/vi: something else (PR #41)', 'b' * 40 + '\tnvn/x: the change (PR #42)']


class Judge(unittest.TestCase):
    def test_landed_by_commit_title(self):
        self.assertEqual(us.judge(ROW, LOG, {'state': 'CLOSED', 'comments': []}), ('landed ' + 'b' * 12, None))

    def test_landed_by_short_form(self):
        self.assertEqual(us.landed_commit(['c' * 40 + '\tgame: y (#42)'], 42), 'c' * 40)
        self.assertIsNone(us.landed_commit(['c' * 40 + '\tgame: y (#420)'], 42))

    def test_merged(self):
        self.assertEqual(us.judge(ROW, [], {'state': 'MERGED', 'mergeCommit': {'oid': 'd' * 40}})[0], 'landed ' + 'd' * 12)

    def test_closed_without_commit_is_flagged_not_declined(self):
        status, note = us.judge(ROW, [], {'state': 'CLOSED', 'comments': [{'body': 'Thanks!'}]})
        self.assertEqual(status, ROW['status']); self.assertIn('look at it', note or '')

    def test_declined_when_it_says_so(self):
        status, note = us.judge(ROW, [], {'state': 'CLOSED', 'comments': [{'body': "This is out of scope for nxnative, sorry."}]})
        self.assertEqual(status, 'fork-only (declined #42)'); self.assertIn('declined', note or '')

    def test_open_with_changes_requested(self):
        status, note = us.judge(ROW, [], {'state': 'OPEN', 'reviews': [{'state': 'CHANGES_REQUESTED'}]})
        self.assertEqual(status, ROW['status']); self.assertIn('changes requested', note or '')

    def test_open_quiet(self):
        self.assertEqual(us.judge(ROW, [], {'state': 'OPEN', 'reviews': [{'state': 'COMMENTED'}]}), (ROW['status'], None))

    def test_unreadable(self):
        self.assertIn('could not be read', us.judge(ROW, [], None)[1] or '')


class Table(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 't.tsv'
            us.save(['# head'], [dict(ROW)], p)
            head, rows = us.load(p)
            self.assertEqual(head, ['# head']); self.assertEqual(rows, [ROW])

    def test_repository_table(self):
        _, rows = us.load()
        self.assertTrue(rows)
        ids = {r['id'] for r in rows}
        self.assertEqual(len(ids), len(rows), 'ids are unique')
        for r in rows:
            s = r['status']
            self.assertTrue(s == 'pending' or us.forwarded(s) or s.startswith(('landed ', 'fork-only (')), f'{r["id"]}: unknown status {s!r}')
            self.assertTrue(r['base'] == '-' or r['base'] in ids, f'{r["id"]}: base {r["base"]} is not a row')
            if s == 'pending': self.assertTrue(r['branch'].startswith('pr/'), f'{r["id"]}: a pending change names its branch')


if __name__ == '__main__':
    unittest.main()
