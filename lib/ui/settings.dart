import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/transport.dart';
import '../redact.dart';
import '../scanner.dart';
import '../secrets.dart';
import '../store.dart';
import 'theme.dart';

/// The settings pane: scan roots, the optional GitHub PAT, and the MCP
/// server's status.
///
/// [pickDirectory] is injected so a widget test can supply a path with no
/// native dialog. [mcpPort] and [mcpError] are also injected: this widget
/// never starts or owns the transport, it only reports what `main.dart`
/// already decided at launch.
class SettingsPane extends StatefulWidget {
  const SettingsPane({
    super.key,
    required this.store,
    required this.secrets,
    required this.pickDirectory,
    required this.onScan,
    required this.mcpPort,
    this.mcpError,
  });

  final Store store;
  final Secrets secrets;
  final Future<String?> Function() pickDirectory;
  final Future<ScanResult> Function() onScan;
  final int? mcpPort;

  /// Non-null when the MCP server could not start — most often no keyring.
  final Object? mcpError;

  @override
  State<SettingsPane> createState() => _SettingsPaneState();
}

class _SettingsPaneState extends State<SettingsPane> {
  final _patController = TextEditingController();
  String? _scanSummary;
  var _scanning = false;
  var _hasStoredPat = false;
  String? _revealedToken;
  String? _patStatus;
  var _patStatusIsError = false;

  @override
  void initState() {
    super.initState();
    _loadPatPresence();
  }

  @override
  void dispose() {
    _patController.dispose();
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

  Future<void> _addRoot() async {
    final path = await widget.pickDirectory();
    if (path == null || path.isEmpty) return;
    widget.store.addScanRoot(path);
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final r = await widget.onScan();
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
        _patStatus = 'Token saved to the host keyring.';
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

  Future<void> _revealToken() async {
    final token = await widget.secrets.mcpToken();
    if (mounted) setState(() => _revealedToken = token);
  }

  /// Rotation invalidates every existing MCP client's saved bearer token, so
  /// this only ever runs from an explicit tap, never automatically.
  Future<void> _rotateToken() async {
    await widget.secrets.rotateMcpToken();
    await _revealToken();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final roots = widget.store.scanRoots();
    final body = TextStyle(fontSize: 13, color: t.slate, height: 1.5);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _SettingsSection(
          label: 'Scanned folders',
          first: true,
          children: [
            Text(
              'Each folder is walked three levels deep, skipping node_modules, '
              'target, build, and similar.',
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
                          widget.store.removeScanRoot(path);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 9),
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
              'Optional. Without one, release notes still come from public '
              'Atom feeds. A token gets richer Markdown notes and faster '
              'lookups. Stored in the host keyring, never on disk.',
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
            else if (widget.mcpPort != null) ...[
              Text(
                'http://127.0.0.1:${widget.mcpPort}$mcpPath',
                style: monoStyle(color: t.ink, size: 12.5),
              ),
              const SizedBox(height: 4),
              Text('Loopback only.', style: body),
              const SizedBox(height: 9),
              Text(
                'Paste the bearer token into your MCP client config. It lives '
                'in the host keyring, so this is the only place to read it.',
                style: body,
              ),
              const SizedBox(height: 8),
              if (_revealedToken == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _revealToken,
                    child: const Text('Reveal token'),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _revealedToken!,
                        style: monoStyle(color: t.ink, size: 12.5),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 17),
                      tooltip: 'Copy',
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: _revealedToken!),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 17),
                      tooltip: 'Rotate token — invalidates the current one',
                      onPressed: _rotateToken,
                    ),
                  ],
                ),
            ] else
              Text('Starting…', style: body),
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
