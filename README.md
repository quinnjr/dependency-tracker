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

## Testing

```
flutter test
```
