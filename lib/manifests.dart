import 'dart:convert';

import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

import 'models.dart';
import 'versions.dart';

class ParsedDep {
  const ParsedDep({
    required this.kind,
    required this.name,
    required this.version,
    required this.isResolved,
    required this.isDevDep,
  });

  final WatchKind kind;
  final String name;

  /// Either a concrete version (when [isResolved]) or the range as written.
  final String version;

  /// True only when the version is a single concrete version rather than a
  /// range. The spec forbids fake-resolving ranges, so this flag decides
  /// whether the value may be compared against a release.
  final bool isResolved;

  final bool isDevDep;
}

/// Basenames the scanner looks for. Lockfiles are listed before the manifest
/// they resolve for readability, but the scanner does not rely on this list's
/// order to decide precedence — that is handled explicitly by the
/// `_supersedes` map in `scanner.dart`.
const List<String> manifestFilenames = [
  'pubspec.lock',
  'pubspec.yaml',
  'Cargo.lock',
  'Cargo.toml',
  'package-lock.json',
  'pnpm-lock.yaml',
  'package.json',
  'go.mod',
  'pyproject.toml',
  'requirements.txt',
];

List<ParsedDep> parseManifest(String filename, String content) {
  switch (filename) {
    case 'pubspec.lock':
      return _pubspecLock(content);
    case 'pubspec.yaml':
      return _pubspecYaml(content);
    case 'package.json':
      return _packageJson(content);
    case 'package-lock.json':
      return _packageLockJson(content);
    case 'pnpm-lock.yaml':
      return _pnpmLockYaml(content);
    case 'Cargo.toml':
      return _cargoToml(content);
    case 'Cargo.lock':
      return _cargoLock(content);
    case 'go.mod':
      return _goMod(content);
    case 'pyproject.toml':
      return _pyproject(content);
    case 'requirements.txt':
      return _requirements(content);
    default:
      throw ArgumentError.value(filename, 'filename', 'unsupported manifest');
  }
}

Map<String, dynamic> _yamlMap(String content) {
  final Object? doc;
  try {
    doc = loadYaml(content);
  } on YamlException catch (e) {
    throw FormatException('invalid YAML: $e');
  }
  if (doc is! Map) throw const FormatException('expected a YAML mapping');
  return Map<String, dynamic>.from(doc);
}

List<ParsedDep> _pubspecLock(String content) {
  final packages = _yamlMap(content)['packages'];
  if (packages is! Map) return const [];
  final out = <ParsedDep>[];
  packages.forEach((name, spec) {
    if (spec is! Map) return;
    // Only hosted packages have a registry to check; path and git deps do not.
    if (spec['source'] != 'hosted') return;
    final version = spec['version'];
    if (version is! String) return;
    out.add(
      ParsedDep(
        kind: WatchKind.pub,
        name: name as String,
        version: version,
        isResolved: true,
        isDevDep: (spec['dependency'] as String? ?? '').contains('dev'),
      ),
    );
  });
  return out;
}

List<ParsedDep> _pubspecYaml(String content) {
  final doc = _yamlMap(content);
  final out = <ParsedDep>[];
  for (final (key, isDev) in [
    ('dependencies', false),
    ('dev_dependencies', true),
  ]) {
    final section = doc[key];
    if (section is! Map) continue;
    section.forEach((name, spec) {
      // `sdk: flutter` and git/path deps have no pub.dev version to track.
      if (spec is! String) return;
      out.add(
        ParsedDep(
          kind: WatchKind.pub,
          name: name as String,
          version: spec,
          isResolved: _isPinnedVersion(spec),
          isDevDep: isDev,
        ),
      );
    });
  }
  return out;
}

List<ParsedDep> _packageJson(String content) {
  final Object? doc;
  try {
    doc = jsonDecode(content);
  } on FormatException {
    rethrow;
  }
  if (doc is! Map) throw const FormatException('expected a JSON object');
  final out = <ParsedDep>[];
  for (final (key, isDev) in [
    ('dependencies', false),
    ('devDependencies', true),
  ]) {
    final section = doc[key];
    if (section is! Map) continue;
    section.forEach((name, spec) {
      if (spec is! String) return;
      // Local and git protocols have no registry version.
      if (spec.startsWith('file:') ||
          spec.startsWith('git') ||
          spec.startsWith('link:') ||
          spec.startsWith('workspace:')) {
        return;
      }
      out.add(
        ParsedDep(
          kind: WatchKind.npm,
          name: name as String,
          version: spec,
          // node-semver's "version" range type means "must match version
          // exactly" — a bare `"2.0.1"` is a pin, not a caret range. The
          // implicit-caret behavior only applies to what `npm install <pkg>`
          // *writes* when the user doesn't specify an operator; it does not
          // change how an already-written bare string is interpreted.
          isResolved: _isPinnedVersion(spec),
          isDevDep: isDev,
        ),
      );
    });
  }
  return out;
}

