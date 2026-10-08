import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/core/input/system_back_guard.dart';

/// The app in miniature: a first page that asks before exiting, like the
/// console list, and pages on top that Back closes.
class _App extends StatefulWidget {
  const _App({required this.handlesBackKey});

  /// Whether the pages act on Android's Back key press themselves, as the
  /// real screens do.
  final bool handlesBackKey;

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  final guard = SystemBackGuard();
  int exitQuestions = 0;

  @override
  void initState() {
    super.initState();
    guard.attach();
  }

  @override
  void dispose() {
    guard.detach();
    super.dispose();
  }

  Widget _page(String name, {required bool first}) => Builder(
        builder: (context) => PopScope(
          canPop: !first,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => exitQuestions++);
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (!widget.handlesBackKey ||
                  event is! KeyDownEvent ||
                  event.logicalKey != LogicalKeyboardKey.goBack) {
                return KeyEventResult.ignored;
              }
              if (first) {
                setState(() => exitQuestions++);
              } else {
                Navigator.of(context).pop();
              }
              return KeyEventResult.handled;
            },
            child: Scaffold(body: Center(child: Text(name))),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: _page('console list', first: true),
        routes: {
          '/files': (_) => _page('system files', first: false),
          '/asset': (_) => _page('one asset', first: false),
        },
      );
}

/// Android's Back as a key press. The test simulator has no physical key of
/// its own for it; which one stands in does not matter to the app.
Future<void> _backKeyDown(WidgetTester tester) => tester.sendKeyDownEvent(
    LogicalKeyboardKey.goBack,
    physicalKey: PhysicalKeyboardKey.escape,
    platform: 'android');

Future<void> _backKeyUp(WidgetTester tester) => tester.sendKeyUpEvent(
    LogicalKeyboardKey.goBack,
    physicalKey: PhysicalKeyboardKey.escape,
    platform: 'android');

void main() {
  Future<_AppState> open(WidgetTester tester,
      {required bool handlesBackKey, List<String> pages = const []}) async {
    await tester.pumpWidget(_App(handlesBackKey: handlesBackKey));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    for (final page in pages) {
      navigator.pushNamed(page);
      await tester.pumpAndSettle();
    }
    return tester.state<_AppState>(find.byType(_App));
  }

  /// What Android 14 and later send for one Back: the key goes down, the
  /// back callback fires, the key comes up.
  Future<void> androidBack(WidgetTester tester) async {
    await _backKeyDown(tester);
    await tester.binding.handlePopRoute();
    await _backKeyUp(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('one Back closes one page', (tester) async {
    final app = await open(tester,
        handlesBackKey: true, pages: ['/files', '/asset']);
    expect(find.text('one asset'), findsOneWidget);

    await androidBack(tester);
    expect(find.text('system files'), findsOneWidget,
        reason: 'not two pages down');
    expect(app.exitQuestions, 0);

    await androidBack(tester);
    expect(find.text('console list'), findsOneWidget);
    expect(app.exitQuestions, 0,
        reason: 'leaving the last page must not also ask to exit');
  });

  testWidgets('Back on the first page asks to exit once', (tester) async {
    final app = await open(tester, handlesBackKey: true);

    await androidBack(tester);
    expect(app.exitQuestions, 1,
        reason: 'twice would open the question and close it again');
  });

  testWidgets('a Back that comes without a key press still pops the route',
      (tester) async {
    final app = await open(tester, handlesBackKey: true, pages: ['/files']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('console list'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(app.exitQuestions, 1);
  });

  testWidgets('a Back key press nothing acted on still pops the route',
      (tester) async {
    final app = await open(tester, handlesBackKey: false, pages: ['/files']);

    await androidBack(tester);
    expect(find.text('console list'), findsOneWidget);
    expect(app.exitQuestions, 0);

    await androidBack(tester);
    expect(app.exitQuestions, 1);
  });

  testWidgets('an old key press does not swallow a later Back', (tester) async {
    var now = DateTime(2026, 10, 8, 12);
    final guard = SystemBackGuard(clock: () => now)..attach();
    addTearDown(guard.detach);
    await tester.pumpWidget(MaterialApp(
      home: Focus(
        autofocus: true,
        onKeyEvent: (_, event) => event.logicalKey == LogicalKeyboardKey.goBack
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: const SizedBox(),
      ),
    ));
    await tester.pump();

    await _backKeyDown(tester);
    await _backKeyUp(tester);
    expect(await guard.didPopRoute(), isTrue, reason: 'the pair of that press');
    expect(await guard.didPopRoute(), isFalse,
        reason: 'one key press pairs with one route pop');

    await _backKeyDown(tester);
    await _backKeyUp(tester);
    now = now.add(const Duration(seconds: 5));
    expect(await guard.didPopRoute(), isFalse);
  });
}
