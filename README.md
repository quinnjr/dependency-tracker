# deptracker

A Flutter desktop app that watches the packages you depend on across
ecosystems and shows you what moved, with enough release-note text to decide
whether you care. It seeds its watchlist by scanning real project files on
disk, and it deduplicates: a package used by several repos is one row with
several usages, not one row per repo.

It is not a bot — it never opens pull requests or edits manifests, and it does
not poll in the background or push notifications. There is no tray icon and
no CI/headless mode. It is a GUI app that shows you what's new when you open
or refresh it, and it has an MCP side door for agents.

## Ecosystems

Lockfile/manifest scanning and release tracking cover pub, npm, crates.io,
Go modules, and PyPI, plus manual GitHub-repo and RSS/Atom watches (e.g. for
projects that only tag releases, or non-package sources like security
advisories).

## GitHub token (optional)

GitHub's unauthenticated API is capped at 60 requests/hour, which is not
enough to resolve release notes for a large watchlist. A personal access
token raises that limit and improves metadata quality, but it is never
required: `releases.atom`/`tags.atom` feeds cost no API quota and are the
default path, so the app works fully without a token.

## Secrets

The GitHub PAT and the MCP bearer token live only in the host keyring — never
in the SQLite database, a config file, or logs. On Linux this requires a
running secret service such as gnome-keyring; without one, the MCP server
refuses to start rather than falling back to an unauthenticated server or a
plaintext file.

## MCP server

While the app's window is open, it also runs a local MCP server (Streamable
HTTP) on `127.0.0.1` so an agent can read the same watchlist data and curate
it. Every request must present a bearer token, and the `Origin` header is
validated to guard against DNS-rebinding from other local processes or a
browser tab.

## Running it

```
flutter run -d linux
```

On Linux, a secret service such as gnome-keyring must be running; see the Secrets section for details.

## Web build

```
flutter build web --release
```

The output under `build/web/` is static files, meant to be served by a
container image later — there is no hosted deployment in this repo. SQLite
runs as WebAssembly (`web/sqlite3.wasm`, vendored and checksummed) with the
watch database persisted in the browser's IndexedDB.

A browser build is a reduced version of the app, by nature rather than by
switch:

- **No disk scanning.** There is no filesystem; watches are added by hand.
- **No MCP server.** Nothing can listen on a socket in a page.
- **The GitHub token is kept in memory for the tab session only.** There is
  no keyring, and this app does not store secrets at rest in weaker places —
  re-enter the token next visit.
- **GitHub watches effectively require a token.** The no-token default path
  reads `github.com/.../releases.atom`, and github.com sends no CORS
  headers, so a browser cannot fetch it; `api.github.com` does allow it,
  with a token or without one at 60 requests/hour.
- **RSS/Atom watches work only when the feed host allows cross-origin
  reads.** Failures surface per-watch as fetch errors, same as any other.

The registry APIs (pub.dev, npm, crates.io, PyPI, the Go module proxy) allow
cross-origin requests and work unchanged.

## Testing

```
flutter test
```

On Windows the tests load the SQLite DLL vendored under
`third_party/sqlite3/windows-x64/`, because `sqlite3_flutter_libs` supplies a
library to the built app but not to the Dart VM that runs `flutter test`. See
the README there.

## Upgrading on Linux from a build before 1.0.0

The application id changed from `ai.lexmata.deptracker` to
`dev.quinnjr.deptracker`, so the Flatpak app id and the GTK application id
agree and the window matches its `.desktop` entry.

Login keyring entries are namespaced by that id, so the previous ones are
invisible to the new build:

- **Re-enter your GitHub token** in Settings. Without it, refreshes fall back
  to unauthenticated rate limits rather than failing loudly.
- **Re-copy the MCP token** into any agent configured against this app. The
  token is regenerated on first launch, so an agent still presenting the old
  one gets `401 Unauthorized`.

The watch database is untouched — it lives under a path derived from the app
*name*, not the app id.