/// npm v7+ writes a flat `packages` map keyed by the install path
/// (`""` for the project root, `"node_modules/left-pad"` for a top-level
/// dependency, `"node_modules/a/node_modules/b"` when a transitive
/// dependency needed a different version than the one already hoisted).
/// Every key but the root names exactly one resolved version, which is what
/// makes lockfiles the only npm spelling `outdated` can act on at all —
/// `package.json` alone yields nothing but ranges.
List<ParsedDep> _packageLockJson(String content) {
  final Object? doc;
  try {
    doc = jsonDecode(content);
  } on FormatException {
    rethrow;
  }
  if (doc is! Map) throw const FormatException('expected a JSON object');
  final out = <ParsedDep>[];
  final packages = doc['packages'];
  if (packages is Map) {
    const marker = 'node_modules/';
    packages.forEach((path, spec) {
      if (path is! String || spec is! Map) return;
      final idx = path.lastIndexOf(marker);
      if (idx == -1) return; // the "" root entry, or an unrecognised shape
      final version = spec['version'];
      if (version is! String) return;
      out.add(
        ParsedDep(
          kind: WatchKind.npm,
          name: path.substring(idx + marker.length),
          version: version,
          isResolved: true,
          isDevDep: spec['dev'] == true,
        ),
      );
    });
    return out;
  }

  // The legacy (npm v1-v6) lockfile shape nests transitive dependencies
  // inside their parent's own `dependencies` map rather than flattening
  // everything under one `packages` key.
  void walkLegacy(Object? node) {
    if (node is! Map) return;
    node.forEach((name, spec) {
      if (name is! String || spec is! Map) return;
      final version = spec['version'];
      if (version is String) {
        out.add(
          ParsedDep(
            kind: WatchKind.npm,
            name: name,
            version: version,
            isResolved: true,
            isDevDep: spec['dev'] == true,
          ),
        );
      }
      walkLegacy(spec['dependencies']);
    });
  }

  walkLegacy(doc['dependencies']);
  return out;
}

/// pnpm-lock.yaml's `packages` map is keyed by a string like
/// `/left-pad@1.3.0` or `/@scope/pkg@1.2.3(peer@1.0.0)`, flat regardless of
/// whether a package is a direct or transitive dependency — pnpm resolves
/// the whole graph into this one map, so no recursive walk is needed the
/// way the legacy npm lockfile shape needs one.
List<ParsedDep> _pnpmLockYaml(String content) {
  final doc = _yamlMap(content);
  final packages = doc['packages'];
  if (packages is! Map) return const [];
  final out = <ParsedDep>[];
  packages.forEach((key, spec) {
    if (key is! String) return;
    final entry = _pnpmPackageEntry(key);
    if (entry == null) return;
    final (name, version) = entry;
    out.add(
      ParsedDep(
        kind: WatchKind.npm,
        name: name,
        version: version,
        isResolved: true,
        isDevDep: spec is Map && spec['dev'] == true,
      ),
    );
  });
  return out;
}

/// Splits a pnpm-lock.yaml package key into (name, version). A scoped
/// name's own `@` (`@scope/pkg`) must not be mistaken for the version
/// separator, so the split is on the LAST `@`; an optional leading `/` and
/// a trailing peer-dependency suffix (`(react@18.0.0)`) are stripped first.
(String, String)? _pnpmPackageEntry(String key) {
  var k = key.startsWith('/') ? key.substring(1) : key;
  final parenIdx = k.indexOf('(');
  if (parenIdx != -1) k = k.substring(0, parenIdx);
  final at = k.lastIndexOf('@');
  if (at <= 0) return null;
  return (k.substring(0, at), k.substring(at + 1));
}

Map<String, dynamic> _tomlMap(String content) {
  try {
    return TomlDocument.parse(content).toMap();
  } catch (e) {
    throw FormatException('invalid TOML: $e');
  }
}

