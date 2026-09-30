import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../models/config/provider_config.dart';
import '../../models/config/source.dart';
import '../../models/system_model.dart';
import '../../providers/app_providers.dart';
import '../../providers/game_providers.dart';
import '../../providers/library_providers.dart';
import '../../services/retroarr_api_service.dart';
import '../../widgets/console_hud.dart';

/// Asks RetroArr to rescan its library, then refreshes the platform list and
/// syncs the affected systems so new games show up on the tablet.
class RetroArrScanScreen extends ConsumerStatefulWidget {
  const RetroArrScanScreen({super.key, required this.sources});

  final List<Source> sources;

  @override
  ConsumerState<RetroArrScanScreen> createState() => _RetroArrScanScreenState();
}

class _RetroArrScanScreenState extends ConsumerState<RetroArrScanScreen> {
  final _screenFocus = FocusNode(debugLabel: 'retroarr_scan_screen');
  final _closeFocus = FocusNode(debugLabel: 'retroarr_scan_close');
  String _status = 'Contacting RetroArr…';
  String? _detail;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closeFocus.requestFocus();
      _run();
    });
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  void _update(String status, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _detail = detail;
    });
  }

  Future<void> _run() async {
    var added = 0;
    try {
      for (final source in widget.sources) {
        final api = RetroArrApiService(ProviderConfig(
            type: ProviderType.retroarr,
            priority: source.priority,
            url: source.url,
            sourceId: source.id));
        _update('Scanning ${source.name}…');
        await for (final status in scanRetroArrLibrary(api)) {
          if (!mounted) return;
          _update(
            status.isScanning ? 'Scanning ${source.name}…' : 'Scan finished',
            detail: [
              '${status.gamesAdded} new game${status.gamesAdded == 1 ? '' : 's'}',
              if (status.isScanning && status.lastGameFound != null)
                'Latest: ${status.lastGameFound}',
            ].join('\n'),
          );
          if (!status.isScanning) added += status.gamesAdded;
        }
        if (!mounted) return;
        _update('Updating systems…');
        await _refreshAndSync(source, api);
      }
      if (!mounted) return;
      setState(() {
        _done = true;
        _status = 'Library updated';
        _detail = '$added new game${added == 1 ? '' : 's'} found. '
            'Systems are syncing in the background.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _done = true;
        _failed = true;
        _status = 'Scan failed';
        _detail = e is StateError ? e.message : e.toString();
      });
    }
  }

  /// New platforms become systems; every system of the source re-syncs.
  Future<void> _refreshAndSync(Source source, RetroArrApiService api) async {
    final platforms = await api.fetchPlatforms();
    final known = RetroArrPlatform.matchSystems(
        SystemModel.supportedSystems.map((s) => s.id), platforms);
    if (!mounted) return;
    final notifier = ref.read(sourcesProvider.notifier);
    final storage = ref.read(storageServiceProvider);
    await notifier.updateKnownPlatforms(source.id, known);
    await notifier.ensureSystemsForSource(
        source.copyWith(knownPlatforms: known),
        basePath: storage.getRomPath() ?? '/storage/emulated/0/ROMs');
    if (!mounted) return;
    ref.invalidate(bootstrappedConfigProvider);
    final config = await ref.read(bootstrappedConfigProvider.future);
    if (!mounted) return;
    final sync = ref.read(librarySyncServiceProvider.notifier);
    final timeout = Duration(seconds: ref.read(syncTimeoutProvider));
    for (final systemId in known.keys) {
      if (config.systems.any((s) => s.id == systemId)) {
        sync.syncSystem(systemId, config,
            syncTimeout: timeout, storageService: storage);
      }
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final accent = _failed ? Colors.redAccent : AppTheme.primaryColor;
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Stack(
        children: [
          SafeArea(
            child: Focus(
              focusNode: _screenFocus,
              onKeyEvent: _handleKey,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 56,
                          height: 56,
                          child: _done
                              ? Icon(
                                  _failed
                                      ? Icons.error_outline
                                      : Icons.check_circle_outline,
                                  color: accent,
                                  size: 56)
                              : CircularProgressIndicator(color: accent),
                        ),
                        const SizedBox(height: 20),
                        Text(_status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        if (_detail != null) ...[
                          const SizedBox(height: 8),
                          Text(_detail!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.grey.shade400, fontSize: 14)),
                        ],
                        if (!_done) ...[
                          const SizedBox(height: 8),
                          Text(
                              'You can leave this screen; RetroArr keeps scanning.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.grey.shade600, fontSize: 12)),
                        ],
                        const SizedBox(height: 28),
                        ConsoleFocusable(
                          focusNode: _closeFocus,
                          focusScale: 1.0,
                          onSelect: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: accent, width: 2),
                            ),
                            child: Text(_done ? 'Done' : 'Close',
                                style: TextStyle(
                                    color: accent,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          ConsoleHud(
            b: HudAction('Back', onTap: () => Navigator.maybePop(context)),
          ),
        ],
      ),
    );
  }
}
