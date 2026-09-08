import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'settings/settings_store.dart';

void main() {
  runApp(const OrderPicApp());
}

class OrderPicApp extends StatelessWidget {
  const OrderPicApp({super.key, this.store = const SecureSettingsStore()});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OrderPic',
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
