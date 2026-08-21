import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_keys.dart';
import '../bootstrap/app_resources.dart';
import '../mcp/endpoint.dart';
import '../models.dart';
import '../redact.dart';
import '../secrets.dart';
import '../store.dart';
import 'theme.dart';

/// The settings pane: scan roots, the optional GitHub PAT, and the MCP
/// API-key manager.
///
/// [pickDirectory] is injected so a widget test can supply a path with no
/// native dialog; when it is null but [onScan] is not — the server-backed
/// web build, where the paths are the server's — the add-root control is a
/// typed path field instead of a picker. [mcpPort] and [mcpError] are also
/// injected: this widget never starts or owns the transport, it only
/// reports what the bootstrap already decided at launch.
///
/// [isWeb] selects the server-mode copy and sections: a note about where
/// the data lives, the account section (driven by [auth]), and the MCP
/// endpoint shown as a path on this origin rather than a loopback port.
class SettingsPane extends StatefulWidget {
  const SettingsPane({
    super.key,
    required this.store,
    required this.secrets,
    required this.pickDirectory,
    required this.onScan,
    required this.mcpKeys,
    required this.mutations,
    required this.mcpPort,
    this.auth,
    this.mcpError,
    this.isWeb = false,
  });

  final Store store;
  final Secrets secrets;
  final Future<String?> Function()? pickDirectory;
  final Future<ScanResult> Function()? onScan;

  /// List/create/revoke for the MCP API keys the transport authenticates
  /// against — injected so web can back them with REST.
  final McpKeyOps mcpKeys;

  /// Scan-root mutations — injected for the same reason.
  final StoreMutations mutations;

  final int? mcpPort;

  /// Present on web: drives the account section.
  final AuthController? auth;

  /// Non-null when the MCP server could not start.
  final Object? mcpError;

  final bool isWeb;

  @override
  State<SettingsPane> createState() => _SettingsPaneState();
}

class _SettingsPaneState extends State<SettingsPane> {
  final _patController = TextEditingController();
  final _keyNameController = TextEditingController();
  final _rootPathController = TextEditingController();
  String? _scanSummary;
  var _scanning = false;
  var _hasStoredPat = false;
  String? _patStatus;
  var _patStatusIsError = false;

  List<ApiKeyInfo> _keys = const [];

  /// The key minted by the most recent "Create key" tap. Held only until the
  /// next mint (or pane rebuild from scratch): the hash in the store is all
  /// that survives, so this is genuinely the one chance to copy it.
  MintedKey? _justMinted;
  String? _keyError;

  @override
  void initState() {
    super.initState();
    _loadPatPresence();
    _loadKeys();
  }

  @override
  void dispose() {
    _patController.dispose();
    _keyNameController.dispose();
    _rootPathController.dispose();
    super.dispose();
  }

  Future<void> _loadPatPresence() async {
    try {
      final token = await widget.secrets.githubToken();
      if (mounted) setState(() => _hasStoredPat = token != null);
    } on KeyringUnavailable {
      // Nothing to report here: the MCP error banner already explains it.
    }
  }

  Future<void> _loadKeys() async {
    try {
      final keys = await widget.mcpKeys.list();
      if (mounted) setState(() => _keys = keys);
    } catch (e) {
      if (mounted) setState(() => _keyError = redact(e.toString()));
    }
  }

  Future<void> _addRoot() async {
    final path = await widget.pickDirectory!();
    if (path == null || path.isEmpty) return;
    widget.mutations.addScanRoot(path);
    if (mounted) setState(() {});
  }