List<ParsedDep> _cargoToml(String content) {
  final doc = _tomlMap(content);
  final out = <ParsedDep>[];
  for (final (key, isDev) in [
    ('dependencies', false),
    ('dev-dependencies', true),
    ('build-dependencies', true),
  ]) {
    final section = doc[key];
    if (section is! Map) continue;
    section.forEach((name, spec) {
      String? version;
      if (spec is String) {
        version = spec;
      } else if (spec is Map) {
        // A table dep with no `version` is a path or git dep: nothing to check.
        version = spec['version'] as String?;
      }
      if (version == null) return;
      final isResolved = _isCargoExactVersion(version);
      out.add(
        ParsedDep(
          kind: WatchKind.crates,
          name: name as String,
          // The `=` operator is Cargo manifest syntax, not part of the
          // version: compareVersions cannot parse a leading `=` and treats
          // it as malformed, which sorts below every real release.
          version: isResolved ? version.trim().substring(1).trim() : version,
          isResolved: isResolved,
          isDevDep: isDev,
        ),
      );
    });
  }
  return out;
}

List<ParsedDep> _cargoLock(String content) {
  final packages = _tomlMap(content)['package'];
  if (packages is! List) return const [];
  return packages
      .whereType<Map>()
      .where((p) => p['name'] is String && p['version'] is String)
      .map(
        (p) => ParsedDep(
          kind: WatchKind.crates,
          name: p['name'] as String,
          version: p['version'] as String,
          isResolved: true,
          isDevDep: false,
        ),
      )
      .toList();
}

List<ParsedDep> _goMod(String content) {
  final out = <ParsedDep>[];
  var inBlock = false;
  for (final raw in content.split('\n')) {
    final indirect = raw.contains('// indirect');
    final line = raw.split('//').first.trim();
    if (line.isEmpty) continue;

    if (line == 'require (') {
      inBlock = true;
      continue;
    }
    if (inBlock && line == ')') {
      inBlock = false;
      continue;
    }

    // Only `require` lines name dependencies. `module`, `go`, `toolchain`,
    // `replace`, and `exclude` must not be mistaken for one.
    var spec = line;
    if (!inBlock) {
      if (!line.startsWith('require ')) continue;
      spec = line.substring('require '.length).trim();
    }

    final parts = spec.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    out.add(
      ParsedDep(
        kind: WatchKind.go,
        name: parts[0],
        version: parts[1],
        isResolved: true,
        isDevDep: indirect,
      ),
    );
  }
  return out;
}

/// Splits a PEP 508 requirement into name and specifier.
(String, String)? _splitPep508(String raw) {
  // Drop environment markers and extras: `pkg[extra]>=1.0 ; python < "3.12"`.
  final noMarker = raw.split(';').first.trim();
  if (noMarker.isEmpty) return null;
  final match = RegExp(
    r'^([A-Za-z0-9._-]+)\s*(\[[^\]]*\])?\s*(.*)$',
  ).firstMatch(noMarker);
  if (match == null) return null;
  return (match.group(1)!, match.group(3)!.trim());
}

List<ParsedDep> _pyproject(String content) {
  final doc = _tomlMap(content);
  final out = <ParsedDep>[];
  final project = doc['project'];
  if (project is! Map) return out;

  void add(Object? entry, {required bool isDev}) {
    if (entry is! String) return;
    final split = _splitPep508(entry);
    if (split == null) return;
    final (name, spec) = split;
    final (version, isResolved) = _pep440Pin(spec);
    out.add(
      ParsedDep(
        kind: WatchKind.pypi,
        name: name,
        version: version,
        isResolved: isResolved,
        isDevDep: isDev,
      ),
    );
  }

  final deps = project['dependencies'];
  if (deps is List) {
    for (final d in deps) {
      add(d, isDev: false);
    }
  }
  final optional = project['optional-dependencies'];
  if (optional is Map) {
    optional.forEach((groupName, group) {
      if (group is! List) return;
      // PEP 621 optional-dependencies groups are arbitrary named extras
      // (`docs`, `test`, `speedups`, ...), not all of them "dev" work. Only
      // a group actually named `dev` maps to isDevDep; anything else is a
      // regular optional runtime extra.
      final isDev = groupName == 'dev';
      for (final d in group) {
        add(d, isDev: isDev);
      }
    });
  }
  return out;
}

