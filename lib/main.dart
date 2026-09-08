import 'dart:async';

import 'package:flutter/material.dart';

import 'capture/session.dart';
import 'pages/home_page.dart';
import 'route_observer.dart';
import 'settings/settings_store.dart';

void main() {
  // Reclaim session dirs orphaned by a crash/force-kill; never block startup.
  unawaited(sweepStaleSessions());
  runApp(const OrderPicApp());
}

class OrderPicApp extends StatelessWidget {
  const OrderPicApp({super.key, this.store = const SecureSettingsStore()});

  final SettingsStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OrderPic',
      navigatorObservers: [routeObserver],
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
