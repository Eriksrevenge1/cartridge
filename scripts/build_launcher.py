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


def min_os():   # the Mac host's minimum macOS (dm/mac/min_os.mk)
    m = re.search(r'^MACOS_MIN\s*:=\s*(\S+)', (ROOT / 'dm/mac/min_os.mk').read_text(), re.M)
    return m.group(1) if m else '26.6'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=Path('/Applications'), help='folder to put the app in (default /Applications, which the Apps list shows)')
    ap.add_argument('--open', action='store_true', help='start the app when it is built')
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
        commit = subprocess.run(['git', '-C', ROOT, 'rev-parse', '--short=12', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with open(stage / 'Contents/Info.plist', 'wb') as f:
            plistlib.dump({
                'CFBundleName': NAME, 'CFBundleDisplayName': NAME, 'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': EXE, 'CFBundleIconFile': 'AppIcon',
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'CFBundleInfoDictionaryVersion': '6.0',
                'LSMinimumSystemVersion': minos, 'LSArchitecturePriority': ['arm64'], 'NSHighResolutionCapable': True,
                'LSApplicationCategoryType': 'public.app-category.games', 'DMCommit': commit,
                'CFBundleURLTypes': [{'CFBundleURLName': BUNDLE_ID, 'CFBundleURLSchemes': ['cartridge']}],   # cartridge:// links (dm/launcher/Router.swift)
                'DMRepo': str(ROOT), 'DMPython': sys.executable,   # where the Build window runs build_ipa_from_nsp.py, and with what (changeable in its settings)
            }, f)
        run(['codesign', '--force', '--sign', a.sign or '-', stage])   # ad hoc by default, as the linker signs any arm64 binary: the bundle's seal covers Info.plist too
        if app.exists():
            shutil.rmtree(app)
        stage.rename(app)
    # the same app (its bundle ID and settings) under an earlier name, or in the other Applications folder: to the Trash, so the Dock and the Apps list show one
    for o in [d / f'{n}.app' for d in {a.out, Path('/Applications'), Path.home() / 'Applications'} for n in [NAME] + OLD_NAMES]:
        if o != app and o.exists():
            subprocess.run(['osascript', '-e', f'tell application "Finder" to delete POSIX file "{o}"'], capture_output=True)
            if o.exists(): shutil.rmtree(o)
            print(f'build_launcher: moved {o} to the Trash (an earlier copy)')
    print(f'build_launcher: {app}')
    lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    subprocess.run([lsregister, '-f', app], capture_output=True)   # known to Launch Services (and so the Apps list) at once, not at the next scan
    if a.open:
        subprocess.run(['open', app])


if __name__ == '__main__':
    main()
