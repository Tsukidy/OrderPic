import 'settings_store.dart';

/// SMB share connection settings. Credentials default to empty and are
/// never compiled into the binary — the user enters them on first startup
/// (settings persist via flutter_secure_storage). Formerly `SmbSettings`;
/// renamed when the upload preferences moved in beside it under
/// [AppSettings] — keys and behavior are unchanged.
class ConnectionSettings {
  final String host;
  final String
  sharePath; // <share>/<sub-folder> (sub-folder is created if missing)
  final String domain;
  final String username;
  final String password;

  const ConnectionSettings({
    required this.host,
    required this.sharePath,
    required this.domain,
    required this.username,
    required this.password,
  });

  /// Seeds ONLY the non-secret fields; username/password stay empty (Q7).
  static const ConnectionSettings defaults = ConnectionSettings(
    host: '192.168.1.29',
    sharePath: '/zdrive/InvoiceData',
    domain: '',
    username: '',
    password: '',
  );

  ConnectionSettings copyWith({
    String? host,
    String? sharePath,
    String? domain,
    String? username,
    String? password,
  }) => ConnectionSettings(
    host: host ?? this.host,
    sharePath: sharePath ?? this.sharePath,
    domain: domain ?? this.domain,
    username: username ?? this.username,
    password: password ?? this.password,
  );

