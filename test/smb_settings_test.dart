import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

void main() {
  group('SmbSettings', () {
    test('defaults seed config fields but never credentials', () {
      expect(SmbSettings.defaults.host, '192.168.1.29');
      expect(SmbSettings.defaults.sharePath, '/zdrive/InvoiceData');
      expect(SmbSettings.defaults.domain, '');
      expect(SmbSettings.defaults.username, ''); // never in the binary
      expect(SmbSettings.defaults.password, ''); // never in the binary
    });

    test('equality covers all five fields', () {
      const a = SmbSettings(
          host: 'h', sharePath: '/s', domain: '', username: 'u', password: 'p');
      final b = a.copyWith();
      final c = a.copyWith(password: 'other');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('copyWith only changes given fields', () {
      final s = SmbSettings.defaults.copyWith(username: 'opk');
      expect(s.username, 'opk');
      expect(s.host, SmbSettings.defaults.host);
      expect(s.sharePath, SmbSettings.defaults.sharePath);
    });
  });
}
