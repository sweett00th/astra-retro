import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../widgets/console_hud.dart';

/// Short numbered instructions with one confirm action. Used where R-Shop
/// cannot do something inside an emulator itself (download a RetroArch
/// core, open a game's settings). Pops true when confirmed.
class EmulatorStepsScreen extends StatefulWidget {
  const EmulatorStepsScreen({
    super.key,
    required this.title,
    required this.steps,
    required this.confirmLabel,
    this.intro,
  });

  final String title;
  final String? intro;
  final List<String> steps;
  final String confirmLabel;

  @override
  State<EmulatorStepsScreen> createState() => _EmulatorStepsScreenState();
}

class _EmulatorStepsScreenState extends State<EmulatorStepsScreen> {
  final _screenFocus = FocusNode(debugLabel: 'emulator_steps');
  final _confirmFocus = FocusNode(debugLabel: 'emulator_steps_confirm');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _confirmFocus.requestFocus());
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    _confirmFocus.dispose();
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
                        Text(widget.title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        if (widget.intro != null) ...[
                          const SizedBox(height: 8),
                          Text(widget.intro!,
                              style: TextStyle(
                                  color: Colors.grey.shade400, fontSize: 14)),
                        ],
                        const SizedBox(height: 16),
                        for (var i = 0; i < widget.steps.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('${i + 1}. ${widget.steps[i]}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 15)),
                          ),
                        const SizedBox(height: 24),
                        ConsoleFocusable(
                          focusNode: _confirmFocus,
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
                            child: Text(widget.confirmLabel,
                                style: const TextStyle(
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
            a: HudAction(widget.confirmLabel,
                onTap: () => Navigator.of(context).pop(true)),
            b: HudAction('Back', onTap: () => Navigator.of(context).pop(false)),
          ),
        ],
      ),
    );
  }
}
