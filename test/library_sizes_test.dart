import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/library/library_sizes.dart';

const _kb = 1024;
const _mb = 1024 * _kb;
const _gb = 1024 * _mb;

void main() {
  group('formatSize', () {
    test('is short enough for a game tile', () {
      expect(formatSize(0), '0 B');
      expect(formatSize(900), '900 B');
      expect(formatSize(40 * _kb), '40 KB');
      expect(formatSize(40 * _mb), '40 MB');
      expect(formatSize(850 * _mb), '850 MB');
      expect(formatSize((3.14 * _gb).round()), '3.1 GB');
      expect(formatSize(64 * _gb), '64 GB');
      expect(formatSize(420 * _gb), '420 GB');
    });

    test('never shows 1024 of a unit', () {
      expect(formatSize(_mb - 1), '1 MB');
      expect(formatSize(_mb - _kb), '1023 KB');
      expect(formatSize(_gb - 1), '1.0 GB');
      expect(formatSize(_gb - _mb), '1023 MB');
    });

    test('drops the decimal where it would read 10.0', () {
      expect(formatSize((9.94 * _gb).round()), '9.9 GB');
      expect(formatSize((9.96 * _gb).round()), '10 GB');
    });
  });

  group('sizeLevel', () {
    test('rises at fixed sizes', () {
      expect(sizeLevel(0), 0);
      expect(sizeLevel(250 * _mb - 1), 0);
      expect(sizeLevel(250 * _mb), 1);
      expect(sizeLevel(_gb), 2);
      expect(sizeLevel(4 * _gb), 3);
      expect(sizeLevel(16 * _gb), 4);
      expect(sizeLevel(500 * _gb), 4);
    });

    test('has a colour for every level', () {
      expect(sizeRamp, hasLength(sizeLevels));
      expect(sizeColor(0), sizeRamp.first);
      expect(sizeColor(500 * _gb), sizeRamp.last);
    });
  });
}