  @override
  bool operator ==(Object other) =>
      other is ConnectionSettings &&
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
  static Future<ConnectionSettings> load({
    SettingsStore store = const SecureSettingsStore(),
  }) async {
    try {
      Future<String> field(String key, String fallback) async =>
          (await store.read(key)) ?? fallback;
      return ConnectionSettings(
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

/// Umbrella over everything the app persists: the SMB connection
/// ([connection]) plus the capture/upload preferences ([upload]). Pages
/// hold a single `ValueNotifier<AppSettings>`; SMB call sites read
/// `.value.connection`. Equality spans BOTH halves — a host change and a
/// folders-toggle change are equally "not the same settings" — but note
/// that History's remount key deliberately tracks only [connection]
/// identity (see HomePage): upload-only changes rebuild History in place
/// instead of re-listing the share.
class AppSettings {
  final ConnectionSettings connection;
  final UploadPrefs upload;

  const AppSettings({required this.connection, required this.upload});

  static const AppSettings defaults = AppSettings(
    connection: ConnectionSettings.defaults,
    upload: UploadPrefs.defaults,
  );

  /// Untouched halves are reused BY INSTANCE — ObjectKey compares with
  /// identical(), and History's remount key is
  /// ObjectKey(settings.connection), so an upload-only copyWith keeps the
  /// same key (no History remount) while a connection change makes a new
  /// one. Don't construct a fresh equal-valued half here.
  AppSettings copyWith({ConnectionSettings? connection, UploadPrefs? upload}) =>
      AppSettings(
        connection: connection ?? this.connection,
        upload: upload ?? this.upload,
      );

  /// Assembles the whole settings object; each half keeps its own
  /// fallback/recovery behavior ([ConnectionSettings.load] wipes an
  /// unreadable store, [UploadPrefs.load] just falls back to defaults).
  static Future<AppSettings> load({
    SettingsStore store = const SecureSettingsStore(),
  }) async => AppSettings(
    connection: await ConnectionSettings.load(store: store),
    upload: await UploadPrefs.load(store: store),
  );

  Future<void> save({SettingsStore store = const SecureSettingsStore()}) async {
    await connection.save(store: store);
    await upload.save(store: store);
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.connection == connection &&
      other.upload == upload;

  @override
  int get hashCode => Object.hash(connection, upload);
}

/// Output image format for uploads. PNG is lossless and full-size (the
/// quality knobs only exist for JPEG); JPEG keeps the camera's own encoding
/// when quality is [JpegQuality.original].
enum ImageFormat { jpeg, png }

/// JPEG compression presets. Presets map to fixed quality/edge caps;
/// [custom] takes its numbers from [UploadPrefs.customQuality] and
/// [UploadPrefs.customMaxEdgePx].
enum JpegQuality { original, high, balanced, small, custom }

/// Capture & upload preferences: folder layout, batch mode, and the
/// format/quality knobs. Defaults preserve the pre-folder-bundling behavior
/// (flat uploads of untouched JPEGs); persists via flutter_secure_storage
/// alongside the SMB settings — no secrets here, so a corrupt store just
/// falls back to defaults without wiping.
class UploadPrefs {
  final bool useOrderFolders;
  final bool batchMode;
  final ImageFormat format;
  final JpegQuality jpegQuality;

  /// JPEG quality for [JpegQuality.custom]; only meaningful 30–100.
  final int customQuality;

  /// Optional cap on the long edge in px for [JpegQuality.custom];
  /// null = uncapped.
  final int? customMaxEdgePx;

  const UploadPrefs({
    this.useOrderFolders = false,
    this.batchMode = false,
    this.format = ImageFormat.jpeg,
    this.jpegQuality = JpegQuality.original,
    this.customQuality = 80,
    this.customMaxEdgePx,
  });

  static const UploadPrefs defaults = UploadPrefs();

  UploadPrefs copyWith({
    bool? useOrderFolders,
    bool? batchMode,
    ImageFormat? format,
    JpegQuality? jpegQuality,
    int? customQuality,
    int? customMaxEdgePx,
  }) => UploadPrefs(
    useOrderFolders: useOrderFolders ?? this.useOrderFolders,
    batchMode: batchMode ?? this.batchMode,
    format: format ?? this.format,
    jpegQuality: jpegQuality ?? this.jpegQuality,
    customQuality: customQuality ?? this.customQuality,
    customMaxEdgePx: customMaxEdgePx ?? this.customMaxEdgePx,
  );

  @override
  bool operator ==(Object other) =>
      other is UploadPrefs &&
      other.useOrderFolders == useOrderFolders &&
      other.batchMode == batchMode &&
      other.format == format &&
      other.jpegQuality == jpegQuality &&
      other.customQuality == customQuality &&
      other.customMaxEdgePx == customMaxEdgePx;

  @override
  int get hashCode => Object.hash(
    useOrderFolders,
    batchMode,
    format,
    jpegQuality,
    customQuality,
    customMaxEdgePx,
  );

  /// Per-field fallback to [defaults]; unknown/unparseable values degrade
  /// to the default rather than throwing. Unlike [ConnectionSettings.load]
  /// there is no wipe — nothing here is a secret worth resetting setup over.
  static Future<UploadPrefs> load({
    SettingsStore store = const SecureSettingsStore(),
  }) async {
    try {
      Future<String?> field(String key) async => await store.read(key);
      final String? maxEdge = await field('upload.custom_max_edge');
      return UploadPrefs(
        useOrderFolders: await field('upload.use_order_folders') == 'true',
        batchMode: await field('upload.batch_mode') == 'true',
        format:
            ImageFormat.values.asNameMap()[await field('upload.format')] ??
            defaults.format,
        jpegQuality:
            JpegQuality.values.asNameMap()[await field('upload.jpeg_quality')] ??
            defaults.jpegQuality,
        customQuality:
            int.tryParse(await field('upload.custom_quality') ?? '') ??
            defaults.customQuality,
        customMaxEdgePx: (maxEdge == null || maxEdge.isEmpty)
                ? null
                : int.tryParse(maxEdge),
      );
    } catch (_) {
      return defaults;
    }
  }

  Future<void> save({SettingsStore store = const SecureSettingsStore()}) async {
    await store.write(
      'upload.use_order_folders',
      useOrderFolders ? 'true' : 'false',
    );
    await store.write('upload.batch_mode', batchMode ? 'true' : 'false');
    await store.write('upload.format', format.name);
    await store.write('upload.jpeg_quality', jpegQuality.name);
    await store.write('upload.custom_quality', customQuality.toString());
    await store.write(
      'upload.custom_max_edge',
      customMaxEdgePx?.toString() ?? '',
    );
  }
}

/// Maps the saved JPEG preferences onto image_picker's re-encode
/// parameters (quality / max long edge). Returns null when the capture
/// must NOT be re-encoded: PNG format (lossless — the quality knobs
/// don't apply) or JPEG quality [JpegQuality.original] (keep the
/// camera's own encoding, full size). Otherwise the preset's fixed
/// pair; [JpegQuality.custom] passes the stored numbers through.
({int? quality, int? maxEdge})? jpegPickParams(UploadPrefs p) {
  if (p.format != ImageFormat.jpeg) return null;
  return switch (p.jpegQuality) {
    JpegQuality.original => null,
    JpegQuality.high => (quality: 90, maxEdge: null),
    JpegQuality.balanced => (quality: 80, maxEdge: 2560),
    JpegQuality.small => (quality: 70, maxEdge: 1080),
    JpegQuality.custom => (quality: p.customQuality, maxEdge: p.customMaxEdgePx),
  };
}
