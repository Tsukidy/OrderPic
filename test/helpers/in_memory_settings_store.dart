import 'package:orderpic/settings/settings_store.dart';

/// In-memory SettingsStore for tests — no platform channels.
class InMemorySettingsStore implements SettingsStore {
  final Map<String, String> data = {};

  /// When true, [read] throws — simulates an unreadable store
  /// (e.g. undecryptable secure storage) without a separate class.
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) {
      throw Exception('unreadable');
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// Simulates an undecryptable secure store (e.g. restored backup).
class UnreadableSettingsStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => throw Exception('unreadable');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('unreadable');

  @override
  Future<void> delete(String key) async {}
}
