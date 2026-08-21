// The platform seam main.dart imports: the io variant assembles the full
// desktop resource set (database file, keyring, scanner, MCP server), the
// web variant assembles the reduced browser one (WASM database, in-memory
// secrets, no scanner, no MCP). Both export `Future<AppResources> bootstrap()`.
export 'bootstrap_io.dart' if (dart.library.js_interop) 'bootstrap_web.dart';
