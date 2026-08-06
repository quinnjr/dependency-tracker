import 'dart:io';

import 'package:path/path.dart' as p;

import 'manifests.dart';
import 'models.dart';
import 'store.dart';

/// Directories that never contain a project worth scanning but do contain
/// thousands of files, including manifests belonging to other packages.
const Set<String> skipDirectories = {
  'node_modules',
  '.git',
  'target',
  'build',
  '.dart_tool',
  '.venv',
  'venv',
  'vendor',
  '.worktrees',
  'Pods',
};

/// Lockfiles take precedence over the manifest they resolve, because a
/// resolved version can be compared against a release and a range cannot.
const Map<String, String> _supersedes = {
  'pubspec.lock': 'pubspec.yaml',
  'Cargo.lock': 'Cargo.toml',
  'package-lock.json': 'package.json',
  'pnpm-lock.yaml': 'package.json',
};

class ScanResult {
  const ScanResult({
    required this.projectsScanned,
    required this.depsFound,
    required this.errors,
  });

  final int projectsScanned;
  final int depsFound;
  final List<String> errors;
}

/// Walks every scan root configured in [store] and reconciles the store with
/// what it finds. See [scanDirectory] for the per-root behavior.
Future<ScanResult> scanRoots(Store store, {int maxDepth = 3}) async {
  var projects = 0;
  var deps = 0;
  final errors = <String>[];
  for (final root in store.scanRoots()) {
    final r = await scanDirectory(store, root, maxDepth: maxDepth);
    projects += r.projectsScanned;
    deps += r.depsFound;
    errors.addAll(r.errors);
  }
  return ScanResult(projectsScanned: projects, depsFound: deps, errors: errors);
}

/// Walks [root] up to [maxDepth] directories deep, looking for manifest
/// files, and reconciles each one found into [store].
///
/// Reconciliation happens per manifest file, never per directory: a bad
/// `package.json` next to a good `pubspec.yaml` must not stop the pubspec's
/// usages from being recorded, and must not delete the pubspec's existing
/// usages either. When both a lockfile and the manifest it resolves are
/// present in the same directory, only the lockfile is parsed.
Future<ScanResult> scanDirectory(
  Store store,
  String root, {
  int maxDepth = 3,
}) async {
  final dir = Directory(root);
  if (!dir.existsSync()) {
    return ScanResult(
      projectsScanned: 0,
      depsFound: 0,
      errors: ['scan root does not exist: $root'],
    );
  }

  final errors = <String>[];
  // dir.path -> manifest basenames present in that directory.
  final manifestsByDir = <String, List<String>>{};

  void walk(Directory d, int depth) {
    if (depth > maxDepth) return;
    final List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } on FileSystemException catch (e) {
      errors.add('cannot read ${d.path}: ${e.osError?.message ?? e.message}');
      return;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        // Dot-directories are tooling caches (.pub-cache, .gradle, .cargo,
        // ...) that either aren't scan targets or, like .cargo's registry
        // cache of every downloaded crate's Cargo.toml, are exactly the
        // phantom-watch hazard node_modules is skipped for. No supported
        // manifest format is expected to live inside one. This only affects
        // directories discovered during the walk, not the root itself.
        if (skipDirectories.contains(name) || name.startsWith('.')) continue;
        walk(entry, depth + 1);
      } else if (entry is File && manifestFilenames.contains(name)) {
        manifestsByDir.putIfAbsent(d.path, () => []).add(name);
      }
    }
  }

  walk(dir, 1);

  var deps = 0;
  for (final entry in manifestsByDir.entries) {
    final projectPath = entry.key;
    final present = entry.value;
    final superseded = present
        .map((f) => _supersedes[f])
        .whereType<String>()
        .toSet();

    for (final filename in present.where((f) => !superseded.contains(f))) {
      final path = p.join(projectPath, filename);
      final List<ParsedDep> parsed;
      try {
        parsed = parseManifest(filename, File(path).readAsStringSync());
      } catch (e) {
        errors.add('failed to parse $path: $e');
        continue;
      }

      final usages = <Usage>[];
      for (final d in parsed) {
        // notify: false — replaceUsagesForProject below notifies once for
        // the whole manifest; without this a 2,000-dependency monorepo scan
        // fires 2,000 notifications instead of one per manifest.
        final watchId = store.upsertWatch(d.kind, d.name, notify: false);
        usages.add(
          Usage(
            watchId: watchId,
            projectPath: projectPath,
            manifestFile: filename,
            pinnedVersion: d.version,
            isResolved: d.isResolved,
            isDevDep: d.isDevDep,
          ),
        );
      }
      store.replaceUsagesForProject(projectPath, filename, usages);
      deps += usages.length;
    }
  }

  return ScanResult(
    projectsScanned: manifestsByDir.length,
    depsFound: deps,
    errors: errors,
  );
}
