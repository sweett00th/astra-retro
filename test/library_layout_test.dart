import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/core/input/app_intents.dart';
import 'package:retro_eshop/features/library/library_layout.dart';

const _metrics = LibraryMetrics(
  topPadding: 10,
  bottomPadding: 20,
  recentsHeight: 100,
  headerHeight: 50,
  tileHeight: 80,
  rowSpacing: 8,
  sectionGap: 16,
);

/// Two platforms: 5 games (indexes 0-4) and 2 games (5-6), 3 columns.
LibraryLayout _layout({
  int recents = 2,
  bool firstExpanded = false,
  bool secondExpanded = false,
}) =>
    LibraryLayout(
      recentCount: recents,
      columns: 3,
      metrics: _metrics,
      sections: [
        LibrarySection(key: 'gc', start: 0, count: 5, expanded: firstExpanded),
        LibrarySection(key: 'n64', start: 5, count: 2, expanded: secondExpanded),
      ],
    );

void main() {
  group('rows', () {
    test('collapsed platforms show only recents and headers', () {
      final layout = _layout();
      expect(layout.rows.map((r) => r.kind), [
        LibraryCursorKind.recent,
        LibraryCursorKind.header,
        LibraryCursorKind.header,
      ]);
      expect(layout.rows.map((r) => r.top), [10, 110, 160]);
      expect(layout.contentHeight, 230);
      expect(layout.first, const LibraryCursor.recent(0));
    });

    test('an expanded platform adds its grid rows below the header', () {
      final layout = _layout(firstExpanded: true);
      // recents, gc header, 2 grid rows (3 + 2 games), n64 header
      expect(layout.rows.map((r) => r.count), [2, 1, 3, 2, 1]);
      expect(layout.rows.map((r) => r.top), [10, 110, 160, 248, 344]);
      expect(layout.contentHeight, 344 + 50 + 20);
    });

    test('no recents starts on the first header', () {
      expect(_layout(recents: 0).first, const LibraryCursor.header(0));
    });

    test('a headerless section is a plain grid', () {
      final layout = LibraryLayout(
        recentCount: 0,
        columns: 3,
        metrics: _metrics,
        sections: const [
          LibrarySection(key: '', start: 0, count: 4, hasHeader: false),
        ],
      );
      expect(layout.rows.map((r) => r.kind),
          [LibraryCursorKind.game, LibraryCursorKind.game]);
      expect(layout.first, const LibraryCursor.game(0));
    });

    test('empty library has no cells', () {
      final layout = LibraryLayout(
          recentCount: 0, columns: 3, metrics: _metrics, sections: const []);
      expect(layout.first, isNull);
      expect(layout.resolve(const LibraryCursor.game(3)), isNull);
    });
  });

  group('move', () {
    test('down walks recents, header, grid rows, next header', () {
      final layout = _layout(firstExpanded: true);
      var cursor = layout.first!;
      final visited = <LibraryCursor>[cursor];
      while (true) {
        final next = layout.move(cursor, GridDirection.down, column: 1);
        if (next == null) break;
        visited.add(cursor = next);
      }
      expect(visited, const [
        LibraryCursor.recent(0),
        LibraryCursor.header(0),
        LibraryCursor.game(1),
        LibraryCursor.game(4),
        LibraryCursor.header(1),
      ]);
    });

    test('the chosen column is clamped to shorter rows', () {
      final layout = _layout(firstExpanded: true);
      expect(
          layout.move(const LibraryCursor.game(2), GridDirection.down,
              column: 2),
          const LibraryCursor.game(4));
    });

    test('left and right stay inside the row', () {
      final layout = _layout(firstExpanded: true);
      expect(layout.move(const LibraryCursor.game(0), GridDirection.left),
          isNull);
      expect(layout.move(const LibraryCursor.game(0), GridDirection.right),
          const LibraryCursor.game(1));
      expect(layout.move(const LibraryCursor.game(2), GridDirection.right),
          isNull);
      expect(layout.move(const LibraryCursor.game(4), GridDirection.right),
          isNull);
      expect(layout.move(const LibraryCursor.header(0), GridDirection.right),
          isNull);
      expect(layout.move(const LibraryCursor.recent(0), GridDirection.right),
          const LibraryCursor.recent(1));
    });

    test('up into recents returns to the remembered tile', () {
      final layout = _layout();
      expect(
          layout.move(const LibraryCursor.header(0), GridDirection.up,
              recentIndex: 1),
          const LibraryCursor.recent(1));
      expect(
          layout.move(const LibraryCursor.header(0), GridDirection.up,
              recentIndex: 9),
          const LibraryCursor.recent(1));
    });

    test('edges return null', () {
      final layout = _layout();
      expect(layout.move(const LibraryCursor.recent(0), GridDirection.up),
          isNull);
      expect(layout.move(const LibraryCursor.header(1), GridDirection.down),
          isNull);
    });
  });

  group('resolve', () {
    test('a game in a collapsed platform falls back to its header', () {
      final layout = _layout(firstExpanded: true);
      expect(layout.resolve(const LibraryCursor.game(6)),
          const LibraryCursor.header(1));
      expect(layout.resolve(const LibraryCursor.game(3)),
          const LibraryCursor.game(3));
    });

    test('out of range cursors are clamped', () {
      final layout = _layout(secondExpanded: true);
      expect(layout.resolve(const LibraryCursor.game(40)),
          const LibraryCursor.game(6));
      expect(layout.resolve(const LibraryCursor.recent(5)),
          const LibraryCursor.recent(1));
      expect(layout.resolve(const LibraryCursor.header(7)),
          const LibraryCursor.header(1));
    });

    test('recents that disappeared fall back to the first cell', () {
      expect(_layout(recents: 0).resolve(const LibraryCursor.recent(0)),
          const LibraryCursor.header(0));
    });
  });

  test('cell ids never collide', () {
    final ids = {
      for (var i = 0; i < 50; i++) ...[
        LibraryCursor.game(i).id,
        LibraryCursor.header(i).id,
        LibraryCursor.recent(i).id,
      ],
    };
    expect(ids.length, 150);
  });

  test('firstVisibleRow finds the row to move the cursor to after scrolling',
      () {
    final layout = _layout(firstExpanded: true);
    // Viewport 200 tall scrolled to 150: gc grid row 0 (160-240) fits.
    final row = layout.firstVisibleRow(150, 200)!;
    expect(row.kind, LibraryCursorKind.game);
    expect(layout.cellIn(row, 5), const LibraryCursor.game(2));
    // Viewport too small for any whole row: the row under its top edge.
    expect(layout.firstVisibleRow(170, 30)!.start, 0);
  });
}
