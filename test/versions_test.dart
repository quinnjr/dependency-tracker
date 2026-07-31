import 'package:deptracker/versions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('numeric segments compare numerically, not lexically', () {
    expect(compareVersions('1.9.0', '1.10.0'), lessThan(0));
    expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
    expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
  });

  test('missing segments are zero', () {
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.2', '1.2.1'), lessThan(0));
  });

  test('a leading v is ignored', () {
    expect(compareVersions('v3.0.0', '3.0.0'), 0);
    expect(compareVersions('v3.1.0', '3.0.9'), greaterThan(0));
  });

  test('build metadata is ignored', () {
    expect(compareVersions('1.0.0+abc', '1.0.0'), 0);
  });

  test('a prerelease sorts below its release', () {
    expect(compareVersions('1.0.0-alpha', '1.0.0'), lessThan(0));
    expect(compareVersions('1.0.0-rc.1', '1.0.0'), lessThan(0));
  });

  test('prerelease identifiers compare numerically when both are numeric', () {
    expect(compareVersions('1.0.0-alpha.9', '1.0.0-alpha.10'), lessThan(0));
    expect(compareVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
  });

  test('PEP 440 suffixes without a dash are treated as prereleases', () {
    expect(compareVersions('2.0.0rc1', '2.0.0'), lessThan(0));
    expect(compareVersions('2.0.0b2', '2.0.0rc1'), lessThan(0));
  });

  test('newestVersion picks the maximum', () {
    expect(newestVersion(['1.0.0', '1.10.0', '1.9.0']), '1.10.0');
    expect(newestVersion(['2.0.0-rc.1', '1.9.9']), '2.0.0-rc.1');
    expect(newestVersion(const <String>[]), isNull);
  });

  test('unparseable versions never throw', () {
    expect(compareVersions('nightly', 'nightly'), 0);
    expect(() => compareVersions('', '1.0.0'), returnsNormally);
  });

  test('PEP 440 post-releases sort above their base release', () {
    expect(compareVersions('2.0.0.post1', '2.0.0'), greaterThan(0));
    expect(compareVersions('1.0.post1', '1.0.post2'), lessThan(0));
    expect(compareVersions('1.0', '1.0.post1'), lessThan(0));
  });

  test('PEP 440 dev-releases sort below everything at the same release', () {
    expect(compareVersions('1.2.3.dev1', '1.2.3'), lessThan(0));
    expect(compareVersions('1.0.dev1', '1.0.dev2'), lessThan(0));
    expect(compareVersions('1.0.dev9', '1.0a1'), lessThan(0));
    expect(compareVersions('1.0a1', '1.0'), lessThan(0));
  });

  test('a malformed version sorts below a clean one, never equal', () {
    expect(compareVersions('1.x.3', '1.0.0'), lessThan(0));
    expect(compareVersions('1.0.0', '1.x.3'), greaterThan(0));
    expect(compareVersions('nightly', '1.0.0'), lessThan(0));
    expect(compareVersions('nightly', 'nightly'), 0);
    expect(compareVersions('', '1.0.0'), lessThan(0));
  });

  test('Go pseudo-versions order by timestamp and never fragment', () {
    const a = 'v0.0.0-20260101120000-4f9a2c1e8b3d';
    const b = 'v0.0.0-20260501120000-9c3b1d7e2a5f';
    expect(compareVersions(a, a), 0);
    expect(compareVersions(a, b), lessThan(0));
    expect(compareVersions(a, 'v0.7.0'), lessThan(0));
  });

  test('newestVersion still degrades gracefully over unparseable input', () {
    expect(newestVersion(['nightly', 'latest']), isNotNull);
    expect(newestVersion(['nightly', '1.0.0']), '1.0.0');
    expect(newestVersion(const <String>[]), isNull);
  });
}
