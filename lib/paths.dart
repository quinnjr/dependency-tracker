import 'dart:io';

import 'package:path/path.dart' as p;

const appDirName = 'deptracker';

/// The three desktop platforms disagree about where an app's files belong, and
/// getting it wrong means the database silently lands somewhere the user does
/// not back up. Every path in the app is derived here.
///
/// `env` and `platform` are injectable so the tests can exercise all three
/// platforms from one machine. Production callers omit both.
String _platform(String? override) => override ?? Platform.operatingSystem;

Map<String, String> _env(Map<String, String>? override) =>
    override ?? Platform.environment;

/// The path context matching the target platform's separator conventions,
/// not the conventions of the machine actually running the code — the tests
/// exercise all three platforms' conventions from a single host.
p.Context _ctx(String os) => os == 'windows' ? p.windows : p.posix;

/// The XDG spec says a relative or empty value must be treated as unset.
String? _absoluteOrNull(String? v, p.Context ctx) =>
    (v == null || v.isEmpty || !ctx.isAbsolute(v)) ? null : v;

String _home(Map<String, String> env, String os) {
  String? v;
  if (os == 'windows') {
    final userProfile = env['USERPROFILE'];
    final homeDrive = env['HOMEDRIVE'];
    final homePath = env['HOMEPATH'];
    if (userProfile != null && userProfile.isNotEmpty) {
      v = userProfile;
    } else if (homeDrive != null &&
        homeDrive.isNotEmpty &&
        homePath != null &&
        homePath.isNotEmpty) {
      v = '$homeDrive$homePath';
    }
  } else {
    v = env['HOME'];
  }
  if (v == null || v.isEmpty) {
    throw StateError('Cannot locate the user home directory for $os');
  }
  return v;
}

String configDir({Map<String, String>? env, String? platform}) {
  final e = _env(env);
  final os = _platform(platform);
  final ctx = _ctx(os);
  return switch (os) {
    'windows' => ctx.join(
      _absoluteOrNull(e['APPDATA'], ctx) ??
          ctx.join(_home(e, os), 'AppData', 'Roaming'),
      appDirName,
    ),
    'macos' => ctx.join(
      _home(e, os),
      'Library',
      'Application Support',
      appDirName,
    ),
    _ => ctx.join(
      _absoluteOrNull(e['XDG_CONFIG_HOME'], ctx) ??
          ctx.join(_home(e, os), '.config'),
      appDirName,
    ),
  };
}

String dataDir({Map<String, String>? env, String? platform}) {
  final e = _env(env);
  final os = _platform(platform);
  final ctx = _ctx(os);
  return switch (os) {
    'windows' => ctx.join(
      _absoluteOrNull(e['LOCALAPPDATA'], ctx) ??
          ctx.join(_home(e, os), 'AppData', 'Local'),
      appDirName,
    ),
    'macos' => ctx.join(
      _home(e, os),
      'Library',
      'Application Support',
      appDirName,
    ),
    _ => ctx.join(
      _absoluteOrNull(e['XDG_DATA_HOME'], ctx) ??
          ctx.join(_home(e, os), '.local', 'share'),
      appDirName,
    ),
  };
}

String cacheDir({Map<String, String>? env, String? platform}) {
  final e = _env(env);
  final os = _platform(platform);
  final ctx = _ctx(os);
  return switch (os) {
    'windows' => ctx.join(dataDir(env: env, platform: platform), 'cache'),
    'macos' => ctx.join(_home(e, os), 'Library', 'Caches', appDirName),
    _ => ctx.join(
      _absoluteOrNull(e['XDG_CACHE_HOME'], ctx) ??
          ctx.join(_home(e, os), '.cache'),
      appDirName,
    ),
  };
}

String databasePath({Map<String, String>? env, String? platform}) => _ctx(
  _platform(platform),
).join(dataDir(env: env, platform: platform), 'deptracker.db');

String mcpDiscoveryPath({Map<String, String>? env, String? platform}) => _ctx(
  _platform(platform),
).join(configDir(env: env, platform: platform), 'mcp.json');

Directory ensureDir(String path) {
  final d = Directory(path);
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}
