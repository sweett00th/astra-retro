import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/console_focusable.dart';
import '../../../widgets/console_hud.dart';

/// Height the button hints take at the bottom of a screen.
const hudClearance = 84.0;

/// One selectable line of a System Files screen.
class SystemRow {
  const SystemRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.leadingWidth = 32,
    this.badges = const [],
    this.trailing,
    this.progress,
    this.onSelect,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Wider for a platform's wordmark, which is unreadable in a square.
  final double leadingWidth;
  final List<SystemBadge> badges;
  final String? trailing;

  /// 0..1 while a transfer for this row is running.
  final double? progress;
  final VoidCallback? onSelect;
  final Color? accent;
}

class SystemBadge {
  const SystemBadge(this.label, this.color);
  final String label;
  final Color color;

  static const preferred = SystemBadge('PREFERRED', Colors.greenAccent);
  static const pinned = SystemBadge('PINNED', Colors.lightBlueAccent);
  static const deprecated = SystemBadge('DEPRECATED', Colors.redAccent);
  static const sensitive = SystemBadge('SENSITIVE', Colors.amber);
  static const onDevice = SystemBadge('ON THIS DEVICE', Colors.greenAccent);
}

/// A state the screen is in instead of (or above) its rows: not connected,
/// offline, empty, an error.
class SystemMessage {
  const SystemMessage(this.icon, this.title, [this.detail, this.color]);
  final IconData icon;
  final String title;
  final String? detail;
  final Color? color;
}

class SystemHudAction {
  const SystemHudAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

/// Shared frame of the System Files screens: a title, an optional message, a
/// column of focusable rows and the button hints. Up/Down move, A selects,
/// B goes back, X and Y run the screen's extra actions; rows and hints also
/// take touch. Built like the Emulators settings screen.
class SystemScreen extends StatefulWidget {
  const SystemScreen({
    super.key,
    required this.title,
    this.subtitle,
    this.loading = false,
    this.message,
    this.details,
    this.rows = const [],
    this.selectLabel = 'Select',
    this.x,
    this.y,
  });

  final String title;
  final String? subtitle;
  final bool loading;
  final SystemMessage? message;

  /// Read-only content shown above the rows.
  final Widget? details;
  final List<SystemRow> rows;
  final String selectLabel;
  final SystemHudAction? x;
  final SystemHudAction? y;

  @override
  State<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends State<SystemScreen> {
  final _screenFocus = FocusNode(debugLabel: 'system_screen');
  final _scroll = ScrollController();
  List<FocusNode> _nodes = const [];

  /// The row the cursor is on, or was on before focus left the rows.
  int _focused = 0;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    _screenFocus.addListener(_handFocusToRow);
    _syncNodes();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(SystemScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rows.length != _nodes.length) _syncNodes();
  }

  FocusNode _newNode(int index) {
    final node = FocusNode(debugLabel: 'system_row_$index');
    // Touch moves focus too; remember where it went.
    node.addListener(() {
      if (node.hasFocus) _focused = index;
    });
    return node;
  }

  /// Rows keep their focus node for as long as their position exists; only
  /// the end of the list grows or shrinks. The cursor therefore stays put
  /// while rows come and go, and a focused row is never handed a new node.
  void _syncNodes() {
    final wanted = widget.rows.length;
    final wasEmpty = _nodes.isEmpty;
    final lostCursor = _nodes.skip(wanted).any((node) => node.hasFocus);
    for (final node in _nodes.skip(wanted)) {
      node.dispose();
    }
    _nodes = [
      ..._nodes.take(wanted),
      for (var i = _nodes.length; i < wanted; i++) _newNode(i),
    ];
    _focused = _nodes.isEmpty ? 0 : _focused.clamp(0, _nodes.length - 1);
    if (!wasEmpty && !lostCursor && _nodes.isNotEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only the screen on top may take focus; one that is covered gets it
      // back through [_handFocusToRow] when it is shown again.
      if (!mounted || !(_route?.isCurrent ?? true)) return;
      (_nodes.isEmpty ? _screenFocus : _nodes[_focused]).requestFocus();
    });
  }

  /// Focus lands on the screen itself when the row it was on went away while
  /// another screen was on top. Pass it on, so a row is always marked and A
  /// acts on what the user sees.
  void _handFocusToRow() {
    if (_screenFocus.hasPrimaryFocus && _nodes.isNotEmpty) {
      _nodes[_focused].requestFocus();
    }
  }

