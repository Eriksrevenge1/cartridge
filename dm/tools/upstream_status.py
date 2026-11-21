#!/usr/bin/env python3
"""Where each of Cartridge's changes to upstream nxnative stands (docs/upstream.tsv; docs/launcher.md, Sending changes upstream).

    python3 dm/tools/upstream_status.py                  # the table, with what changed upstream and what applies
    python3 dm/tools/upstream_status.py --update         # the same, and the table rewritten with the new statuses
    python3 dm/tools/upstream_status.py --attention F    # also write the rows that need the owner to F (Markdown, for the workflow's issue)

For a row forwarded as seedds/nxnative#N it asks GitHub (gh) about the pull request and reads upstream's main for a commit titled with "(PR #N)" or "(#N)": the
maintainer closes pull requests and commits them himself, so a closed pull request is not a declined one. A merged pull request, or such a commit, makes the row
landed <sha>. A pull request closed with no such commit becomes fork-only (declined #N) only when it was closed as not planned or a maintainer's last comment says
so; otherwise the row is flagged for the owner to look at. For each pending or forwarded row with a branch, a merge preview (git merge-tree) on upstream's main says
whether the branch still applies, so a conflict shows before upstream merges anything. For an open forwarded pull request it reads its CI checks: a failing check
is the fork's to fix (flagged, and the workflow's Claude fixes it) unless the same workflow's newest run on upstream's main that passed or failed (not one cancelled) failed too, which makes it
upstream's own (noted, nothing to do). Exit status 0; 1 on an error (no table, no upstream ref).
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / 'docs/upstream.tsv'
UPSTREAM = 'seedds/nxnative'
COLS = ['id', 'title', 'status', 'branch', 'base', 'fork_commits', 'notes']
DECLINED = re.compile(r"\b(not planned|won't (merge|take|accept)|will not (merge|take|accept)|declin|reject|out of scope|not going to (merge|take))", re.I)


def load(path=TABLE):
    head, rows = [], []
    for line in Path(path).read_text().splitlines():
        if line.startswith('#') or not line.strip(): head.append(line); continue
        f = line.split('\t')
        if f[0] == 'id': continue
        rows.append(dict(zip(COLS, f + [''] * (len(COLS) - len(f)))))
    return head, rows


def save(head, rows, path=TABLE):
    out = head + ['\t'.join(COLS)] + ['\t'.join(r[c] for c in COLS) for r in rows]
    Path(path).write_text('\n'.join(out) + '\n')


def gh(args):   # a gh call's JSON (mocked in the tests)
    r = subprocess.run(['gh'] + args, capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f'gh {" ".join(args)}: {r.stderr.strip()}')
    return json.loads(r.stdout or 'null')


def gh_checks(repo, n):   # a pull request's checks; gh exits 1 while any fails and 8 while any is pending, with the JSON all the same
    r = subprocess.run(['gh', 'pr', 'checks', str(n), '--repo', repo, '--json', 'name,state,workflow,link'], capture_output=True, text=True)
    try: return json.loads(r.stdout or '[]')
    except ValueError as e: raise RuntimeError(f'gh pr checks {n}: {r.stderr.strip()}') from e


FAILED = {'FAILURE', 'ERROR', 'TIMED_OUT', 'STARTUP_FAILURE', 'ACTION_REQUIRED'}


def ci(repo, n, checks, main_failing):
    """(ours, upstreams): the failing checks of pull request n, split by whether the same workflow's newest finished run on upstream's main failed too.
    main_failing(workflow) -> bool"""
    ours, theirs = [], []
    for c in checks or []:
        if (c.get('state') or '').upper() not in FAILED: continue
        (theirs if c.get('workflow') and main_failing(c['workflow']) else ours).append(c.get('name') or c.get('workflow') or '?')
    return sorted(set(ours)), sorted(set(theirs))


def git(args, check=True):
    r = subprocess.run(['git', '-C', str(ROOT)] + args, capture_output=True, text=True)
    if check and r.returncode: raise RuntimeError(f'git {" ".join(args)}: {r.stderr.strip()}')
    return r


def forwarded(status):
    m = re.fullmatch(r'forwarded\s+(\S+?)#(\d+)', status.strip())
    return (m.group(1), int(m.group(2))) if m else None


def landed_commit(log, n):
    """The upstream commit whose title names pull request n: '(PR #n)' or '(#n)' at the end"""
    pat = re.compile(rf'\((?:PR )?#{n}\)\s*$')
    for line in log:
        sha, _, subject = line.partition('\t')
        if pat.search(subject): return sha
    return None


def judge(row, log, pr):
    """The new status of a forwarded row and a note for the owner (None when nothing needs them). pr: gh's view of the pull request"""
    fw = forwarded(row['status'])
    if not fw: return row['status'], None
    repo, n = fw
    sha = landed_commit(log, n)
    if pr and pr.get('state') == 'MERGED': sha = sha or (pr.get('mergeCommit') or {}).get('oid')
    if sha: return f'landed {sha[:12]}', None
    if not pr: return row['status'], f'{repo}#{n}: could not be read'
    if pr.get('state') == 'CLOSED':
        comments = pr.get('comments') or []
        last = comments[-1]['body'] if comments else ''
        if (pr.get('stateReason') or '').upper() == 'NOT_PLANNED' or DECLINED.search(last):
            return f'fork-only (declined #{n})', f'{repo}#{n} was declined: {last.strip()[:200] or "closed as not planned"}'
        return row['status'], f'{repo}#{n} was closed with no landed commit: look at it'
    reviews = [r for r in (pr.get('reviews') or []) if r.get('state') == 'CHANGES_REQUESTED']
    if reviews: return row['status'], f'{repo}#{n}: changes requested'
    return row['status'], None


