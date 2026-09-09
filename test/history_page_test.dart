import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/smb_connect.dart';

import 'package:orderpic/pages/history_page.dart';
import 'package:orderpic/pages/image_viewer_page.dart';
import 'package:orderpic/settings/app_settings.dart';

// Attribute constants for hand-built fake entries (smb_connect does not
// export these; SmbConstants.ATTR_DIRECTORY is 0x10, ATTR_NORMAL is 0x80).
// Detection in HistoryPage MUST key off the DIRECTORY bit only.
const int _attrDirectory = 0x10; // FILE_ATTRIBUTE_DIRECTORY
const int _attrPlainFile = 0x80; // normal file — NOT the directory bit

/// Builds a share entry the way the real enumerator does: `name` is derived
/// from `path` (everything after the final '/'), so paths must be real.
SmbFile _entry(String name, {required int attributes, int size = 0}) {
  const base = '/zdrive/InvoiceData';
  return SmbFile(
    '$base/$name',
    r'\zdrive\InvoiceData'
        r'\',
    'zdrive',
    0,
    0,
    0,
    attributes,
    size,
    true,
  );
}

HistoryPage _page(Future<List<SmbFile>> Function(String path) listDir) {
  return HistoryPage(
    settingsNotifier: ValueNotifier(AppSettings.defaults),
    listDir: listDir,
  );
}

/// Pumps [page], resolves the initState refresh, and returns the y-coordinates
/// the assertions order by.
Future<void> _pump(WidgetTester tester, HistoryPage page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump(); // initState refresh future resolves
}

/// Minimal stand-in for [HomePage]'s tab shell: lazily creates HistoryPage on
/// first History visit (KeyedSubtree-ish) and keeps it mounted afterwards,
/// flipping `active` with the selected tab — exactly the contract Task 1.5
/// built. HomePage itself has no injection point for [HistoryPage.listDir],
/// so the harness reproduces its structure around the seam instead.
class _TabShellHarness extends StatefulWidget {
  const _TabShellHarness({required this.listDir});

  final Future<List<SmbFile>> Function(String path) listDir;

  @override
  State<_TabShellHarness> createState() => _TabShellHarnessState();
}

class _TabShellHarnessState extends State<_TabShellHarness> {
  int _tab = 0;
  bool _historyVisited = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          const SizedBox.shrink(), // Scan stand-in (no camera in tests)
          if (_historyVisited)
            HistoryPage(
              active: _tab == 1,
              settingsNotifier: ValueNotifier(AppSettings.defaults),
              listDir: widget.listDir,
            ),
        ],
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

