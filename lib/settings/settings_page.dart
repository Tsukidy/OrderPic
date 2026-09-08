import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../smb/smb.dart';
import 'app_settings.dart';
import 'settings_store.dart';

/// Settings / first-run setup. One widget, two entry modes: gear-invoked
/// ("Settings"; back discards edits) and first-run ("Set up SMB login";
/// back disabled until a valid save — see PopScope). Edits the whole
/// [AppSettings] in two sections — Capture & upload prefs on top, the
/// SMB connection below.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settingsNotifier,
    this.firstRun = false,
    this.store = const SecureSettingsStore(),
  });

  final ValueNotifier<AppSettings> settingsNotifier;
  final bool firstRun;
  final SettingsStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _sharePath;
  late final TextEditingController _domain;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _obscured = true;

  // Capture & upload section. The quality block is only mounted while
  // _format is JPEG (PNG is lossless — no quality knobs); its state
  // lives here, so it survives the hide/show round-trip.
  late bool _folders;
  late bool _batch;
  late ImageFormat _format;
  late JpegQuality _quality;

  /// Controller for the custom max-long-edge field; hoisted to State so
  /// dispose runs after the page's exit animation (dialog-controller
  /// rule applies to pushed pages' TextFields too).
  late final TextEditingController _customMaxEdge;
  int _customQuality = 80; // clamped 30–100 at set-time (ledger, Task 2.1)

  @override
  void initState() {
    super.initState();
    final s = widget.settingsNotifier.value.connection;
    _host = TextEditingController(text: s.host);
    _sharePath = TextEditingController(text: s.sharePath);
    _domain = TextEditingController(text: s.domain);
    _username = TextEditingController(text: s.username);
    _password = TextEditingController(text: s.password);
    final upload = widget.settingsNotifier.value.upload;
    _folders = upload.useOrderFolders;
    _batch = upload.batchMode;
    _format = upload.format;
    _quality = upload.jpegQuality;
    _customQuality = upload.customQuality.clamp(30, 100);
    _customMaxEdge = TextEditingController(
      text: upload.customMaxEdgePx?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _host.dispose();
    _sharePath.dispose();
    _domain.dispose();
    _username.dispose();
    _password.dispose();
    _customMaxEdge.dispose();
    super.dispose();
  }

  ConnectionSettings _formSettings() => ConnectionSettings(
    host: _host.text.trim(),
    sharePath: _sharePath.text.trim(),
    domain: _domain.text.trim(),
    username: _username.text.trim(),
    password: _password.text,
  );

  bool _testing = false;
  int? _testCount;
  String? _testError;

  /// Share path the successful count came from (the snapshot as tested,
  /// not the live field — see _testConnection).
  String? _testPath;

  /// A field edit invalidates the last test result: clear it so a stale
  /// count/error can't be mistaken for the current form values.
  void _clearTestResultIfAny() {
    if (_testCount == null && _testError == null && _testPath == null) return;
    setState(() {
      _testCount = null;
      _testError = null;
      _testPath = null;
    });
  }

  Future<void> _testConnection() async {
    final s = _formSettings();
    if (s.username.isEmpty) {
      setState(() {
        _testing = false;
        _testCount = null;
        _testPath = null;
        _testError = SmbNotConfiguredException.message;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testCount = null;
      _testPath = null;
      _testError = null;
    });
    try {
      final conn = await connect(s);
      try {
        final folder = await conn.file(s.sharePath);
        final entries = await conn.listFiles(folder);
        if (!mounted) return;
        setState(() {
          _testing = false;
          _testCount = entries.length;
          _testPath = s.sharePath;
        });
      } finally {
        await conn.close();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testing = false;
          _testError = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final s = _formSettings();
    final current = widget.settingsNotifier.value;
    // Build the upload half from form state with ALL fields explicit.
    // copyWith can't set customMaxEdgePx back to null (its ?? swallows
    // the null), so a blanked field would ride through as the old cap —
    // construct fresh instead (ledger, Task 2.1). Only the connection
    // half carries the live-instance-reuse discipline; History's remount
    // key doesn't read the upload half.
    final t = _customMaxEdge.text.trim();
    final upload = UploadPrefs(
      useOrderFolders: _folders,
      batchMode: _batch,
      format: _format,
      jpegQuality: _quality,
      customQuality: _customQuality.clamp(30, 100),
      customMaxEdgePx: t.isEmpty ? null : int.tryParse(t),
    );
    try {
      await AppSettings(connection: s, upload: upload).save(
        store: widget.store,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save settings')),
        );
      }
      return; // stay on the page
    }
    // Instance discipline: HomePage's History remount key is
    // ObjectKey(settings.connection), and ObjectKey compares with
    // identical() — a fresh ==-equal connection instance would look
    // like a change to that key. So when the form values are unchanged,
    // reuse the LIVE connection instance; only a real change swaps
    // identity. The upload half is always built fresh from form state
    // (History's key doesn't read it), and a fully ==-equal AppSettings
    // is dropped by ValueNotifier's == suppression (no History rebuild
    // at all) — an upload-only save rebuilds History in place, never
    // remounts it.
    widget.settingsNotifier.value = current.copyWith(
      connection: s == current.connection ? current.connection : s,
      upload: upload,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  String? _sharePathValidator(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Required';
    if (!t.startsWith('/')) return 'Must start with / (share/sub-folder)';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.firstRun, // setup mode: no escape before a valid save
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.firstRun ? 'Set up SMB login' : 'Settings'),
          // Setup mode: back is blocked anyway — don't show a dead arrow.
          automaticallyImplyLeading: !widget.firstRun,
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Capture & upload',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              SwitchListTile(
                key: const Key('folders_toggle'),
                title: const Text('Upload into per-order folders'),
                value: _folders,
                onChanged: (v) => setState(() => _folders = v),
              ),
              SwitchListTile(
                key: const Key('batch_toggle'),
                title: const Text('Multi-photo batch capture'),
                value: _batch,
                onChanged: (v) => setState(() => _batch = v),
              ),
              SegmentedButton<ImageFormat>(
                key: const Key('format_selector'),
                segments: const [
                  ButtonSegment(value: ImageFormat.jpeg, label: Text('JPEG')),
                  ButtonSegment(value: ImageFormat.png, label: Text('PNG')),
                ],
                selected: {_format},
                onSelectionChanged: (selection) =>
                    setState(() => _format = selection.first),
              ),
              // Quality only exists for JPEG — selecting PNG hides the
              // whole block; the selection state lives in this State, so
              // switching back restores it untouched.
              if (_format == ImageFormat.jpeg) ...[
                const SizedBox(height: 8),
                Padding(
                  key: const Key('quality_section'),
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<JpegQuality>(
                        key: const Key('quality_selector'),
                        segments: const [
                          ButtonSegment(
                            value: JpegQuality.original,
                            label: Text('Original'),
                          ),
                          ButtonSegment(
                            value: JpegQuality.high,
                            label: Text('High'),
                          ),
                          ButtonSegment(
                            value: JpegQuality.balanced,
                            label: Text('Balanced'),
                          ),
                          ButtonSegment(
                            value: JpegQuality.small,
                            label: Text('Small'),
                          ),
                          ButtonSegment(
                            value: JpegQuality.custom,
                            label: Text('Custom'),
                          ),
                        ],
                        selected: {_quality},
                        onSelectionChanged: (selection) =>
                            setState(() => _quality = selection.first),
                      ),
                      if (_quality == JpegQuality.custom) ...[
                        const SizedBox(height: 8),
                        Column(
                          key: const Key('custom_quality_controls'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'JPEG quality: $_customQuality',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Slider(
                              key: const Key('custom_quality_slider'),
                              min: 30,
                              max: 100,
                              divisions: 70,
                              value: _customQuality.clamp(30, 100).toDouble(),
                              label: '$_customQuality',
                              onChanged: (v) => setState(
                                () => _customQuality = v.round(),
                              ),
                            ),
                            TextFormField(
                              key: const Key('custom_max_edge_field'),
                              controller: _customMaxEdge,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Max long edge, px (optional)',
                                hintText:
                                    'Blank = keep the original size',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'SMB connection',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              TextFormField(
                key: const Key('host_field'),
                controller: _host,
                decoration: const InputDecoration(labelText: 'Host'),
                validator: _required,
                onChanged: (_) => _clearTestResultIfAny(),
              ),
              TextFormField(
                key: const Key('share_path_field'),
                controller: _sharePath,
                decoration: const InputDecoration(
                  labelText: 'Share path (/share/sub-folder)',
                ),
                validator: _sharePathValidator,
                onChanged: (_) => _clearTestResultIfAny(),
              ),
              TextFormField(
                key: const Key('domain_field'),
                controller: _domain,
                decoration: const InputDecoration(
                  labelText: 'Domain (optional)',
                ),
                onChanged: (_) => _clearTestResultIfAny(),
              ),
              TextFormField(
                key: const Key('username_field'),
                controller: _username,
                // Setup gate opens on the username (spec Req 3); the gear
                // entry never steals focus.
                autofocus: widget.firstRun,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: _required,
                onChanged: (_) => _clearTestResultIfAny(),
              ),
              TextFormField(
                key: const Key('password_field'),
                controller: _password,
                decoration: InputDecoration(
                  labelText: 'Password (optional)',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscured ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  ),
                ),
                obscureText: _obscured,
                onChanged: (_) => _clearTestResultIfAny(),
              ),
              const SizedBox(height: 16),
              if (_testError != null)
                Text(
                  _testError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_testCount != null)
                Text('Connected — $_testCount files in $_testPath'),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _testing ? null : _testConnection,
                    child: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _testing ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
