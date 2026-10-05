# System Files

BIOS, firmware and key files from your own [RomDrop](https://github.com/sweett00th/romdrop)
server, saved into a folder on the device. They are support files for
emulators, not games: they are not in the Library, have no cover and cannot be
launched.

Nothing is fetched from anywhere else. The app has no links to firmware, BIOS
or key sites; what you can download is what you uploaded to your RomDrop.

## Connecting

1. In RomDrop's admin site (`https://<server>:3002`) open **Devices → Pair a
   device**. The code is good for ten minutes and for one use. Tick the
   sensitive permission there if this device may receive keys.
2. In the app open **Settings → RomDrop** (or **System Files → Connect to
   RomDrop**). Enter the address, the code and a name for the device, then
   **Connect**.
3. RomDrop's own certificate is self-signed, so the app shows its SHA-256
   fingerprint. Compare it with the one on the **Status** page of the admin
   site and continue only if they are the same. From then on the app accepts
   exactly that certificate; if the server presents another one later, the app
   asks again instead of connecting. Certificate checks are never switched off.

The app holds its own read-only device credential, in Android's
keystore-backed secure storage. The admin password is never entered in the
app. The credential is sent only in the `Authorization` header to the address
you entered; it is never part of a URL, and redirects are refused.

**Test Connection** checks the credential and reports whether the library is
online and whether sensitive files are allowed. **Disconnect** makes the device
forget the server; to end the credential itself, choose **Revoke** next to the
device in RomDrop.

An `http://` address works on a network you trust, but the credential and the
files then travel unencrypted, and RomDrop does not send sensitive files that
way.

## Browsing

**Home → System Files** (a tile after the Library, also in the **+** menu), then
platform → BIOS / Firmware / Keys / Other → asset → version → files.

- The preferred version is listed first; older versions stay available. Badges:
  `PREFERRED`, `PINNED`, `DEPRECATED`, `SENSITIVE`, `ON THIS DEVICE`.
- Sensitive assets are left out unless RomDrop allows them for this device.
  The number left out is shown.
- **Up / Down** move, **A** selects, **B** goes back, **X** is the screen's
  extra action (Refresh, Download all, Clear finished). Rows also take touch.

## Downloading

- The first download asks for a folder with Android's folder picker. That
  becomes the default destination. **Destinations** changes it, and a platform
  can have a folder of its own.
- Pick a folder your emulator reads, or one you import from. Android does not
  let an app write into another app's `Android/data` folder and the picker does
  not offer it. For an emulator that keeps these files in its private storage,
  save to a shared folder and use the emulator's own import.
- A file is downloaded into app-private staging, its length and SHA-256 are
  checked against RomDrop, then it is copied into the folder under its
  original name and checked again there. Folders inside a version are kept
  (`dc/dc_boot.bin` goes into a `dc` folder). Archives are saved as they are;
  nothing is unpacked.
- An interrupted download resumes where it stopped. It is retried three times
  by itself; after that, or after the app was closed, it waits under
  **Transfers** until you select it.
- If the folder already holds the identical file, it is recorded as on the
  device without downloading. If it holds a different file of that name, the
  app asks before replacing it.
- If Android took the folder access back, or the folder is gone, the app says
  so and asks for the folder again before downloading anything.

"Saved to …" and `ON THIS DEVICE` mean exactly that. Whether the emulator has
imported the file is something the app cannot see; **Imported in my emulator**
is a note you tick yourself.

## Not included

- No launching, no installing into an emulator, no unpacking.
- No effect on game downloads: system files have their own queue and only share
  the "downloading" notification.

## Code

| Part | Where |
| --- | --- |
| Models, API client, certificate pinning | `lib/models/romdrop_models.dart`, `lib/services/romdrop/romdrop_api_service.dart` |
| Connection and credential storage | `lib/services/romdrop/romdrop_connection.dart`, `romdrop_controller.dart` |
| Transfer queue (resume, verify, save) | `lib/services/romdrop/system_file_download_manager.dart` |
| Folder access (Storage Access Framework) | `lib/services/romdrop/system_file_storage.dart`, `android/…/SafStorage.kt` |
| Screens | `lib/features/system_files/` |

The server's contract is RomDrop's `docs/api/openapi.json`.
`test/fixtures/romdrop/` holds copies of its `docs/api/examples`; copy them
again when the API changes. Every file body in the tests is made-up bytes.

## Tests

```sh
flutter test \
  test/romdrop_models_test.dart test/romdrop_api_service_test.dart \
  test/system_file_transfer_test.dart test/romdrop_controller_test.dart \
  test/widgets/system_files_screens_test.dart \
  test/widgets/romdrop_connection_screen_test.dart \
  test/widgets/home_system_files_tile_test.dart
```

The transfer and API tests run against a server they start on loopback. The
certificate tests create a throwaway key pair with `openssl` and are skipped
where it is not installed.

`test/romdrop_live_test.dart` runs the same client against a real RomDrop. It
signs in as the admin, adds two synthetic assets and a device and removes them
again, so point it at a test container, not at the library you use:

```sh
ROMDROP_LIVE_URL=https://127.0.0.1:3002 ROMDROP_LIVE_ADMIN_PASSWORD=change-me \
  flutter test test/romdrop_live_test.dart
```

## Checking it on a device

The folder bridge (`SafStorage.kt`) and the look of the screens can only be
checked on Android. Install with
`adb install -r build/app/outputs/flutter-apk/app-debug.apk`, then:

1. **Home** — the System Files tile follows the Library in carousel and grid;
   the **+** menu has System Files; **A** opens it.
2. **Pair** — connect with a code; the fingerprint shown equals the one on
   RomDrop's Status page.
3. **Browse** — platform → kind → asset → version with the controller only;
   **B** returns one level each time.
4. **Download** — a small file: the folder picker opens, the row goes through
   downloading, checking and saving to "Saved to …". The file in the folder
   has its exact original name and the SHA-256 shown in the app.
5. **Resume** — a large file: switch Wi-Fi off mid-download, then on again. It
   continues (RomDrop's log shows `bytes N-…`) and completes.
6. **Restart** — force-stop the app mid-download, open it again: **Transfers**
   lists it as interrupted; selecting it continues.
7. **Replace** — put a different file of the same name in the folder: the app
   asks; **B** keeps the old file.
8. **Folder access** — delete the folder (or remove the app's access to it):
   the next download says access was lost and asks for the folder again.
9. **Sensitive** — without the permission the keys are hidden and counted;
   allow it under Devices, **X** to refresh, and they appear and download.
10. **Revoke** — revoke the device in RomDrop, **X**: "RomDrop no longer
    accepts this device".
11. **Emulator** — the saved file is where the emulator's import or BIOS
    folder setting can pick it up.
12. **Games** — a game download still works while a system file transfers.
