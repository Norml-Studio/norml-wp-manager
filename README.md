# Norml WordPress Copilot

Public product name: **Norml WordPress Copilot**. Installed skill: `norml-wp-manager`.

Repository: [`normlstudio/norml-wordpress-copilot`](https://github.com/normlstudio/norml-wordpress-copilot).
The installed slug remains `norml-wp-manager` so existing installations, local
site dossiers, and credential references continue to work.

Manage the content and administration layer of a WordPress site from Claude,
Codex, or Gemini in plain language. It connects through WordPress's built-in REST
API, maps the site once, writes a visible `capabilities.md`, and checks that map
before every change.

## What it does

- Edits and publishes pages, posts, media, taxonomies, menus, users, settings,
  custom post types, and exposed custom fields when the connected WordPress role
  and REST surface allow it.
- Scans the site before the first edit and records the content model, plugins,
  theme, REST namespaces, access level, blockers, and safe operating surface.
- Keeps the reusable site dossier in one folder on the user's computer—not in the
  skill package and not in the WordPress theme.
- Logs changes and asks before risky or broad writes.

## When to reach for it

Use this Copilot for day-to-day site work that a site owner or content team would
normally do in wp-admin. Use **Norml WordPress Copilot Advanced**
(`norml-wp-developer`) when the request needs code, theme files, WP-CLI, database
access, SSH, GitHub, or deployment.

## How it flows

1. Install or upload the skill.
2. Say: **“Set up my WordPress access.”**
3. Authorize a dedicated WordPress Application Password. The secret is captured
   outside chat and stored in the OS secret store or a protected local file.
4. The Copilot tests the connection and analyzes the site read-only.
5. It writes `capabilities.md`, `project-notes.md`, `changelog.md`, and the detailed
   generated scan under `.wpm/docs/`.
6. From then on, ask for WordPress work in plain language.

## Install

Claude Code:

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a claude-code
```

Codex:

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a codex
```

Gemini CLI:

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a gemini-cli
```

Claude Desktop / Cowork uses the standalone ZIP and the bundled local
`connect.html` onboarding page. See
[`install.md`](.claude/skills/norml-wp-manager/install.md).

## What gets created for each site

```text
your-site/
├── README.md
├── capabilities.md
├── project-notes.md
├── changelog.md
└── .wpm/
    ├── config.json
    ├── credential              # file fallback only; gitignored
    └── docs/
        ├── 00-connection.md
        ├── 01-site.md
        ├── 02-content-model.md
        ├── 03-plugins-theme.md
        └── 04-rest-capabilities.md
```

The top-level `capabilities.md` is the plain-English operating contract. The
numbered files preserve the evidence behind it. Rescans rewrite generated files
but never overwrite `project-notes.md` or the append-only `changelog.md`.

## Credential safety

- No WordPress password or Application Password is requested in chat.
- Terminal runtimes prefer macOS Keychain, Windows Credential Manager, or Linux
  libsecret.
- Desktop / Cowork uses a local no-network handoff page. Its one-time handoff file
  is imported, permission-locked, authenticated, and deleted immediately.
- Connection metadata never contains the secret. Authenticated requests are HTTPS
  only.
- Revoke the dedicated Application Password in wp-admin at any time.

## Boundary

This is the API/content Copilot. It does not edit theme or plugin code, run SQL,
use SSH, deploy, or pretend a non-REST field is editable. Those requests route to
Norml WordPress Copilot Advanced.

## Documentation

- [Human guide](.claude/skills/norml-wp-manager/readme.md)
- [Visual one-pager](.claude/skills/norml-wp-manager/readme.html)
- [Installation](.claude/skills/norml-wp-manager/install.md)
- [Onboarding chooser](.claude/skills/norml-wp-manager/onboarding.md)
- [Changelog](.claude/skills/norml-wp-manager/changelog.md) — current version 1.1.1

## License

[MIT](LICENSE) © Norml Studio
