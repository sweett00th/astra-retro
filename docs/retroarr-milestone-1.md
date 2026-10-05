# RetroArr browsing and downloads (Milestones 1-2)

Add a RetroArr source from onboarding's **Add server** flow or
**Settings → Sources → Add → RetroArr**. Enter the server root URL (including
any reverse-proxy base path) and API key, then select **Test Connection**.
The form lists enabled server platforms and reports how many R-Shop can map.
Save the source, then open a matching system in the existing library UI.
The usual library refresh fetches the catalog again.

HTTP LAN URLs and HTTPS URLs are supported. Do not append `/api/v3` to the URL.
The key is stored with `flutter_secure_storage`, keyed by source ID; it is not
written into source JSON, game URLs, artwork URLs, or exported config. Removing
the source removes its secure key. Newly enabled RetroArr platforms are picked up
at app start and after a library scan. To change the URL or key, use the
source's **Edit connection** action (a blank key keeps the stored one).
Exported sources require credentials to be entered again on another device. The key must use the same secure-storage options as the rest of
the app (encrypted shared preferences); mixing modes hides the stored key.

## Verified contract in the checked-out RetroArr code

- `PlatformController.GetAll`: `GET /api/v3/platform?enabledOnly=true` returns an
  array of platforms with `id`, `name`, `slug`, `folderName`, `igdbPlatformId`.
- `GameController.GetPaged`: `GET /api/v3/game/paged`, with `platformId`, `page`
  and `pageSize`; response has `items` and `totalPages`. The client requests 100
  items per page and reads through the last page, including valid empty results.
- `GameController.GetById`: `GET /api/v3/game/{id}` supplies overview, credits,
  year, release date, genres and rating for the existing detail UI.
- `GameListDto.CoverUrl` supplies the list cover. Relative URLs are resolved
  against the configured server. Absolute external artwork URLs get no API key.
- `GameController.GetLocalMedia` and `ServeLocalMediaFile` expose local artwork
  at `/api/v3/game/{id}/local-media` and `/local-media/file`. The discovery
  response contains signed URLs. This slice uses catalog `coverUrl`; it does
  not scan local-media directories when a catalog cover is absent.
- `ApiKeyAuthMiddleware` accepts `X-Api-Key` and returns 401 for unauthenticated
  remote catalog access. The connection test uses the protected platform route,
  not the anonymously accessible system-status endpoint.

## Integration boundaries

`RetroArrProvider` implements `SourceProvider` and is registered in
`ProviderFactory`. `SourceResolver` uses the discovered platform map to create
per-system providers. Platform matching reuses the established slug/folder/IGDB
matcher. Unmatched platforms are not added as unsupported R-Shop consoles.

Each game uses the file or folder name from RetroArr's path (for example
Game (USA).z64), so downloads, installed state, deletion and the merge with
local files use R-Shop's normal filename identity. Catalog entries without files
on the server (wanted-only or missing) are not listed. Launching installed games
is described in [Library and emulators](library.md).

## Downloads (Milestone 2)

GET /api/v3/game/{id}/files lists a game's files (cue/bin companions included;
patches and DLC are skipped) and /files/download?path= serves each with HTTP
Range support. A single file uses the existing HTTP downloader with resume. Several
files use a multi-file handle: each file resumes independently in a stable temp
folder that survives a failed attempt (cancel discards it), then files are moved
into place with the crash-safe staging move. A file-based set (.cue + .bin)
lands directly in the system folder; a folder-based game keeps its folder.
Downloads go to the configured LAN URL with the key in a header and refuse
redirects. The free-space check covers the game plus its temporary copy. Library
folders in shared storage need Android's "All files access", which the queue
requests before the first download.

## Library scan

**Scan RetroArr library** (home quick menu, or the source's actions in
Settings → Sources) calls POST /api/v3/media/scan, follows
/media/scan/status, refreshes platforms, then syncs the source's systems.
RetroArr requires IGDB credentials to scan and ignores a request while a scan is
running; the app then follows the running scan.

