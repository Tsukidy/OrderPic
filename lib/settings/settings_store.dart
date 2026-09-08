import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage keys for the five settings (all live in the encrypted store).
const List<String> smbSettingKeys = [
  'smb.host',
  'smb.share_path',
  'smb.domain',
  'smb.username',
  'smb.password',
];

/// Minimal async key-value contract so settings logic is testable
/// without platform channels.
abstract class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store: flutter_secure_storage (Android Keystore / iOS Keychain).
class SecureSettingsStore implements SettingsStore {
  const SecureSettingsStore();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
