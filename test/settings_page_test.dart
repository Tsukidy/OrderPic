import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmcpicv4/main.dart';

import 'helpers/in_memory_settings_store.dart';

Future<void> _openSettings(WidgetTester tester, SettingsPage page) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fields are seeded from current settings', (tester) async {
    final notifier =
        ValueNotifier(SmbSettings.defaults.copyWith(username: 'opk'));
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    expect(find.widgetWithText(TextFormField, '192.168.1.29'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '/zdrive/InvoiceData'), findsOneWidget);
  });

  testWidgets('password visibility toggle reveals text', (tester) async {
    final notifier = ValueNotifier(SmbSettings.defaults);
    await _openSettings(
        tester, SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()));
    await tester.enterText(find.byKey(const Key('password_field')), 'secret');
    // obscureText lives on the descendant TextField (TextFormField doesn't
    // expose it on Flutter 3.47), so assert against the TextField widget.
    final field = tester.widget<TextField>(find.descendant(
        of: find.byKey(const Key('password_field')),
        matching: find.byType(TextField)));
    expect(field.obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.descendant(
          of: find.byKey(const Key('password_field')),
          matching: find.byType(TextField))).obscureText,
      isFalse,
    );
  });
}
