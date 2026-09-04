import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

import 'helpers/in_memory_settings_store.dart';

void main() {
  testWidgets('first run (no stored login) opens the setup gate',
      (tester) async {
    await tester.pumpWidget(MmcPicApp(store: InMemorySettingsStore()));
    await tester.pump(); // load() future resolves
    await tester.pump(); // post-frame callback pushes the gate
    await tester.pump(); // route builds
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Set up SMB login'), findsOneWidget);
  });

  testWidgets('configured app starts on Scan without the gate',
      (tester) async {
    final store = InMemorySettingsStore()
      ..data['smb.username'] = 'opk'
      ..data['smb.host'] = '192.168.1.29';
    await tester.pumpWidget(MmcPicApp(store: store));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('Scan QR code'), findsOneWidget);
    // Gear in the Scan app bar opens settings (History's gear is the same
    // callback — covered by the manual pass).
    await tester.tap(find.byTooltip('SMB settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('SMB settings'), findsOneWidget); // not setup mode
  });
}
