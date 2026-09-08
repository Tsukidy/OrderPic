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
}
