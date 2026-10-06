import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/console_focusable.dart';
import '../../models/romdrop_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/romdrop_providers.dart';
import '../../services/romdrop/romdrop_api_service.dart';
import '../../services/romdrop/romdrop_connection.dart';
import '../../services/romdrop/romdrop_controller.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/console_hud.dart';
import '../emulators/emulator_steps_screen.dart';
import 'widgets/system_screen.dart' show hudClearance;

typedef RomDropProbe = Future<String?> Function(String baseUrl);
typedef RomDropPair = Future<RomDropPairing> Function({
  required String baseUrl,
  required String code,
  required String deviceName,
  String? pinnedFingerprint,
});
typedef RomDropApiBuilder = RomDropApiService Function(
    String baseUrl, String token, String? pinnedFingerprint);

/// Settings > RomDrop: the server that hosts the system files.
///
/// RomDrop has its own credential, separate from the RetroArr source's API
/// key. The device is paired with a short-lived code from RomDrop > Devices
/// and then holds a read-only credential in secure storage.
class RomDropConnectionScreen extends ConsumerStatefulWidget {
  const RomDropConnectionScreen({
    super.key,
    this.probe = RomDropApiService.untrustedFingerprint,
    this.pair = _defaultPair,
    this.apiBuilder = _defaultApi,
  });

  final RomDropProbe probe;
  final RomDropPair pair;
  final RomDropApiBuilder apiBuilder;

  static Future<RomDropPairing> _defaultPair({
    required String baseUrl,
    required String code,
    required String deviceName,
    String? pinnedFingerprint,
  }) =>
      RomDropApiService.pair(
          baseUrl: baseUrl,
          code: code,
          deviceName: deviceName,
          pinnedFingerprint: pinnedFingerprint);

  static RomDropApiService _defaultApi(
          String baseUrl, String token, String? pinnedFingerprint) =>
      RomDropApiService(
          baseUrl: baseUrl, token: token, pinnedFingerprint: pinnedFingerprint);

  @override
  ConsumerState<RomDropConnectionScreen> createState() =>
      _RomDropConnectionScreenState();
}

class _Field {
  _Field(this.label, this.controller, {this.hint = '', this.monospace = false})
      : consoleFocus = FocusNode(debugLabel: 'romdrop_${label}_wrap'),
        textFocus =
            FocusNode(skipTraversal: true, debugLabel: 'romdrop_${label}_text');

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool monospace;
  final FocusNode consoleFocus;
  final FocusNode textFocus;
}

