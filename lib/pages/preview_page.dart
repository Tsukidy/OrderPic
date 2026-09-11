import 'dart:io';

import 'package:flutter/material.dart';

import '../capture/image_processor.dart';
import '../capture/session.dart';
import '../capture/uploader.dart';
import '../settings/app_settings.dart';
import 'camera_page.dart';

/// Stage 3 — review the shots of the session, then retake the newest one,
/// add more (batch mode), or upload every staged shot to the SMB share.
/// Batch mode shows the strip: tapping a thumbnail reviews that shot
/// full-screen (default = the newest).
///
/// Admission is background (Task 6.6): a picked shot lands here as a
/// PENDING entry while its conversion still runs, so this page re-renders
/// off the session's notifications ([CaptureSession] is a ChangeNotifier).
/// Pending thumbs show a spinner; failed conversions stay staged flagged
/// (error tint + full-screen retake); Upload all waits for pending shots
/// to settle and then uploads the READY ones only — failed entries are
/// never uploaded, they are surfaced for retake.
///
/// The upload itself lives in [uploadSession] (Task 4.1); this page only
/// owns the state machine around it. [PreviewPage.uploader] is the test
/// seam — null means the real thing, exactly like the `SettingsStore` /
/// `ImageProcessor` seams.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.session,
    required this.settingsNotifier,
    this.uploader,
    this.processor = const NativeImageProcessor(),
  });

  final CaptureSession session;
  final ValueNotifier<AppSettings> settingsNotifier;

  /// Injectable upload — null → the real [uploadSession]. Tests pass a
  /// fake that records calls and returns a canned [UploadSummary]. The
  /// extra named parameters keep the injected shape assignable from the
  /// real `uploadSession` (`only` = the READY-only subset this page
  /// uploads) while letting fakes ignore them.
  final Future<UploadSummary> Function(
    CaptureSession,
    AppSettings, {
    List<Shot>? only,
    void Function(int done, int total)? onProgress,
  })? uploader;

  /// Injectable admission for the camera pages this page opens (Retake /
  /// Add photo / More for this order) — forwarded so a test's fake or
  /// thrower reaches the whole capture loop, not just the review side.
  /// Defaults to production.
  final ImageProcessor processor;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

enum _UploadStatus { idle, waiting, uploading, done, failed }

class _PreviewPageState extends State<PreviewPage> {
  _UploadStatus _status = _UploadStatus.idle;

  /// The staged shot the full-screen preview shows — null means "newest"
  /// (today's behavior). A thumbnail tap pins the index; returning to the
  /// last shot is tapping its thumbnail again. Every new admission, the
  /// Retake rollback, and the upload-completion state all fall back here,
  /// so the selection is only ever a review-time view.
  int? _selectedIndex;

  /// The file name shown by the batch-off done banner (the session's last
  /// uploaded shot) — 'Uploaded: {fileName}' preserves today's shape.
  String? _uploadedName;

  /// Upload-progress overlay counters. `done` counts PROCESSED shots
  /// (uploader contract) — never used as the "N uploaded" figure; that is
  /// the summary's [UploadSummary.uploadedCount].
  int _done = 0;
  int _total = 0;
  UploadSummary? _summary;

  /// Thrown-uploader escape text (per-shot errors live in [_summary]).
  String? _error;

  /// Last READY path the full-screen image pointed at. A successful upload
  /// empties the session (the uploader deletes each local file and reclaims
  /// the dir), but today's page keeps showing the just-uploaded photo
  /// behind the done banner — the image cache still holds it. Pin the path
  /// so that survives the session emptying. Pending/failed selections
  /// never overwrite it (they have no displayable file).
  String? _lastShownPath;

  /// The folder-bundling UI switch: count chip, thumb strip, Add photo,
  /// Upload all. Batch OFF must stay exactly today's single-shot UX.
  bool get _batchOn => widget.settingsNotifier.value.upload.batchMode;

  /// The staged shots that may be uploaded — the ones whose conversion
  /// finished. PENDING shots gate the upload (it starts only after they
  /// settle); FAILED ones are surfaced for retake instead.
  List<Shot> get _readyShots => [
    for (final s in widget.session.shots)
      if (s.status == ShotStatus.ready) s,
  ];

  List<Shot> get _failedShots => [
    for (final s in widget.session.shots)
      if (s.status == ShotStatus.failed) s,
  ];

