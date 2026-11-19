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

Each game has five pages:

- **Settings**: the game's settings, as its own settings window shows them ([Settings](settings.md)). A setting an `env.txt` fixes is shown greyed out.
- **Mods**: add a mod's folder (a Switch SD card's `atmosphere` folder, a folder with `romfs` in it, or the game's files themselves), turn mods on and off, and choose which wins where two change the same file. Mods that change the game's code (`exefs`, IPS patches) are not supported.
- **Cheats**: add an Atmosphère cheat file for the game's version (the page shows its build ID) and turn cheats on and off. Typed values and run-once cheats are set in the game's own Cheats window.
- **Controls**: for every game or for this game only. Remap a controller's buttons (or swap its sticks), rebind the keyboard, and make the mouse the camera stick: click in the game to capture the pointer, press Escape to give it back. A pair of Joy-Con 2 splits into two players when you hold SL and SR on one of them ([Pairs and singles](playing.md#switch-2-controllers-mac)).
- **Saves**: the cloud saves folder (one folder can serve every game), the save and log folders, and the game's `env.txt`.

Changes take effect at the game's next start.

## Building games

**Build Games** (the hammer) runs the packing script for you. Choose the game's NSP folder, a dump folder or a Switch 2 game's `.nup` file, and build a Mac app, an IPA for iPhone and iPad, or both. NSPs need your `prod.keys`. A finished Mac app joins the library; a finished IPA is ready to install. **Rebuild** on a game's page builds it again from the same files, after a game update or a newer nxnative. If the launcher was moved or nxnative lives elsewhere, set the repository folder and Python in the launcher's Settings › Building.

## Installing on an iPhone or iPad

The IPAs run on an iPhone with an A17 Pro or later and an iPad with an M1 or later. **Install on iPhone or iPad** signs an IPA with your own Apple ID and installs it over the cable:

1. Once: sign in to your Apple ID in Xcode › Settings › Accounts, and put your team's ID (10 characters) in the install window. `brew install xcodegen` if you have not.
2. Connect the device, unlock it and trust this Mac. Developer Mode must be on (Settings › Privacy & Security › Developer Mode).
3. Pick the device and the IPA and click **Install**. On the device, trust your certificate once: Settings › General › VPN & Device Management.

The first install of a game asks Xcode for a signing profile, which needs the internet. A free Apple ID's apps stop opening after 7 days (install again), and it cannot give the bigger games the increased memory limit they need; a paid developer account can. An IPA built with the game files kept out of it (`--romfs separate`) gets them copied after the install; for a large game, `brew install libimobiledevice` first. You can still use AltStore, SideStore, Sideloadly or LiveContainer instead ([Install](../README.md#install)).
