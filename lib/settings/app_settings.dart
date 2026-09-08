import 'settings_store.dart';

/// SMB share settings. Credentials default to empty and are never
/// compiled into the binary — the user enters them on first startup
/// (settings persist via flutter_secure_storage).
class SmbSettings {
  final String host;
  final String
  sharePath; // <share>/<sub-folder> (sub-folder is created if missing)
  final String domain;
  final String username;
  final String password;

  const SmbSettings({
    required this.host,
    required this.sharePath,
    required this.domain,
    required this.username,
    required this.password,
  });

  /// Seeds ONLY the non-secret fields; username/password stay empty (Q7).
  static const SmbSettings defaults = SmbSettings(
    host: '192.168.1.29',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  );

  SmbSettings copyWith({
    String? host,
    String? sharePath,
    String? domain,
    String? username,
    String? password,
  }) => SmbSettings(
    host: host ?? this.host,
    sharePath: sharePath ?? this.sharePath,
    domain: domain ?? this.domain,
    username: username ?? this.username,
    password: password ?? this.password,
  );

  @override
  bool operator ==(Object other) =>
      other is SmbSettings &&
      other.host == host &&
      other.sharePath == sharePath &&
      other.domain == domain &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(host, sharePath, domain, username, password);

  /// Per-field fallback: config fields → defaults, credentials → empty.
  /// An unreadable/undecryptable store is wiped and falls back to
  /// defaults (the empty username then re-triggers first-run setup).
  static Future<SmbSettings> load({
    SettingsStore store = const SecureSettingsStore(),
  }) async {
    try {
      Future<String> field(String key, String fallback) async =>
          (await store.read(key)) ?? fallback;
      return SmbSettings(
        host: await field('smb.host', defaults.host),
        sharePath: await field('smb.share_path', defaults.sharePath),
        domain: await field('smb.domain', defaults.domain),
        username: await field('smb.username', ''),
        password: await field('smb.password', ''),
      );
    } catch (_) {
      for (final key in smbSettingKeys) {
        try {
          await store.delete(key);
        } catch (_) {
          /* best effort wipe */
        }
      }
      return defaults;
    }
  }

  Future<void> save({SettingsStore store = const SecureSettingsStore()}) async {
    await store.write('smb.host', host);
    await store.write('smb.share_path', sharePath);
    await store.write('smb.domain', domain);
    await store.write('smb.username', username);
    await store.write('smb.password', password);
  }
}