void main() {
  testWidgets(
    'root: folder tile (Icons.folder + grey Folder subtitle) above image tiles',
    (tester) async {
      // Returned UNSORTED on purpose — HistoryPage must do the ordering.
      Future<List<SmbFile>> fake(String path) async => [
        _entry(
          '999999_20260101_000000_001.jpg',
          attributes: _attrPlainFile,
          size: 999,
        ),
        _entry('100438', attributes: _attrDirectory),
        _entry(
          '100438_20260908_140305_001.jpg',
          attributes: _attrPlainFile,
          size: 12345,
        ),
      ];

      await _pump(tester, _page(fake));

      // Folder tile: exact shape from the brief.
      final folderTile = find.ancestor(
        of: find.byIcon(Icons.folder),
        matching: find.byType(ListTile),
      );
      expect(folderTile, findsOneWidget);
      expect(
        find.descendant(of: folderTile, matching: find.text('100438')),
        findsOneWidget,
      );
      expect(find.text('Folder'), findsOneWidget);

      // Image tiles keep today's rendering (parse + size trailing) untouched.
      final imageTiles = find.ancestor(
        of: find.byIcon(Icons.image_outlined),
        matching: find.byType(ListTile),
      );
      expect(imageTiles, findsNWidgets(2));
      // Tile #1 is the order-like-named FILE '999999_...': its parsed title
      // renders as an IMAGE tile because attributes (0x80) carry no directory
      // bit — never a name heuristic.
      expect(
        find.descendant(of: imageTiles.first, matching: find.text('999999')),
        findsOneWidget,
      );
      expect(find.text('2026-01-01 00:00:00'), findsOneWidget);
      expect(find.text('999 B'), findsOneWidget);
      // Tile #2 shares the folder's order number — the two '100438' texts
      // (folder title vs parsed image title) must each stay scoped to their tile.
      expect(
        find.descendant(of: imageTiles.at(1), matching: find.text('100438')),
        findsOneWidget,
      );
      expect(find.text('2026-09-08 14:03:05'), findsOneWidget);
      expect(find.text('12 KB'), findsOneWidget);
      expect(find.text('100438'), findsNWidgets(2)); // folder + image title

      // Order: folder first, then images name-descending (= today's
      // newest-first contract within the flat-file listing).
      final folderY = tester.getCenter(folderTile).dy;
      expect(folderY, lessThan(tester.getCenter(imageTiles.first).dy));
      expect(
        tester.getCenter(imageTiles.first).dy,
        lessThan(tester.getCenter(imageTiles.at(1)).dy),
      );
    },
  );

  testWidgets('drill-down: folder tap lists that folder\'s images', (
    tester,
  ) async {
    final paths = <String>[];
    Future<List<SmbFile>> fake(String path) async {
      paths.add(path);
      if (path == '/zdrive/InvoiceData') {
        return [_entry('100438', attributes: _attrDirectory)];
      }
      return [
        _entry(
          '100438/100438_20260908_140305_001.jpg',
          attributes: _attrPlainFile,
          size: 12345,
        ),
        _entry(
          '100438/100438_20260907_090000_001.jpg',
          attributes: _attrPlainFile,
          size: 2048,
        ),
        _entry('100438/scan_2026.jpg', attributes: _attrPlainFile, size: 999),
        _entry('100438/notes.txt', attributes: _attrPlainFile, size: 55),
      ];
    }

    await _pump(tester, _page(fake));

    // Root: the folder tile plus pull-to-refresh, no loose images.
    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.tap(find.byIcon(Icons.folder));
    await tester.pump(); // route push
    await tester.pump(); // initState refresh future resolves

    // The seam received the share root AND the folder's full path (the same
    // shape conn.file() gets in production — folderPath is passed verbatim).
    expect(paths, ['/zdrive/InvoiceData', '/zdrive/InvoiceData/100438']);

    // AppBar title = folder name.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('100438')),
      findsOneWidget,
    );

    // Images only — notes.txt is filtered out; three tiles remain.
    final imageTiles = find.ancestor(
      of: find.byIcon(Icons.image_outlined),
      matching: find.byType(ListTile),
    );
    expect(imageTiles, findsNWidgets(3));

    // Parsed name: title = readable time, subtitle = filename, size trailing.
    expect(find.text('2026-09-08 14:03:05'), findsOneWidget);
    expect(find.text('100438_20260908_140305_001.jpg'), findsOneWidget);
    expect(find.text('12 KB'), findsOneWidget);
    expect(find.text('2026-09-07 09:00:00'), findsOneWidget);
    expect(find.text('100438_20260907_090000_001.jpg'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);

    // Unparsable image name: title falls back to the raw filename (which is
    // also the subtitle, hence two matches).
    expect(find.text('scan_2026.jpg'), findsNWidgets(2));
    expect(find.text('999 B'), findsOneWidget);

    // Newest first (name-desc) within the folder.
    expect(
      tester.getCenter(find.text('2026-09-08 14:03:05')).dy,
      lessThan(tester.getCenter(find.text('2026-09-07 09:00:00')).dy),
    );

    // Pull-to-refresh present at this level too. (The root page's own
    // indicator stays mounted beneath the pushed route, so the un-scoped
    // finder sees both — scope this one to the folder page.)
    expect(
      find.descendant(
        of: find.byType(OrderFilesPage),
        matching: find.byType(RefreshIndicator),
      ),
      findsOneWidget,
    );
  });

  testWidgets('drill-down: tapping a photo pushes ImageViewerPage', (
    tester,
  ) async {
    Future<List<SmbFile>> fake(String path) async {
      if (path == '/zdrive/InvoiceData') {
        return [_entry('100438', attributes: _attrDirectory)];
      }
      return [
        _entry(
          '100438/100438_20260908_140305_001.jpg',
          attributes: _attrPlainFile,
          size: 12345,
        ),
      ];
    }

    await _pump(tester, _page(fake));

    await tester.tap(find.byIcon(Icons.folder));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pump(); // route push
    await tester.pump(); // viewer builds; its download attempt resolves

    expect(find.byType(ImageViewerPage), findsOneWidget);
    // The viewer's app bar shows the tapped file's own name.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('100438_20260908_140305_001.jpg'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('drill-down: folder with no images shows the empty state', (
    tester,
  ) async {
    Future<List<SmbFile>> fake(String path) async {
      if (path == '/zdrive/InvoiceData') {
        return [_entry('100438', attributes: _attrDirectory)];
      }
      return [_entry('100438/notes.txt', attributes: _attrPlainFile, size: 55)];
    }

    await _pump(tester, _page(fake));

    await tester.tap(find.byIcon(Icons.folder));
    await tester.pump();
    await tester.pump();

    expect(find.text('No images in this folder.'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
  });

  testWidgets('activation: every History presentation re-lists via the seam', (
    tester,
  ) async {
    var calls = 0;
    final paths = <String>[];
    Future<List<SmbFile>> fake(String path) async {
      calls++;
      paths.add(path);
      return const [];
    }

    await tester.pumpWidget(MaterialApp(home: _TabShellHarness(listDir: fake)));
    await tester.pump();
    expect(calls, 0); // Scan first — HistoryPage not created yet

    // Presentation #1: first visit → initState refresh.
    await tester.tap(find.text('History'));
    await tester.pump();
    expect(calls, 1);

    // Back to Scan: hidden, no re-list.
    await tester.tap(find.text('Scan'));
    await tester.pump();
    expect(calls, 1);

    // Presentation #2: false → true flip → didUpdateWidget refresh.
    await tester.tap(find.text('History'));
    await tester.pump();
    expect(calls, 2);

    // The seam always receives the share root here.
    expect(paths, everyElement('/zdrive/InvoiceData'));
  });
}
