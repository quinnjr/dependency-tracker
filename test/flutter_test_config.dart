import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// Runs once before every test file, for all of them.
///
/// Its only job is to make `package:sqlite3` loadable on Windows. The package
/// finds a SQLite shared library on its own everywhere else: Linux and macOS
/// runners ship one system-wide, and inside the built app `sqlite3_flutter_libs`
/// supplies it. Neither applies to the Dart VM running `flutter test` on
/// Windows, where the load simply fails and every store-backed test with it.
///
/// So on Windows the loader is pointed at the DLL vendored under `third_party/`.
/// See `third_party/sqlite3/windows-x64/README.md` for its provenance.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, _openVendoredSqlite3);
  }
  await testMain();
}

DynamicLibrary _openVendoredSqlite3() {
  // `flutter test` runs with the package root as the working directory.
  final vendored = p.join(
    Directory.current.path,
    'third_party',
    'sqlite3',
    'windows-x64',
    'sqlite3.dll',
  );

  // Deliberately no fallback to a bare `sqlite3.dll`. Resolving through the
  // Windows DLL search path would load whatever build happens to be on the
  // machine, so a missing or pruned vendored file would produce a green run
  // that never exercised the engine the app actually ships — the exact thing
  // vendoring exists to guarantee. Fail loudly and name the fix instead.
  if (!File(vendored).existsSync()) {
    throw StateError(
      'Vendored sqlite3.dll not found at $vendored. '
      'See third_party/sqlite3/windows-x64/README.md.',
    );
  }
  return DynamicLibrary.open(vendored);
}
