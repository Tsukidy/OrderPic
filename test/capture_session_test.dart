import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:orderpic/capture/session.dart';

/// Everything this file creates under Directory.systemTemp, so tearDown can
/// remove it without touching anything the user put there. Only ever paths
/// built from [seed]/planted names with the exact mmcpic-session- prefix.
final List<Directory> _created = [];

Directory _plant(String name) {
  final d = Directory('${Directory.systemTemp.path}/$name')
    ..createSync(recursive: true);
  _created.add(d);
  return d;
}

File _shotFile(Directory dir, String fileName) {
  final f = File('${dir.path}/$fileName')..writeAsBytesSync([1, 2, 3]);
  return f;
}

void main() {
  tearDown(() {
    for (final d in _created.toList().reversed) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {/* best effort — test cleanup only */}
    }
    _created.clear();
  });

  group('CaptureSession.create', () {
    test('makes a mmcpic-session-<order>-<epoch> dir under systemTemp',
        () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      expect(s.orderNumber, '100438');
      expect(s.dir.existsSync(), isTrue);
      expect(s.dir.parent.path, Directory.systemTemp.path);
      expect(
        s.dir.name,
        matches(RegExp(r'^mmcpic-session-100438-\d+$')),
      );
    });

    test('two sessions for the same order get distinct dirs', () async {
      final a = await CaptureSession.create('100438');
      // The name is pinned to epochMillis, so guarantee a tick passes
      // before the second create (same-millisecond creates may share a
      // dir by design — callers never create sessions that fast).
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await CaptureSession.create('100438');
      _created.addAll([a.dir, b.dir]);
      expect(a.dir.path, isNot(b.dir.path));
    });
  });

  group('shot bookkeeping', () {
    test('nextIndex starts at 1 and advances per add', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      expect(s.nextIndex, 1);
      expect(s.shots, isEmpty);
      s.add(const Shot(localPath: 'a.jpg', fileName: 'a.jpg'));
      s.add(const Shot(localPath: 'b.jpg', fileName: 'b.jpg'));
      expect(s.nextIndex, 3);
      expect(s.shots.length, 2);
    });

    test('shots list is unmodifiable', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      s.add(const Shot(localPath: 'a.jpg', fileName: 'a.jpg'));
      expect(() => s.shots.clear(), throwsUnsupportedError);
    });

    test('removeLast returns the last shot only and drops nextIndex',
        () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      const first = Shot(localPath: '1.jpg', fileName: '1.jpg');
      const second = Shot(localPath: '2.jpg', fileName: '2.jpg');
      s
        ..add(first)
        ..add(second);
      final removed = s.removeLast();
      expect(removed, second);
      expect(s.shots, [first]);
      expect(s.nextIndex, 2, reason: 'one shot still staged');
      expect(s.removeLast(), first);
      expect(s.removeLast(), isNull);
      expect(s.nextIndex, 1);
    });
  });

  group('deleteLocal', () {
    test('removes the file from disk and the shot from the list', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      final f = _shotFile(s.dir, '100438_20260908_140305_001.jpg');
      final shot = Shot(localPath: f.path, fileName: f.name);
      s.add(shot);
      await s.deleteLocal(shot);
      expect(f.existsSync(), isFalse);
      expect(s.shots, isEmpty);
      expect(s.nextIndex, 1);
    });

    test('missing shot is a no-op that does not throw', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      const stray = Shot(localPath: 'nowhere.jpg', fileName: 'nowhere.jpg');
      await s.deleteLocal(stray);
      expect(s.shots, isEmpty);
    });
  });

  group('cleanupIfEmpty', () {
    test('removes the dir when no shots remain', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      await s.cleanupIfEmpty();
      expect(s.dir.existsSync(), isFalse);
    });

    test('keeps the dir when shots remain', () async {
      final s = await CaptureSession.create('100438');
      _created.add(s.dir);
      final f = _shotFile(s.dir, '100438_20260908_140305_001.jpg');
      s.add(Shot(localPath: f.path, fileName: f.name));
      await s.cleanupIfEmpty();
      expect(s.dir.existsSync(), isTrue);
    });
  });

  group('sweepStaleSessions', () {
    test('removes planted mmcpic-session-* dirs, leaves non-matching siblings',
        () async {
      final stale = _plant('mmcpic-session-x');
      _shotFile(stale, 'leftover.jpg');
      final other = _plant('keep-me');
      await sweepStaleSessions();
      expect(stale.existsSync(), isFalse,
          reason: 'stale session dir must be swept');
      expect(other.existsSync(), isTrue,
          reason: 'non-matching sibling must survive the sweep');
    });
  });
}

extension on Directory {
  String get name => path.split(Platform.pathSeparator).last;
}

extension _FileName on File {
  String get name => path.split(Platform.pathSeparator).last;
}
