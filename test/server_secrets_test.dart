import 'dart:io';

import 'package:deptracker/secrets.dart';
import 'package:deptracker/server/keys.dart';
import 'package:deptracker/server/sqlite_secrets.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('srv_secrets'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('key file is created once, 64 bytes, mode 0600, and reloaded', () async {
    final path = p.join(tmp.path, 'deptracker.key');
    final a = await loadOrCreateServerKeys(path);
    final b = await loadOrCreateServerKeys(path);
    expect(a.aesKey, b.aesKey);
    expect(a.jwtKey, b.jwtKey);
    expect(a.aesKey.length, 32);
    expect(a.jwtKey.length, 32);
    expect(a.aesKey, isNot(a.jwtKey));
    if (!Platform.isWindows) {
      final mode = (await Process.run('stat', [
        '-c',
        '%a',
        path,
      ])).stdout.toString().trim();
      expect(mode, '600');
    }
  });

  test('a key file of the wrong size is refused, not silently regrown', () {
    final path = p.join(tmp.path, 'short.key');
    File(path).writeAsBytesSync(List.filled(16, 7));
    expect(loadOrCreateServerKeys(path), throwsA(isA<StateError>()));
  });

  test(
    'github token round-trips through Secrets on the sqlite backend',
    () async {
      final store = Store.openInMemory();
      addTearDown(store.close);
      final keys = await loadOrCreateServerKeys(p.join(tmp.path, 'k'));
      final secrets = Secrets(SqliteSecretBackend(store, keys.aesKey));
      await secrets.setGithubToken('ghp_averyrealtoken1234');
      expect(await secrets.githubToken(), 'ghp_averyrealtoken1234');
    },
  );

  test('the DB alone is useless: a different key fails closed', () async {
    final store = Store.openInMemory();
    addTearDown(store.close);
    final k1 = await loadOrCreateServerKeys(p.join(tmp.path, 'k1'));
    final k2 = await loadOrCreateServerKeys(p.join(tmp.path, 'k2'));
    await SqliteSecretBackend(store, k1.aesKey).write('x', 'sensitive-value');
    await expectLater(
      SqliteSecretBackend(store, k2.aesKey).read('x'),
      throwsA(anything),
    );
    // And the plaintext is not sitting in the DB image.
    final raw = store.secretGet('x')!;
    expect(String.fromCharCodes(raw.ciphertext), isNot(contains('sensitive')));
  });

  test('deleting a secret removes the row', () async {
    final store = Store.openInMemory();
    addTearDown(store.close);
    final keys = await loadOrCreateServerKeys(p.join(tmp.path, 'k'));
    final backend = SqliteSecretBackend(store, keys.aesKey);
    await backend.write('x', 'value-to-drop');
    await backend.delete('x');
    expect(await backend.read('x'), isNull);
    expect(store.secretGet('x'), isNull);
  });

  test('secret writes do not notify listeners', () async {
    final store = Store.openInMemory();
    addTearDown(store.close);
    var notified = 0;
    store.addListener(() => notified++);
    final keys = await loadOrCreateServerKeys(p.join(tmp.path, 'k'));
    await SqliteSecretBackend(store, keys.aesKey).write('x', 'yy');
    expect(notified, 0);
  });
}