def applies(branch, upstream):
    """'applies', 'conflicts: <files>' or 'no branch', by a merge preview of the branch on upstream's main"""
    if git(['rev-parse', '--verify', '-q', branch], check=False).returncode: return 'no branch'
    r = git(['merge-tree', '--write-tree', '--name-only', upstream, branch], check=False)
    if r.returncode == 0: return 'applies'
    files = [l for l in r.stdout.splitlines()[1:] if l and not l.startswith(('Auto-merging', 'CONFLICT'))]
    return 'conflicts: ' + ' '.join(sorted(set(files))[:6])


_main_runs = {}
def main_failing(repo, workflow):   # whether the workflow's newest finished run on upstream's main failed (cached per run of this script)
    if (repo, workflow) not in _main_runs:
        try: runs = gh(['run', 'list', '--repo', repo, '--branch', 'main', '--workflow', workflow, '--status', 'completed', '--limit', '10', '--json', 'conclusion'])
        except RuntimeError: runs = []
        done = [r.get('conclusion') for r in runs or [] if r.get('conclusion') in ('success', 'failure')]   # a cancelled or skipped run says nothing
        _main_runs[repo, workflow] = bool(done) and done[0] == 'failure'
    return _main_runs[repo, workflow]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--update', action='store_true', help='rewrite docs/upstream.tsv with the new statuses')
    ap.add_argument('--upstream-ref', default='origin/main', help="upstream's main in this checkout (default origin/main)")
    ap.add_argument('--table', default=str(TABLE))
    ap.add_argument('--attention', help='write the rows that need the owner to this file (Markdown); none: the file is removed')
    a = ap.parse_args(argv)
    head, rows = load(a.table)
    if git(['rev-parse', '--verify', '-q', a.upstream_ref], check=False).returncode: sys.exit(f'upstream_status: no {a.upstream_ref} (git fetch it first)')
    log = git(['log', '--format=%H%x09%s', '-n', '3000', a.upstream_ref]).stdout.splitlines()
    notes, changed = [], 0
    for r in rows:
        fw = forwarded(r['status'])
        if fw:
            repo, n = fw
            try: pr = gh(['pr', 'view', str(n), '--repo', repo, '--json', 'state,mergeCommit,comments,reviews,url'])
            except RuntimeError: pr = None
            new, note = judge(r, log, pr)
            if new != r['status']: changed += 1; r['status'] = new
            if note: notes.append((r['id'], note))
            if forwarded(new) and pr and pr.get('state') == 'OPEN':
                try:
                    ours, theirs = ci(repo, n, gh_checks(repo, n), lambda wf, repo=repo: main_failing(repo, wf))
                except RuntimeError: ours, theirs = [], []
                if ours: notes.append((r['id'], f"{repo}#{n}: CI fails ({', '.join(ours)}); upstream's main passes these: ours to fix"))
                if theirs: print(f"note: {r['id']}: {repo}#{n} fails {', '.join(theirs)}, as upstream's main does: not ours")
        r['_applies'] = applies(r['branch'], a.upstream_ref) if r['branch'] not in ('', '-') and (r['status'] == 'pending' or forwarded(r['status'])) else ''
        if r['_applies'].startswith('conflicts'): notes.append((r['id'], f"{r['branch']} no longer applies on upstream's main ({r['_applies']})"))
    w = max(len(r['id']) for r in rows)
    for r in rows: print(f"{r['id']:<{w}}  {r['status']:<40}  {r['_applies']}")
    for i, note in notes: print(f'attention: {i}: {note}')
    if a.update and changed:
        save(head, [{c: r[c] for c in COLS} for r in rows], a.table); print(f'upstream_status: {changed} row(s) updated')
    if a.attention:
        p = Path(a.attention)
        if notes: p.write_text('Cartridge changes sent upstream that need a look (`docs/upstream.tsv`):\n\n' + '\n'.join(f'- **{i}**: {n}' for i, n in notes) + '\n')
        elif p.exists(): p.unlink()
    return 0


if __name__ == '__main__':
    sys.exit(main())
