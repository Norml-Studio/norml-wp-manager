# `config.json` schema — reference (`schema_version: 4`)

This is the human/Claude reference for `{site_folder}/.wpm/config.json`. JSON can't
carry comments and the scripts parse the file, so every field rule lives here instead.
The companion `config.template.json` is the literal shape with placeholder values.

The file holds connection info and a **pointer** to the secret — **never the secret
value**. Written `chmod 600`, atomically. It contains **zero paths that escape the site
folder**, so the whole folder can be moved / renamed / zipped and keep working (file
tier). The site folder itself is always derived at runtime from where `config.json` was
found (the `.wpm/` parent) — it is never stored in the file.

```json
{
  "schema_version": 4,
  "site_name": "acme-marketing",
  "production_url": "https://acme.com",
  "wp_user": "acme-editor",
  "env": "desktop",
  "secret_store": {
    "kind": "portable-file",
    "ref": "credential"
  },
  "created_at": "2026-06-16T12:00:00Z",
  "last_scan_at": "2026-06-16T12:00:30Z"
}
```

## Field rules

| Field | Type | Rule |
|---|---|---|
| `schema_version` | integer | Always `4` for new configs. Pre-flight + scripts accept `3` **and** `4` — on a `3`, offer one-time migration, never silently dual-home. |
| `site_name` | string | Kebab-case label. Validated `^[a-z0-9]+(-[a-z0-9]+)*$`. Not a secret. Used in the connector deep-link `app_name` and the OS-vault service name. |
| `production_url` | string | Base URL, trailing slash stripped. **MUST be `https://`** for any Application-Password-bearing call (warn-and-allow only for explicit `localhost` dev). |
| `wp_user` | string | WordPress **login slug** — not the display name, not the email. Not a secret; stored in clear. (A `401` almost always means this is wrong — check `{production_url}/wp-admin/profile.php`.) |
| `env` | enum | One of `console-macos` \| `console-windows` \| `console-linux` \| `desktop`. Set once at setup by probe. Governs secret lookup, the network gate, and 403 disambiguation. Held for the session. |
| `secret_store.kind` | enum | One of `macos-keychain` \| `windows-credential-manager` \| `linux-libsecret` \| `portable-file`. The storage tier chosen at setup. |
| `secret_store.ref` | string | For the three OS-store tiers: the vault service name `norml-wp-manager-{site_name}`. For `portable-file`: the **bare relative** filename `credential` (resolved against `.wpm/`, never absolute — keeps the folder movable). |
| `created_at` | string | ISO-8601 UTC timestamp of first setup. |
| `last_scan_at` | string | ISO-8601 UTC timestamp of the last successful scan. Drives the **>7-day staleness check** (pre-flight mentions it once, then proceeds unless declined). |

## `env` × `secret_store.kind` — valid pairings

| `env` | Expected `secret_store.kind` | Secret lives in |
|---|---|---|
| `console-macos` | `macos-keychain` (preferred) or `portable-file` (no vault) | macOS Keychain, or `.wpm/credential` |
| `console-windows` | `windows-credential-manager` (preferred) or `portable-file` | Windows Credential Manager, or `.wpm/credential` |
| `console-linux` | `linux-libsecret` (only if the round-trip probe passed) or `portable-file` | libsecret, or `.wpm/credential` |
| `desktop` | `portable-file` (always — the sandbox has no OS vault) | `.wpm/credential` |

## What is NOT in this schema

**Never stored:** the Application Password (or any secret) — ever.

**Dropped from schema 3** (all computable / derivable, or a portability hazard):
`project_dir`, `docs_dir`, `architecture_doc`, `project_notes_doc`, `changelog_doc`,
`mode`, `_comment`, `_platform_options`, `version` (renamed → `schema_version`), and —
the field that broke portability — `site_folder` (an absolute path stored inside the
folder it points at goes stale on `mv`; the site folder is derived at runtime instead).

All path-shaped values are derived from the `.wpm/` location: the site folder
(`.wpm/`'s parent), `.wpm/docs/`, `.wpm/credential`, and the two top-level curated docs
(`project-notes.md`, `changelog.md`).
