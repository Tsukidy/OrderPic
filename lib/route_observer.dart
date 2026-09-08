import 'package:flutter/material.dart';

/// Shared route observer for pages that must pause work while another route
/// covers them (e.g. ScannerPage stopping its camera under Settings or the
/// capture flow).
///
/// Register once via [MaterialApp.navigatorObservers]; [RouteAware] states
/// subscribe to their [ModalRoute] and react to didPushNext/didPopNext.
/// Dialogs are popup routes, not page routes, so they do not count as
/// covering routes here.
final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();
