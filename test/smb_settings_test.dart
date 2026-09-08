import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/settings/app_settings.dart';
import 'package:orderpic/smb/smb.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  group('ConnectionSettings', () {
    test('defaults seed config fields but never credentials', () {
      expect(ConnectionSettings.defaults.host, '192.168.1.29');
      expect(ConnectionSettings.defaults.sharePath, '/zdrive/InvoiceData');
      expect(ConnectionSettings.defaults.domain, '');
      expect(ConnectionSettings.defaults.username, ''); // never in the binary
      expect(ConnectionSettings.defaults.password, ''); // never in the binary
    });

    test('equality covers all five fields', () {
      const a = ConnectionSettings(
        host: 'h',
        sharePath: '/s',
        domain: '',
        username: 'u',
        password: 'p',
      );
      final b = a.copyWith();
      final c = a.copyWith(password: 'other');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('copyWith only changes given fields', () {
      final s = ConnectionSettings.defaults.copyWith(username: 'tester');
      expect(s.username, 'tester');
      expect(s.host, ConnectionSettings.defaults.host);
      expect(s.sharePath, ConnectionSettings.defaults.sharePath);
    });
  });

  group('ConnectionSettings persistence', () {
    test(
      'missing keys fall back per-field: config seeded, credentials empty',
      () async {
        final store = InMemorySettingsStore(); // nothing stored
        final s = await ConnectionSettings.load(store: store);
        expect(s.host, ConnectionSettings.defaults.host);
        expect(s.sharePath, ConnectionSettings.defaults.sharePath);
        expect(s.username, '');
      },
    );

    test('save/load round-trips through the store', () async {
      final store = InMemorySettingsStore();
      final s = ConnectionSettings.defaults.copyWith(
        host: '10.0.0.5',
        sharePath: '/photos/shop',
        username: 'tester',
        password: 'secret',
      );
      await s.save(store: store);
      expect(store.data['smb.username'], 'tester');
      expect(await ConnectionSettings.load(store: store), s);
    });

    test('unreadable store is wiped and falls back to defaults', () async {
      final store = UnreadableSettingsStore();
      final s = await ConnectionSettings.load(store: store);
      expect(s, ConnectionSettings.defaults); // empty username re-triggers first-run
    });
  });

  group('connect guard', () {
    test('refuses to dial when username is empty', () async {
      await expectLater(
        connect(ConnectionSettings.defaults), // username is ''
        throwsA(isA<SmbNotConfiguredException>()),
      );
    });

    test('guard message is user-readable', () {
      expect(
        SmbNotConfiguredException().toString(),
        'SMB login not configured — open Settings',
      );
    });
  });
}