  @override
  void dispose() {
    _screenFocus.dispose();
    _scroll.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _move(int delta) {
    if (_nodes.isEmpty) {
      // Nothing to focus: Up and Down scroll, so the text can still be read
      // with a controller.
      _scrollBy(delta);
      return;
    }
    final current = _nodes.indexWhere((n) => n.hasFocus);
    if (current < 0) {
      // No row is marked: the first press marks one rather than passing it.
      _nodes[_focused].requestFocus();
      return;
    }
    final to = (current + delta).clamp(0, _nodes.length - 1);
    if (to == current) {
      // At either end the press scrolls, which brings text above the first
      // row back into view.
      _scrollBy(delta);
      return;
    }
    _focused = to;
    _nodes[to].requestFocus();
  }

  void _scrollBy(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = (position.pixels + direction * position.viewportDimension * 0.6)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
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
    } else if (event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
    } else if (widget.x != null &&
        (key == LogicalKeyboardKey.gameButtonX ||
            key == LogicalKeyboardKey.keyX)) {
      widget.x!.onPressed();
    } else if (widget.y != null &&
        (key == LogicalKeyboardKey.gameButtonY ||
            key == LogicalKeyboardKey.keyY)) {
      widget.y!.onPressed();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final message = widget.message;
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Stack(
        children: [
          SafeArea(
            child: Focus(
              focusNode: _screenFocus,
              autofocus: true,
              onKeyEvent: _handleKey,
              // From the top, so the title stays put from screen to screen
              // however many rows there are. The list ends above the button
              // hints, so no row is ever half hidden behind them.
              child: Container(
                alignment: Alignment.topCenter,
                padding: const EdgeInsets.only(bottom: hudClearance),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  // Every row is built, not only those in view: a row has to
                  // exist before the controller can move focus to it.
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(widget.title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(widget.subtitle!,
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 12)),
                        ],
                        const SizedBox(height: 16),
                        if (widget.loading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        if (message != null) _MessageBox(message),
                        if (widget.details != null) ...[
                          widget.details!,
                          const SizedBox(height: 16),
                        ],
                        for (var i = 0; i < rows.length; i++)
                          Padding(
                            // Keyed, so a row keeps its element (and with it
                            // its focus highlight) when the widgets around it
                            // come and go. Without the key Flutter pairs
                            // rows with whatever sits in the same place, and
                            // a row that already has focus can end up in a
                            // new element that never saw it arrive.
                            key: ValueKey('system_row_$i'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ConsoleFocusable(
                              focusNode: _nodes[i],
                              focusScale: 1.0,
                              onSelect: rows[i].onSelect,
                              child: _RowBody(rows[i]),
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
            a: rows.isEmpty
                ? null
                : HudAction(widget.selectLabel, onTap: () {
                    if (_focused < rows.length) rows[_focused].onSelect?.call();
                  }),
            b: HudAction('Back', onTap: () => Navigator.maybePop(context)),
            x: widget.x == null
                ? null
                : HudAction(widget.x!.label, onTap: widget.x!.onPressed),
            y: widget.y == null
                ? null
                : HudAction(widget.y!.label, onTap: widget.y!.onPressed),
          ),
        ],
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox(this.message);
  final SystemMessage message;

  @override
  Widget build(BuildContext context) {
    final color = message.color ?? Colors.white54;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(message.icon, color: color, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                if (message.detail != null) ...[
                  const SizedBox(height: 4),
                  Text(message.detail!,
                      style:
                          TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RowBody extends StatelessWidget {
  const _RowBody(this.row);
  final SystemRow row;

  @override
  Widget build(BuildContext context) {
    final enabled = row.onSelect != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (row.leading != null) ...[
                SizedBox(
                    width: row.leadingWidth, height: 32, child: row.leading),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(row.title,
                            style: TextStyle(
                                color: enabled ? Colors.white : Colors.white54,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        for (final badge in row.badges) _BadgeChip(badge),
                      ],
                    ),
                    if (row.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(row.subtitle!,
                          style: TextStyle(
                              color: Colors.grey.shade400, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              if (row.trailing != null) ...[
                const SizedBox(width: 12),
                Text(row.trailing!,
                    style: TextStyle(
                        color: row.accent ?? Colors.white60, fontSize: 13)),
              ],
            ],
          ),
          if (row.progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: row.progress,
                minHeight: 4,
                color: row.accent ?? AppTheme.primaryColor,
                backgroundColor: Colors.white12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip(this.badge);
  final SystemBadge badge;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: badge.color.withValues(alpha: 0.7)),
      ),
      child: Text(badge.label,
          style: TextStyle(
              color: badge.color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8)),
    );
  }
}

/// Labelled values (file name, size, checksum …) above the rows.
class SystemFacts extends StatelessWidget {
  const SystemFacts(this.facts, {super.key});
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in facts)
          if (value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 132,
                    child: Text(label,
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12)),
                  ),
                  Expanded(
                    child: Text(value,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
