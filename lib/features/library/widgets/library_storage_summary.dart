import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/disk_space_service.dart';
import '../library_sizes.dart';

/// Where the storage stands, at the top of the library: how much the
/// installed games take, what else is on it, and what is still free.
///
/// One thin stacked bar for the whole storage with the three figures spelled
/// out beside it, so nothing has to be read from colour alone. Narrow headers
/// drop the bar first, then "Other".
class LibraryStorageSummary extends StatelessWidget {
  const LibraryStorageSummary({
    super.key,
    required this.gamesBytes,
    required this.storage,
    this.isSmall = false,
  });

  /// Bytes the installed games take.
  final int gamesBytes;

  /// The storage the games are on; null where it cannot be asked (not on
  /// Android), which leaves just the games' figure.
  final StorageInfo? storage;
  final bool isSmall;

  @override
  Widget build(BuildContext context) {
    final storage = this.storage;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (storage == null || storage.totalBytes <= 0) {
        return width < 110
            ? const SizedBox.shrink()
            : _row([_figure(sizeRamp[3], 'Games', gamesBytes)]);
      }
      if (width < 190) return const SizedBox.shrink();
      final used = storage.totalBytes - storage.freeBytes;
      final games = gamesBytes.clamp(0, used);
      final other = used - games;
      final showBar = width >= 360;
      final showOther = width >= 500;
      return _row([
        if (showBar) ...[
          StorageBar(
            games: games,
            other: other,
            free: storage.freeBytes,
            width: isSmall ? 90 : 130,
          ),
          SizedBox(width: isSmall ? 8 : 12),
        ],
        _figure(sizeRamp[3], 'Games', gamesBytes),
        if (showOther) ...[
          SizedBox(width: isSmall ? 8 : 12),
          _figure(otherUsedColor, 'Other', other),
        ],
        SizedBox(width: isSmall ? 8 : 12),
        _figure(meterTrackColor, 'Free', storage.freeBytes, outlined: true),
      ]);
    });
  }

  Widget _row(List<Widget> children) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );

  /// A swatch, what it stands for, and the amount in plain text.
  Widget _figure(Color swatch, String label, int bytes,
      {bool outlined = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: swatch,
            borderRadius: BorderRadius.circular(2),
            // The free part is nearly as dark as the page: give it an edge.
            border: outlined ? Border.all(color: Colors.white24) : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: isSmall ? 9 : 10,
            fontWeight: FontWeight.w600,
            color: Colors.grey[400],
            letterSpacing: 1,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          formatSize(bytes),
          style: TextStyle(
            fontSize: isSmall ? 10 : 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

/// The whole storage as one bar: games, everything else in use, free.
class StorageBar extends StatelessWidget {
  const StorageBar({
    super.key,
    required this.games,
    required this.other,
    required this.free,
    required this.width,
  });

  final int games;
  final int other;
  final int free;
  final double width;

  static const _height = 6.0;
  static const _gap = 2.0;

  /// A sliver stays visible however small its share is.
  static const _minPart = 2.0;

  @override
  Widget build(BuildContext context) {
    final total = games + other + free;
    if (total <= 0) return SizedBox(width: width, height: _height);
    final parts = [
      (games, sizeRamp[3]),
      (other, otherUsedColor),
      (free, meterTrackColor),
    ].where((part) => part.$1 > 0).toList();
    final room = width - _gap * (parts.length - 1);
    final widths = [
      for (final part in parts) math.max(_minPart, room * part.$1 / total),
    ];
    // The largest part gives up what the slivers gained, so the bar keeps
    // its length.
    final excess = widths.fold<double>(0, (a, b) => a + b) - room;
    if (excess > 0) {
      var largest = 0;
      for (var i = 1; i < widths.length; i++) {
        if (widths[i] > widths[largest]) largest = i;
      }
      widths[largest] -= excess;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(_height / 2),
      child: SizedBox(
        width: width,
        height: _height,
        child: Row(
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Container(width: widths[i], color: parts[i].$2),
            ],
          ],
        ),
      ),
    );
  }
}
