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

/// Two platforms: 5 games (indexes 0-4) and 2 games (5-6).
LibraryLayout _layout({
  int recents = 2,
  bool firstExpanded = true,
  bool secondExpanded = true,
  double leadIn = 0,
}) =>
    LibraryLayout(
      recentCount: recents,
      columns: 3,
      metrics: _metrics,
      leadIn: leadIn,
      sections: [
        LibrarySection(key: 'gc', start: 0, count: 5, expanded: firstExpanded),
        LibrarySection(key: 'n64', start: 5, count: 2, expanded: secondExpanded),
      ],
    );

/// Search results or a shelf: one wrapped grid, 3 per row.
LibraryLayout _grid(int count) => LibraryLayout(
      recentCount: 0,
      columns: 3,
      metrics: _metrics,
      sections: [
        LibrarySection(key: '', start: 0, count: count, hasHeader: false),
      ],
    );

void main() {
  group('rows', () {
    test('each platform is a header and one strip holding all its games', () {
      final layout = _layout();
      expect(layout.rows.map((r) => r.kind), [
        LibraryCursorKind.recent,
        LibraryCursorKind.header,
        LibraryCursorKind.game,
        LibraryCursorKind.header,
        LibraryCursorKind.game,
      ]);
      expect(layout.rows.map((r) => r.count), [2, 1, 5, 1, 2]);
      expect(layout.rows.map((r) => r.strip), [true, false, true, false, true]);
      expect(layout.rows.map((r) => r.top), [10, 110, 160, 256, 306]);
      expect(layout.rows.map((r) => r.extent), [100, 50, 96, 50, 96]);
      expect(layout.contentHeight, 306 + 96 + 20);
    });

    test('a collapsed platform keeps only its header', () {
      final layout = _layout(firstExpanded: false);
      expect(layout.rows.map((r) => r.count), [2, 1, 1, 2]);
      expect(layout.rowIndexOf(const LibraryCursor.game(2)), -1);
      expect(layout.rowIndexOf(const LibraryCursor.game(6)), 3);
    });

    test('the cursor starts on a game, not on a platform header', () {
      expect(_layout().firstTile, const LibraryCursor.recent(0));
      expect(_layout(recents: 0).first, const LibraryCursor.header(0));
      expect(_layout(recents: 0).firstTile, const LibraryCursor.game(0));
      expect(
          _layout(recents: 0, firstExpanded: false, secondExpanded: false)
              .firstTile,
          const LibraryCursor.header(0));
    });

    test('a lead-in pushes every row down', () {
      final layout = _layout(recents: 0, leadIn: 40);
      expect(layout.rows.first.top, 50);
      expect(layout.contentHeight, 50 + 50 + 96 + 50 + 96 + 20);
    });

    test('a headerless section is a wrapped grid', () {
      final layout = _grid(4);
      expect(layout.rows.map((r) => r.count), [3, 1]);
      expect(layout.rows.every((r) => !r.strip), isTrue);
      expect(layout.rows.map((r) => r.top), [10, 98]);
      expect(layout.rows.map((r) => r.extent), [88, 96]);
      expect(layout.firstTile, const LibraryCursor.game(0));
    });

    test('empty library has no cells', () {
      final layout = LibraryLayout(
          recentCount: 0, columns: 3, metrics: _metrics, sections: const []);
      expect(layout.first, isNull);
      expect(layout.firstTile, isNull);
      expect(layout.resolve(const LibraryCursor.game(3)), isNull);
    });
  });

  group('move', () {
    test('down walks recents, header, strip, header, strip', () {
      final layout = _layout();
      var cursor = layout.first!;
      final visited = <LibraryCursor>[cursor];
      while (true) {
        final next = layout.move(cursor, GridDirection.down);
        if (next == null) break;
        visited.add(cursor = next);
      }
      expect(visited, const [
        LibraryCursor.recent(0),
        LibraryCursor.header(0),
        LibraryCursor.game(0),
        LibraryCursor.header(1),
        LibraryCursor.game(5),
      ]);
    });

    test('left and right run along the whole strip', () {
      final layout = _layout();
      var cursor = const LibraryCursor.game(0);
      for (var i = 1; i <= 4; i++) {
        cursor = layout.move(cursor, GridDirection.right)!;
        expect(cursor, LibraryCursor.game(i));
      }
      // End of the platform: does not spill into the next one.
      expect(layout.move(cursor, GridDirection.right), isNull);
      expect(layout.move(const LibraryCursor.game(5), GridDirection.left),
          isNull);
      expect(layout.move(const LibraryCursor.header(0), GridDirection.right),
          isNull);
    });

    test('entering a strip returns to the tile it was left on', () {
      final layout = _layout();
      int memory(LibraryRow row) => switch (row.kind) {
            LibraryCursorKind.recent => 1,
            _ => row.section == 0 ? 3 : 9,
          };
      expect(
          layout.move(const LibraryCursor.header(0), GridDirection.down,
              stripPosition: memory),
          const LibraryCursor.game(3));
      // A remembered position past the end is clamped.
      expect(
          layout.move(const LibraryCursor.header(1), GridDirection.down,
              stripPosition: memory),
          const LibraryCursor.game(6));
      expect(
          layout.move(const LibraryCursor.header(0), GridDirection.up,
              stripPosition: memory),
          const LibraryCursor.recent(1));
    });

    test('a wrapped grid keeps the chosen column across short rows', () {
      final layout = _grid(5);
      expect(
          layout.move(const LibraryCursor.game(2), GridDirection.down,
              column: 2),
          const LibraryCursor.game(4));
      expect(layout.move(const LibraryCursor.game(2), GridDirection.right),
          isNull);
      expect(layout.move(const LibraryCursor.game(4), GridDirection.up, column: 2),
          const LibraryCursor.game(2));
    });

    test('edges return null', () {
      final layout = _layout();
      expect(layout.move(const LibraryCursor.recent(0), GridDirection.up),
          isNull);
      expect(layout.move(const LibraryCursor.game(6), GridDirection.down),
          isNull);
    });
  });

  group('resolve', () {
    test('a game in a collapsed platform falls back to its header', () {
      final layout = _layout(secondExpanded: false);
      expect(layout.resolve(const LibraryCursor.game(6)),
          const LibraryCursor.header(1));
      expect(layout.resolve(const LibraryCursor.game(3)),
          const LibraryCursor.game(3));
    });

    test('out of range cursors are clamped', () {
      final layout = _layout();
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
    final layout = _layout();
    // Viewport 200 tall scrolled to 150: the first strip (160-240) fits.
    final row = layout.firstVisibleRow(150, 200)!;
    expect(row.kind, LibraryCursorKind.game);
    expect(layout.cellIn(row, 9), const LibraryCursor.game(4));
    // Viewport too small for any whole row: the row under its top edge.
    expect(layout.firstVisibleRow(170, 30)!.start, 0);
  });
}
