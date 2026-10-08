import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Makes one Back from Android count once.
///
/// From Android 14 on, a Back gesture or button reaches the app twice: first
/// as a key press (`goBack`), which the screens and overlays act on like the
/// B button, and then through Android's back callback, which Flutter turns
/// into "pop the current route". Acting on both closed two things per swipe:
/// a page and then the one behind it, or a page and then the exit question.
///
/// The guard watches for the key press and swallows the "pop the route" that
/// belongs to it. A Back that arrives without a key press, or whose key press
/// nothing acted on, still pops the route as before.
class SystemBackGuard with WidgetsBindingObserver {
  SystemBackGuard({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How long after the key press its route pop can still arrive. The two
  /// come within the same touch, a few milliseconds apart.
  static const _pairWindow = Duration(seconds: 1);

  DateTime? _backKeyAt;
  bool _backKeyActedOn = false;

  /// Starts watching. Attach before the app's navigator exists, so this
  /// observer is asked before the one that pops routes.
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_beforeTheApp);
    FocusManager.instance.addLateKeyEventHandler(_afterTheApp);
  }

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeEarlyKeyEventHandler(_beforeTheApp);
    FocusManager.instance.removeLateKeyEventHandler(_afterTheApp);
  }

  static bool _isBackPress(KeyEvent event) =>
      event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.goBack;

  KeyEventResult _beforeTheApp(KeyEvent event) {
    if (_isBackPress(event)) {
      _backKeyAt = _clock();
      // Until the late handler below says nothing took it.
      _backKeyActedOn = true;
    }
    return KeyEventResult.ignored;
  }

  /// Only reached by key presses no screen or overlay handled.
  KeyEventResult _afterTheApp(KeyEvent event) {
    if (_isBackPress(event)) _backKeyActedOn = false;
    return KeyEventResult.ignored;
  }

  @override
  Future<bool> didPopRoute() async {
    final pressedAt = _backKeyAt;
    _backKeyAt = null;
    if (pressedAt == null || !_backKeyActedOn) return false;
    final stillDown = HardwareKeyboard.instance.logicalKeysPressed
        .contains(LogicalKeyboardKey.goBack);
    // True tells Flutter this Back is dealt with: it was, as a key press.
    return stillDown || _clock().difference(pressedAt) < _pairWindow;
  }
}
