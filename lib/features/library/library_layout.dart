import '../../core/input/app_intents.dart';

enum LibraryCursorKind { recent, header, game }

/// Controller cursor position in the library.
///
/// [index] is the position in the recents row, the section index, or the
/// index into the flat game list, depending on [kind].
class LibraryCursor {
  final LibraryCursorKind kind;
  final int index;

  const LibraryCursor.recent(this.index) : kind = LibraryCursorKind.recent;
  const LibraryCursor.header(this.index) : kind = LibraryCursorKind.header;
  const LibraryCursor.game(this.index) : kind = LibraryCursorKind.game;

  static const _recentBase = -1000000;

  /// Unique int per cell for selection notifiers: games keep their list
  /// index; headers and recents use disjoint negative ranges.
  int get id => switch (kind) {
        LibraryCursorKind.game => index,
        LibraryCursorKind.header => -1 - index,
        LibraryCursorKind.recent => _recentBase - index,
      };

  @override
  bool operator ==(Object other) =>
      other is LibraryCursor && other.kind == kind && other.index == index;

  @override
  int get hashCode => Object.hash(kind, index);

  @override
  String toString() => 'LibraryCursor(${kind.name}, $index)';
}

/// A platform group. A section without a header is a plain grid (search
/// results, shelves) and always shows its games.
class LibrarySection {
  final String key;

  /// First game of the section in the flat game list.
  final int start;
  final int count;
  final bool hasHeader;
  final bool expanded;

  const LibrarySection({
    required this.key,
    required this.start,
    required this.count,
    this.hasHeader = true,
    this.expanded = false,
  });

  bool get showsGames => count > 0 && (expanded || !hasHeader);
}

/// Heights the scroll view is built with; the layout uses the same numbers
/// to know where every row is without it having been built.
class LibraryMetrics {
  final double topPadding;
  final double bottomPadding;

  /// Whole recents block (label, tiles and the gap below).
  final double recentsHeight;

  /// Section header including the gap below it.
  final double headerHeight;
  final double tileHeight;
  final double rowSpacing;

  /// Gap below the last row of an expanded section.
  final double sectionGap;

  const LibraryMetrics({
    this.topPadding = 0,
    this.bottomPadding = 0,
    required this.recentsHeight,
    required this.headerHeight,
    required this.tileHeight,
    required this.rowSpacing,
    required this.sectionGap,
  });
}

/// One horizontal line of focusable cells.
class LibraryRow {
  final LibraryCursorKind kind;

  /// Section index, or -1 for the recents row.
  final int section;

  /// First cell: recents index, section index or game index.
  final int start;
  final int count;
  final double top;
  final double height;

  const LibraryRow({
    required this.kind,
    required this.section,
    required this.start,
    required this.count,
    required this.top,
    required this.height,
  });

  double get bottom => top + height;
}

/// Rows of the library (recents, platform headers, game grids) with their
/// vertical positions, and d-pad movement between them.
class LibraryLayout {
  LibraryLayout({
    required this.recentCount,
    required this.sections,
    required this.columns,
    required this.metrics,
  }) : assert(columns > 0) {
    _build();
  }

  final int recentCount;
  final List<LibrarySection> sections;
  final int columns;
  final LibraryMetrics metrics;

  final List<LibraryRow> rows = [];
  final List<int> _headerRow = [];
  final List<int> _firstGameRow = [];
  double _contentHeight = 0;

  double get contentHeight => _contentHeight;

  void _build() {
    var y = metrics.topPadding;
    if (recentCount > 0) {
      rows.add(LibraryRow(
          kind: LibraryCursorKind.recent,
          section: -1,
          start: 0,
          count: recentCount,
          top: y,
          height: metrics.recentsHeight));
      y += metrics.recentsHeight;
    }
    for (var s = 0; s < sections.length; s++) {
      final section = sections[s];
      if (section.hasHeader) {
        _headerRow.add(rows.length);
        rows.add(LibraryRow(
            kind: LibraryCursorKind.header,
            section: s,
            start: s,
            count: 1,
            top: y,
            height: metrics.headerHeight));
        y += metrics.headerHeight;
      } else {
        _headerRow.add(-1);
      }
      if (!section.showsGames) {
        _firstGameRow.add(-1);
        continue;
      }
      _firstGameRow.add(rows.length);
      for (var offset = 0; offset < section.count; offset += columns) {
        final remaining = section.count - offset;
        rows.add(LibraryRow(
            kind: LibraryCursorKind.game,
            section: s,
            start: section.start + offset,
            count: remaining < columns ? remaining : columns,
            top: y,
            height: metrics.tileHeight));
        y += metrics.tileHeight +
            (remaining > columns ? metrics.rowSpacing : metrics.sectionGap);
      }
    }
    _contentHeight = y + metrics.bottomPadding;
  }

