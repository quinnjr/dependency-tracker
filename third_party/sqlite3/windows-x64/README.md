# Vendored SQLite for Windows

`sqlite3.dll` here exists so `flutter test` can run on Windows.

The tests drive `package:sqlite3` over FFI, which loads a SQLite shared library
at runtime. On Linux and macOS the system provides one. On Windows nothing does:
`sqlite3_flutter_libs` supplies a DLL to the *built application*, but not to the
Dart VM that runs the tests, so without this file every store-backed test fails
to load the library.

`test/flutter_test_config.dart` points `package:sqlite3` at this file when the
tests run on Windows. Nothing else references it, and it is not shipped in any
release artifact — the packaged Windows app gets its DLL from
`sqlite3_flutter_libs` as usual.

## Provenance

| | |
| --- | --- |
| Version | 3.53.4 |
| Source | <https://sqlite.org/2026/sqlite-dll-win-x64-3530400.zip> |
| Archive SHA-256 | `8b959b7eff4a81f6a62fc3468f9273e5cfe78d4a927e62215aed231b654fb104` |
| `sqlite3.dll` SHA-256 | see `sqlite3.dll.sha256` |
| Architecture | x86-64 |

The DLL's checksum lives in `sqlite3.dll.sha256` rather than in this prose,
because CI verifies it (`sha256sum -c`) before running the Windows tests. A
hash recorded only in a README is documentation; a swapped binary is not
reviewable in a diff, so the check has to be machine-run to be worth anything.

The version matches the SQLite that `sqlite3_flutter_libs` links into the app,
so the tests exercise the same engine the application uses. That matters for the
`RETURNING` clause in `lib/store.dart`, which needs SQLite 3.35 or newer.

SQLite is in the public domain: <https://sqlite.org/copyright.html>.

## Updating

Download the `sqlite-dll-win-x64-<version>.zip` for the version that
`sqlite3_flutter_libs` bundles, replace `sqlite3.dll`, and update the version
and the archive checksum above. Verify the download, then regenerate the
checksum file CI reads:

```sh
sha256sum sqlite-dll-win-x64-<version>.zip
sha256sum sqlite3.dll > sqlite3.dll.sha256
```

`test/store_test.dart` asserts the loaded SQLite is at least 3.35, so a DLL
old enough to break `upsertWatch`'s `RETURNING` fails the suite rather than
failing at runtime.
