import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orderpic/settings/app_settings.dart';
import 'package:orderpic/settings/settings_page.dart';
import 'package:orderpic/smb/smb.dart';

import 'helpers/in_memory_settings_store.dart';

Future<void> _openSettings(WidgetTester tester, SettingsPage page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => page)),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The sectioned page is taller than the default test surface — the
/// Save/Test row and the lower connection fields live below the fold,
/// and since Task 2.4's quality block grew the page further they sit
/// beyond the ListView's lazy build extent (not mounted at all).
/// scrollUntilVisible drives the scroll until the target is actually
/// laid out on screen; ensureVisible alone can't reach unmounted
/// elements.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tapScrolled(WidgetTester tester, Finder finder) async {
  await _scrollTo(tester, finder);
  await tester.tap(finder);
}

Future<void> _enterTextScrolled(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  await _scrollTo(tester, finder);
  await tester.enterText(finder, text);
}

void main() {
  testWidgets('fields are seeded from current settings', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults.copyWith(
        connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
      ),
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    expect(find.widgetWithText(TextFormField, '192.168.1.29'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, '/zdrive/InvoiceData'),
      findsOneWidget,
    );
  });

  testWidgets('password visibility toggle reveals text', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('password_field')),
      'secret',
    );
    // obscureText lives on the descendant TextField (TextFormField doesn't
    // expose it on Flutter 3.47), so assert against the TextField widget.
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('password_field')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.obscureText, isTrue);
    await _tapScrolled(tester, find.byIcon(Icons.visibility));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('password_field')),
              matching: find.byType(TextField),
            ),
          )
          .obscureText,
      isFalse,
    );
  });

  testWidgets('empty host is rejected', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    await _enterTextScrolled(tester, find.byKey(const Key('host_field')), '');
    await _tapScrolled(tester, find.text('Save'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('host_field')),
        matching: find.text('Required'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SettingsPage), findsOneWidget); // did not pop
  });

  testWidgets('share path without leading slash is rejected', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('share_path_field')),
      'zdrive/x',
    );
    await _tapScrolled(tester, find.text('Save'));
    await tester.pump();
    expect(find.text('Must start with / (share/sub-folder)'), findsOneWidget);
    expect(find.byType(SettingsPage), findsOneWidget); // did not pop
  });

  testWidgets('empty username is rejected', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('username_field')),
      '',
    );
    await _tapScrolled(tester, find.text('Save'));
    await tester.pump();
    expect(find.text('Required'), findsAtLeastNWidgets(1));
    expect(find.byType(SettingsPage), findsOneWidget); // did not pop
  });

  testWidgets('save persists, updates notifier, and pops', (tester) async {
    final store = InMemorySettingsStore();
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: store),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('username_field')),
      'tester',
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('password_field')),
      'secret',
    );
    await _tapScrolled(tester, find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing); // popped
    expect(notifier.value.connection.username, 'tester');
    expect(store.data['smb.username'], 'tester');
    expect(store.data['smb.password'], 'secret');
  });

  testWidgets('blank password is allowed', (tester) async {
    final store = InMemorySettingsStore();
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: store),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('username_field')),
      'tester',
    );
    await _tapScrolled(tester, find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(store.data['smb.password'], '');
  });

  testWidgets('test connection shows guard wording when unconfigured', (
    tester,
  ) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    await _openSettings(
      tester,
      SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
    );
    await _enterTextScrolled(
      tester,
      find.byKey(const Key('host_field')),
      '10.9.9.9',
    );
    await _tapScrolled(tester, find.text('Test connection'));
    await tester.pump();
    expect(find.text(SmbNotConfiguredException.message), findsOneWidget);
  });

  testWidgets('back is blocked in first-run mode', (tester) async {
    final notifier = ValueNotifier(
      AppSettings.defaults,
    );
    // The gate hides the AppBar back arrow (it would be inert anyway), so
    // drive the system-back path directly — the same channel a hardware
    // back press / gesture uses.
    await _openSettings(
      tester,
      SettingsPage(
        settingsNotifier: notifier,
        firstRun: true,
        store: InMemorySettingsStore(),
      ),
    );
    expect(find.byTooltip('Back'), findsNothing); // no dead arrow shown
    await WidgetsBinding.instance.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget); // still mounted
  });

  group('sectioned layout', () {
    testWidgets('gear-mode title is Settings', (tester) async {
      final notifier = ValueNotifier(AppSettings.defaults);
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
      );
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('SMB settings'), findsNothing);
    });

    testWidgets('first-run title stays Set up SMB login', (tester) async {
      final notifier = ValueNotifier(AppSettings.defaults);
      await _openSettings(
        tester,
        SettingsPage(
          settingsNotifier: notifier,
          firstRun: true,
          store: InMemorySettingsStore(),
        ),
      );
      expect(find.text('Set up SMB login'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets(
      'both section headers present, Capture & upload above SMB connection',
      (tester) async {
        final notifier = ValueNotifier(AppSettings.defaults);
        await _openSettings(
          tester,
          SettingsPage(
            settingsNotifier: notifier,
            store: InMemorySettingsStore(),
          ),
        );
        expect(find.text('Capture & upload'), findsOneWidget);
        expect(find.text('SMB connection'), findsOneWidget);
        // Capture & upload section sits ABOVE SMB connection in the list —
        // compare laid-out y positions (finder evaluate order alone isn't
        // a layout guarantee).
        final captureTop = tester.getTopLeft(
          find.text('Capture & upload'),
        ).dy;
        final connectionTop = tester.getTopLeft(
          find.text('SMB connection'),
        ).dy;
        expect(captureTop, lessThan(connectionTop));
      },
    );

    testWidgets('upload controls are seeded from notifier value', (
      tester,
    ) async {
      final notifier = ValueNotifier(
        AppSettings.defaults.copyWith(
          upload: const UploadPrefs(
            useOrderFolders: true,
            batchMode: true,
            format: ImageFormat.png,
          ),
        ),
      );
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
      );
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('folders_toggle')))
            .value,
        isTrue,
      );
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('batch_toggle'))).value,
        isTrue,
      );
      expect(
        tester
            .widget<SegmentedButton<ImageFormat>>(
              find.byKey(const Key('format_selector')),
            )
            .selected,
        {ImageFormat.png},
      );
    });

    testWidgets(
      'toggling folders and saving updates notifier and persists',
      (tester) async {
        final store = InMemorySettingsStore();
        final notifier = ValueNotifier(AppSettings.defaults);
        await _openSettings(
          tester,
          SettingsPage(settingsNotifier: notifier, store: store),
        );
        // Defaults have an empty username, so a plain Save would be blocked
        // by validation — seed a valid connection first.
        await tester.enterText(find.byKey(const Key('username_field')), 'tester');
        await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
        await tester.pump();
        await _tapScrolled(tester, find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsNothing); // popped
        expect(notifier.value.upload.useOrderFolders, isTrue);
        expect(store.data['upload.use_order_folders'], 'true');
      },
    );

    testWidgets(
      'upload-only save reuses the live connection instance',
      (tester) async {
        final store = InMemorySettingsStore();
        // Connection already valid — the form fields load it verbatim, so a
        // save that only touches upload prefs must NOT swap the connection
        // instance (ObjectKey(settings.connection) → no History remount).
        final notifier = ValueNotifier(
          AppSettings.defaults.copyWith(
            connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
          ),
        );
        await _openSettings(
          tester,
          SettingsPage(settingsNotifier: notifier, store: store),
        );
        final liveConnection = notifier.value.connection;
        await _tapScrolled(tester, find.byKey(const Key('folders_toggle')));
        await tester.pump();
        await _tapScrolled(tester, find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsNothing); // popped
        expect(notifier.value.upload.useOrderFolders, isTrue);
        expect(identical(notifier.value.connection, liveConnection), isTrue);
      },
    );
  });

  group('quality block', () {
    testWidgets('visible for JPEG, hidden for PNG, selection survives', (
      tester,
    ) async {
      final notifier = ValueNotifier(AppSettings.defaults);
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: InMemorySettingsStore()),
      );
      // Default format is JPEG — the quality block is showing.
      expect(find.byKey(const Key('quality_section')), findsOneWidget);
      // Change the saved preset first so the restore assert is meaningful.
      await _tapScrolled(tester, find.text('Balanced'));
      await tester.pump();
      // PNG hides the ENTIRE quality block.
      await _tapScrolled(tester, find.text('PNG'));
      await tester.pump();
      expect(find.byKey(const Key('quality_section')), findsNothing);
      // Back to JPEG: restored, still Balanced (state survived the round-trip).
      await _tapScrolled(tester, find.text('JPEG'));
      await tester.pump();
      expect(find.byKey(const Key('quality_section')), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<JpegQuality>>(
              find.byKey(const Key('quality_selector')),
            )
            .selected,
        {JpegQuality.balanced},
      );
    });

    testWidgets('custom reveals slider clamped 30-100 and persists via save', (
      tester,
    ) async {
      final store = InMemorySettingsStore();
      final notifier = ValueNotifier(
        AppSettings.defaults.copyWith(
          connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
        ),
      );
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: store),
      );
      // Custom controls hidden until Custom is selected.
      expect(find.byKey(const Key('custom_quality_controls')), findsNothing);
      await _tapScrolled(tester, find.text('Custom'));
      await tester.pump();
      expect(find.byKey(const Key('custom_quality_controls')), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('custom_quality_slider')),
      );
      expect(slider.min, 30);
      expect(slider.max, 100);
      expect(slider.divisions, 70);
      // Drag the thumb to the far left — the set-time clamp floor is 30
      // (the slider's own min), so quality lands at 30, not 0.
      final sliderRect = tester.getRect(
        find.byKey(const Key('custom_quality_slider')),
      );
      await tester.dragFrom(
        Offset(sliderRect.left + (sliderRect.width * 0.5), sliderRect.center.dy),
        Offset(-sliderRect.width, 0),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('custom_max_edge_field')),
        '2048',
      );
      await _tapScrolled(tester, find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing); // popped
      expect(notifier.value.upload.jpegQuality, JpegQuality.custom);
      expect(notifier.value.upload.customQuality, 30); // clamped at set-time
      expect(notifier.value.upload.customMaxEdgePx, 2048);
      // InMemory round-trip: what was saved is what loads back.
      expect(await UploadPrefs.load(store: store), notifier.value.upload);
    });

    testWidgets('blanking the max edge clears it back to null on save', (
      tester,
    ) async {
      final store = InMemorySettingsStore();
      // copyWith can't set customMaxEdgePx back to null, so seed the whole
      // upload half explicitly — the fresh-construction path under test.
      final notifier = ValueNotifier(
        AppSettings.defaults.copyWith(
          connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
          upload: const UploadPrefs(
            jpegQuality: JpegQuality.custom,
            customQuality: 65,
            customMaxEdgePx: 2048,
          ),
        ),
      );
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: store),
      );
      await tester.enterText(
        find.byKey(const Key('custom_max_edge_field')),
        '',
      );
      await _tapScrolled(tester, find.text('Save'));
      await tester.pumpAndSettle();
      expect(notifier.value.upload.customMaxEdgePx, isNull);
      expect(store.data['upload.custom_max_edge'], '');
      expect(await UploadPrefs.load(store: store), notifier.value.upload);
    });

    testWidgets('switching format to PNG and saving persists png', (
      tester,
    ) async {
      final store = InMemorySettingsStore();
      final notifier = ValueNotifier(
        AppSettings.defaults.copyWith(
          connection: ConnectionSettings.defaults.copyWith(username: 'tester'),
        ),
      );
      await _openSettings(
        tester,
        SettingsPage(settingsNotifier: notifier, store: store),
      );
      await _tapScrolled(tester, find.text('PNG'));
      await tester.pump();
      expect(find.byKey(const Key('quality_section')), findsNothing);
      await _tapScrolled(tester, find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing); // popped
      expect(notifier.value.upload.format, ImageFormat.png);
      expect(store.data['upload.format'], 'png');
    });
  });
}
