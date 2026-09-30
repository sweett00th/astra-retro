import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../models/emulator.dart';
import '../../services/emulator_service.dart';
import '../../widgets/console_hud.dart';

/// What the user picked. [emulatorId] null means "use the system default".
class EmulatorChoice {
  final String? emulatorId;
  final bool forWholeSystem;
  const EmulatorChoice(this.emulatorId, {this.forWholeSystem = false});
}

/// Controller-friendly list of emulators for one game or a whole system.
/// A picks for this game; Y makes the focused emulator the system default.
class EmulatorPickerScreen extends StatefulWidget {
  const EmulatorPickerScreen({
    super.key,
    required this.systemId,
    required this.systemName,
    required this.title,
    this.currentId,
    this.systemDefaultId,
    this.service,
    this.systemMode = false,
  });

  final String systemId;
  final String systemName;
  final String title;
  final String? currentId;
  final String? systemDefaultId;
  final EmulatorService? service;

  /// Choosing the default for the whole system (Settings > Emulators):
  /// A sets the system default and row 0 means automatic.
  final bool systemMode;

  @override
  State<EmulatorPickerScreen> createState() => _EmulatorPickerScreenState();
}

class _EmulatorPickerScreenState extends State<EmulatorPickerScreen> {
  final _screenFocus = FocusNode(debugLabel: 'emulator_picker');
  List<EmulatorOption>? _options;
  List<FocusNode> _nodes = const [];
  int _focused = 0;

  @override
  void initState() {
    super.initState();
    (widget.service ?? EmulatorService())
        .optionsFor(widget.systemId)
        .then((options) {
      if (!mounted) return;
      setState(() {
        _options = options;
        _nodes = List.generate(
            options.length + 1, (i) => FocusNode(debugLabel: 'emu_$i'));
        final current = options.indexWhere((o) => o.id == widget.currentId);
        _focused = current >= 0 ? current + 1 : 0;
      });
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _nodes[_focused].requestFocus());
    });
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Index 0 is "system default"; options start at 1.
  String? _idAt(int index) => index == 0 ? null : _options![index - 1].id;

  void _pick(int index, {bool forSystem = false}) {
    final id = _idAt(index);
    if (widget.systemMode) forSystem = true;
    if (forSystem && id == null && !widget.systemMode) return;
    Navigator.of(context).pop(EmulatorChoice(id, forWholeSystem: forSystem));
  }

  /// Official download page for an emulator that is not installed.
  void _openHomepage(int index) {
    if (index == 0) return;
    final option = _options![index - 1];
    final url = option.definition.homepage;
    if (option.installed || url == null) return;
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _move(int delta) {
    if (_nodes.isEmpty) return;
    setState(() => _focused = (_focused + delta).clamp(0, _nodes.length - 1));
    _nodes[_focused].requestFocus();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.gameButtonX) {
      _openHomepage(_focused);
    } else if (key == LogicalKeyboardKey.gameButtonY) {
      _pick(_focused, forSystem: true);
    } else if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _row(int index, String title, String subtitle,
      {bool selected = false, bool dim = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConsoleFocusable(
        focusNode: _nodes[index],
        focusScale: 1.0,
        onSelect: () => _pick(index),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? AppTheme.primaryColor : Colors.white12,
                width: selected ? 2 : 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: dim ? Colors.white38 : Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded, color: AppTheme.primaryColor),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final defaultName = options
            ?.where((o) => o.id == widget.systemDefaultId)
            .firstOrNull
            ?.name ??
        'first installed emulator';
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Stack(
        children: [
          SafeArea(
            child: Focus(
              focusNode: _screenFocus,
              autofocus: true,
              onKeyEvent: _handleKey,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                    child: options == null
                        ? const Center(child: CircularProgressIndicator())
                        : ListView(
                            children: [
                              Text(widget.title,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(
                                  widget.systemMode
                                      ? 'A: use for every ${widget.systemName} game'
                                      : 'A: use for this game   Y: use for all ${widget.systemName} games',
                                  style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 12)),
                              const SizedBox(height: 16),
                              if (widget.systemMode)
                                _row(0, 'Automatic',
                                    'First installed emulator for ${widget.systemName}',
                                    selected: widget.currentId == null)
                              else
                                _row(0, '${widget.systemName} default',
                                    'Currently: $defaultName',
                                    selected: widget.currentId == null),
                              for (var i = 0; i < options.length; i++)
                                _row(
                                  i + 1,
                                  options[i].name,
                                  options[i].definition.packages.isEmpty
                                      ? 'Pick any installed app each time'
                                      : options[i].installed
                                          ? 'Installed${options[i].versionName != null ? ' · ${options[i].versionName}' : ''}'
                                          : options[i].definition.homepage !=
                                                  null
                                              ? 'Not installed · X: get it'
                                              : 'Not installed',
                                  selected: widget.currentId == options[i].id,
                                  dim: !options[i].installed,
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
            x: HudAction('Get emulator', onTap: () => _openHomepage(_focused)),
            y: widget.systemMode
                ? null
                : HudAction('All ${widget.systemName}',
                    onTap: () => _pick(_focused, forSystem: true)),
          ),
        ],
      ),
    );
  }
}
