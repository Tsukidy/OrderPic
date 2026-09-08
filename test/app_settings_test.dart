import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/settings/app_settings.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  group('AppSettings.load', () {
    test('store with only smb.* values yields those + upload defaults', () async {
      final store = InMemorySettingsStore()
        ..data['smb.host'] = '10.0.0.5'
        ..data['smb.share_path'] = '/photos/shop'
        ..data['smb.username'] = 'tester'
        ..data['smb.password'] = 'secret';
      final s = await AppSettings.load(store: store);
      // Connection side comes from the store...
      expect(s.connection.host, '10.0.0.5');
      expect(s.connection.sharePath, '/photos/shop');
      expect(s.connection.username, 'tester');
      expect(s.connection.password, 'secret');
      // ...upload side is untouched defaults (pre-folder-bundling behavior).
      expect(s.upload, UploadPrefs.defaults);
    });

    test('assembles both halves from a fully populated store', () async {
      final store = InMemorySettingsStore()
        ..data['smb.username'] = 'tester'
        ..data['upload.use_order_folders'] = 'true';
      final s = await AppSettings.load(store: store);
      expect(s.connection.username, 'tester');
      expect(s.upload.useOrderFolders, isTrue);
    });
  });

  group('AppSettings equality', () {
    const connection = ConnectionSettings(
      host: 'h',
      sharePath: '/s',
      domain: '',
      username: 'u',
      password: 'p',
    );

    test('equal when both halves are equal', () {
      const a = AppSettings(
        connection: connection,
        upload: UploadPrefs(useOrderFolders: true),
      );
      const b = AppSettings(
        connection: connection,
        upload: UploadPrefs(useOrderFolders: true),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('distinguishes upload-only changes', () {
      const a = AppSettings(connection: connection, upload: UploadPrefs());
      const b = AppSettings(
        connection: connection,
        upload: UploadPrefs(useOrderFolders: true),
      );
      expect(a, isNot(b)); // same connection, different folders toggle
    });

    test('distinguishes connection-only changes', () {
      const a = AppSettings(
        connection: connection,
        upload: UploadPrefs.defaults,
      );
      const b = AppSettings(
        connection: ConnectionSettings(
          host: 'other',
          sharePath: '/s',
          domain: '',
          username: 'u',
          password: 'p',
        ),
        upload: UploadPrefs.defaults,
      );
      expect(a, isNot(b));
    });
  });

  group('AppSettings.save', () {
    test('writes both halves to the store', () async {
      final store = InMemorySettingsStore();
      const s = AppSettings(
        connection: ConnectionSettings(
          host: '10.0.0.5',
          sharePath: '/photos/shop',
          domain: '',
          username: 'tester',
          password: 'secret',
        ),
        upload: UploadPrefs(useOrderFolders: true, batchMode: true),
      );
      await s.save(store: store);
      expect(store.data['smb.host'], '10.0.0.5');
      expect(store.data['smb.username'], 'tester');
      expect(store.data['upload.use_order_folders'], 'true');
      expect(store.data['upload.batch_mode'], 'true');
      expect(await AppSettings.load(store: store), s);
    });
  });

  test('defaults = ConnectionSettings.defaults + UploadPrefs.defaults', () {
    expect(AppSettings.defaults.connection, ConnectionSettings.defaults);
    expect(AppSettings.defaults.upload, UploadPrefs.defaults);
  });
}
