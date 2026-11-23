#!/usr/bin/env python3
"""Publish Cartridge (with the engine it carries) as a release of your fork, which every Cartridge built from it updates from (dm/launcher/Updates.swift).

    python3 scripts/release_cartridge.py                  # a release (one channel: every Cartridge takes the newest)
    python3 scripts/release_cartridge.py --dry-run        # build and zip, publish nothing

It needs the GitHub CLI signed in (gh auth login) with the git remote named "fork" pointing at your fork, and a clean checkout: the release is the commit
your branch is at, pushed to the fork first. Cartridge is built into a work folder (on the games folder's drive when one is set: about 2 GB), not over your
installed copy, zipped as Cartridge.zip and published as cartridge-<build> (the commit count, the build number Cartridge compares), with the commit titles since the
last release as its notes, kept to what players notice (player_notes). It refuses a build number not above the newest release's: no update goes backwards.
Exit status 0 when published (or, --dry-run, built), 1 on an error.
"""
import argparse, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Release notes: commit titles by what a player notices, from their area (the part before the colon, split at "/") or a game's name in the title; the rest is counted
AREAS = [
    ('Games', {'game', 'games'}),
    ('Display, controls and sound', {'vi', 'present', 'front_mac', 'front_ios', 'input', 'hid', 'pad', 'audio', 'mac', 'ios', 'controls', 'display', 'fstep', 'link', 'screen'}),
    ('Cartridge', {'launcher'}),
]


def game_names():   # the games table's names (dm/games/README.md), for titles that name a game
    try: text = (ROOT / 'dm/games/README.md').read_text()
    except OSError: return []
    return [n for n in re.findall(r'^\| \[([^\]]+)\]\(', text, re.M) if len(n) >= 6]


def player_notes(subjects, names=(), actions=()):
    """Release notes from commit titles: grouped by AREAS, a title naming a game under Games, merges left out, the rest counted; first, under
    'What to do', the commits' Players: trailers (what a player must do, such as rebuild a game, which a title in another area would hide)"""
    groups, other = {g: [] for g, _ in AREAS}, 0
    for t in subjects:
        t = t.strip()
        if not t or t.startswith(('merge ', 'Merge ')): continue
        area = t.split(':', 1)[0] if ':' in t else ''
        words = set(area.replace('-', '/').split('/'))
        group = next((g for g, keys in AREAS if words & keys), None)
        if not group and any(n in t for n in names): group = 'Games'
        if group: groups[group].append(t)
        else: other += 1
    out = []
    acts = list(dict.fromkeys(a.strip() for a in actions if a.strip()))
    if acts: out += ['What to do:'] + [f'- {a}' for a in acts] + ['']
    for g, items in groups.items():
        if items: out += [f'{g}:'] + [f'- {t}' for t in items] + ['']
    if other: out.append(f'And {other} other engine change{"s" if other != 1 else ""} (shaders, memory, services, tools).')
    return '\n'.join(out).strip() or 'No changes players notice.'


def newest_build(tags):   # the highest cartridge-<build> among release tags, 0 when none
    return max((int(t[len('cartridge-'):]) for t in tags if re.fullmatch(r'cartridge-\d+', t)), default=0)


def run(cmd, **kw):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode: sys.exit(f'release_cartridge: {Path(str(cmd[0])).name} failed:\n{r.stdout}{r.stderr}')
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dry-run', action='store_true', help='build and zip; publish nothing')
    ap.add_argument('--notes', help='release notes (default: the commit titles since the last release)')
    a = ap.parse_args()
    if not a.dry_run and run(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=no']):
        sys.exit('release_cartridge: commit your changes first: a release is a commit')
    m = re.search(r'github\.com[:/]([^/]+/[^/.]+)', run(['git', '-C', ROOT, 'remote', 'get-url', 'fork']))
    if not m: sys.exit('release_cartridge: no git remote named fork on GitHub')
    repo, branch, sha = m.group(1), run(['git', '-C', ROOT, 'branch', '--show-current']), run(['git', '-C', ROOT, 'rev-parse', 'HEAD'])
    build = int(run(['git', '-C', ROOT, 'rev-list', '--count', 'HEAD']))
    tag = f'cartridge-{build}'
    if not a.dry_run:
        tags = run(['gh', 'release', 'list', '--repo', repo, '--limit', '100', '--json', 'tagName', '--jq', '.[].tagName']).split()
        if newest_build(tags) >= build: sys.exit(f'release_cartridge: cartridge-{newest_build(tags)} is out already, and this is build {build}: a release never goes backwards (commit something first)')
        run(['git', '-C', ROOT, 'push', 'fork', branch])
    games = subprocess.run(['defaults', 'read', 'org.nxnative.launcher', 'games.root'], capture_output=True, text=True).stdout.strip()
    base = Path(games) if games and Path(games).is_dir() else None
    with tempfile.TemporaryDirectory(dir=base, prefix='.cartridge-release-') as t:
        print(f'release_cartridge: building Cartridge 1.{build} in {t}')
        run([sys.executable, ROOT / 'scripts/build_launcher.py', '--out', t, '--keep-others'])
        zip_ = Path(t) / 'Cartridge.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', Path(t) / 'Cartridge.app', zip_])
        print(f'release_cartridge: Cartridge.zip, {zip_.stat().st_size / 2**20:.0f} MB')
        if a.dry_run:
            keep = ROOT / 'dm/launcher/.cache/Cartridge.zip'; shutil.copyfile(zip_, keep); print(f'release_cartridge: dry run: {keep}'); return
        notes = a.notes
        subprocess.run(['git', '-C', ROOT, 'fetch', '-q', 'fork', '--tags'], capture_output=True)   # the last release's tag, for the notes
        if not notes:
            prev = [x for x in run(['gh', 'release', 'list', '--repo', repo, '--limit', '30', '--json', 'tagName', '--jq', '.[].tagName']).split() if x.startswith('cartridge-')]
            since = None
            for p in prev:
                r = subprocess.run(['git', '-C', ROOT, 'rev-list', '-n', '1', p], capture_output=True, text=True)
                if r.returncode == 0: since = r.stdout.strip(); break
            log = run(['git', '-C', ROOT, 'log', '--no-merges', '--format=%s', f'{since}..HEAD' if since else '-15'])
            acts = run(['git', '-C', ROOT, 'log', '--no-merges', '--format=%(trailers:key=Players,valueonly,separator=%x0A)', f'{since}..HEAD' if since else '-15'])
            notes = player_notes(log.splitlines(), game_names(), acts.splitlines())
        cmd = ['gh', 'release', 'create', tag, zip_, '--repo', repo, '--target', sha, '--title', f'Cartridge 1.{build}', '--notes', notes]
        print(run(cmd))


if __name__ == '__main__':
    main()
