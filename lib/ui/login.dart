import 'package:flutter/material.dart';

import '../bootstrap/app_resources.dart';
import 'theme.dart';

/// The gate in front of the shell on the web build: sign in, or — while the
/// server reports zero accounts — create the first (admin) account. Which
/// form it shows is the server's state, not a user choice: first-run gets
/// registration, an existing install gets login, and a register toggle
/// appears only while registration is open.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  var _registering = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _registerMode => widget.auth.zeroUsers || _registering;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _username.text.trim();
    final call = _registerMode ? widget.auth.register : widget.auth.login;
    final error = await call(name, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    // The gate above rebuilds via auth.changes on success; nothing to do.
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final body = TextStyle(fontSize: 13, color: t.slate, height: 1.5);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'deptracker',
                style: monoStyle(
                  color: t.ink,
                  size: 16,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.auth.zeroUsers
                    ? 'No accounts yet. Create the first one — it becomes '
                          'the admin account.'
                    : _registerMode
                    ? 'Create an account.'
                    : 'Sign in to your team\'s watchlist.',
                style: body,
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('login-username'),
                controller: _username,
                autofocus: true,
                style: monoStyle(color: t.ink, size: 13),
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('login-password'),
                controller: _password,
                obscureText: true,
                onSubmitted: (_) => _busy ? null : _submit(),
                style: monoStyle(color: t.ink, size: 13),
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: 12),
              // Wrap, not Row: "Create account" plus the mode toggle can
              // outgrow the 360px column, and a wrapped second line beats an
              // overflow stripe.
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(_registerMode ? 'Create account' : 'Sign in'),
                  ),
                  if (!widget.auth.zeroUsers && widget.auth.registrationOpen)
                    TextButton(
                      onPressed: () =>
                          setState(() => _registering = !_registering),
                      child: Text(
                        _registering ? 'Sign in instead' : 'Register instead',
                      ),
                    ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: t.behind,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
