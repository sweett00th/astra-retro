import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/library/widgets/library_storage_summary.dart';
import 'package:retro_eshop/services/disk_space_service.dart';

const _gb = 1024 * 1024 * 1024;

void main() {
  // 512 GB storage: 12 GB of games, 100 GB of other data, 400 GB free.
  Future<void> pumpSummary(
    WidgetTester tester, {
    required double width,
    int games = 12 * _gb,
    StorageInfo? storage =
        const StorageInfo(freeBytes: 400 * _gb, totalBytes: 512 * _gb),
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: LibraryStorageSummary(gamesBytes: games, storage: storage),
            ),
          ),
        ),
      ));

  List<String?> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
          of: find.byType(LibraryStorageSummary), matching: find.byType(Text)))
      .map((t) => t.data)
      .toList();

  testWidgets('shows the storage as a bar with what is used and what is free',
      (tester) async {
    await pumpSummary(tester, width: 700);

    expect(find.byType(StorageBar), findsOneWidget);
    expect(texts(tester),
        ['GAMES', '12 GB', 'OTHER', '100 GB', 'FREE', '400 GB']);
  });

  testWidgets('a narrow header drops Other, then the bar, then all of it',
      (tester) async {
    await pumpSummary(tester, width: 420);
    expect(find.byType(StorageBar), findsOneWidget);
    expect(texts(tester), ['GAMES', '12 GB', 'FREE', '400 GB']);

    await pumpSummary(tester, width: 250);
    expect(find.byType(StorageBar), findsNothing);
    expect(texts(tester), ['GAMES', '12 GB', 'FREE', '400 GB']);

    await pumpSummary(tester, width: 150);
    expect(texts(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the games alone where the storage cannot be asked',
      (tester) async {
    await pumpSummary(tester, width: 700, storage: null);

    expect(find.byType(StorageBar), findsNothing);
    expect(texts(tester), ['GAMES', '12 GB']);
  });

  testWidgets('a sliver stays visible and the bar keeps its length',
      (tester) async {
    // A few kilobytes of games and of other data on an almost empty storage.
    await pumpSummary(
      tester,
      width: 700,
      games: 4096,
      storage: const StorageInfo(
          freeBytes: 512 * _gb - 8192, totalBytes: 512 * _gb),
    );
    expect(tester.takeException(), isNull);

    final bar = find.byType(StorageBar);
    final parts = find.descendant(of: bar, matching: find.byType(Container));
    final widths = [
      for (var i = 0; i < 3; i++) tester.getSize(parts.at(i)).width,
    ];
    expect(parts, findsNWidgets(3));
    expect(widths.take(2), everyElement(2.0));
    // Three parts and two gaps of 2 make up the whole bar.
    expect(widths.reduce((a, b) => a + b) + 4, tester.getSize(bar).width);
  });
}
