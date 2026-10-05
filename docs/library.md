# Library and emulators

The app opens on the Library. **B** goes back to the console list (settings,
sync and the RetroArr scan live in its **+** menu).

## Layout

- **Recently played** — games started from the app, newest first. Only games
  that are still installed are shown; the row appears after the first launch.
- **Tabs** (ZL / ZR): **Installed**, **Available** (on a source, not on the
  device), **All**, **Favorites**, then your shelves.
- **Platforms** — each tab groups its games by platform. Platforms start
  collapsed; **A** on a platform expands or collapses it, and the **+** menu has
  *Expand all / Collapse all platforms*. Each tab remembers what it has open
  until you leave the Library.
- Search (**Y**) and shelves show one plain grid.
- **L / R** change the tile size. Without a saved size, as many covers fit per
  row as the screen comfortably holds.

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