List<ParsedDep> _requirements(String content) {
  final out = <ParsedDep>[];
  for (final raw in content.split('\n')) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    // Includes, editable installs, and pip flags are not requirements.
    if (line.startsWith('-') || line.startsWith('.')) continue;
    final split = _splitPep508(line);
    if (split == null) continue;
    final (name, spec) = split;
    final (version, isResolved) = _pep440Pin(spec);
    out.add(
      ParsedDep(
        kind: WatchKind.pypi,
        name: name,
        version: version,
        isResolved: isResolved,
        isDevDep: false,
      ),
    );
  }
  return out;
}

/// Splits a PEP 508/440 specifier into the stored `version` string and
/// whether it is a resolved pin.
///
/// A resolved `pinned_version` must be a bare version: every consumer
/// (the outdated filter in `store.dart`, `applyFirstFetchBaseline`, the
/// detail pane) feeds it straight to `compareVersions`, which treats a
/// leading operator as
/// malformed and therefore sorts it below every real release. The operator
/// is manifest syntax, not part of the version, so it is stripped here
/// rather than carried into the database.
///
/// `===` is PEP 440 arbitrary equality — a pin. `==2.31.*` is a wildcard
/// RANGE, not a pin, even though it shares `==`'s prefix.
///
/// The gate below is [isWellFormedVersion], not the stricter gate this
/// replaced: PEP 440 pins routinely spell as `==1.2.3.post1`, `==1.0rc1`,
/// `==2.0b3`, or `==1.0.dev1`, none of which matched that older regex's
/// hyphen/plus-only suffix pattern. Gating on a regex stricter than the
/// comparator that consumes the result meant those pins were silently
/// demoted to "unresolved" — never compared, so a pinned prerelease/post
/// release could never be reported outdated. `versions.dart` is the
/// authority on what counts as a parseable version; the gate here must
/// agree with it rather than second-guess it. A wildcard like `2.31.*`
/// still fails this gate because `_parse` cannot consume the trailing
/// `.*` and marks it malformed.
(String, bool) _pep440Pin(String spec) {
  final s = spec.trim();
  final op = s.startsWith('===') ? 3 : (s.startsWith('==') ? 2 : 0);
  if (op == 0) return (s, false);
  final bare = s.substring(op).trim();
  return isWellFormedVersion(bare) ? (bare, true) : (s, false);
}

/// True when [s] is a bare pinned version for pub's and npm's shared range
/// syntax — not a caret/tilde/comparison range, a wildcard, or an
/// alternation.
///
/// The well-formedness check is [isWellFormedVersion], not a hand-rolled
/// regex — see `_pep440Pin`'s doc for why gating on a stricter hand-rolled
/// regex silently demotes valid pins to "unresolved" (the same class of
/// mistake also fixed for Cargo's `=` pin in `_isCargoExactVersion`).
/// [isWellFormedVersion] is more permissive than that old regex, though, so
/// range syntax must be rejected explicitly before deferring to it: `^ ~ >
/// < * |`, any whitespace (which also catches npm's `1.2.3 - 2.0.0` hyphen
/// range and `||` alternatives), and an `x`/`X` wildcard segment (`1.2.x`)
/// all mark a range, never a pin.
bool _isPinnedVersion(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'[\^~><*|\s]').hasMatch(trimmed)) return false;
  if (RegExp(r'(^|\.)[xX](\.|$)').hasMatch(trimmed)) return false;
  return isWellFormedVersion(trimmed);
}

/// True only for Cargo's explicit exact-match operator (`"=1.2.3"`). Cargo
/// treats a bare version (`"1.2.3"`) as caret-default — exactly equivalent
/// to `"^1.2.3"` per the Cargo Book — so a plain well-formedness check
/// would wrongly mark a caret range as resolved; only a leading `=` pins
/// the version.
///
/// The well-formedness check itself is [isWellFormedVersion], not a
/// hand-rolled regex — see `_pep440Pin`'s doc for why gating on a stricter
/// hand-rolled regex silently demotes valid pins to "unresolved". Cargo's
/// full semver allows a prerelease *and* build metadata together
/// (`"1.2.3-alpha.1+build"`), which is exactly the kind of spelling that
/// mistake would reject, but which Cargo accepts and `versions.dart` parses
/// cleanly.
bool _isCargoExactVersion(String s) {
  final trimmed = s.trim();
  return trimmed.startsWith('=') &&
      !trimmed.startsWith('==') &&
      isWellFormedVersion(trimmed.substring(1));
}
