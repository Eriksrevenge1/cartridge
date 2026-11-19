#!/usr/bin/env python3
"""Build nxnative Launcher, the Mac library app for the games the NSP script packs (dm/launcher).

It lists the nxnative Mac apps in the folders you pick and edits each game's settings, mods, cheats, controls and cloud saves, then starts the game. It writes only
what each game reads by itself (docs/frontends.md), so a game started from Finder plays the same.

    python3 scripts/build_launcher.py                 # ~/Applications/nxnative Launcher.app
    python3 scripts/build_launcher.py --out /Applications
    python3 scripts/build_launcher.py --open          # and start it

Needs Xcode (the version README names) on a Mac with Apple silicon.
"""
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = 'nxnative Launcher'
BUNDLE_ID = 'org.nxnative.launcher'


def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f'build_launcher: {Path(str(cmd[0])).name} failed ({r.returncode})')
    return r.stdout


def sources():   # the launcher's own files, with the settings model and rows the games' own settings windows use
    return sorted((ROOT / 'dm/launcher').glob('*.swift')) + [ROOT / 'dm/ios/Sources/LauncherSettings.swift', ROOT / 'dm/ios/Sources/LauncherRow.swift']


def min_os():   # the Mac host's minimum macOS (dm/mac/min_os.mk)
    m = re.search(r'^MACOS_MIN\s*:=\s*(\S+)', (ROOT / 'dm/mac/min_os.mk').read_text(), re.M)
    return m.group(1) if m else '26.6'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=Path.home() / 'Applications', help='folder to put the app in (default ~/Applications)')
    ap.add_argument('--open', action='store_true', help='start the app when it is built')
    a = ap.parse_args()
    if sys.platform != 'darwin':
        sys.exit('build_launcher: needs macOS')
    swiftc = run(['xcrun', '--find', 'swiftc']).strip()
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    minos = min_os()
    a.out.mkdir(parents=True, exist_ok=True)
    app = a.out / f'{NAME}.app'
    with tempfile.TemporaryDirectory(dir=a.out) as t:
        stage = Path(t) / f'{NAME}.app'
        macos = stage / 'Contents/MacOS'; macos.mkdir(parents=True)
        (stage / 'Contents/Resources').mkdir()
        print(f'build_launcher: compiling {len(sources())} Swift files for macOS {minos}')
        run([swiftc, '-sdk', sdk, '-target', f'arm64-apple-macos{minos}', '-O', '-swift-version', '5', '-parse-as-library',
             '-module-cache-path', Path(t) / 'module-cache', '-o', macos / 'nxnative-launcher', *sources(),
             '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'GameController'])
        commit = subprocess.run(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with open(stage / 'Contents/Info.plist', 'wb') as f:
            plistlib.dump({
                'CFBundleName': NAME, 'CFBundleDisplayName': NAME, 'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'nxnative-launcher',
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'CFBundleInfoDictionaryVersion': '6.0',
                'LSMinimumSystemVersion': minos, 'LSArchitecturePriority': ['arm64'], 'NSHighResolutionCapable': True,
                'LSApplicationCategoryType': 'public.app-category.games', 'DMCommit': commit,
            }, f)
        run(['codesign', '--force', '--sign', '-', stage])   # ad hoc, as the linker signs any arm64 binary: the bundle's seal covers Info.plist too
        if app.exists():
            shutil.rmtree(app)
        stage.rename(app)
    print(f'build_launcher: {app}')
    if a.open:
        subprocess.run(['open', app])


if __name__ == '__main__':
    main()
