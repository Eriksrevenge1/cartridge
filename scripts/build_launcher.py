#!/usr/bin/env python3
"""Build Cartridge, the Mac library app for the games the NSP script packs (dm/launcher).

It lists the nxnative Mac apps in the folders you pick and edits each game's settings, mods, cheats, controls and cloud saves, then starts the game. It writes only
what each game reads by itself (docs/frontends.md), so a game started from Finder plays the same.

    python3 scripts/build_launcher.py                 # /Applications/Cartridge.app (macOS's Apps list shows that folder's apps)
    python3 scripts/build_launcher.py --out ~/Applications
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
NAME = 'Cartridge'
OLD_NAMES = ['nxnative Launcher']   # the app's earlier names: a build moves a copy of one in the same folder to the Trash
EXE = 'cartridge'
BUNDLE_ID = 'org.nxnative.launcher'


def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f'build_launcher: {Path(str(cmd[0])).name} failed ({r.returncode})')
    return r.stdout


def icon(res, t):   # the app icon, drawn by dm/launcher/icon.swift
    iconset = Path(t) / 'AppIcon.iconset'
    run(['xcrun', 'swift', ROOT / 'dm/launcher/icon.swift', iconset])
    run(['iconutil', '-c', 'icns', '-o', res / 'AppIcon.icns', iconset])


def sources():   # the launcher's own files, with the settings model and rows the games' own settings windows use
    return sorted(p for p in (ROOT / 'dm/launcher').glob('*.swift') if p.name != 'icon.swift') + [ROOT / 'dm/ios/Sources/LauncherSettings.swift', ROOT / 'dm/ios/Sources/LauncherRow.swift']


def widget(stage, t, swiftc, sdk, minos, identity):
    """Contents/PlugIns/CartridgeWidget.appex: the Last Played widget (dm/launcher/widget). A widget must run sandboxed; it reads what Cartridge writes for it
    (<Application Support>/nxnative/cartridge) through a read-only exception. macOS runs a widget only from an app signed with an Apple developer team: ad hoc signed, chronod
    ignores the app ("restricted or unknown extension") and the extension stops at its start (_EXRunningExtension), so the widget is built only with --sign"""
    appex = stage / 'Contents/PlugIns/CartridgeWidget.appex'
    (appex / 'Contents/MacOS').mkdir(parents=True)
    run([swiftc, '-sdk', sdk, '-target', f'arm64-apple-macos{minos}', '-O', '-wmo', '-swift-version', '5', '-parse-as-library', '-application-extension',
         '-module-name', 'CartridgeWidget', '-module-cache-path', Path(t) / 'module-cache', '-o', appex / 'Contents/MacOS/CartridgeWidget',
         *sorted((ROOT / 'dm/launcher/widget').glob('*.swift')), '-framework', 'SwiftUI', '-framework', 'WidgetKit'])
    with open(appex / 'Contents/Info.plist', 'wb') as f:
        plistlib.dump({
            'CFBundleName': 'CartridgeWidget', 'CFBundleDisplayName': NAME, 'CFBundleIdentifier': f'{BUNDLE_ID}.widget', 'CFBundleExecutable': 'CartridgeWidget',
            'CFBundlePackageType': 'XPC!', 'CFBundleSupportedPlatforms': ['MacOSX'], 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'CFBundleInfoDictionaryVersion': '6.0',
            'LSMinimumSystemVersion': minos, 'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'},
        }, f)
    ent = Path(t) / 'widget.entitlements'
    with open(ent, 'wb') as f:
        plistlib.dump({'com.apple.security.app-sandbox': True,
                       'com.apple.security.temporary-exception.files.home-relative-path.read-only': ['/Library/Application Support/nxnative/cartridge/']}, f)
    run(['codesign', '--force', '--sign', identity, '--entitlements', ent, appex])


# The engine Cartridge carries (dm/launcher/Engine.swift unpacks it on the games folder's drive): the repository's files as committed paths (docs left out) in
# Resources/engine.tar, and a standalone Python (python-build-standalone, the version the user's builds run) with the NSP script's modules in Resources/python.tar.
# Xcode stays a requirement: every build compiles the host and the shaders with its compilers, which cannot be shipped (the Setup Assistant handles it)
PY_RELEASE, PY_VERSION = '20261110', '3.15.2'
PY_MODULES = ['lz4', 'capstone>=5,<6', 'fonttools', 'nsz', 'zbic']
CACHE = ROOT / 'dm/launcher/.cache'   # downloads kept between builds (git ignores it)


def bundle_engine(res):
    files = [f for f in run(['git', '-C', ROOT, 'ls-files']).splitlines() if not f.startswith('docs/')]
    lst = CACHE / 'engine-files.txt'; CACHE.mkdir(parents=True, exist_ok=True); lst.write_text('\n'.join(files) + '\n')
    # the commit the engine is, for the apps it packs (dm/mac/pack_app.py source_commit: the engine has no .git): +dirty with uncommitted changes to tracked files
    head = run(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD']).strip()
    dirty = run(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=no']).strip()
    (CACHE / 'ENGINE_COMMIT').write_text(head + ('+dirty' if dirty else '') + '\n')
    # what reaches a game's app, as one fingerprint (dm/mac/pack_app.py records it as DMEngineHash; Health.swift asks for a rebuild only when it differs, not when
    # Cartridge itself changed): the content of the host, graphics, Mac app, tools, scripts, the game profiles and the settings list
    # Split as well, so Cartridge asks to rebuild only the games an update reaches (Health.swift): ENGINE_SHAREDHASH, everything but the game profiles (the host, the
    # graphics, the tools, the shared files of dm/games, which reach every game), and ENGINE_PROFILEHASHES, one line per profile folder dm/games/<id> (id, fingerprint), which
    # reach only the games packed from them (pack_app.py records the app's profile and its fingerprint)
    import hashlib
    h, shared, per = hashlib.sha256(), hashlib.sha256(), {}
    for f in sorted(f for f in files if f.startswith(('dm/host/', 'dm/gfx/', 'dm/mac/', 'dm/tools/', 'dm/games/', 'dm/third_party/', 'scripts/build_ipa_from_nsp.py'))):
        try: data = (ROOT / f).read_bytes()
        except OSError: data = b''
        h.update(f.encode() + b'\0' + data)
        m = re.match(r'dm/games/([0-9A-Fa-f]{16})/', f)
        (per.setdefault(m[1], hashlib.sha256()) if m else shared).update(f.encode() + b'\0' + data)
    (CACHE / 'ENGINE_GAMEHASH').write_text(h.hexdigest()[:16] + '\n')
    (CACHE / 'ENGINE_SHAREDHASH').write_text(shared.hexdigest()[:16] + '\n')
    (CACHE / 'ENGINE_PROFILEHASHES').write_text(''.join(f'{k}\t{v.hexdigest()[:16]}\n' for k, v in sorted(per.items())))
    run(['tar', '-c', '-f', res / 'engine.tar', '-C', ROOT, '-T', lst])
    run(['tar', '-r', '-f', res / 'engine.tar', '-C', CACHE, 'ENGINE_COMMIT', 'ENGINE_GAMEHASH', 'ENGINE_SHAREDHASH', 'ENGINE_PROFILEHASHES'])   # appended: bsdtar takes a -C after -T before reading the list
    print(f'build_launcher: engine: {len(files)} files, {(res / "engine.tar").stat().st_size / 2**20:.0f} MB')


def engine_version(res, commit):   # the commit and the packed files' hash: a build with uncommitted changes is another version
    import hashlib
    h = hashlib.sha256()
    with open(res / 'engine.tar', 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return f'{commit}-{h.hexdigest()[:8]}'


def bundle_python(res, t):
    name = f'cpython-{PY_VERSION}+{PY_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz'
    tgz = CACHE / name
    if not tgz.is_file():
        CACHE.mkdir(parents=True, exist_ok=True)
        print(f'build_launcher: downloading {name}')
        run(['curl', '-fsSL', '-o', tgz, f'https://github.com/astral-sh/python-build-standalone/releases/download/{PY_RELEASE}/{name}'])
    ready = CACHE / f'python-{PY_VERSION}-{PY_RELEASE}.tar'   # the Python with its modules installed, made once per version and module list
    stamp = CACHE / (ready.name + '.modules')
    if not ready.is_file() or not stamp.is_file() or stamp.read_text() != ' '.join(PY_MODULES):
        work = Path(t) / 'pyroot'; work.mkdir()
        run(['tar', '-x', '-z', '-f', tgz, '-C', work])
        py = work / 'python/bin/python3'
        run([py, '-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', *PY_MODULES])
        run(['tar', '-c', '-f', ready, '-C', work, 'python'])
        stamp.write_text(' '.join(PY_MODULES))
    shutil.copyfile(ready, res / 'python.tar')
    print(f'build_launcher: python {PY_VERSION} with {", ".join(m.split(">")[0] for m in PY_MODULES)}')


def build_number():   # the count of commits: grows with every commit, so versions compare as numbers (Updates.swift)
    r = subprocess.run(['git', '-C', ROOT, 'rev-list', '--count', 'HEAD'], capture_output=True, text=True)
    return int(r.stdout.strip() or 0)


def update_repo():   # owner/name of the fork whose releases Cartridge updates from (the git remote named fork, else CARTRIDGE_UPDATE_REPO); None: no updates
    import os
    if os.environ.get('CARTRIDGE_UPDATE_REPO'): return os.environ['CARTRIDGE_UPDATE_REPO']
    r = subprocess.run(['git', '-C', ROOT, 'remote', 'get-url', 'fork'], capture_output=True, text=True)
    m = re.search(r'github\.com[:/]([^/]+/[^/.]+)', r.stdout)
    return m.group(1) if m else None


def min_os():   # the Mac host's minimum macOS (dm/mac/min_os.mk)
    m = re.search(r'^MACOS_MIN\s*:=\s*(\S+)', (ROOT / 'dm/mac/min_os.mk').read_text(), re.M)
    return m.group(1) if m else '26.6'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=Path('/Applications'), help='folder to put the app in (default /Applications, which the Apps list shows)')
    ap.add_argument('--open', action='store_true', help='start the app when it is built')
    ap.add_argument('--keep-others', action='store_true', help='leave other copies of Cartridge alone (a release build to another folder: the installed one stays)')
    ap.add_argument('--no-engine', action='store_true', help='leave the engine and its Python out (a quick build while working on Cartridge itself; it then builds games from DMRepo)')
    ap.add_argument('--sign', metavar='IDENTITY', help='sign with this Apple Development identity (security find-identity -p codesigning; a free Apple ID makes one in Xcode › Settings › '
                    'Accounts) and include the Last Played widget, which macOS runs only from an app signed with a developer team; default: ad hoc, without the widget')
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
        icon(stage / 'Contents/Resources', t)
        print(f'build_launcher: compiling {len(sources())} Swift files for macOS {minos}')
        run([swiftc, '-sdk', sdk, '-target', f'arm64-apple-macos{minos}', '-O', '-wmo', '-swift-version', '5', '-parse-as-library', '-module-name', EXE,
             '-module-cache-path', Path(t) / 'module-cache', '-o', macos / EXE, *sources(),
             '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'GameController', '-framework', 'IOKit', '-framework', 'WidgetKit'])
        if a.sign: widget(stage, t, swiftc, sdk, minos, a.sign)
        if not a.no_engine: bundle_engine(stage / 'Contents/Resources'); bundle_python(stage / 'Contents/Resources', t)
        commit = subprocess.run(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with open(stage / 'Contents/Info.plist', 'wb') as f:
            plistlib.dump({
                'CFBundleName': NAME, 'CFBundleDisplayName': NAME, 'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': EXE, 'CFBundleIconFile': 'AppIcon',
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': f'1.{build_number()}', 'CFBundleVersion': str(build_number()), 'CFBundleInfoDictionaryVersion': '6.0',
                **({'DMUpdateRepo': update_repo()} if update_repo() else {}),   # where Cartridge looks for updates (dm/launcher/Updates.swift): the fork's GitHub releases
                'LSMinimumSystemVersion': minos, 'LSArchitecturePriority': ['arm64'], 'NSHighResolutionCapable': True,
                'LSApplicationCategoryType': 'public.app-category.games', 'DMCommit': commit,
                'CFBundleURLTypes': [{'CFBundleURLName': BUNDLE_ID, 'CFBundleURLSchemes': ['cartridge']}],   # cartridge:// links (dm/launcher/Router.swift)
                **({'DMEngine': engine_version(stage / 'Contents/Resources', commit)} if not a.no_engine else {}),
                'DMRepo': str(ROOT), 'DMPython': sys.executable,   # where the Build window runs build_ipa_from_nsp.py, and with what (changeable in its settings)
            }, f)
        run(['codesign', '--force', '--sign', a.sign or '-', stage])   # ad hoc by default, as the linker signs any arm64 binary: the bundle's seal covers Info.plist too
        if app.exists():
            shutil.rmtree(app)
        stage.rename(app)
    # the same app (its bundle ID and settings) under an earlier name, or in the other Applications folder: to the Trash, so the Dock and the Apps list show one
    for o in ([] if a.keep_others else [d / f'{n}.app' for d in {a.out, Path('/Applications'), Path.home() / 'Applications'} for n in [NAME] + OLD_NAMES]):
        if o != app and o.exists():
            subprocess.run(['osascript', '-e', f'tell application "Finder" to delete POSIX file "{o}"'], capture_output=True)
            if o.exists(): shutil.rmtree(o)
            print(f'build_launcher: moved {o} to the Trash (an earlier copy)')
    print(f'build_launcher: {app}')
    if a.keep_others: return   # a release build elsewhere: not registered, so Launch Services keeps opening the installed Cartridge
    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    subprocess.run([lsregister, '-f', app], capture_output=True)   # known to Launch Services (and so the Apps list) at once, not at the next scan
    if a.open:
        subprocess.run(['open', app])


if __name__ == '__main__':
    main()
