import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

/// The native half of the database-opening seam: FFI sqlite3, exactly what
/// Store.open has always done. The web half (db_open_web.dart) substitutes
/// WASM + IndexedDB; Store itself only ever sees [CommonDatabase].
CommonDatabase openDatabaseFile(String ref) => sqlite3.open(ref);

CommonDatabase openDatabaseInMemory() => sqlite3.openInMemory();

/// Async for signature parity with the web half, where loading the WASM
/// module genuinely is async. On the VM it completes synchronously.
Future<CommonDatabase> openDatabaseAsync(String ref) async => sqlite3.open(ref);
