import 'package:flutter/painting.dart';

const _kb = 1024;
const _mb = _kb * 1024;
const _gb = _mb * 1024;

/// A size short enough for a game tile: "850 MB", "3.1 GB", "64 GB".
String formatSize(int bytes) {
  // Each form hands over where its own figure would round up to the next.
  if (bytes >= 9.95 * _gb) return '${(bytes / _gb).round()} GB';
  if (bytes >= _gb - _mb ~/ 2) return '${(bytes / _gb).toStringAsFixed(1)} GB';
  if (bytes >= _mb - _kb ~/ 2) return '${(bytes / _mb).round()} MB';
  if (bytes >= _kb) return '${(bytes / _kb).round()} KB';
  return '$bytes B';
}

/// How heavy an amount of installed data is, in five steps. The steps are
/// absolute sizes, so a platform keeps its level until its own size changes,
/// whatever the other platforms hold.
const sizeLevels = 5;

const _levelLimits = [250 * _mb, _gb, 4 * _gb, 16 * _gb];

/// 0 (under 250 MB) to 4 (16 GB and more).
int sizeLevel(int bytes) {
  for (var level = 0; level < _levelLimits.length; level++) {
    if (bytes < _levelLimits[level]) return level;
  }
  return _levelLimits.length;
}

/// One hue, the green the library already uses for "installed", from dim to
/// bright: the more space taken, the more intense. Checked as an ordinal ramp
/// against the library's black background (lightness rises step by step,
/// every step is clearly apart from the next, and the dimmest still stands
/// out at 2.9:1).
const sizeRamp = [
  Color(0xFF01633E),
  Color(0xFF0D8355),
  Color(0xFF07A66C),
  Color(0xFF27C986),
  Color(0xFF56EAA5),
];

Color sizeColor(int bytes) => sizeRamp[sizeLevel(bytes)];

/// Space on the storage that is used by something other than games.
const otherUsedColor = Color(0xFF898781);

/// The unused part of a meter.
const meterTrackColor = Color(0xFF2C2C2A);
