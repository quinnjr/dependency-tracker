import 'dart:io';

import 'package:deptracker/paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  homeFallbackTests();
  test('linux honours XDG variables when set', () {
    final env = {
      'HOME': '/home/j',
      'XDG_CONFIG_HOME': '/home/j/cfg',
      'XDG_DATA_HOME': '/home/j/dat',
      'XDG_CACHE_HOME': '/home/j/cch',
    };
    expect(configDir(env: env, platform: 'linux'), '/home/j/cfg/deptracker');
    expect(dataDir(env: env, platform: 'linux'), '/home/j/dat/deptracker');
    expect(cacheDir(env: env, platform: 'linux'), '/home/j/cch/deptracker');
  });

  test('linux falls back to the XDG spec defaults', () {
    final env = {'HOME': '/home/j'};
    expect(
      configDir(env: env, platform: 'linux'),
      '/home/j/.config/deptracker',
    );
    expect(
      dataDir(env: env, platform: 'linux'),
      '/home/j/.local/share/deptracker',
    );
    expect(cacheDir(env: env, platform: 'linux'), '/home/j/.cache/deptracker');
  });

  test('an empty or relative XDG value is ignored per the spec', () {
    final env = {
      'HOME': '/home/j',
      'XDG_CONFIG_HOME': '',
      'XDG_DATA_HOME': 'rel',
    };
    expect(
      configDir(env: env, platform: 'linux'),
      '/home/j/.config/deptracker',
    );
    expect(
      dataDir(env: env, platform: 'linux'),
      '/home/j/.local/share/deptracker',
    );
  });

  test(
    'windows uses APPDATA for config and LOCALAPPDATA for data and cache',
    () {
      final env = {
        'APPDATA': r'C:\Users\j\AppData\Roaming',
        'LOCALAPPDATA': r'C:\Users\j\AppData\Local',
      };
      expect(
        configDir(env: env, platform: 'windows'),
        r'C:\Users\j\AppData\Roaming\deptracker',
      );
      expect(
        dataDir(env: env, platform: 'windows'),
        r'C:\Users\j\AppData\Local\deptracker',
      );
      expect(
        cacheDir(env: env, platform: 'windows'),
        r'C:\Users\j\AppData\Local\deptracker\cache',
      );
    },
  );

  test('windows falls back to USERPROFILE when APPDATA is absent', () {
    final env = {'USERPROFILE': r'C:\Users\j'};
    expect(
      configDir(env: env, platform: 'windows'),
      r'C:\Users\j\AppData\Roaming\deptracker',
    );
  });

  test('macos uses Application Support and Caches', () {
    final env = {'HOME': '/Users/j'};
    expect(
      configDir(env: env, platform: 'macos'),
      '/Users/j/Library/Application Support/deptracker',
    );
    expect(
      dataDir(env: env, platform: 'macos'),
      '/Users/j/Library/Application Support/deptracker',
    );
    expect(
      cacheDir(env: env, platform: 'macos'),
      '/Users/j/Library/Caches/deptracker',
    );
  });

  test('macos ignores XDG variables even when they are set', () {
    final env = {'HOME': '/Users/j', 'XDG_CONFIG_HOME': '/Users/j/cfg'};
    expect(
      configDir(env: env, platform: 'macos'),
      '/Users/j/Library/Application Support/deptracker',
    );
  });

  test('derived file paths live under the right directory', () {
    final env = {'HOME': '/home/j'};
    expect(
      mcpDiscoveryPath(env: env, platform: 'linux'),
      '/home/j/.config/deptracker/mcp.json',
    );
    expect(
      databasePath(env: env, platform: 'linux'),
      '/home/j/.local/share/deptracker/deptracker.db',
    );
  });

  test(
    'omitting env and platform resolves to the host OS and real environment',
    () {
      // Production is the only caller that omits both. Nothing else in the suite
      // covers it, so a regression in the defaulting would be invisible until a
      // user on another platform lost their database.
      final os = Platform.operatingSystem;
      final env = Platform.environment;

      expect(configDir(), configDir(env: env, platform: os));
      expect(dataDir(), dataDir(env: env, platform: os));
      expect(cacheDir(), cacheDir(env: env, platform: os));
      expect(databasePath(), databasePath(env: env, platform: os));
      expect(mcpDiscoveryPath(), mcpDiscoveryPath(env: env, platform: os));
    },
  );

  test('the default paths are absolute, app-scoped, and correctly nested', () {
    final ctx = Platform.isWindows ? p.windows : p.posix;

    expect(ctx.isAbsolute(configDir()), isTrue);
    expect(ctx.isAbsolute(dataDir()), isTrue);
    expect(ctx.isAbsolute(cacheDir()), isTrue);

    expect(ctx.basename(configDir()), appDirName);
    expect(ctx.basename(dataDir()), appDirName);

    // The two derived files must sit inside the directories they are built from.
    expect(ctx.basename(databasePath()), 'deptracker.db');
    expect(ctx.dirname(databasePath()), dataDir());
    expect(ctx.basename(mcpDiscoveryPath()), 'mcp.json');
    expect(ctx.dirname(mcpDiscoveryPath()), configDir());
  });

  group('ensureDir', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('paths_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('creates a nested directory that does not yet exist', () {
      final target = p.join(tmp.path, 'a', 'b', 'c');
      expect(Directory(target).existsSync(), isFalse);
      final result = ensureDir(target);
      expect(result.existsSync(), isTrue);
      expect(result.path, target);
    });

    test('is a no-op when the directory already exists', () {
      final target = p.join(tmp.path, 'already-there');
      Directory(target).createSync();
      final result = ensureDir(target);
      expect(result.existsSync(), isTrue);
    });
  });
}

// Windows fallbacks and the no-home failure, none of which the happy-path
// tests reach. Getting these wrong means the database silently lands
// somewhere the user does not back up.
void homeFallbackTests() {
  test(
    'windows falls back to HOMEDRIVE + HOMEPATH when USERPROFILE is absent',
    () {
      final dir = dataDir(
        platform: 'windows',
        env: {'HOMEDRIVE': r'C:', 'HOMEPATH': r'\Users\joseph'},
      );
      expect(dir, r'C:\Users\joseph\AppData\Local\deptracker');
    },
  );

  test('windows prefers USERPROFILE over the HOMEDRIVE pair', () {
    final dir = dataDir(
      platform: 'windows',
      env: {
        'USERPROFILE': r'D:\profiles\joseph',
        'HOMEDRIVE': r'C:',
        'HOMEPATH': r'\Users\wrong',
      },
    );
    expect(dir, startsWith(r'D:\profiles\joseph'));
  });

  test(
    'windows falls back to the home dir when LOCALAPPDATA is not absolute',
    () {
      // The XDG rule the posix branch follows — a relative value is treated as
      // unset — applies here too, or the database lands somewhere relative to
      // the working directory.
      final dir = dataDir(
        platform: 'windows',
        env: {
          'USERPROFILE': r'C:\Users\joseph',
          'LOCALAPPDATA': r'relative\path',
        },
      );
      expect(dir, r'C:\Users\joseph\AppData\Local\deptracker');
    },
  );

  test('a half-set HOMEDRIVE pair is not accepted as a home directory', () {
    // HOMEDRIVE without HOMEPATH would otherwise build "C:deptracker".
    expect(
      () => dataDir(platform: 'windows', env: {'HOMEDRIVE': r'C:'}),
      throwsA(isA<StateError>()),
    );
  });

  test('no home directory at all is a StateError naming the platform', () {
    expect(
      () => dataDir(platform: 'linux', env: const {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('linux'),
        ),
      ),
    );
  });
}
