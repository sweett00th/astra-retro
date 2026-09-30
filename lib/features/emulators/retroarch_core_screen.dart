import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../widgets/console_hud.dart';

/// Shown before the first RetroArch launch of a core. RetroArch crashes when
/// asked to load a core that is not downloaded, and R-Shop cannot see its
/// cores, so the user confirms once. Pops true to launch.
class RetroArchCoreScreen extends StatefulWidget {
  const RetroArchCoreScreen(
      {super.key, required this.coreName, required this.systemName});

  final String coreName;
  final String systemName;

  @override
  State<RetroArchCoreScreen> createState() => _RetroArchCoreScreenState();
}

class _RetroArchCoreScreenState extends State<RetroArchCoreScreen> {
  final _screenFocus = FocusNode(debugLabel: 'retroarch_core');
  final _launchFocus = FocusNode(debugLabel: 'retroarch_core_launch');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _launchFocus.requestFocus());
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    _launchFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      'Open RetroArch.',
      'Main Menu > Online Updater > Core Downloader.',
      'Download "${widget.coreName}".',
      'Come back here and press A.',
    ];
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
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('RetroArch needs a ${widget.systemName} core',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text(
                            'RetroArch crashes if the core is missing, and '
                            'R-Shop cannot check its cores for you. You only '
                            'need to do this once per core.',
                            style: TextStyle(
                                color: Colors.grey.shade400, fontSize: 14)),
                        const SizedBox(height: 16),
                        for (var i = 0; i < steps.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('${i + 1}. ${steps[i]}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15)),
                          ),
                        const SizedBox(height: 24),
                        ConsoleFocusable(
                          focusNode: _launchFocus,
                          focusScale: 1.0,
                          onSelect: () => Navigator.of(context).pop(true),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.greenAccent, width: 2),
                            ),
                            child: const Text('I have the core - Play',
                                style: TextStyle(
                                    color: Colors.greenAccent,
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
            a: HudAction('Play', onTap: () => Navigator.of(context).pop(true)),
            b: HudAction('Cancel',
                onTap: () => Navigator.of(context).pop(false)),
          ),
        ],
      ),
    );
  }
}
