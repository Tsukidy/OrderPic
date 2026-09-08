import 'package:flutter_test/flutter_test.dart';

import 'package:orderpic/capture/naming.dart';
import 'package:orderpic/settings/app_settings.dart';

void main() {
  test('first shot indexed 001', () {
    final n = buildUploadFileName(orderNumber: '100438',
        admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 1,
        format: ImageFormat.jpeg);
    expect(n, '100438_20260908_140305_001.jpg');
  });

  test('same-second shots get distinct indexes', () {
    final when = DateTime(2026, 9, 8, 14, 3, 5);
    final a = buildUploadFileName(orderNumber: '100438',
        admittedAt: when, shotIndex: 1, format: ImageFormat.jpeg);
    final b = buildUploadFileName(orderNumber: '100438',
        admittedAt: when, shotIndex: 2, format: ImageFormat.jpeg);
    expect(a, '100438_20260908_140305_001.jpg');
    expect(b, '100438_20260908_140305_002.jpg');
  });

  test('png extension follows format', () {
    final n = buildUploadFileName(orderNumber: '100438',
        admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 1,
        format: ImageFormat.png);
    expect(n, '100438_20260908_140305_001.png');
  });

  test('index pads past 99 without truncation', () {
    final n = buildUploadFileName(orderNumber: '100438',
        admittedAt: DateTime(2026, 9, 8, 14, 3, 5), shotIndex: 123,
        format: ImageFormat.jpeg);
    expect(n, '100438_20260908_140305_123.jpg');
  });

  group('parseUploadName', () {
    test('legacy 3-part name parses to order and readable time', () {
      final parsed = parseUploadName('100438_20260901_101530.jpg');
      expect(parsed, isNotNull);
      expect(parsed!.$1, '100438');
      expect(parsed.$2, '2026-09-01 10:15:30');
    });

    test('new 4-part name parses to same order and time, index ignored', () {
      final parsed = parseUploadName('100438_20260908_140305_003.png');
      expect(parsed, isNotNull);
      expect(parsed!.$1, '100438');
      expect(parsed.$2, '2026-09-08 14:03:05');
    });

    test('garbage name returns null', () {
      expect(parseUploadName('garbage_name.jpg'), isNull);
    });

    test('4-part name with non-3-digit index returns null', () {
      expect(parseUploadName('a_20260101_000000_1.jpg'), isNull);
    });

    test('non-digit date segment returns null', () {
      expect(parseUploadName('100438_2026090a_101530.jpg'), isNull);
    });

    test('descending name sort over mixed shapes is newest first', () {
      final names = [
        'a_20260101_000000_001.jpg',
        'a_20251231_235959.jpg',
        'b_20260102_000000_002.jpg',
      ];
      names.sort((a, b) => b.compareTo(a));
      expect(names, [
        'b_20260102_000000_002.jpg',
        'a_20260101_000000_001.jpg',
        'a_20251231_235959.jpg',
      ]);
    });
  });
}
