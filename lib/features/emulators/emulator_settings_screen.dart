import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../models/system_model.dart';
import '../../providers/game_providers.dart';
import '../../services/emulator_service.dart';
import '../../widgets/console_hud.dart';
import 'emulator_picker_screen.dart';

/// Default emulator per configured system. A opens the picker for that system.
class EmulatorSettingsScreen extends ConsumerStatefulWidget {
  const EmulatorSettingsScreen({super.key});

  @override
  ConsumerState<EmulatorSettingsScreen> createState() =>
      _EmulatorSettingsScreenState();
}

class _SystemRow {
  final SystemModel system;
  final String emulatorName;
  final bool installed;
  const _SystemRow(this.system, this.emulatorName, this.installed);
}

class _EmulatorSettingsScreenState
    extends ConsumerState<EmulatorSettingsScreen> {
  final _screenFocus = FocusNode(debugLabel: 'emulator_settings');
  final _service = EmulatorService();
  List<_SystemRow>? _rows;
  List<FocusNode> _nodes = const [];
  int _focused = 0;
  EmulatorPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = EmulatorPreferences(await SharedPreferences.getInstance());
    final config = await ref.read(bootstrappedConfigProvider.future);
    final ids = config.systems.map((s) => s.id).toSet();
    final systems = SystemModel.supportedSystems
        .where((s) => ids.contains(s.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final rows = <_SystemRow>[];
    for (final system in systems) {
      final option = await _service.resolve(system.id, '', prefs);
      rows.add(_SystemRow(system, option.name, option.installed));
    }
    if (!mounted) return;
    for (final n in _nodes) {
      n.dispose();
    }
    setState(() {
      _prefs = prefs;
      _rows = rows;
      _nodes = List.generate(rows.length, (i) => FocusNode(debugLabel: 'emu_sys_$i'));
      _focused = _focused.clamp(0, rows.isEmpty ? 0 : rows.length - 1);
    });
    if (rows.isNotEmpty) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _nodes[_focused].requestFocus());
    }
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _edit(int index) async {
    final system = _rows![index].system;
    final choice = await Navigator.of(context).push<EmulatorChoice>(
      MaterialPageRoute(
        builder: (_) => EmulatorPickerScreen(
          systemId: system.id,
          systemName: system.name,
          title: 'Default emulator for ${system.name}',
          currentId: _prefs!.systemDefault(system.id),
          systemMode: true,
        ),
      ),
    );
    if (choice == null) return;
    await _prefs!.setSystemDefault(system.id, choice.emulatorId);
    await _load();
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
    } else if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
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
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 80),
                    child: rows == null
                        ? const Center(child: CircularProgressIndicator())
                        : ListView(
                            children: [
                              const Text('Emulators',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(
                                  'Default emulator for each system. A game can '
                                  'override it from its Emulator button.',
                                  style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 12)),
                              const SizedBox(height: 16),
                              for (var i = 0; i < rows.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: ConsoleFocusable(
                                    focusNode: _nodes[i],
                                    focusScale: 1.0,
                                    onSelect: () => _edit(i),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.white12),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(rows[i].system.name,
                                                style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 16,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          ),
                                          Text(rows[i].emulatorName,
                                              style: TextStyle(
                                                  color: rows[i].installed
                                                      ? Colors.greenAccent
                                                      : Colors.white38,
                                                  fontSize: 14)),
                                        ],
                                      ),
                                    ),
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
            a: HudAction('Change', onTap: () {
              if (_rows != null && _rows!.isNotEmpty) _edit(_focused);
            }),
            b: HudAction('Back', onTap: () => Navigator.maybePop(context)),
          ),
        ],
      ),
    );
  }
}
