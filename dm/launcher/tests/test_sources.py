"""Cartridge's launcher readers (dm/launcher/Sources.swift) on a fixture home holding every launcher's files, those this Mac has and those it has not: Steam (Mac and in a
CrossOver bottle), Battle.net, Epic (Mac and bottle), GOG (Mac app and bottle registry), Heroic, itch, Ubisoft and Amazon (bottle), CrossOver Start menu programs, Whisky
pins, Mac App Store and other Mac game apps. Compiled with sources_check.swift and run on macOS."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)


def field(num, data):   # a length-delimited protobuf field
    return varint(num << 3 | 2) + varint(len(data)) + data


def app(path, name, category=None, bundle=None, receipt=False, gog=None):
    c = path / 'Contents'
    c.mkdir(parents=True)
    info = {'CFBundleName': name, 'CFBundleIdentifier': bundle or 'com.example.' + name.replace(' ', '').lower()}
    if category: info['LSApplicationCategoryType'] = category
    (c / 'Info.plist').write_bytes(plistlib.dumps(info))
    if receipt: (c / '_MASReceipt').mkdir()
    if gog:
        (c / 'Resources').mkdir()
        (c / 'Resources' / f'goggame-{gog[0]}.info').write_text(json.dumps({'gameId': gog[0], 'name': gog[1]}))


def build(root):
    home, shared, apps = root / 'home', root / 'shared', root / 'Applications'
    sup = home / 'Library/Application Support'
    # Steam on the Mac: one library elsewhere, a Mac game, a Windows-only game (no app: left out), Steam's runtime (left out)
    lib = root / 'SteamLib'
    (sup / 'Steam/steamapps').mkdir(parents=True)
    (sup / 'Steam/steamapps/libraryfolders.vdf').write_text(f'"libraryfolders"\n{{\n "0"\n {{\n  "path" "{sup / "Steam"}"\n }}\n "1"\n {{\n  "path" "{lib}"\n }}\n}}\n')
    (lib / 'steamapps/common').mkdir(parents=True)
    for appid, name, d, flags in [(892970, 'Valheim', 'Valheim', 4), (1245620, 'Elden Ring', 'ELDEN RING', 4), (228980, 'Steamworks Common Redistributables', 'Steamworks Shared', 4), (570, 'Dota 2', 'dota 2 beta', 2)]:
        (lib / f'steamapps/appmanifest_{appid}.acf').write_text(f'"AppState"\n{{\n "appid" "{appid}"\n "name" "{name}"\n "installdir" "{d}"\n "StateFlags" "{flags}"\n "LastPlayed" "1700000000"\n}}\n')
        (lib / 'steamapps/common' / d).mkdir()
    app(lib / 'steamapps/common/Valheim/valheim.app', 'valheim', bundle='com.irongate.valheim')
    (sup / 'Steam/userdata/42/config').mkdir(parents=True)
    (sup / 'Steam/userdata/42/config/localconfig.vdf').write_text('"UserLocalConfigStore"\n{\n "Software"\n {\n  "Valve"\n  {\n   "Steam"\n   {\n    "apps"\n    {\n     "892970"\n     {\n      "LastPlayed" "1795384267"\n      "Playtime" "2059"\n     }\n    }\n   }\n  }\n }\n}\n')
    # Battle.net on the Mac
    wow = root / 'Battle Net/World of Warcraft'
    app(wow / '_retail_/World of Warcraft.app', 'Wow')
    app(wow / 'World of Warcraft Launcher.app', 'World of Warcraft Launcher')
    (shared / 'Battle.net/Agent').mkdir(parents=True)
    db = field(1, field(1, b'battle.net') + field(3, field(1, b'/Applications/Battle.net.app'))) + field(1, field(1, b'wow') + field(2, b'wow') + field(3, field(1, str(wow).encode())))
    (shared / 'Battle.net/Agent/product.db').write_bytes(db)
    (sup / 'Battle.net').mkdir(parents=True)
    (sup / 'Battle.net/Battle.net.config').write_text(json.dumps({'Games': {'wow': {'LastPlayed': '1795269432'}}}))
    # Epic on the Mac: a game and Unreal Engine (left out)
    man = sup / 'Epic/EpicGamesLauncher/Data/Manifests'
    man.mkdir(parents=True)
    (man / 'A.item').write_text(json.dumps({'DisplayName': 'Fortnite', 'AppName': 'Fortnite', 'CatalogNamespace': 'fn', 'CatalogItemId': 'abc', 'InstallLocation': str(root / 'Epic/Fortnite'), 'AppCategories': ['public', 'games']}))
    (man / 'B.item').write_text(json.dumps({'DisplayName': 'Unreal Engine', 'AppName': 'UE_5', 'InstallLocation': '/x', 'AppCategories': ['engines']}))
    # Heroic: Epic, GOG and Amazon through it, and a game added by hand
    h = sup / 'heroic'
    (h / 'legendaryConfig/legendary').mkdir(parents=True); (h / 'gog_store').mkdir(); (h / 'nile_config/nile').mkdir(parents=True); (h / 'sideload_apps').mkdir(); (h / 'store_cache').mkdir()
    (h / 'legendaryConfig/legendary/installed.json').write_text(json.dumps({'Sugar': {'title': 'Hades', 'install_path': '/Games/Hades'}}))
    (h / 'gog_store/installed.json').write_text(json.dumps({'installed': [{'appName': '1207658924', 'install_path': '/Games/Witcher', 'platform': 'windows'}]}))
    (h / 'store_cache/gog_library.json').write_text(json.dumps({'games': [{'app_name': '1207658924', 'title': 'The Witcher: Enhanced Edition'}]}))
    (h / 'nile_config/nile/installed.json').write_text(json.dumps([{'id': 'amzn1.adg.product.1', 'path': '/Games/Quake'}]))
    (h / 'store_cache/nile_library.json').write_text(json.dumps({'games': [{'app_name': 'amzn1.adg.product.1', 'title': 'Quake'}]}))
    (h / 'sideload_apps/library.json').write_text(json.dumps({'games': [{'app_name': 'side1', 'title': 'Celeste', 'is_installed': True}]}))
    # itch
    (sup / 'itch/db').mkdir(parents=True)
    c = sqlite3.connect(sup / 'itch/db/butler.db')
    c.executescript("CREATE TABLE games(id INTEGER, title TEXT); CREATE TABLE install_locations(id TEXT, path TEXT);"
                    "CREATE TABLE caves(id TEXT, game_id INTEGER, install_folder_name TEXT, install_location_id TEXT, last_touched_at TEXT, seconds_run INTEGER);"
                    "INSERT INTO games VALUES (7, 'A Short Hike'); INSERT INTO install_locations VALUES ('loc', '/Games/itch');"
                    "INSERT INTO caves VALUES ('cave1', 7, 'a-short-hike', 'loc', '2026-11-01T10:00:00Z', 5400);")
    c.commit(); c.close()
    # a CrossOver bottle with Steam, Epic, GOG, Ubisoft and Amazon inside, a game installed straight into it, and the launchers' own menu entries
    b = sup / 'CrossOver/Bottles/Games'
    dc = b / 'drive_c'
    (b / 'dosdevices').mkdir(parents=True)
    os.symlink('../drive_c', b / 'dosdevices/c:')
    (b / 'cxbottle.conf').write_text('[Bottle]\n"Template" = "win10_64"\n')
    steam = dc / 'Program Files (x86)/Steam'
    (steam / 'steamapps/common/Cyberpunk 2077').mkdir(parents=True)
    (steam / 'steamapps/libraryfolders.vdf').write_text('"libraryfolders"\n{\n "0"\n {\n  "path" "C:\\\\Program Files (x86)\\\\Steam"\n }\n}\n')
    (steam / 'steamapps/appmanifest_1091500.acf').write_text('"AppState"\n{\n "appid" "1091500"\n "name" "Cyberpunk 2077"\n "installdir" "Cyberpunk 2077"\n "StateFlags" "4"\n}\n')
    (dc / 'ProgramData/Epic/EpicGamesLauncher/Data/Manifests').mkdir(parents=True)
    (dc / 'ProgramData/Epic/EpicGamesLauncher/Data/Manifests/C.item').write_text(json.dumps({'DisplayName': 'Alan Wake 2', 'AppName': 'Dodo', 'CatalogNamespace': 'ns', 'CatalogItemId': 'it', 'InstallLocation': 'C:\\Program Files\\Epic Games\\AlanWake2'}))
    (dc / 'Ubisoft Games/Anno 1800').mkdir(parents=True)
    (b / 'system.reg').write_text('WINE REGISTRY Version 2\n\n'
                                   '[Software\\\\Wow6432Node\\\\GOG.com\\\\Games\\\\1495134320] 1700000000\n"gameID"="1495134320"\n"gameName"="Cyberpunk 2077 GOG"\n"path"="C:\\\\GOG Games\\\\Cyberpunk 2077"\n"exe"="C:\\\\GOG Games\\\\Cyberpunk 2077\\\\bin\\\\x64\\\\Cyberpunk2077.exe"\n\n'
                                   '[Software\\\\Wow6432Node\\\\Ubisoft\\\\Launcher\\\\Installs\\\\4553] 1700000000\n"InstallDir"="C:/Ubisoft Games/Anno 1800/"\n\n')
    (b / 'user.reg').write_text('WINE REGISTRY Version 2\n\n[Software\\\\Valve\\\\Steam] 1700000000\n"SteamPath"="c:/program files (x86)/steam"\n')
    amz = dc / 'users/crossover/AppData/Local/Amazon Games/Data/Games/Sql'
    amz.mkdir(parents=True)
    c = sqlite3.connect(amz / 'GameInstallInfo.sqlite')
    c.executescript("CREATE TABLE DbSet(Id TEXT, ProductTitle TEXT, InstallDirectory TEXT, Installed INTEGER);"
                    "INSERT INTO DbSet VALUES ('amzn1.adg.product.2', 'Tomb Raider', 'C:\\Amazon Games\\Library\\Tomb Raider', 1);"
                    "INSERT INTO DbSet VALUES ('amzn1.adg.product.3', 'Not Installed', 'C:\\x', 0);")
    c.commit(); c.close()
    (b / 'cxmenu.conf').write_text('[StartMenu.C^3A_ProgramData_Microsoft_Windows_Start+Menu/Programs/Steam/Steam.lnk]\n"Type" = "Windows"\n'
                                   '[StartMenu.C^3A_ProgramData_Microsoft_Windows_Start+Menu/Programs/Hollow Knight/Hollow Knight.lnk]\n"Type" = "Windows"\n'
                                   '[StartMenu.C^3A_ProgramData_Microsoft_Windows_Start+Menu/Programs/Hollow Knight/Uninstall Hollow Knight.lnk]\n"Type" = "Windows"\n'
                                   '[Desktop.C^3A_users_Public_Desktop/Hollow Knight.lnk]\n"Type" = "Windows"\n')
    # a Whisky bottle with a pinned game and a pinned launcher
    wb = home / 'Library/Containers/com.isaacmarovitz.Whisky/Bottles/UUID-1'
    (wb / 'drive_c').mkdir(parents=True)
    (wb / 'Metadata.plist').write_bytes(plistlib.dumps({'info': {'name': 'Whisky Games'}, 'pins': [{'name': 'Stardew Valley', 'url': 'file:///W/drive_c/Stardew/Stardew%20Valley.exe'}, {'name': 'Steam', 'url': 'file:///W/steam.exe'}]}))
    # Mac apps: an App Store game, a game app, a GOG game, a launcher and a non-game (both left out), an nxnative app (the library has it)
    app(apps / 'Sky.app', 'Sky', 'public.app-category.adventure-games', receipt=True)
    app(apps / 'Games/Baldur.app', "Baldur's Gate 3", 'public.app-category.role-playing-games')
    app(apps / 'Disco.app', 'Disco', None, gog=('1771589310', 'Disco Elysium'))
    app(apps / 'Steam.app', 'Steam', 'public.app-category.games', bundle='com.valvesoftware.steam')
    app(apps / 'Notes.app', 'Notes', 'public.app-category.productivity')
    app(apps / 'Mario.app', 'Mario', 'public.app-category.games')
    p = apps / 'Mario.app/Contents/Info.plist'
    p.write_bytes(plistlib.dumps({**plistlib.loads(p.read_bytes()), 'DMTitleID': '0100000000010000'}))
    (root / 'CrossOver.app').mkdir()
    return home, shared, apps


@unittest.skipUnless(shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class SourcesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        home, shared, apps = build(root)
        exe = root / 'sources_check'
        r = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(root / 'mc'), '-o', str(exe),
                            str(REPO / 'dm/launcher/Sources.swift'), str(HERE / 'sources_check.swift')], capture_output=True, text=True, timeout=600)
        assert r.returncode == 0, r.stdout + r.stderr
        r = subprocess.run([str(exe), str(home), str(shared), str(apps), str(root / 'CrossOver.app')], capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stdout + r.stderr
        cls.games = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        cls.by = {g['name']: g for g in cls.games}
        cls.root = root

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def test_every_launcher_is_read(self):
        want = {'Valheim': 'Steam', 'World of Warcraft': 'Battle.net', 'Fortnite': 'Epic Games', 'Hades': 'Epic Games', 'The Witcher: Enhanced Edition': 'GOG',
                'Quake': 'Amazon Games', 'Celeste': 'Heroic', 'A Short Hike': 'itch.io', 'Cyberpunk 2077': 'Steam', 'Alan Wake 2': 'Epic Games',
                'Cyberpunk 2077 GOG': 'GOG', 'Anno 1800': 'Ubisoft Connect', 'Tomb Raider': 'Amazon Games', 'Hollow Knight': 'CrossOver',
                'Stardew Valley': 'Whisky', 'Sky': 'App Store', "Baldur's Gate 3": 'Mac', 'Disco Elysium': 'GOG'}
        for name, store in want.items():
            self.assertIn(name, self.by, f'{name} not found; found {sorted(self.by)}')
            self.assertEqual(self.by[name]['store'], store, name)

    def test_what_is_left_out(self):
        for name in ['Elden Ring', 'Steamworks Common Redistributables', 'Dota 2', 'Unreal Engine', 'Steam', 'Notes', 'Mario', 'Not Installed', 'Uninstall Hollow Knight', 'battle.net']:
            self.assertNotIn(name, self.by, name)
        self.assertEqual(sum(g['name'] == 'Hollow Knight' for g in self.games), 1, 'a Start menu and a desktop shortcut are one game')

    def test_launches(self):
        self.assertEqual(self.by['Valheim']['launch'], {'url': 'steam://rungameid/892970'})
        self.assertIn('--exec=launch WoW', self.by['World of Warcraft']['launch']['process'])
        self.assertEqual(self.by['Fortnite']['launch'], {'url': 'com.epicgames.launcher://apps/fn%3Aabc%3AFortnite?action=launch&silent=true'})
        self.assertEqual(self.by['Hades']['launch'], {'url': 'heroic://launch?appName=Sugar&runner=legendary'})
        self.assertEqual(self.by['A Short Hike']['launch'], {'url': 'itch://caves/cave1/launch'})
        cp = self.by['Cyberpunk 2077']
        self.assertEqual((cp['runtime'], cp['bottle']), ('CrossOver', 'Games'))
        self.assertEqual(cp['launch'], {'crossover': 'Games', 'args': ['c:\\program files (x86)\\steam\\steam.exe', '-silent', 'steam://rungameid/1091500']})
        self.assertEqual(self.by['Anno 1800']['launch']['args'], ['C:\\windows\\system32\\start.exe', 'uplay://launch/4553/0'])
        self.assertEqual(self.by['Cyberpunk 2077 GOG']['launch']['args'], ['C:\\GOG Games\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe'])
        self.assertEqual(self.by['Hollow Knight']['launch']['args'][1], 'C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Hollow Knight\\Hollow Knight.lnk')
        self.assertEqual(self.by['Stardew Valley']['launch'], {'whisky': '/W/drive_c/Stardew/Stardew Valley.exe'})
        self.assertTrue(self.by['Sky']['launch']['app'].endswith('Sky.app'))

    def test_windows_paths_land_in_the_bottle(self):
        self.assertTrue(self.by['Cyberpunk 2077']['folder'].lower().endswith('dosdevices/c:/program files (x86)/steam/steamapps/common/cyberpunk 2077'))   # APFS ignores case, as Windows does
        self.assertTrue(self.by['Anno 1800']['folder'].endswith('dosdevices/c:/Ubisoft Games/Anno 1800'))

    def test_play_time(self):
        self.assertEqual(self.by['Valheim']['seconds'], 2059 * 60)
        self.assertEqual(self.by['Valheim']['last'], 1795384267)
        self.assertEqual(self.by['World of Warcraft']['last'], 1795269432)
        self.assertEqual(self.by['A Short Hike']['seconds'], 5400)


if __name__ == '__main__':
    unittest.main()