  /// First cell from the top, or null when nothing is shown.
  LibraryCursor? get first => rows.isEmpty ? null : _cellAt(rows.first, 0);

  /// Section holding [gameIndex], or -1.
  int sectionOfGame(int gameIndex) {
    for (var s = 0; s < sections.length; s++) {
      final section = sections[s];
      if (gameIndex >= section.start &&
          gameIndex < section.start + section.count) {
        return s;
      }
    }
    return -1;
  }

  /// Row showing [cursor], or -1 when it is not shown (out of range, or a
  /// game inside a collapsed section).
  int rowIndexOf(LibraryCursor cursor) {
    switch (cursor.kind) {
      case LibraryCursorKind.recent:
        return cursor.index >= 0 && cursor.index < recentCount ? 0 : -1;
      case LibraryCursorKind.header:
        if (cursor.index < 0 || cursor.index >= sections.length) return -1;
        return _headerRow[cursor.index];
      case LibraryCursorKind.game:
        final s = sectionOfGame(cursor.index);
        if (s < 0 || _firstGameRow[s] < 0) return -1;
        return _firstGameRow[s] +
            (cursor.index - sections[s].start) ~/ columns;
    }
  }

  LibraryRow? rowOf(LibraryCursor cursor) {
    final index = rowIndexOf(cursor);
    return index < 0 ? null : rows[index];
  }

  /// Position of [cursor] within its row.
  int columnOf(LibraryCursor cursor) {
    final row = rowOf(cursor);
    if (row == null) return 0;
    return row.kind == LibraryCursorKind.header ? 0 : cursor.index - row.start;
  }

  /// [cursor] if it is shown, otherwise the closest cell that is: a game in
  /// a collapsed section becomes that section's header, anything else the
  /// first cell.
  LibraryCursor? resolve(LibraryCursor cursor) {
    if (rowIndexOf(cursor) >= 0) return cursor;
    switch (cursor.kind) {
      case LibraryCursorKind.recent:
        if (recentCount > 0) {
          return LibraryCursor.recent(cursor.index.clamp(0, recentCount - 1));
        }
      case LibraryCursorKind.header:
        if (sections.isNotEmpty) {
          final s = cursor.index.clamp(0, sections.length - 1);
          if (_headerRow[s] >= 0) return LibraryCursor.header(s);
        }
      case LibraryCursorKind.game:
        final total =
            sections.isEmpty ? 0 : sections.last.start + sections.last.count;
        if (total > 0) {
          final index = cursor.index.clamp(0, total - 1);
          final s = sectionOfGame(index);
          if (s >= 0 && _firstGameRow[s] >= 0) return LibraryCursor.game(index);
          if (s >= 0 && _headerRow[s] >= 0) return LibraryCursor.header(s);
        }
    }
    return first;
  }

  /// Cell reached from [from] with one d-pad press, or null at an edge.
  ///
  /// [column] is the grid column the user last chose (kept while moving
  /// vertically through shorter rows and headers); [recentIndex] is the
  /// recents tile to return to.
  LibraryCursor? move(
    LibraryCursor from,
    GridDirection direction, {
    int column = 0,
    int recentIndex = 0,
  }) {
    final rowIndex = rowIndexOf(from);
    if (rowIndex < 0) return resolve(from);
    final row = rows[rowIndex];
    final position = columnOf(from);
    switch (direction) {
      case GridDirection.left:
        return position > 0 ? _cellAt(row, position - 1) : null;
      case GridDirection.right:
        return position < row.count - 1 ? _cellAt(row, position + 1) : null;
      case GridDirection.up:
      case GridDirection.down:
        final target = rowIndex + (direction == GridDirection.up ? -1 : 1);
        if (target < 0 || target >= rows.length) return null;
        final next = rows[target];
        final wanted =
            next.kind == LibraryCursorKind.recent ? recentIndex : column;
        return _cellAt(next, wanted.clamp(0, next.count - 1));
    }
  }

  LibraryCursor _cellAt(LibraryRow row, int position) => switch (row.kind) {
        LibraryCursorKind.recent => LibraryCursor.recent(row.start + position),
        LibraryCursorKind.header => LibraryCursor.header(row.section),
        LibraryCursorKind.game => LibraryCursor.game(row.start + position),
      };

  /// First row that is completely inside the viewport starting at
  /// [scrollOffset], or the row covering its top edge.
  LibraryRow? firstVisibleRow(double scrollOffset, double viewportHeight) {
    LibraryRow? covering;
    for (final row in rows) {
      if (row.top >= scrollOffset && row.bottom <= scrollOffset + viewportHeight) {
        return row;
      }
      if (row.top < scrollOffset && row.bottom > scrollOffset) covering = row;
    }
    return covering;
  }

  /// Cell of [row] closest to [column].
  LibraryCursor cellIn(LibraryRow row, int column) =>
      _cellAt(row, column.clamp(0, row.count - 1));
}
