import 'package:sqlite3/wasm.dart';

/// The web half of the database-opening seam. Only [openDatabaseAsync] is
/// real: loading sqlite3.wasm and attaching the IndexedDB VFS are both
/// async, which is why the seam has an async member at all. IndexedDB is
/// chosen over OPFS deliberately — OPFS needs COOP/COEP response headers,
/// and this build must work under any static file server.
CommonDatabase openDatabaseFile(String ref) =>
    throw UnsupportedError('Synchronous open is not available on the web');

CommonDatabase openDatabaseInMemory() =>
    throw UnsupportedError('Synchronous open is not available on the web');

Future<CommonDatabase> openDatabaseAsync(String ref) async {
  // Served from the app's own origin next to index.html; vendored under
  // web/ with a checksum, the same arrangement as the Windows sqlite3.dll.
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  // In-memory, not IndexedDB: the browser Store is a disposable mirror of
  // the server's database, and locally persisted state could only ever
  // misrepresent the server after someone else's mutation.
  sqlite.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
  return sqlite.open(ref);
}
