import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/responsive/responsive.dart';

/// Label above a platform's row of games in the library: chevron (the row
/// collapses), platform name, its logo and how many games it holds.
class LibrarySectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final bool isSelected;
  final Color accentColor;
  final String? iconAsset;

  /// Games marked for uninstall in this platform (multi-select).
  final int markedCount;
  final VoidCallback onTap;

  const LibrarySectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.expanded,
    required this.isSelected,
    required this.accentColor,
    required this.onTap,
    this.iconAsset,
    this.markedCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final rs = context.rs;
    final iconSize = rs.isSmall ? 16.0 : 20.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.symmetric(horizontal: rs.isSmall ? 6 : 8),
        // A plain label above its row of games; it only gets a frame while
        // the cursor is on it.
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: isSelected ? 0.12 : 0),
          borderRadius: BorderRadius.circular(rs.isSmall ? 8 : 10),
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.chevron_right_rounded,
                size: iconSize + 2,
                color: isSelected ? Colors.white : Colors.grey[500],
              ),
            ),
            SizedBox(width: rs.isSmall ? 6 : 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: rs.isSmall ? 12 : 14,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? Colors.white : Colors.grey[300],
                  letterSpacing: 0.5,
                ),
              ),
            ),
            if (markedCount > 0) ...[
              _Pill(
                label: '$markedCount marked',
                color: Colors.redAccent,
                isSmall: rs.isSmall,
              ),
              const SizedBox(width: 10),
            ],
            // Platform logos are wordmarks of very different widths: on the
            // right they line up on one edge and leave the names aligned.
            if (iconAsset != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: rs.isSmall ? 84 : 110),
                child: SvgPicture.asset(
                  iconAsset!,
                  height: iconSize,
                  alignment: Alignment.centerRight,
                  colorFilter: ColorFilter.mode(accentColor, BlendMode.srcIn),
                  placeholderBuilder: (_) => SizedBox(height: iconSize),
                ),
              ),
              SizedBox(width: rs.isSmall ? 8 : 12),
            ],
            _Pill(
              label: '$count',
              color: isSelected ? Colors.white : Colors.grey[500]!,
              isSmall: rs.isSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSmall;

  const _Pill({required this.label, required this.color, required this.isSmall});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: isSmall ? 9 : 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
