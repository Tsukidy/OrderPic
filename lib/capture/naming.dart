import '../settings/app_settings.dart';

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// {OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.{ext}, stamped when the capture
/// is admitted; [shotIndex] disambiguates same-second shots.
String buildUploadFileName({
  required String orderNumber,
  required DateTime admittedAt,
  required int shotIndex,
  required ImageFormat format,
}) {
  final date =
      '${admittedAt.year}${_twoDigits(admittedAt.month)}${_twoDigits(admittedAt.day)}';
  final time = '${_twoDigits(admittedAt.hour)}'
      '${_twoDigits(admittedAt.minute)}'
      '${_twoDigits(admittedAt.second)}';
  final index = shotIndex.toString().padLeft(3, '0');
  final ext = format == ImageFormat.png ? 'png' : 'jpg';
  return '${orderNumber}_${date}_${time}_$index.$ext';
}

final _digits = RegExp(r'^\d+$');

/// Split ORDER_YYYYMMDD_HHMMSS[_NNN].ext into (order, readable date/time).
///
/// Accepts the legacy 3-part shape and the current 4-part shape (the shot
/// index is validated but not surfaced). Anything else — wrong part count,
/// non-digit date/time segments, an index that isn't exactly 3 digits —
/// returns null so callers fall back to the raw filename.
(String, String)? parseUploadName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final parts = name.substring(0, dot).split('_');
  if (parts.length != 3 && parts.length != 4) return null;
  if (parts[1].length != 8 || parts[2].length != 6) return null;
  if (!_digits.hasMatch(parts[1]) || !_digits.hasMatch(parts[2])) return null;
  if (parts.length == 4 &&
      (parts[3].length != 3 || !_digits.hasMatch(parts[3]))) {
    return null;
  }
  final d = parts[1];
  final t = parts[2];
  final iso =
      '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
      '${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}';
  return (parts[0], iso);
}
