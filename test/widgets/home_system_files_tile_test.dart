import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/core/responsive/responsive.dart';
import 'package:retro_eshop/features/home/widgets/hero_carousel_item.dart';
import 'package:retro_eshop/features/home/widgets/home_grid_view.dart';
import 'package:retro_eshop/l10n/app_localizations.dart';
import 'package:retro_eshop/models/system_model.dart';
import 'package:retro_eshop/providers/game_providers.dart';

void main() {
  Widget app(Widget Function(BuildContext context) child) => ProviderScope(
        overrides: [
          systemSourceCountsProvider.overrideWith(
              (ref) async => <String, ({int remote, int local})>{}),
        ],
        child: MaterialApp(
          localizationsDelegates: L.localizationsDelegates,
          supportedLocales: L.supportedLocales,
          home: Scaffold(body: Builder(builder: child)),
        ),
      );

  group('home grid', () {
    Widget grid({
      required int selected,
      required void Function(int index) onSelect,
      required VoidCallback onConfirm,
    }) =>
        app((context) => HomeGridView(
              systems: [SystemModel.supportedSystems.first],
              selectedIndex: selected,
              columns: 3,
              onSelect: onSelect,
              onConfirm: onConfirm,
              rs: context.rs,
            ));

    testWidgets('System Files is a tile of its own after the library',
        (tester) async {
      final selected = <int>[];
      var confirmed = 0;
      await tester.pumpWidget(grid(
          selected: 0, onSelect: selected.add, onConfirm: () => confirmed++));
      await tester.pumpAndSettle();

      expect(find.text('ALL GAMES'), findsOneWidget);
      expect(find.text('System Files'), findsOneWidget);
      expect(find.text('BIOS · Firmware · Keys'), findsOneWidget);
      expect(find.byIcon(Icons.memory_rounded), findsOneWidget);
      expect(
          tester.getTopLeft(find.text('System Files')).dx,
          greaterThan(tester.getTopLeft(find.text('ALL GAMES')).dx),
          reason: 'one console, the library, then System Files');

      await tester.tap(find.text('System Files'));
      expect(selected, [2]);
      expect(confirmed, 0, reason: 'the first tap only moves the cursor');
    });

    testWidgets('selecting it again opens it', (tester) async {
      var confirmed = 0;
      await tester.pumpWidget(
          grid(selected: 2, onSelect: (_) {}, onConfirm: () => confirmed++));
      await tester.pumpAndSettle();

      await tester.tap(find.text('System Files'));

      expect(confirmed, 1);
    });
  });

  testWidgets('the carousel entry carries the System Files icon',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(app((context) => Center(
          child: HeroLibraryCarouselItem(
            scale: 1,
            opacity: 1,
            isSelected: true,
            rs: context.rs,
            onTap: () => taps++,
            icon: Icons.memory_rounded,
            accentColor: systemFilesAccent,
          ),
        )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.memory_rounded), findsOneWidget);
    expect(find.byIcon(Icons.library_books_rounded), findsNothing);

    await tester.tap(find.byType(HeroLibraryCarouselItem));
    expect(taps, 1);
  });
}
