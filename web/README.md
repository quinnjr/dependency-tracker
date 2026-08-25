# Vendored sqlite3.wasm

`sqlite3.wasm` is the WebAssembly build of SQLite that `package:sqlite3`'s
`WasmSqlite3.loadFromUrl` fetches at startup — the web counterpart of the
native library `sqlite3_flutter_libs` supplies to the desktop builds. It has
to sit here, next to `index.html`, because the app loads it from its own
origin as `sqlite3.wasm` and `flutter build web` copies everything in this
directory into the build output verbatim.

It is vendored rather than fetched at build time so a build never depends on
a release asset staying up, and it is pinned by checksum for the same reason
the Windows `sqlite3.dll` under `third_party/sqlite3/` is:

- Source: <https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-2.9.4/sqlite3.wasm>
  (the asset published for the `sqlite3` Dart package version this project
  locks, 2.9.4 — keep the two in step when upgrading).
- Verify: `sha256sum -c sqlite3.wasm.sha256` in this directory. CI does this
  on every build.
