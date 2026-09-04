// The app's main flow (QR scan -> camera capture -> SMB upload) needs real
// camera hardware and a network share, so it cannot run as a widget test.
// This placeholder just keeps the test target compiling.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
