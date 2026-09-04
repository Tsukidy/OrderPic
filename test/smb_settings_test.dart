import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

import 'helpers/in_memory_settings_store.dart';

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

  group('SmbSettings persistence', () {
    test('missing keys fall back per-field: config seeded, credentials empty', () async {
      final store = InMemorySettingsStore(); // nothing stored
      final s = await SmbSettings.load(store: store);
      expect(s.host, SmbSettings.defaults.host);
      expect(s.sharePath, SmbSettings.defaults.sharePath);
      expect(s.username, '');
    });

    test('save/load round-trips through the store', () async {
      final store = InMemorySettingsStore();
      final s = SmbSettings.defaults.copyWith(
          host: '10.0.0.5', sharePath: '/photos/shop', username: 'opk', password: 'pw');
      await s.save(store: store);
      expect(store.data['smb.username'], 'opk');
      expect(await SmbSettings.load(store: store), s);
    });

    test('unreadable store is wiped and falls back to defaults', () async {
      final store = UnreadableSettingsStore();
      final s = await SmbSettings.load(store: store);
      expect(s, SmbSettings.defaults); // empty username re-triggers first-run
    });
  });

  group('connect guard', () {
    test('refuses to dial when username is empty', () async {
      await expectLater(
        connect(SmbSettings.defaults), // username is ''
        throwsA(isA<SmbNotConfiguredException>()),
      );
    });

    test('guard message is user-readable', () {
      expect(SmbNotConfiguredException().toString(),
          'SMB login not configured — open Settings');
    });
  });
}