  void _addTypedRoot() {
    final path = _rootPathController.text.trim();
    if (path.isEmpty) return;
    widget.mutations.addScanRoot(path);
    _rootPathController.clear();
    setState(() {});
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final r = await widget.onScan!();
      if (!mounted) return;
      setState(
        () => _scanSummary =
            '${r.projectsScanned} projects, ${r.depsFound} dependencies'
            '${r.errors.isEmpty ? '' : ', ${r.errors.length} problems'}',
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Surfaces both a too-short-to-redact token ([ArgumentError], see
  /// [Secrets.setGithubToken]) and a missing keyring ([KeyringUnavailable])
  /// as inline status text rather than letting either propagate and crash
  /// the pane or silently swallowing it.
  Future<void> _savePat() async {
    final value = _patController.text;
    try {
      await widget.secrets.setGithubToken(value);
      _patController.clear();
      await _loadPatPresence();
      if (!mounted) return;
      setState(() {
        _patStatus = widget.isWeb
            ? 'Token saved to the server, encrypted at rest.'
            : 'Token saved to the host keyring.';
        _patStatusIsError = false;
      });
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() {
        _patStatus = e.message.toString();
        _patStatusIsError = true;
      });
    } on KeyringUnavailable catch (e) {
      if (!mounted) return;
      setState(() {
        _patStatus = redact(e.toString());
        _patStatusIsError = true;
      });
    }
  }

  Future<void> _createKey() async {
    final name = _keyNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _keyError = 'Name the key first — e.g. "claude-code".');
      return;
    }
    try {
      final minted = await widget.mcpKeys.create(name);
      _keyNameController.clear();
      if (!mounted) return;
      setState(() {
        _justMinted = minted;
        _keyError = null;
      });
    } catch (e) {
      // The one expected failure is a duplicate name (UNIQUE on api_key).
      if (mounted) setState(() => _keyError = redact(e.toString()));
    }
    await _loadKeys();
  }

  Future<void> _revokeKey(int id) async {
    await widget.mcpKeys.revoke(id);
    if (!mounted) return;
    setState(() {
      // A revoked key's show-once box must not linger: the key it shows no
      // longer authenticates anything.
      if (_justMinted?.id == id) _justMinted = null;
    });
    await _loadKeys();
  }

