# Library and emulators

The app opens on the Library. **B** asks before leaving the app. The **+**
menu has *Platforms* (the console list) and the same sync, RetroArr scan,
System Files and Settings entries the console list has.

## Layout

- **Recently played** — games started from the app, newest first. Only games
  that are still installed are shown. Until a game has been started, a line of
  text holds the row's place.
- **Tabs** (ZL / ZR): **All** (opens first), **Installed**, **Available** (on
  a source, not on the device), **Favorites**, then your shelves.
- **Platforms** — each tab groups its games by platform. A platform is a label
  and one row of games that scrolls sideways: installed games first, then the
  ones still on a source, each by title. Moving up or down returns to the game
  a row was left on.
- Platforms start expanded. **A** on a platform's label collapses or expands
  it, and the **+** menu has *Collapse all / Expand all platforms*. Each tab
  remembers what it has collapsed until you leave the Library.
- **Outlines** — a green glow marks a game that is installed and ready to
  play, a light blue one a game that is only on a source.
- Search (**Y**) and shelves show one plain grid.
- **L / R** change the tile size. Without a saved size, a row shows as many
  whole covers as the screen comfortably holds, plus a slice of the next one.

## Sizes and storage

- **On a tile** — what the game takes on the device, measured from its files:
  a folder game counts everything in its folder, a disc game the track files
  its `.cue` or `.gdi` sheet names. The mark beside the number brightens with
  the size. A game that is only on a source shows the size the source lists,
  with a download arrow. RomM lists sizes; RetroArr's game list does not, so
  those tiles carry no size until the game is installed.
- **Beside a platform's name** — what the installed games listed under it
  take together, so it follows the tab and the search. Five bars fill up and
  brighten in fixed steps: under 250 MB, up to 1 GB, 4 GB, 16 GB, and above.
- **Beside the title** — the storage the ROM folders are on, as one bar:
  installed games, everything else in use, and free space, each with its
  amount. Narrow screens drop *Other* first, then the bar.

The ROM folders are measured in the background when the Library opens and
again after a download, an uninstall or a change in a ROM folder, so sizes
appear a moment after the tiles.

## Uninstalling several games

1. **X** (or a long press) starts multi-select and marks the game under the
   cursor.
2. **A** marks or unmarks a game; **X** on a platform marks all of its
   installed games.
3. **Y** asks for confirmation, then deletes the marked games' files. A disc
   game's `.cue` or `.gdi` sheet takes its track files with it.
4. **B** cancels.

Uninstalled games stay in the library under **Available** while their source
still has them. Games that only existed on the device are removed from the
library with their file.

## Emulators

**Settings → Emulators** sets the emulator per system; the **Emulator** button
on a game's page overrides it for that game. Without a choice, the first
installed emulator for the system is used, then Android's "Open with".

Emulators are matched by package name, so a build that installs under a
different name needs its own entry in `lib/services/emulator_service.dart`.
Eden's nightly builds (`dev.eden.eden_emulator.nightly`) are listed as
**Eden Nightly**.

## Updates and DLC

RetroArr links files from a platform's `Patches`, `Updates` or `DLC` folder to
their game and lists them with a file type of `Patch` or `DLC`. The app
downloads a game's main files only; updates and DLC are not downloaded or
installed yet.
