// The deptracker server: the desktop engine, headless, behind the AppServer
// gateway. Assembles real resources (a database file, the key file beside
// it, a listening socket), so like lib/main.dart it is excluded from
// coverage — every collaborator it wires is covered by the lib/server tests.
//
// coverage:ignore-file
import 'dart:io';

import 'package:deptracker/api_keys.dart';
import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/mcp/transport.dart';
import 'package:deptracker/net.dart';
import 'package:deptracker/paths.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/scanner.dart';
import 'package:deptracker/secrets.dart';
import 'package:deptracker/server/auth.dart';
import 'package:deptracker/server/http.dart';
import 'package:deptracker/server/keys.dart';
import 'package:deptracker/server/sqlite_secrets.dart';
import 'package:deptracker/store.dart';
import 'package:path/path.dart' as p;

const _usage = '''
deptracker server — serves the web UI, the REST API, and MCP.

  dart run bin/server.dart [options]

Options:
  --db <path>              SQLite file (default: data/deptracker.db).
                           The 64-byte key file lives beside it.
  --web-root <path>        Built frontend to serve (default: build/web)
  --port <int>             Port to bind (default: 8080)
  --bind <ip>              Address to bind (default: 0.0.0.0)
  --add-user <name>        Create an account (password read from stdin), exit
  --reset-password <name>  Reset an account password (from stdin), exit
  --help                   This text
''';

Future<void> main(List<String> args) async {
  String db = p.join('data', 'deptracker.db');
  String webRoot = p.join('build', 'web');
  int port = 8080;
  String bindText = '0.0.0.0';
  String? addUser;
  String? resetPassword;

  for (var i = 0; i < args.length; i++) {
    String value() {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for ${args[i]}');
        exit(64);
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--db':
        db = value();
      case '--web-root':
        webRoot = value();
      case '--port':
        port = int.tryParse(value()) ?? -1;
        if (port < 0) {
          stderr.writeln('--port needs an integer');
          exit(64);
        }
      case '--bind':
        bindText = value();
      case '--add-user':
        addUser = value();
      case '--reset-password':
        resetPassword = value();
      case '--help':
        stdout.write(_usage);
        return;
      default:
        stderr.writeln('unknown option ${args[i]}\n\n$_usage');
        exit(64);
    }
  }

  ensureDir(File(db).parent.path);
  final store = Store.open(db);
  final keys = await loadOrCreateServerKeys(
    p.join(File(db).parent.path, 'deptracker.key'),
  );
  final auth = Auth(store, keys.jwtKey);

  if (addUser != null || resetPassword != null) {
    final username = (addUser ?? resetPassword)!;
    final password = _promptPassword();
    if (addUser != null) {
      // The CLI outranks the network by construction: it has the disk, so it
      // creates accounts directly, without touching the registration flag —
      // flipping that global open for the hash would briefly open
      // registration to the network on a live server sharing this database.
      try {
        final role = await auth.createAccount(username, password);
        stdout.writeln('created $role account "$username"');
      } on UsernameTaken {
        stderr.writeln('an account named "$username" already exists');
        exit(1);
      }
    } else {
      final ok = await auth.resetPassword(username, password);
      if (!ok) {
        stderr.writeln('no account named "$username"');
        exit(1);
      }
      stdout.writeln('password reset for "$username"');
    }
    store.close();
    return;
  }

  final secrets = Secrets(SqliteSecretBackend(store, keys.aesKey));
  final net = Net(cache: store);

  // githubTokenOrNull, not githubToken: a corrupt or rotated key file makes
  // the decrypt throw, and an optional token must not turn every refresh
  // into a 500 telling a headless operator to start gnome-keyring.
  Future<RefreshReport> refresh(int? watchId) async => refreshAll(
    store,
    net,
    token: await secrets.githubTokenOrNull(),
    onlyWatchId: watchId,
  );

  // A hostname does not parse as an InternetAddress, and passing null would
  // silently bind every interface — the opposite of what someone typing
  // `--bind localhost` to lock down the server intends. Fail loudly instead.
  final bindAddress = InternetAddress.tryParse(bindText);
  if (bindAddress == null) {
    stderr.writeln(
      '--bind must be an IP address, not a hostname (got "$bindText"). '
      'Use 127.0.0.1 for loopback or 0.0.0.0 for all interfaces.',
    );
    store.close();
    exit(64);
  }

  final server = AppServer(
    store: store,
    auth: auth,
    secrets: secrets,
    refresh: refresh,
    scan: () => scanRoots(store),
    mcp: McpTransport(
      onSession: () => buildMcpServer(buildTools(store, refresh: refresh)),
      authenticate: (k) => authenticateApiKey(store, k),
    ),
    webRoot: webRoot,
    requestedPort: port,
    bindAddress: bindAddress,
  );

  final bound = await server.start();
  stdout.writeln('deptracker server on http://$bindText:$bound');
  stdout.writeln('  data: $db (+ deptracker.key)');
  stdout.writeln('  web root: $webRoot');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nshutting down');
    await server.stop();
    net.close();
    store.close();
    exit(0);
  });
}

String _promptPassword() {
  // echoMode throws when stdin is not a terminal (a pipe or a file), which
  // is exactly the documented `echo pw | ... --add-user` and CI path — so
  // only toggle echo when there is a terminal to toggle.
  if (!stdin.hasTerminal) {
    return stdin.readLineSync() ?? '';
  }
  stdout.write('password: ');
  final hadEcho = stdin.echoMode;
  stdin.echoMode = false;
  final password = stdin.readLineSync() ?? '';
  stdin.echoMode = hadEcho;
  stdout.writeln();
  return password;
}