  /// The API-key manager rows: existing keys, the show-once box for a key
  /// minted this session, and the name-plus-create row.
  List<Widget> _keyManager(DriftTokens t, TextStyle body) {
    String stamp(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return [
      if (_keys.isEmpty)
        Text(
          'No keys yet — agents cannot connect until one exists.',
          style: body,
        )
      else
        for (final k in _keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${k.name} — created ${stamp(k.createdAt)}, last used '
                    '${k.lastUsedAt == null ? 'never' : stamp(k.lastUsedAt!)}',
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: t.ink, size: 12.5),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 17),
                  tooltip: 'Revoke',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _revokeKey(k.id),
                ),
              ],
            ),
          ),
      if (_justMinted != null) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                _justMinted!.key,
                style: monoStyle(color: t.ink, size: 12.5),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 17),
              tooltip: 'Copy',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _justMinted!.key)),
            ),
          ],
        ),
        Text('Copy it now — it cannot be shown again.', style: body),
      ],
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('mcp-key-name'),
              controller: _keyNameController,
              style: monoStyle(color: t.ink, size: 13),
              decoration: const InputDecoration(
                labelText: 'New key name',
                hintText: 'e.g. claude-code',
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _createKey,
            child: const Text('Create key'),
          ),
        ],
      ),
      if (_keyError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _keyError!,
            style: TextStyle(fontSize: 12.5, height: 1.4, color: t.behind),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final roots = widget.store.scanRoots();
    final body = TextStyle(fontSize: 13, color: t.slate, height: 1.5);
    final auth = widget.auth;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (widget.isWeb)
          _SettingsSection(
            label: 'Server mode',
            first: true,
            children: [
              Text(
                'This browser is a client of the deptracker server, which '
                'owns the watch database, does all the fetching, and scans '
                'its own filesystem. Scan roots below are server paths.',
                style: body,
              ),
            ],
          ),
        if (widget.onScan != null)
          _SettingsSection(
            label: 'Scanned folders',
            first: !widget.isWeb,
            children: [
              Text(
                'Each folder is walked three levels deep, skipping '
                'node_modules, target, build, and similar.',
                style: body,
              ),
              const SizedBox(height: 9),
              if (roots.isEmpty)
                Text('No folders yet.', style: body)
              else
                for (final path in roots)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            path,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(color: t.ink, size: 12.5),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 17),
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            widget.mutations.removeScanRoot(path);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 9),
              if (widget.pickDirectory != null)
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _addRoot,
                      child: const Text('Add folder'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _scanning ? null : _scan,
                      child: const Text('Scan now'),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('scan-root-path'),
                        controller: _rootPathController,
                        style: monoStyle(color: t.ink, size: 13),
                        decoration: const InputDecoration(
                          labelText: 'Server path',
                          hintText: '/srv/code',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _addTypedRoot,
                      child: const Text('Add'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _scanning ? null : _scan,
                      child: const Text('Scan now'),
                    ),
                  ],
                ),
              if (_scanSummary != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _scanSummary!,
                    style: monoStyle(color: t.slate, size: 12),
                  ),
                ),
            ],
          ),

        _SettingsSection(
          label: 'GitHub token',
          children: [
            Text(
              widget.isWeb
                  ? 'Optional. A token gets richer Markdown notes and '
                        'faster lookups. Stored on the server, encrypted '
                        'at rest beside its key file — never in this '
                        'browser.'
                  : 'Optional. Without one, release notes still come from '
                        'public Atom feeds. A token gets richer Markdown '
                        'notes and faster lookups. Stored in the host '
                        'keyring, never on disk.',
              style: body,
            ),
            const SizedBox(height: 9),
            if (_hasStoredPat)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'A token is set. Save a new one to replace it.',
                  style: TextStyle(fontSize: 12.5, color: t.current),
                ),
              ),
            TextField(
              key: const Key('pat-field'),
              controller: _patController,
              // Never pre-populated with the stored value: a stored secret
              // should not be readable by anyone who opens this dialog.
              obscureText: true,
              style: monoStyle(color: t.ink, size: 13),
              decoration: const InputDecoration(
                labelText: 'Personal access token',
                hintText: 'Paste your token here',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _savePat,
                child: const Text('Save token'),
              ),
            ),
            if (_patStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _patStatus!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: _patStatusIsError ? t.behind : t.current,
                  ),
                ),
              ),
          ],
        ),

        _SettingsSection(
          label: 'MCP server',
          children: [
            if (widget.mcpError != null)
              Text(
                'The MCP server is not running: '
                '${redact(widget.mcpError.toString())}',
                style: TextStyle(fontSize: 12.5, color: t.behind, height: 1.4),
              )
            else if (widget.isWeb) ...[
              Text(
                'Agents connect to $mcpPath on this server.',
                style: monoStyle(color: t.ink, size: 12.5),
              ),
              const SizedBox(height: 9),
              Text(
                'Agents authenticate with an API key. Each key is shown '
                'once, when it is created — only a hash is kept.',
                style: body,
              ),
              const SizedBox(height: 8),
              ..._keyManager(t, body),
            ] else if (widget.mcpPort != null) ...[
              Text(
                'http://127.0.0.1:${widget.mcpPort}$mcpPath',
                style: monoStyle(color: t.ink, size: 12.5),
              ),
              const SizedBox(height: 4),
              Text('Loopback only.', style: body),
              const SizedBox(height: 9),
              Text(
                'Agents authenticate with an API key. Each key is shown '
                'once, when it is created — only a hash is kept.',
                style: body,
              ),
              const SizedBox(height: 8),
              ..._keyManager(t, body),
            ] else
              Text('Starting…', style: body),
          ],
        ),

        if (auth != null)
          _SettingsSection(
            label: 'Account',
            children: [
              Text(
                'Signed in as ${auth.username ?? 'unknown'}'
                '${auth.role == 'admin' ? ' (admin)' : ''}.',
                style: body,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: auth.logout,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
              if (auth.role == 'admin') ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        auth.registrationOpen
                            ? 'Registration is open: anyone who can reach '
                                  'this server can create an account.'
                            : 'Registration is closed.',
                        style: body,
                      ),
                    ),
                    Switch(
                      value: auth.registrationOpen,
                      onChanged: (open) async {
                        await auth.setRegistrationOpen(open);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
      ],
    );
  }
}

/// Same eyebrow-over-hairline structure the detail pane uses, so the dialog
/// reads as part of the same window rather than as a stock settings sheet.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.label,
    required this.children,
    this.first = false,
  });

  final String label;
  final List<Widget> children;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(top: BorderSide(color: t.rule)),
            ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: eyebrowStyle(color: t.slate)),
          const SizedBox(height: 9),
          ...children,
        ],
      ),
    );
  }
}
