import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/config/source.dart';
import '../../providers/app_providers.dart';
import '../../providers/game_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/ra_providers.dart';
import '../../widgets/quick_menu.dart';
import '../onboarding/onboarding_screen.dart';
import '../settings/settings_screen.dart';
import '../sources/retroarr_scan_screen.dart';
import '../system_files/system_files_screen.dart';

/// A switch between the app's two top-level views, the library and the
/// console list. They are peers, so it cross-fades instead of zooming in the
/// way a page one level deeper does.
class TopLevelRoute<T> extends PageRouteBuilder<T> {
  TopLevelRoute({required WidgetBuilder builder, bool landing = false})
      : super(
          pageBuilder: (context, _, __) => builder(context),
          // The landing view is simply there when the app starts.
          transitionDuration:
              landing ? Duration.zero : const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          transitionsBuilder: (context, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        );
}

/// The menu entries that belong to the app rather than to one view: syncing,
/// the RetroArr scan, System Files and Settings. The library and the console
/// list both mix this in, so neither lacks an entry the other has.
mixin AppMenu<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  @override
  void initState() {
    super.initState();
    // The menu asks how many systems are set up; have the answer loaded by
    // the time it is opened.
    ref.read(bootstrappedConfigProvider);
  }

  List<Source> get retroArrSources => ref
      .read(sourcesProvider)
      .sources
      .where((s) => s.type == SourceType.retroarr && s.enabled && s.url != null)
      .toList();

  /// Runs before an entry opens another screen; a view with held inputs
  /// stops them here.
  void beforeLeavingForMenuEntry() {}

  /// BIOS, firmware and keys from RomDrop. Its own section: these are not
  /// games and never appear in a console or the library.
  void openSystemFiles() {
    beforeLeavingForMenuEntry();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SystemFilesScreen()),
    );
  }

  void scanRetroArr() {
    final sources = retroArrSources;
    if (sources.isEmpty) return;
    beforeLeavingForMenuEntry();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RetroArrScanScreen(sources: sources)));
  }

  Future<void> syncAllSystems() async {
    final config = await ref.read(bootstrappedConfigProvider.future);
    if (!mounted || config.systems.isEmpty) return;
    final syncService = ref.read(librarySyncServiceProvider.notifier);
    if (ref.read(librarySyncServiceProvider).isSyncing) {
      syncService.cancel();
      await syncService.waitForCompletion();
      if (!mounted) return;
    }
    final timeout = Duration(seconds: ref.read(syncTimeoutProvider));
    syncService.syncAll(
      config,
      syncTimeout: timeout,
      storageService: ref.read(storageServiceProvider),
    );
    triggerRaSync(
      ref.read(raSyncServiceProvider.notifier),
      ref.read(storageServiceProvider),
      force: true,
    );
  }

  /// Syncs the systems whose cooldown has run out, and [forceSystemIds]
  /// regardless of it.
  Future<void> syncStaleSystems({Set<String> forceSystemIds = const {}}) async {
    final config = await ref.read(bootstrappedConfigProvider.future);
    if (!mounted) return;
    if (config.systems.isNotEmpty) {
      final timeout = Duration(seconds: ref.read(syncTimeoutProvider));
      final cooldownMinutes = ref.read(syncCooldownProvider);
      final storage = ref.read(storageServiceProvider);
      ref.read(librarySyncServiceProvider.notifier).syncSmart(config,
          syncTimeout: timeout,
          cooldown: Duration(minutes: cooldownMinutes),
          forceSystemIds: forceSystemIds,
          storageService: storage);
    }
  }

  Future<void> openSettings() async {
    ref.read(feedbackServiceProvider).tick();
    beforeLeavingForMenuEntry();
    // Snapshot current system IDs before entering settings
    final preSettingsIds = ref
            .read(bootstrappedConfigProvider)
            .valueOrNull
            ?.systems
            .map((s) => s.id)
            .toSet() ??
        <String>{};
    // Resetting onboarding removes this view; the navigator outlives it.
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          onResetOnboarding: () {
            navigator.popUntil((route) => route.isFirst);
            navigator.pushReplacement(
              MaterialPageRoute(
                builder: (context) => const OnboardingScreen(),
              ),
            );
          },
        ),
      ),
    );
    if (!mounted) return;
    // Config may have changed — reload and smart-sync
    ref.invalidate(bootstrappedConfigProvider);
    final config = await ref.read(bootstrappedConfigProvider.future);
    if (!mounted) return;
    // Only force-sync newly added consoles
    final newIds =
        config.systems.map((s) => s.id).toSet().difference(preSettingsIds);
    if (config.systems.isNotEmpty) {
      syncStaleSystems(forceSystemIds: newIds);
    }
  }

  /// The entries themselves, in the order both views show them.
  List<QuickMenuItem> appMenuItems() {
    final l = L.of(context);
    final systems =
        ref.read(bootstrappedConfigProvider).valueOrNull?.systems.length ?? 0;
    return [
      if (systems > 1)
        QuickMenuItem(
          label: l.home_syncAll,
          icon: Icons.sync_rounded,
          onSelect: syncAllSystems,
        ),
      if (retroArrSources.isNotEmpty)
        QuickMenuItem(
          label: 'Scan RetroArr library',
          icon: Icons.manage_search_rounded,
          onSelect: scanRetroArr,
        ),
      QuickMenuItem(
        label: 'System Files',
        icon: Icons.memory_rounded,
        onSelect: openSystemFiles,
      ),
      QuickMenuItem(
        label: l.home_settings,
        icon: Icons.settings_rounded,
        onSelect: openSettings,
      ),
    ];
  }
}