Authenticated API requests and artwork requests refuse redirects. For a reverse
proxy, configure its final URL. The existing cover cache service injects a key
only for the configured server origin and API base path.

## Astra acceptance check

1. Install the debug APK with `adb install -r build/app/outputs/flutter-apk/app-debug.apk`.
2. Add a source using the real LAN URL/key in the app. Confirm an invalid key
   fails, then test the correct key and inspect the returned platform list.
3. Save, browse a populated system, and verify titles/covers and detail metadata.
4. Exercise D-pad, confirm/back, touch, search, and scrolling. Confirm no RetroArr
   game can be queued or launched.
5. Restart the app and verify the saved connection, cached library and covers.
6. Test an empty platform and an unreachable server; restore the server and
   refresh. Verify a library with more than 100 games is not truncated.
7. Inspect `adb logcat` for runtime failures without logging or sharing secrets.

Unit tests use synthetic hostnames/keys and a Dio adapter; they do not establish
that a real RetroArr instance or Astra controller has been tested.

## Validation on 2026-09-28

- Inspected R-Shop base `d615f87` and RetroArr `9da9f0f`. No RetroArr changes.
- Built with Flutter 3.38.10 / Dart 3.10.9, Temurin JDK 17, Android SDK 36.
  Build tools are workspace-local under `C:\dev\astra-retro\.tools`.
- `flutter build apk --debug --no-pub`: passed, including a rebuild after the
  final proxy-path/source-identity fixes. APK:
  `C:\dev\astra-retro\R-Shop\build\app\outputs\flutter-apk\app-debug.apk`.
- Nine RetroArr API/provider/secure-storage/controller-form tests passed.
  The initial source/config regression run passed 128 tests; the final run of
  RetroArr tests plus source notifier tests passed all 29 tests.
- Analyzer: no errors or warnings; one existing info-level lint in
  `test/l10n_completeness_test.dart:17`.
- Full suite: 1,637 passed, six failed in unchanged tests/services: Windows
  multicast socket support (one), Windows folder path assumptions (three), and
  no live RomM server at the smoke tests' expected address (two). These were
  diagnosed without changing unrelated networking/folder behavior.
- ADB starts successfully but no device was connected. Installation, real
  RetroArr browsing, and physical controller verification remain pending.

On this Windows host, desktop plugin symlinks are unavailable. Android builds
and tests work with these process-local environment settings; there is no need
to change Windows Developer Mode:

```powershell
$env:JAVA_HOME = 'C:/dev/astra-retro/.tools/java/jdk-17.0.20.1+1'
$env:ANDROID_HOME = 'C:/dev/astra-retro/.tools/android'
$env:PUB_CACHE = 'C:/dev/astra-retro/.tools/pub-cache'
$env:GRADLE_USER_HOME = 'C:/dev/astra-retro/.tools/gradle'
$env:FLUTTER_WINDOWS = 'false'
$env:FLUTTER_LINUX = 'false'
$env:FLUTTER_MACOS = 'false'
# Run from R-Shop. `pub get` also generates the Android plugin registrant,
# which `--no-pub` builds need; the Gradle build fails if it is missing.
& ../.tools/flutter/bin/flutter.bat pub get --enforce-lockfile
& ../.tools/flutter/bin/flutter.bat build apk --debug --no-pub
& ../.tools/android/platform-tools/adb.exe install -r build/app/outputs/flutter-apk/app-debug.apk
```

Desktop and CI APKs share a project-only development key so either can update
the other. On the desktop, `android/local.properties` (ignored by Git) points
to it with `astra.debugKeystore=<absolute path>`; CI restores the same key from
the `ASTRA_DEBUG_KEYSTORE_B64` secret. Without that property, Gradle signs with
the machine's default debug key and the APK cannot update CI-built installs.
Never commit the keystore.
