# deptracker

A Flutter desktop app that watches the packages you depend on across
ecosystems and shows you what moved, with enough release-note text to decide
whether you care. It seeds its watchlist by scanning real project files on
disk, and it deduplicates: a package used by several repos is one row with
several usages, not one row per repo.

It is not a bot — it never opens pull requests or edits manifests, and it
does not poll in the background or push notifications. There is no tray
icon. Refreshes happen when you press the button, in the desktop app or in
the browser. The one headless mode is the server (`bin/server.dart`), which
exists to put that same GUI in a browser — it too fetches only when asked.
Both modes have an MCP side door for agents.

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

The GitHub PAT never sits in plaintext at rest — not in the SQLite
database, a config file, or logs:

- **Desktop**: the PAT lives in the host keyring. On Linux this requires a
  running secret service such as gnome-keyring; without one the token
  simply cannot be saved (the MCP server no longer depends on the keyring).
- **Server**: the PAT is AES-256-GCM-encrypted into the server's SQLite,
  keyed by `deptracker.key` — 64 random bytes generated on first run,
  written mode 0600 beside the database. A leaked database or backup is
  useless without that file. Nothing secret is read from environment
  variables.

MCP API keys are stored only as SHA-256 hashes (see below), which is not
secret material, and user passwords only as Argon2id hashes.

## MCP server

While the desktop app's window is open, it runs a local MCP server
(Streamable HTTP) on `127.0.0.1`; the web server exposes the same thing at
`/mcp`. Agents authenticate with named API keys managed in Settings: each
key is shown exactly once at creation, only its hash is stored, and any key
can be revoked on its own. The `Origin` header is validated to guard
against DNS-rebinding from other local processes or a browser tab.

## Running it

```
flutter run -d linux
```

On Linux, a secret service such as gnome-keyring must be running; see the Secrets section for details.

## Web mode (server + browser)

```
flutter build web --release
dart run bin/server.dart --web-root build/web
```

The server owns the engine: it holds the SQLite file (default
`data/deptracker.db`, with `deptracker.key` beside it), does all the
registry/GitHub/feed fetching, scans its own filesystem, and serves three
things from one port — the built frontend, a JSON API under `/api`, and
MCP at `/mcp`. The browser is a thin client: it mirrors the server's data
into in-memory WASM SQLite (`web/sqlite3.wasm`, vendored and checksummed)
and sends every change back over the API. Nothing persists in the browser.
A Docker image serving this is a later effort; `--db`, `--web-root`,
`--port`, and `--bind` cover the meanwhile.

Because fetching happens server-side, the browser has none of the CORS
limitations a purely static build would: GitHub Atom feeds and arbitrary
RSS watches work exactly as on desktop.

Accounts gate the web UI. The first visit offers a create-account form and
that account becomes the admin; registration stays open until an admin
closes it in Settings (accounts can also be managed with
`dart run bin/server.dart --add-user` / `--reset-password`). Sessions are a
15-minute JWT held in page memory plus a rotating 30-day HttpOnly refresh
cookie, so a revisit is a silent refresh, not a password prompt, and a
stolen database contains no usable session material.

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
- **Create an MCP API key** in Settings and put it in any agent configured
  against this app. The old single bearer token (which lived in the keyring)
  is gone entirely — keys are now named, revocable, shown once at creation,
  and stored only as hashes — so an agent still presenting the old token
  gets `401 Unauthorized`.

The watch database is untouched — it lives under a path derived from the app
*name*, not the app id.
