# Norml WordPress Copilot

Installed skill: `norml-wp-manager`.

Manage the content and administration layer of one WordPress site from Claude,
Codex, or Gemini. The Copilot connects through WordPress's built-in REST API,
analyzes the site once, records what is actually reachable, and then works from
plain-language requests.

## The problem

Small WordPress changes accumulate because the person who knows what should change
is not always the person comfortable making it in wp-admin. The alternative is
often a ticket for a typo, a delayed post, or a repetitive media and SEO cleanup.

WordPress sites also differ dramatically. A request that is safe on one site may
be impossible on another because of roles, page builders, custom fields, or REST
settings. A generic assistant should not guess.

This Copilot starts by mapping the connected site. It turns that evidence into a
visible `capabilities.md`, then checks it before writes.

## What it does

- Reads, drafts, edits, publishes, schedules, and organizes WordPress content.
- Manages media metadata, taxonomies, users, settings, and REST-exposed custom
  content when the connected role allows it.
- Detects the active theme, key plugins, page builder, content model, REST
  namespaces, role, and blockers.
- Keeps a durable local dossier and append-only change log for the site.
- Shows broad, destructive, user-access, and site-wide changes before applying
  them.

## When to reach for it

Use it for work a site owner or content team would normally perform in wp-admin:

- correct or rewrite page and post content;
- publish or schedule drafts;
- update images and alt text;
- manage categories, tags, menus, and users;
- fill exposed ACF, SEO, or custom-post-type fields;
- audit what is editable through the connected account.

Use **Norml WordPress Copilot Advanced** when the request needs theme/plugin code,
WP-CLI, the database, SSH, GitHub, local development, deployment, or a field that
is not exposed through REST.

## How it works

1. **Connect.** Authorize a dedicated WordPress Application Password. Terminal
   runtimes capture it in an OS dialog; Desktop / Cowork uses the bundled local
   connector. The secret is never requested in chat.
2. **Analyze.** The Copilot runs a read-only REST scan before the first edit.
3. **Explain.** It writes a top-level `capabilities.md` plus detailed evidence in
   `.wpm/docs/` and explains the site in plain language.
4. **Work.** Ask for a result. The Copilot loads the capability map, content model,
   site notes, and recent change history before acting.
5. **Verify and remember.** It reads writes back where possible and logs each
   completed change or learned constraint.

## The local site dossier

```text
your-site/
├── README.md
├── capabilities.md
├── project-notes.md
├── changelog.md
└── .wpm/
    ├── config.json
    ├── credential              # fallback only; protected and gitignored
    └── docs/
        ├── 00-connection.md
        ├── 01-site.md
        ├── 02-content-model.md
        ├── 03-plugins-theme.md
        └── 04-rest-capabilities.md
```

The folder can live anywhere outside the skill. Generated scan files are replaced
on rescan; `project-notes.md` and `changelog.md` survive. The top-level
`capabilities.md` is deliberately easy for both the person and the AI to find.

## Inside the skill

| Path | Role |
|---|---|
| `SKILL.md` | Runtime entry point, REST capability boundary, safety gates, and request router. |
| `onboarding.md` | Chooses terminal or Desktop / Cowork onboarding without mixing their credential paths. |
| `onboarding-console.md` | Terminal setup, protected secret capture, connection test, and first read-only scan. |
| `onboarding-desktop.md` | Desktop / Cowork setup through a local, short-lived credential handoff. |
| `connect.html` | No-network local connector used only for the Desktop / Cowork handoff. |
| `scripts/` | Cross-platform setup, import, connection, scanning, and WordPress REST helpers. |
| `wordpress-guides/` | Bundled REST, ACF, architecture, plugin, and safety guidance. |
| `templates/` | Contracts for capabilities, notes, changelog, config, and the per-site README. |

This is the installed `norml-wp-manager/` source. It stays separate from the
per-site dossier above, which the Copilot creates on the user's computer.

## Say this to the Copilot

| Need | Example request |
|---|---|
| Explain the site | “Explain how this WordPress site is structured and what you can safely change.” |
| Correct content | “Fix the typo on the About page.” |
| Publish properly | “Publish this draft with its category, featured image, and SEO title.” |
| Fill a repeatable type | “Add this case study and tag it Fintech.” |
| Improve media metadata | “Find images missing alt text and draft accurate replacements.” |
| Audit access | “Show me the administrator accounts before I offboard a contractor.” |
| Refresh the map | “Rescan the site; I added a plugin and a custom post type.” |

## Requirements

- WordPress 5.6+ over HTTPS.
- An editor or administrator login able to create an Application Password.
- Claude Desktop / Cowork, Claude Code, Codex, or Gemini CLI.
- The exact site hostname allowlisted in Desktop / Cowork.
- `curl` and `python3` for shell setup; PowerShell uses native equivalents.

No SSH, WP-CLI, GitHub, local WordPress environment, or database access is needed.

## Credential safety

- The Application Password never goes into chat, config, documentation, or a
  command-line argument.
- Terminal runtimes prefer macOS Keychain, Windows Credential Manager, or Linux
  libsecret.
- Desktop / Cowork uses a static local connector with no external network access.
  Its short-lived handoff is imported, permission-locked, verified, and deleted.
- Authenticated requests use HTTPS and a dedicated revocable WordPress credential.
- If exposure is suspected, revoke the Application Password and run onboarding
  again.

## Boundary

The Copilot does not edit code, install or update plugins/themes, run SQL, change
server configuration, deploy, or reshape opaque page-builder data. It does not
claim access to a field merely because the field exists. `capabilities.md` records
the real boundary for the connected role and current site.

## Where it sits

- **Norml WordPress Copilot** — API/content/admin surface; local site dossier.
- **Norml WordPress Copilot Advanced** — CLI-only development surface; SSH +
  GitHub; theme-local `.claude/` project documentation.

## What changed in 1.1.1

- Renamed the public repository to `norml-wordpress-copilot` while retaining the
  installed `norml-wp-manager` slug for compatibility.
- Renamed the bundled source folder from `references/` to the descriptive
  `wordpress-guides/` path and updated its links.
- Kept runtime behavior, local site dossiers, configuration paths, and credential
  references unchanged.

## What changed in 1.1.0

- Added the public product title while retaining the stable installed slug.
- Added a generated top-level `capabilities.md` as the first operating contract.
- Replaced Desktop chat-based credential entry with a bundled local connector and
  one-time importer.
- Clarified support for Claude Desktop / Cowork, Claude Code, Codex, and Gemini
  CLI, and made the Advanced handoff explicit.
- Added exact installed-package path/role documentation, kept separate from the
  generated site dossier.

---

_Covers SKILL.md v1.1.1 | Last changelog entry: v1.1.1 | Generated: 2026-08-29. If
the skill behaves differently, trust `SKILL.md` and regenerate this guide._