  @override
  void initState() {
    super.initState();
    // Background conversions settle via session notifications — re-render
    // (and start a gated upload) as statuses change.
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// Fired for every staged-list change: admissions, pending →
  /// ready/failed settlements, retake removals, upload deletions.
  void _onSessionChanged() {
    if (!mounted) return;
    if (_status == _UploadStatus.waiting &&
        widget.session.pendingShots.isEmpty) {
      // The gate opened: pending conversions settled (ready or failed) —
      // upload starts NOW, covering the ready shots only. Drop the waiting
      // status first so [_uploadAll]'s re-entry guard lets it run.
      _status = _UploadStatus.idle;
      _uploadAll();
      return;
    }
    setState(() {});
  }

  Future<void> _uploadAll() async {
    if (_status == _UploadStatus.uploading || _status == _UploadStatus.waiting) {
      return;
    }
    final ready = _readyShots;
    if (widget.session.pendingShots.isNotEmpty) {
      // Gate: upload STARTS only after pending conversions settle. The
      // session listener calls back in when they have.
      setState(() => _status = _UploadStatus.waiting);
      return;
    }
    if (ready.isEmpty) {
      // Nothing uploadable: every staged shot failed to convert (or the
      // session is empty). Surface the flags instead of "uploading" a
      // zero-shot batch.
      if (_failedShots.isEmpty) return;
      setState(() {
        _status = _UploadStatus.failed;
        _summary = null;
        _error = null;
        _uploadedName = null;
      });
      return;
    }

    setState(() {
      _status = _UploadStatus.uploading;
      _uploadedName = null;
      _done = 0;
      _total = ready.length;
      _summary = null;
      _error = null;
      _selectedIndex = null; // working set is about to be re-cut — newest again
    });

    try {
      // Retry is this same call: failed-upload shots stay staged, so
      // re-invoking the uploader on the ready subset covers exactly the
      // remaining shots. Conversion-FAILED entries are never passed — they
      // stay staged flagged for retake.
      final summary = await _runUpload(ready);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _status = summary.allOk ? _UploadStatus.done : _UploadStatus.failed;
        if (summary.allOk && summary.outcomes.isNotEmpty) {
          _uploadedName = summary.outcomes.last.shot.fileName;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _UploadStatus.failed;
          _summary = null;
          _error = e.toString();
        });
      }
    }
  }

  Future<UploadSummary> _runUpload(List<Shot> ready) {
    final injected = widget.uploader;
    if (injected != null) {
      return injected(
        widget.session,
        widget.settingsNotifier.value,
        only: ready,
        onProgress: (done, total) {
          if (mounted) setState(() => _done = done);
        },
      );
    }
    return uploadSession(
      widget.session,
      widget.settingsNotifier.value,
      only: ready,
      onProgress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );
  }

  /// Back to the camera for the SAME session — Retake's path only (design
  /// D10: retake is camera-only). [removeLast] drops the newest shot and
  /// deletes its file — that shot never happened, [CaptureSession.nextIndex]
  /// rolls back with it — so the session survives and the numbering keeps
  /// accumulating. Add photo goes through [_pickSource] instead (source
  /// choice first); its same-session leg repeats the disarm-and-push shape
  /// below once a source was actually chosen.
  ///
  /// Retaking a PENDING last shot is the cancel path: the entry goes now
  /// and the in-flight conversion cleans up after itself when it finds its
  /// entry gone ([admitPicked]'s settle step). A FAILED last shot likewise
  /// drops its (nonexistent) file without ceremony.
  Future<void> _openCamera({required bool removeLast}) async {
    // Retake during the upload gate: leaving review while conversions
    // still run means there is no one waiting — clear the gate so the
    // settle never fires an upload into a page that has moved on.
    if (_status == _UploadStatus.waiting) _status = _UploadStatus.idle;
    if (removeLast) {
      final shot = widget.session.removeLast();
      if (shot != null) await widget.session.deleteLocal(shot);
    }
    // The thumbnail selection is review-time state only: Retake must not
    // keep pointing at a dropped index, and coming back from the camera
    // should present the newly admitted (last) shot either way.
    _selectedIndex = null;
    if (!mounted) return;
    await _pushCamera();
  }

  /// The Add-photo source choice (design D4): the next photos are SHOT with
  /// the system camera or PICKED from the gallery's multi-select sheet. The
  /// choice is a bottom sheet, not a third button in an action row — the
  /// narrow-screen contract keeps those rows at Retake / Add photo / the
  /// gated or upload button, and a 360dp screen has no room for a fourth
  /// sibling (documented row overflow, see [_bottomButtons]).
  ///
  /// Opening the sheet changes nothing and navigates nowhere; DISMISSING it
  /// (barrier tap, back gesture) is a full no-op — the armed upload gate
  /// stays armed and the pinned thumbnail stays pinned. So the state changes
  /// below happen only once a choice was made, at the moment navigation
  /// actually happens — never while the sheet is merely open.
  ///
  /// [freshSession] is Task 4.2's leg: the done-state continuations (More
  /// for this order / Another photo (same order)) will come through here
  /// and start a brand-new session with the chosen source. No caller
  /// reaches that branch yet.
  Future<void> _pickSource({required bool freshSession}) async {
    final source = await showModalBottomSheet<CaptureSource>(
      context: context,
      builder: _sourceSheet,
    );
    // Null = dismissed: nothing at all happens.
    if (source == null || !mounted) return;
    if (freshSession) {
      // Task 4.2 turns this branch on (CaptureSession.create + push with
      // [source]); deliberately inert today — nothing calls it.
      return;
    }
    // Same-session Add photo: the exact state [_openCamera] leaves behind
    // for its push, applied now that a source was actually chosen.
    if (_status == _UploadStatus.waiting) _status = _UploadStatus.idle;
    _selectedIndex = null;
    await _pushCamera(source);
  }

  /// The two answers the sheet offers. The labels are the operator-facing
  /// contract ("Choose from gallery" — not the bare "Gallery" the scanner
  /// dialogs use — because this choice is about the NEXT photos, not the
  /// whole flow's source); the keys are the tests' handles.
  Widget _sourceSheet(BuildContext sheetContext) {
    return SafeArea(
      key: const Key('source_sheet'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('sheet_take_photo'),
            leading: const Icon(Icons.photo_camera),
            title: const Text('Take photo'),
            onTap: () => Navigator.of(sheetContext).pop(CaptureSource.camera),
          ),
          ListTile(
            key: const Key('sheet_gallery'),
            leading: const Icon(Icons.photo_library),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(sheetContext).pop(CaptureSource.gallery),
          ),
        ],
      ),
    );
  }

  /// Retake of ONE flagged (failed-conversion) entry — not necessarily the
  /// newest: drops exactly that entry and relaunches the camera on the
  /// same session so the replacement reuses its slot number.
  Future<void> _retakeShot(Shot failed) async {
    // Same gate disarm as [_openCamera]: if a pending conversion settles
    // during the awaits below, the auto-start must not fire into a page
    // that is mid-navigation.
    if (_status == _UploadStatus.waiting) _status = _UploadStatus.idle;
    await widget.session.deleteLocal(failed);
    _selectedIndex = null;
    if (!mounted) return;
    await _pushCamera();
  }

  /// The oldest conversion failure — the "Retake failed photo" shortcut
  /// target when no specific shot is pinned.
  Shot? get _firstFailed {
    for (final s in widget.session.shots) {
      if (s.status == ShotStatus.failed) return s;
    }
    return null;
  }

  /// [source] defaults to the camera so the Retake callers below stay
  /// verbatim; [_pickSource]'s same-session leg forwards the chosen source.
  Future<void> _pushCamera([CaptureSource source = CaptureSource.camera]) {
    return Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraPage(
          session: widget.session,
          settingsNotifier: widget.settingsNotifier,
          processor: widget.processor,
          source: source,
        ),
      ),
    );
  }

  /// Post-upload continuation for the same order — a FRESH session (new
  /// dir, numbering restarted), never a reuse of the one that just
  /// finished. Both 'More for this order' (batch on) and 'Another photo
  /// (same order)' (batch off) land here. Only reachable with no
  /// conversion failures staged (the done row swaps to retake-first then).
  Future<void> _moreForThisOrder() async {
    final session = await CaptureSession.create(widget.session.orderNumber);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CameraPage(
          session: session,
          settingsNotifier: widget.settingsNotifier,
          processor: widget.processor,
        ),
      ),
    );
  }

  void _scanNext() {
    // Pop the capture flow and land back on the tab shell (Scan tab).
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// One line per failed UPLOAD outcome, in session order — a dead local
  /// file would otherwise be invisible behind a single blob message.
  List<String> get _failedLines => [
    for (final o in _summary?.outcomes ?? const <UploadOutcome>[])
      if (!o.ok) '${o.shot.fileName}: ${o.error ?? 'failed'}',
  ];

  @override
  Widget build(BuildContext context) {
    final shots = widget.session.shots;
    final done = _status == _UploadStatus.done;

    // The reviewed shot — pinned index, else the newest. In the done state
    // the working set is over: keep showing the pinned last-uploaded image
    // (a leftover FAILED entry must not replace it with the placeholder).
    Shot? selected;
    if (!done && shots.isNotEmpty) {
      final sel = _selectedIndex;
      selected = (sel != null && sel < shots.length) ? shots[sel] : shots.last;
      if (selected.status == ShotStatus.ready) _lastShownPath = selected.localPath;
    }
    final shownPath = _lastShownPath;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      color: Colors.white,
                      tooltip: 'Scan a different QR code',
                      onPressed: _status == _UploadStatus.uploading ||
                              _status == _UploadStatus.waiting
                          ? null
                          : _scanNext,
                    ),
                    if (done)
                      _doneBanner()
                    else if (_batchOn)
                      _batchChip(shots.length)
                    else
                      _qrChip(),
                  ],
                ),
                if (_batchOn && !done) _thumbStrip(shots),
                // The reviewed shot fills the VISIBLE middle — between the
                // strip and the bottom controls — so BoxFit.contain centers
                // it where the operator's eye expects. Centering on the
                // full screen behind the overlays leaves more visible
                // letterbox below than above (the top overlay is taller),
                // which reads as "pushed to the top" for landscape shots
                // (device finding 6.13).
                Expanded(child: _fullScreen(selected, shownPath)),
                if (_failedShots.isNotEmpty && _status != _UploadStatus.uploading)
                  _conversionBanner(),
                if (_status == _UploadStatus.failed) _errorBanner(),
                _bottomButtons(),
                const SizedBox(height: 24),
              ],
            ),
          ),
          if (_status == _UploadStatus.uploading) _uploadingOverlay(),
        ],
      ),
    );
  }

  /// The full-screen area: the reviewed READY shot, a spinner while its
  /// conversion runs, a retake placeholder when the conversion failed —
  /// or, once uploaded, the pinned last-uploaded image.
  Widget _fullScreen(Shot? selected, String? shownPath) {
    if (selected == null || selected.status == ShotStatus.ready) {
      return shownPath == null
          ? const SizedBox.shrink()
          : Image.file(
              File(shownPath),
              fit: BoxFit.contain,
              gaplessPlayback: true,
            );
    }
    if (selected.status == ShotStatus.pending) {
      return const Center(
        key: Key('preview_pending'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Converting…',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      );
    }
    return Center(
      key: const Key('preview_failed'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 12),
          Text(
            'Could not convert ${selected.fileName}',
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('retake_shot_button'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white),
            ),
            onPressed: () => _retakeShot(selected),
            icon: const Icon(Icons.refresh),
            label: const Text('Retake this photo'),
          ),
        ],
      ),
    );
  }

  Widget _uploadingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Uploading $_done / $_total',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The batch-off order chip — styled exactly like the old page's chip
  /// (and CameraPage's): regular weight, 16 px.
  Widget _qrChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Order: ${widget.session.orderNumber}',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }

  /// Batch-mode header: the order plus how many photos are staged so far
  /// (pending and flagged entries included — they are part of the batch).
  /// Bold to stand apart from the plain single-shot chip.
  Widget _batchChip(int count) {
    final noun = count == 1 ? 'photo' : 'photos';
    return _pill(
      color: Colors.black54,
      text: 'Order: ${widget.session.orderNumber} — $count $noun',
      fontSize: 16,
    );
  }

  /// Thumbnails of every staged shot, oldest first; the one shown
  /// full-screen is highlighted, and tapping a tile makes IT the
  /// full-screen shot (tapping the newest's tile is the way back).
  /// PENDING tiles spin (no file to decode yet); FAILED tiles carry an
  /// error tint — tapping one reviews the failure full-screen, where the
  /// retake button lives. Each ready tile caps the decode at the tile
  /// size × device pixel ratio — without [Image.file.cacheWidth] a 12 MP
  /// shot decodes to ~48 MB of pixels per 56 px thumbnail (jank + memory
  /// pressure once a batch grows).
  Widget _thumbStrip(List<Shot> shots) {
    final cacheWidth = (56 * MediaQuery.devicePixelRatioOf(context)).round();
    final selected = _selectedIndex ?? shots.length - 1;
    return SizedBox(
      key: const Key('thumb_strip'),
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: shots.length,
        itemBuilder: (context, i) {
          final shot = shots[i];
          return GestureDetector(
            onTap: () => setState(() => _selectedIndex = i),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                border: Border.all(
                  color: i == selected ? Colors.white : Colors.white30,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: switch (shot.status) {
                  ShotStatus.ready => Image.file(
                    File(shot.localPath),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: cacheWidth,
                  ),
                  ShotStatus.pending => Container(
                    key: Key('thumb_pending_$i'),
                    color: Colors.black26,
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  ShotStatus.failed => Container(
                    key: Key('thumb_failed_$i'),
                    color: Colors.red.withValues(alpha: 0.35),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.error_outline,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                },
              ),
            ),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(width: 8),
      ),
    );
  }

  Widget _doneBanner() {
    if (_batchOn) {
      final n = _summary?.uploadedCount ?? 0;
      return _pill(
        color: Colors.green,
        text: 'Uploaded $n photo${n == 1 ? '' : 's'}',
      );
    }
    return _pill(color: Colors.green, text: 'Uploaded: ${_uploadedName ?? ''}');
  }

  /// Flags conversion failures at review time: staged entries that will
  /// NOT be part of any upload until retaken. Visible in every state
  /// except mid-upload (the overlay covers the page then).
  Widget _conversionBanner() {
    final failed = _failedShots;
    final n = failed.length;
    return Container(
      key: const Key('conversion_banner'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$n photo${n == 1 ? '' : 's'} failed to convert — retake '
            'before upload:',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          for (final s in failed)
            Text(s.fileName, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _pill({
    required Color color,
    required String text,
    double fontSize = 14,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _errorBanner() {
    final lines = _failedLines;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Upload failed:',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          if (lines.isEmpty)
            Text(_error ?? 'nothing to upload', style: const TextStyle(color: Colors.white))
          else
            ...lines.map((line) => Text(line, style: const TextStyle(color: Colors.white))),
        ],
      ),
    );
  }

  OutlinedButton _outlined({IconData? icon, required String label, VoidCallback? onPressed, Key? key}) {
    return OutlinedButton.icon(
      key: key,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white),
      ),
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
    );
  }

  /// [ellipsize] opts a label into single-line truncation. It matters only
  /// when the row squeezes the button (see [_waitingButton]): FilledButton
  /// hosts the label in a Flexible of its own, so a width-bounded button
  /// passes the bound down and the text truncates — left alone it would
  /// wrap to two lines and stretch the row's height instead.
  FilledButton _filled({
    IconData? icon,
    required String label,
    VoidCallback? onPressed,
    Key? key,
    bool ellipsize = false,
  }) {
    return FilledButton.icon(
      key: key,
      icon: Icon(icon),
      label: ellipsize
          ? Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            )
          : Text(label),
      onPressed: onPressed,
    );
  }

  /// The gated Upload button — shown while conversions are pending. Still
  /// pressable: the tap ARMS the gate ("start the upload once everything
  /// has converted"), and the session listener auto-starts it the moment
  /// the last conversion settles. Capture never blocks on it — Add photo
  /// stays available alongside.
  ///
  /// Narrow-screen contract: whenever this button shares a row with Retake
  /// and Add photo, the row wraps it in a [Flexible] — the two fixed
  /// siblings leave less room than the label wants, so the button shrinks
  /// and the label ellipsizes (device-reported bug: the row used to
  /// overflow by the label's excess). The count stays the label's point —
  /// 'Waiting… (2)' — so it is kept short instead of spelled out
  /// ('Waiting for 2 conversions…'), which alone overflowed 360 dp.
  FilledButton _waitingButton({Key? key}) {
    final n = widget.session.pendingShots.length;
    return _filled(
      key: key ?? const Key('waiting_button'),
      icon: Icons.hourglass_top,
      label: 'Waiting… ($n)',
      onPressed: _uploadAll,
      ellipsize: true,
    );
  }

  /// Retake-first escape when a conversion failure holds the batch: drop
  /// the oldest flagged entry and reopen the camera on the same session.
  Widget _retakeFailedButton() {
    return _outlined(
      icon: Icons.refresh,
      label: 'Retake failed photo',
      onPressed: _firstFailed == null ? null : () => _retakeShot(_firstFailed!),
    );
  }

  Widget _bottomButtons() {
    switch (_status) {
      case _UploadStatus.uploading:
        return const SizedBox.shrink();

      case _UploadStatus.waiting:
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.refresh,
                label: 'Retake',
                onPressed: () => _openCamera(removeLast: true),
              ),
              _outlined(
                key: const Key('add_photo_button'),
                icon: Icons.add_a_photo,
                label: 'Add photo',
                onPressed: () => _pickSource(freshSession: false),
              ),
              // The only squeezable child: on a narrow screen the two fixed
              // buttons can leave less room than the label needs — the
              // button shrinks and the label ellipsizes instead of the row
              // overflowing (see [_waitingButton]).
              Flexible(child: _waitingButton()),
            ],
          );
        }
        return _waitingButton();

      case _UploadStatus.done:
        if (_failedShots.isNotEmpty) {
          // Uploaded everything convertible, but flagged entries remain:
          // retake-first, then the flow re-reviews and re-uploads them.
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _retakeFailedButton(),
              _filled(
                icon: Icons.qr_code_scanner,
                label: 'Scan next QR code',
                onPressed: _scanNext,
              ),
            ],
          );
        }
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.add_a_photo,
                label: 'More for this order',
                onPressed: _moreForThisOrder,
              ),
              _filled(
                icon: Icons.qr_code_scanner,
                label: 'Scan next QR code',
                onPressed: _scanNext,
              ),
            ],
          );
        }
        // Today's single-shot done row, labels verbatim.
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.photo_camera,
              label: 'Another photo\n(same order)',
              onPressed: _moreForThisOrder,
            ),
            _filled(
              icon: Icons.qr_code_scanner,
              label: 'Scan next\nQR code',
              onPressed: _scanNext,
            ),
          ],
        );

      case _UploadStatus.failed:
        if (_batchOn) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_readyShots.isNotEmpty)
                _outlined(
                  icon: Icons.refresh,
                  label: 'Retry upload',
                  onPressed: _uploadAll,
                )
              else
                _retakeFailedButton(),
              _filled(
                icon: Icons.qr_code_scanner,
                label: 'Scan next QR code',
                onPressed: _scanNext,
              ),
            ],
          );
        }
        // Today's single-shot failed row (Retake stays; the QR icon above
        // is the scan-next escape, as before). With nothing convertible
        // left, Retry is pointless — Retake is the way forward.
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.refresh,
              label: 'Retake',
              onPressed: () => _openCamera(removeLast: true),
            ),
            if (_readyShots.isNotEmpty)
              _filled(icon: Icons.refresh, label: 'Retry upload', onPressed: _uploadAll),
          ],
        );

      case _UploadStatus.idle:
        if (_batchOn) {
          final pending = widget.session.pendingShots.isNotEmpty;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _outlined(
                icon: Icons.refresh,
                label: 'Retake',
                onPressed: () => _openCamera(removeLast: true),
              ),
              // Capture never blocks on conversions: Add photo stays live
              // while shots are pending — the next photo can be taken
              // immediately (the spec's point).
              _outlined(
                key: const Key('add_photo_button'),
                icon: Icons.add_a_photo,
                label: 'Add photo',
                onPressed: () => _pickSource(freshSession: false),
              ),
              if (pending)
                // Same narrow-screen squeeze as the waiting row above.
                Flexible(child: _waitingButton())
              else if (_readyShots.isNotEmpty)
                _filled(
                  key: const Key('upload_all_button'),
                  icon: Icons.cloud_upload,
                  label: 'Upload all',
                  onPressed: _uploadAll,
                )
              else
                _retakeFailedButton(),
            ],
          );
        }
        // Today's single-shot idle row — gated when conversions are still
        // in flight, retake-first when everything staged failed.
        if (widget.session.pendingShots.isNotEmpty) return _waitingButton();
        if (_readyShots.isEmpty) {
          return _outlined(
            icon: Icons.refresh,
            label: 'Retake',
            onPressed: () => _openCamera(removeLast: true),
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _outlined(
              icon: Icons.refresh,
              label: 'Retake',
              onPressed: () => _openCamera(removeLast: true),
            ),
            _filled(icon: Icons.cloud_upload, label: 'Upload', onPressed: _uploadAll),
          ],
        );
    }
  }
}
