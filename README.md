# Astra Retro

A controller-first Android frontend for your self-hosted RetroArr library, built
on [R-Shop](https://github.com/AverageConsumer/R-Shop).

**[Download the latest Astra APK](https://github.com/sweett00th/astra-retro/releases/latest/download/astra-retro-debug.apk)**
· [Release notes](https://github.com/sweett00th/astra-retro/releases)
· [Build status](https://github.com/sweett00th/astra-retro/actions/workflows/android-apk.yml)

Open the APK on your Astra and allow installation from your browser/file manager
when Android prompts you. The app currently appears as **R-Shop**. Add a
**RetroArr** source, enter your server URL and API key, test the connection, and
browse and download your library. Use **Scan RetroArr library** in the quick menu
after adding games on the server.

The app opens on the **Library**: recently played games on top, then one row of
games per platform, installed ones first (green outline) and the ones still on
the server after them (blue outline). Installed games start in the emulator you
pick per system or per game. See [Library and emulators](docs/library.md).

**System Files** on the home screen lists the BIOS, firmware and key files you
keep on your own [RomDrop](https://github.com/sweett00th/romdrop) server and
saves them into a folder you choose on the tablet. They are not games and are
not launched. See [System Files](docs/system-files.md).

Some emulators install a game from an archive and cannot use a loose folder
(Vita3K is one). For those systems a game the server keeps as a folder is saved
as one `.zip` in the ROM folder, ready for the emulator's own install option.
It is on for PlayStation Vita; switch it per system under **Settings → the
system → Pack Folder Games as ZIP**.

**App update** under **Settings → About** installs the newest build from this
repository's releases without a cable or a browser. It downloads the APK,
checks it against the SHA-256 published with it and hands it to Android's
installer, which asks you to confirm. The first time, Android also asks you to
allow this app to install apps. Every push to `main` publishes a build, and its
number is the Android version code, so the app can tell which build is newer.

If the tablet is connected to your computer with USB debugging enabled, install
with `adb install -r astra-retro-debug.apk`. CI and desktop builds share a
project-only development signing key (a repository Actions secret in CI, and
`astra.debugKeystore` in the ignored `android/local.properties` on the desktop),
so they can update each other. A desktop build keeps the build number from
`pubspec.yaml`, which is lower than any CI build: App update will offer the
latest CI build over it, and putting it back over a CI build needs
`adb install -r -d`. The first `m1-desktop-1` APK used a different key and
cannot be updated in place.

[Implementation and validation details](docs/retroarr-milestone-1.md)

---

## Original R-Shop project

**The fastest way to turn your retro library into a console-like experience on Android.**

R-Shop is a controller-first game manager for Android handhelds and TVs. Connect your local folders, RomM server, or network shares, and browse your collection through a polished UI that feels closer to an eShop than a file browser.

<p align="center">
  <a href="https://averageconsumer.github.io/R-Shop/">
    <img src="screenshots/console_list.png" width="700" alt="R-Shop Console Overview" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/averageconsumer/R-Shop/releases">
    <img src="https://img.shields.io/badge/Download-Latest_APK-brightgreen?style=for-the-badge&logo=android&logoColor=white" alt="Download latest APK" />
  </a>
  <a href="https://apps.obtainium.imranr.dev/redirect.html?r=obtainium://add/https://github.com/averageconsumer/r-shop">
    <img src="https://img.shields.io/badge/Get_it_on-Obtainium-blue?style=for-the-badge" alt="Get it on Obtainium" />
  </a>
  <a href="https://averageconsumer.github.io/R-Shop/">
    <img src="https://img.shields.io/badge/Website-Visit_R--Shop-blueviolet?style=for-the-badge&logo=google-chrome&logoColor=white" alt="Visit website" />
  </a>
  <a href="https://discord.gg/xVT26BHGqh">
    <img src="https://img.shields.io/badge/Discord-Join_Community-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join Discord" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.7.0-blue?style=flat-square" alt="Version" />
  <img src="https://img.shields.io/badge/platform-Android-brightgreen?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License" />
  <img src="https://img.shields.io/github/stars/averageconsumer/R-Shop?style=flat-square&color=yellow" alt="GitHub stars" />
</p>

---

## Why R-Shop?

Most retro setups are powerful, but they still feel like setups.

R-Shop focuses on the part people actually care about: **getting into their games fast**, with a UI that feels good on a handheld, a controller, or the couch.

It removes as much setup friction as possible:

- **QR pairing for RomM** so users can connect in seconds
- **Automatic source and system mapping** using known naming conventions
- **Automatic metadata and artwork** with no account required
- **Automatic RetroAchievements matching** when available
- **Manual overrides only when needed**, not as the default path

The goal is simple: **scan, connect, browse, play.**

---

## What makes it different

### 🎮 Console-like by design
Built around controllers first, not bolted on later. D-pad navigation, focus handling, layout decisions, and game flow are designed to feel native on Android handhelds and TV setups.

### ⚡ Fast setup, low friction
R-Shop is at its best when it makes complicated retro-library setup feel trivial. Local folders, RomM, SMB, FTP, and Web sources can all feed the same experience.

### 🧠 Smart defaults
Systems are mapped automatically where possible. RomM sources map automatically. Metadata comes in automatically. RetroAchievements can match automatically. You step in only when something needs correction.

### 🌐 Multi-source library, one front end
Merge games from multiple providers into a single clean library instead of juggling separate tools, launchers, or source-specific views.

---

## Features

- **Controller-first UI** for Android handhelds and TV devices
- **Unified Sources screen** for RomM, SMB, FTP, Web, and local libraries
- **QR-based RomM pairing** with token auth and re-pair support
- **Automatic system mapping** for local and network libraries
- **Automatic metadata and cover art** with no manual login required
- **RetroAchievements integration** with game matching, progress, and badges
- **Library-wide browsing** with Installed, Favorites, search, and zoom controls
- **Background-ready download queue** with live progress on cards and buttons
- **Per-card source indicators** showing where each game is available
- **One-question onboarding** that adapts to how users store their ROMs

---

## Screenshots

<p align="center">
  <img src="screenshots/console_list.png" width="400" alt="Console overview" />
  <img src="screenshots/rom_list.png" width="400" alt="ROM list" />
</p>
<p align="center">
  <img src="screenshots/detail_screen.png" width="400" alt="Game detail screen" />
  <img src="screenshots/download_queue.png" width="400" alt="Download queue" />
</p>
<p align="center">
  <img src="screenshots/smb_setup.png" width="400" alt="Source setup" />
</p>

---

## Supported systems

R-Shop supports **66 systems** with icons, RetroAchievements integration, and automatic folder mapping.

Highlights include:
- **Nintendo:** NES, SNES, N64, GameCube, Wii, Wii U, Switch, GB, GBC, GBA, NDS, 3DS, DSi, Virtual Boy, FDS, Game & Watch
- **Sony:** PlayStation, PS2, PS3, PSP, PS Vita
- **Sega:** Master System, Mega Drive, Game Gear, Sega CD, 32X, Saturn, Dreamcast, SG-1000
- **Atari:** 2600, 5200, 7800, Lynx, Jaguar, Jaguar CD, ST
- **NEC:** TurboGrafx-16, TurboGrafx-CD, PC-FX
- **SNK:** Neo Geo Pocket, Neo Geo CD
- **Others:** WonderSwan, ColecoVision, Intellivision, Vectrex, MSX, Amstrad CPC, Commodore 64, Amiga, ZX Spectrum, Arcade, DOS, and more

---

## Installation

### Obtainium
The easiest way to install and stay up to date:

[![Get it on Obtainium](https://raw.githubusercontent.com/ImranR98/Obtainium/main/assets/graphics/badge_obtainium.png)](https://apps.obtainium.imranr.dev/redirect.html?r=obtainium://add/https://github.com/averageconsumer/r-shop)

### Manual APK
Download the latest APK from the [Releases](../../releases) page.

---

## Getting started

1. Install R-Shop
2. Choose how your library is stored
3. Connect a local folder, network source, or RomM server
4. Let R-Shop map systems and pull metadata automatically
5. Browse, download, and play

For a full walkthrough, see the [User Guide](docs/USER_GUIDE.md).

---

## Philosophy

R-Shop does **not** host or distribute ROMs.

It is a library management and browsing tool for content users already own or legally access through their own servers, directories, and devices.

---

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
