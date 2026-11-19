# nxnative Launcher

nxnative Launcher is a Mac app that keeps your games in one library. From it you can build games, change each game's settings, mods, cheats and controls, play the Mac apps, and install the IPAs on an iPhone or iPad over USB. It writes only what each game reads by itself ([Front ends](frontends.md)), so a game you start from Finder or the Dock plays the same as from the launcher.

## Getting it

With the tools of [Build from the command line](../README.md#build-from-the-command-line) installed:

```
python3 scripts/build_launcher.py --open
```

It puts **nxnative Launcher.app** in `~/Applications` (`--out` names another folder). Build it again after you update nxnative.

## The library

Add the folders that hold your games (the toolbar's folder button, or drag a folder onto the list). The launcher lists every nxnative Mac app in them, three folder levels deep. A controller works too: up and down pick a game, A plays it, L and R change the page.

**All Games** shows every game as a tile with its cover: click a tile to open its page, double-click it (or its Play button) to play. Search the sidebar by name or title ID, and sort by recently played, name or play time (the toolbar's sort menu). A game's cover is its own icon, the square key art the game carries, drawn as a tile as on the console; to use another picture, choose **Find Cover…** on its tile or header (right-click): the launcher looks up the game's title ID on nintendo.com (only then, and nothing else is sent) and shows the square key art Nintendo Europe has for it and the eShop's banner and screenshots, to pick one. A Switch 2 Edition has no store page of its own, so the sheet offers a web image search instead. **Choose Cover…** takes an image file, or drop one on the game's header. The launcher counts the time you play each game it starts (a game started from Finder is not counted) and shows it on the tile and the page. Settings › Library sets the appearance: System, Light or Dark.

Each game's page opens with its cover, name, version and play time, and **Rebuild** and **Play**. It has five pages:

- **Settings**: the game's settings, as its own settings window shows them ([Settings](settings.md)). A setting an `env.txt` fixes is shown greyed out. A setting you moved off the value the game was tested with is marked with a dot and shows that value, with **Use Tested** beside it.
- **Mods**: add a mod's folder (a Switch SD card's `atmosphere` folder, a folder with `romfs` in it, or the game's files themselves), turn mods on and off, and choose which wins where two change the same file. Code patches (`exefs` IPS and pchtxt files for the game's own build) are applied; mods that add a code module (exlaunch, skyline) are not supported.
- **Cheats**: add an Atmosphère cheat file for the game's version (the page shows its build ID) and turn cheats on and off. Typed values and run-once cheats are set in the game's own Cheats window.
- **Controls**: for every game or for this game only. Remap a controller's buttons (or swap its sticks), rebind the keyboard, and make the mouse the camera stick: click in the game to capture the pointer, press Escape to give it back. A pair of Joy-Con 2 splits into two players when you hold SL and SR on one of them ([Pairs and singles](playing.md#switch-2-controllers-mac)).
- **Saves**: **Back Up Save…** writes the save as a `.zip`; **Restore Save…** takes one back (or a save folder), after moving the current save to the game's `save-backups` folder. Also the cloud saves folder (one folder can serve every game), the save and log folders, and the game's `env.txt`.

Changes take effect at the game's next start.

**Console mode** (the toolbar's TV button, View › Console Mode, ⇧⌘K, or a controller's Menu button) shows the library full screen for playing from the couch: a row of game tiles over the chosen game's art, with its name and play time. Left and right (the D-pad, the left stick or the arrow keys) choose a game, A or Return plays it, B or Escape leaves.

## Building games

**Build Games** (the hammer) runs the packing script for you. Choose the game's NSP folder, a dump folder or a Switch 2 game's `.nup` file, and build a Mac app, an IPA for iPhone and iPad, or both. NSPs need your `prod.keys`. A finished Mac app joins the library; a finished IPA is ready to install. **Rebuild** on every game's page builds it again, after a game update or a newer nxnative: from the files the launcher built it from, else from the files beside the app (its `.nup`, NSPs, dump folder or `<title ID>_build` folder, where the packing script puts the app, so a game packed from a terminal or by another front end has it too), else from the files you choose. An icon you gave a game without one of its own is kept. It is greyed out while the game runs. To add an update or DLC, choose **Add Update or DLC and Rebuild…** from the arrow beside **Rebuild** (or the game's right-click menu): the files you choose are copied into the game's NSP folder (on the same APFS drive a copy takes no space), then the game is built again. The Build Games window lists a folder's base game, updates and DLC and adds more the same way. A game built from a `.nup` or a dump folder takes its update another way, which the launcher explains. **Rebuild All Games** (hold the toolbar's hammer, or its arrow) rebuilds every game whose files are known or beside its app, one after the other, after you update nxnative; it names the games it cannot. A build does not start with less than 5 GB free on its drive, and warns below 30 GB; the Build Games window shows the free space. If the launcher was moved or nxnative lives elsewhere, set the repository folder and Python in the launcher's Settings › Building.

## Installing on an iPhone or iPad

The IPAs run on an iPhone with an A17 Pro or later and an iPad with an M1 or later. **Install on iPhone or iPad** signs an IPA with your own Apple ID and installs it over the cable:

1. Once: sign in to your Apple ID in Xcode › Settings › Accounts. The install window finds your team's ID (10 characters) by itself; if it does not, select your Apple ID there, click **Manage Certificates…**, add an **Apple Development** certificate with **+**, and click **Find**. `brew install xcodegen` if you have not.
2. Connect the device, unlock it and trust this Mac. Developer Mode must be on (Settings › Privacy & Security › Developer Mode).
3. Pick the device and the IPA and click **Install**. On the device, trust your certificate once: Settings › General › VPN & Device Management.

The first install of a game asks Xcode for a signing profile, which needs the internet. A free Apple ID works, Increased Memory Limit included (a free Personal Team was given it for [this game's iPhone test](../dm/games/010029B0118E8000/README.md)), with Apple's limits: its apps stop opening after 7 days (install again: the save and game files stay), and only a few such apps can be on a device at once. A paid developer account has neither limit. An IPA built with the game files kept out of it (`--romfs separate`) gets them copied after the install; for a large game, `brew install libimobiledevice` first. You can still use AltStore, SideStore, Sideloadly or LiveContainer instead ([Install](../README.md#install)).