class _RomDropConnectionScreenState
    extends ConsumerState<RomDropConnectionScreen> {
  final _urlCtl = TextEditingController();
  final _codeCtl = TextEditingController();
  final _nameCtl = TextEditingController(text: 'R-Shop');
  late final List<_Field> _fields = [
    _Field('Server address', _urlCtl,
        hint: 'https://192.168.1.10:3002', monospace: true),
    _Field('Pairing code', _codeCtl,
        hint: 'From RomDrop > Devices > Pair a device', monospace: true),
    _Field('Name for this device', _nameCtl, hint: 'R-Shop'),
  ];
  final _screenFocus = FocusNode(debugLabel: 'romdrop_connection');
  final _connectFocus = FocusNode(debugLabel: 'romdrop_connect');
  final _testFocus = FocusNode(debugLabel: 'romdrop_test');
  final _disconnectFocus = FocusNode(debugLabel: 'romdrop_disconnect');

  RomDropController? _controller;
  bool _prefilled = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  RomDropCapabilities? _capabilities;

  @override
  void initState() {
    super.initState();
    _urlCtl.addListener(_redraw);
    _codeCtl.addListener(_redraw);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fields.first.consoleFocus.requestFocus();
    });
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_redraw);
    for (final field in _fields) {
      field.controller.dispose();
      field.consoleFocus.dispose();
      field.textFocus.dispose();
    }
    _screenFocus.dispose();
    _connectFocus.dispose();
    _testFocus.dispose();
    _disconnectFocus.dispose();
    super.dispose();
  }

  void _attach(RomDropController controller) {
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_redraw);
    _controller = controller..addListener(_redraw);
    if (!_prefilled && controller.connection != null) {
      _prefilled = true;
      _urlCtl.text = controller.connection!.baseUrl;
      if (controller.connection!.deviceName.isNotEmpty) {
        _nameCtl.text = controller.connection!.deviceName;
      }
    }
  }

  bool get _connected => _controller?.configured ?? false;
  bool get _isToken =>
      _codeCtl.text.trim().startsWith(RomDropApiService.tokenPrefix);
  bool get _editing => _fields.any((f) => f.textFocus.hasFocus);

  List<FocusNode> get _order => [
        for (final field in _fields) field.consoleFocus,
        _connectFocus,
        if (_connected) ...[_testFocus, _disconnectFocus],
      ];

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      for (final field in _fields) {
        if (field.textFocus.hasFocus) {
          field.consoleFocus.requestFocus();
          return KeyEventResult.handled;
        }
      }
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (_editing) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final order = _order;
      final current = order.indexWhere((n) => n.hasFocus);
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = ((current < 0 ? 0 : current) + delta)
          .clamp(0, order.length - 1);
      if (next != current) {
        order[next].requestFocus();
        ref.read(feedbackServiceProvider).tick();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => EmulatorStepsScreen(
              title: title,
              intro: detail,
              steps: const [],
              confirmLabel: action))) ??
      false;

  Future<void> _connect() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final url = RomDropApiService.normalizeUrl(_urlCtl.text);
      final credential = _codeCtl.text.trim();
      if (credential.isEmpty) {
        throw const FormatException(
            'Enter the pairing code shown in RomDrop under Devices > Pair a device.');
      }
      final name =
          _nameCtl.text.trim().isEmpty ? 'R-Shop' : _nameCtl.text.trim();
      final previous = controller.connection;
      var pin = previous != null && previous.baseUrl == url
          ? previous.certificateFingerprint
          : null;
      // A certificate this device cannot verify by itself is only accepted
      // after the user compared its fingerprint with the server's.
      final presented = await widget.probe(url);
      if (presented == null) {
        pin = null;
      } else if (pin == null ||
          RomDropApiService.canonicalFingerprint(pin) !=
              RomDropApiService.canonicalFingerprint(presented)) {
        if (!mounted) return;
        final accepted = await _confirm(
            pin == null
                ? 'Check RomDrop\'s certificate'
                : 'RomDrop\'s certificate changed',
            '${pin == null ? 'RomDrop uses a self-signed certificate, so this device cannot verify it by itself.' : 'The server now presents a different certificate than the one you accepted.'} '
                'Compare this SHA-256 fingerprint with the one on the Status page of RomDrop\'s admin site:\n\n'
                '${RomDropApiService.fingerprintBlock(presented)}\n\n'
                'Continue only if they are the same.',
            'They match');
        if (!accepted) return;
        pin = presented;
      }
      final token = _isToken
          ? credential
          : (await widget.pair(
                  baseUrl: url,
                  code: credential,
                  deviceName: name,
                  pinnedFingerprint: pin))
              .token;
      final capabilities =
          await widget.apiBuilder(url, token, pin).capabilities();
      await controller.connect(
          RomDropConnection(
            baseUrl: url,
            deviceId: capabilities.deviceId,
            deviceName: capabilities.deviceName,
            certificateFingerprint: pin,
          ),
          token);
      _codeCtl.clear();
      if (!mounted) return;
      setState(() {
        _capabilities = capabilities;
        _notice = 'Connected as "${capabilities.deviceName}".';
      });
      _testFocus.requestFocus();
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = getUserFriendlyError(e, returnRawOnNoMatch: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final api = _controller?.api;
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final capabilities = await api.capabilities();
      if (!mounted) return;
      setState(() {
        _capabilities = capabilities;
        _notice = capabilities.libraryAvailable
            ? 'Connection works.'
            : 'Connected, but the system-file library is offline: ${capabilities.libraryReason ?? 'see RomDrop\'s Status page'}';
      });
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = getUserFriendlyError(e, returnRawOnNoMatch: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final controller = _controller;
    final connection = controller?.connection;
    if (controller == null || connection == null || _busy) return;
    final confirmed = await _confirm(
        'Disconnect from RomDrop?',
        'This device forgets the server and its credential. Files already saved stay where they are.\n\n'
            'The credential itself keeps working until you revoke it: in RomDrop\'s admin site open Devices and choose Revoke next to "${connection.deviceName}".',
        'Disconnect');
    if (!confirmed) return;
    await controller.disconnect();
    if (!mounted) return;
    setState(() {
      _capabilities = null;
      _error = null;
      _notice =
          'Disconnected. Revoke "${connection.deviceName}" in RomDrop under Devices to end its access.';
    });
    _fields.first.consoleFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(romDropControllerProvider).valueOrNull;
    if (controller != null) _attach(controller);
    final connection = controller?.connection;
    final insecure = _urlCtl.text.trim().toLowerCase().startsWith('http://');
    final capabilities = _capabilities;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Stack(
        children: [
          SafeArea(
            child: Focus(
              focusNode: _screenFocus,
              autofocus: true,
              onKeyEvent: _handleKey,
              child: Container(
                alignment: Alignment.topCenter,
                padding: const EdgeInsets.only(bottom: hudClearance),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  // Not a lazy list: every field and button has to exist for
                  // the controller to move focus to it.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('RomDrop',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                            'The server that keeps your BIOS, firmware and key files. '
                            'It has its own sign-in for this device; your RetroArr source is not affected.',
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12)),
                        const SizedBox(height: 16),
                        if (connection != null) ...[
                          _summary(connection, capabilities),
                          const SizedBox(height: 16),
                        ],
                        for (final field in _fields) ...[
                          _textBox(field),
                          const SizedBox(height: 12),
                        ],
                        if (insecure)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                                'This address is not encrypted. The device credential and files would travel in the clear, '
                                'and RomDrop does not send sensitive files that way. Use the https:// address.',
                                style: TextStyle(
                                    color: Colors.amber, fontSize: 13)),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: Colors.redAccent, fontSize: 13)),
                          ),
                        if (_notice != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(_notice!,
                                style: const TextStyle(
                                    color: Colors.greenAccent, fontSize: 13)),
                          ),
                        _button(
                            _connectFocus,
                            _busy
                                ? 'Working…'
                                : connection == null
                                    ? 'Connect'
                                    : 'Pair again',
                            AppTheme.primaryColor,
                            _connect),
                        if (connection != null) ...[
                          const SizedBox(height: 8),
                          _button(_testFocus, 'Test Connection', Colors.white70,
                              _test),
                          const SizedBox(height: 8),
                          _button(_disconnectFocus, 'Disconnect',
                              Colors.redAccent, _disconnect),
                        ],
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

  Widget _summary(
      RomDropConnection connection, RomDropCapabilities? capabilities) {
    final lines = <(String, String)>[
      ('Connected to', connection.baseUrl),
      ('This device', connection.deviceName),
      (
        'Encryption',
        !connection.encrypted
            ? 'None (plain HTTP)'
            : connection.certificateFingerprint == null
                ? 'HTTPS, certificate verified by this device'
                : 'HTTPS, certificate you accepted'
      ),
      if (connection.certificateFingerprint != null)
        (
          'Certificate SHA-256',
          '\n${RomDropApiService.fingerprintBlock(connection.certificateFingerprint!)}'
        ),
      if (capabilities != null)
        (
          'Sensitive files',
          capabilities.canSensitive
              ? 'Allowed for this device'
              : 'Not allowed (change it in RomDrop > Devices)'
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('$label: $value',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  Widget _button(
      FocusNode focus, String label, Color color, VoidCallback onSelect) {
    return ConsoleFocusable(
      // Keyed by its focus node: fields and buttons appear and disappear,
      // and each must keep its own element.
      key: ObjectKey(focus),
      focusNode: focus,
      focusScale: 1.0,
      onSelect: _busy ? null : onSelect,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 2),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _textBox(_Field field) {
    return ConsoleFocusable(
      key: ObjectKey(field.consoleFocus),
      focusNode: field.consoleFocus,
      focusScale: 1.0,
      onSelect: () => field.textFocus.requestFocus(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            // Clear of the focus outline, which hugs this column.
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Text(field.label.toUpperCase(),
                style: const TextStyle(
                    color: Colors.grey, fontSize: 11, letterSpacing: 1.2)),
          ),
          ListenableBuilder(
            listenable: field.textFocus,
            builder: (context, _) => Container(
              decoration: BoxDecoration(
                color: const Color(0xFF252525),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: field.textFocus.hasFocus
                      ? AppTheme.primaryColor
                      : AppTheme.primaryColor.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: TextField(
                controller: field.controller,
                focusNode: field.textFocus,
                // A pasted device token is a long-lived secret; a pairing
                // code is short-lived and easier to type when visible.
                obscureText: field.controller == _codeCtl && _isToken,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: field.monospace ? 'monospace' : null,
                ),
                decoration: InputDecoration(
                  hintText: field.hint,
                  hintStyle:
                      TextStyle(color: Colors.grey.shade700, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
