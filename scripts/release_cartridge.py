#!/usr/bin/env python3
"""Publish Cartridge (with the engine it carries) as a release of your fork, which every Cartridge built from it updates from (dm/launcher/Updates.swift).

    python3 scripts/release_cartridge.py                  # a Stable release
    python3 scripts/release_cartridge.py --experimental   # a pre-release: only the Experimental channel takes it
    python3 scripts/release_cartridge.py --dry-run        # build and zip, publish nothing

It needs the GitHub CLI signed in (gh auth login) with the git remote named "fork" pointing at your fork, and a clean checkout: the release is the commit
your branch is at, pushed to the fork first. Cartridge is built into a work folder (on the games folder's drive when one is set: about 2 GB), not over your
installed copy, zipped as Cartridge.zip and published as cartridge-<build> (the commit count, the build number Cartridge compares), with the commit titles since the
last release as its notes. Exit status 0 when published (or, --dry-run, built), 1 on an error.
"""
import argparse, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(cmd, **kw):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode: sys.exit(f'release_cartridge: {Path(str(cmd[0])).name} failed:\n{r.stdout}{r.stderr}')
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--experimental', action='store_true', help='a pre-release, for the Experimental channel only')
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
        if subprocess.run(['gh', 'release', 'view', tag, '--repo', repo], capture_output=True).returncode == 0: sys.exit(f'release_cartridge: {tag} exists already: commit something first')
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
            log = run(['git', '-C', ROOT, 'log', '--format=- %s', f'{since}..HEAD' if since else '-15'])
            notes = 'Changes:\n' + log
        cmd = ['gh', 'release', 'create', tag, zip_, '--repo', repo, '--target', sha, '--title', f'Cartridge 1.{build}' + (' (experimental)' if a.experimental else ''), '--notes', notes]
        if a.experimental: cmd.append('--prerelease')
        print(run(cmd))


if __name__ == '__main__':
    main()
