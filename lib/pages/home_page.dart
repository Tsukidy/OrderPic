import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../settings/settings_page.dart';
import '../settings/settings_store.dart';
import 'history_page.dart';
import 'scanner_page.dart';

/// Root shell — Scan / History tabs along the bottom.
/// (camera, review) is pushed on top of this shell as process progresses.
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.store = const SecureSettingsStore()});

  final SettingsStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final SettingsStore _store;
  final ValueNotifier<SmbSettings> _settingsNotifier = ValueNotifier(
    SmbSettings.defaults,
  );

  int _tab = 0;
  bool _historyVisited = false;

  @override
  void initState() {
    super.initState();
    _store = widget.store;
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final s = await SmbSettings.load(store: _store); // recovery inside load()
    if (!mounted) return;
    _settingsNotifier.value = s;
    if (s.username.isEmpty) {
      // First-run gate — push once the frame is up.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSettings(firstRun: true);
      });
    }
  }

  void _openSettings({bool firstRun = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          settingsNotifier: _settingsNotifier,
          firstRun: firstRun,
          store: _store,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settingsNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<SmbSettings>(
        valueListenable: _settingsNotifier,
        builder: (context, settings, _) => IndexedStack(
          index: _tab,
          children: [
            ScannerPage(
              paused: _tab != 0,
              settingsNotifier: _settingsNotifier,
              onOpenSettings: () => _openSettings(),
            ),
            // Re-key on settings value: remount → initState → fresh list.
            // Invariant: remount-on-change-ONLY relies on ObjectKey identity
            // plus ValueNotifier suppressing ==-equal assignments (so a
            // no-op re-save can't rebuild History). Don't "simplify" either.
            _historyVisited
                ? KeyedSubtree(
                    key: ObjectKey(settings),
                    child: HistoryPage(
                      active: _tab == 1,
                      settingsNotifier: _settingsNotifier,
                      onOpenSettings: () => _openSettings(),
                    ),
                  )
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() {
          _tab = index;
          if (index == 1) _historyVisited = true;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Scan',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
