import 'package:smb_connect/smb_connect.dart';

import '../settings/app_settings.dart';

/// Thrown (before any network dial) when an SMB operation is attempted
/// with no configured login. toString() is shown verbatim in error
/// banners, so it must stay user-readable.
class SmbNotConfiguredException implements Exception {
  static const String message = 'SMB login not configured — open Settings';

  @override
  String toString() => message;
}

/// Opens an SMB connection with [s]. Every operation goes through here so
/// the unconfigured guard and settings snapshot live in one place.
Future<SmbConnect> connect(ConnectionSettings s) async {
  if (s.username.isEmpty) throw SmbNotConfiguredException();
  return SmbConnect.connectAuth(
    host: s.host,
    domain: s.domain,
    username: s.username,
    password: s.password,
  );
}
