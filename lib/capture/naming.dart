String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// {OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg, stamped when the upload starts.
String buildUploadFileName(String orderNumber, DateTime now) {
  final date = '${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}';
  final time =
      '${_twoDigits(now.hour)}${_twoDigits(now.minute)}${_twoDigits(now.second)}';
  return '${orderNumber}_${date}_$time.jpg';
}

/// Split ORDER_YYYYMMDD_HHMMSS.ext into (order, readable date/time).
(String, String)? parseUploadName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final parts = name.substring(0, dot).split('_');
  if (parts.length != 3 || parts[1].length != 8 || parts[2].length != 6) {
    return null;
  }
  final d = parts[1];
  final t = parts[2];
  final iso =
      '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
      '${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}';
  return (parts[0], iso);
}
