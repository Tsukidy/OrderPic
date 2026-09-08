import 'package:flutter/material.dart';

import '../smb/smb.dart';
import 'app_settings.dart';
import 'settings_store.dart';

/// Settings / first-run setup for the SMB share connection. One widget,
/// two entry modes: gear-invoked (back discards edits) and first-run
/// (back disabled until a valid save — see PopScope).
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

  @override
  void initState() {
    super.initState();
    final s = widget.settingsNotifier.value.connection;
    _host = TextEditingController(text: s.host);
    _sharePath = TextEditingController(text: s.sharePath);
    _domain = TextEditingController(text: s.domain);
    _username = TextEditingController(text: s.username);
    _password = TextEditingController(text: s.password);
  }

  @override
  void dispose() {
    _host.dispose();
    _sharePath.dispose();
    _domain.dispose();
    _username.dispose();
    _password.dispose();
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
    try {
      await s.save(store: widget.store);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save settings')),
        );
      }
      return; // stay on the page
    }
    // copyWith reuses the upload half by instance, so a connection save
    // never looks like an upload change (HomePage's remount key reads
    // connection identity only). A ==-equal connection + unchanged
    // upload makes the whole AppSettings ==-equal, and ValueNotifier
    // then suppresses the notification entirely (no History rebuild).
    widget.settingsNotifier.value = widget.settingsNotifier.value.copyWith(
      connection: s,
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
          title: Text(widget.firstRun ? 'Set up SMB login' : 'SMB settings'),
          // Setup mode: back is blocked anyway — don't show a dead arrow.
          automaticallyImplyLeading: !widget.firstRun,
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
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
