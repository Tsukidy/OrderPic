import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'settings/settings_store.dart';

void main() {
  runApp(const MmcPicApp());
}

class MmcPicApp extends StatelessWidget {
  const MmcPicApp({super.key, this.store = const SecureSettingsStore()});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MMCPic',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: HomePage(store: store),
    );
  }
}
