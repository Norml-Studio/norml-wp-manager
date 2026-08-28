# Changelog

All notable changes to **norml-wp-manager**. This project follows
[semantic versioning](https://semver.org/).

## [1.1.0] — 2026-08-28

Published the human-facing name **Norml WordPress Copilot** while keeping
`norml-wp-manager` as the stable installed skill slug. The first scan now renders
a top-level `capabilities.md` from the live REST surface and connected role, so
people and agents have one visible operating contract before any write.

Desktop / Cowork onboarding no longer asks for an Application Password in chat.
The bundled local `connect.html` creates a short-lived, git-ignored handoff; the
new macOS/Linux and Windows importers permission-lock the handoff, config, and
credential, verify the connection, delete the handoff after success, scaffold the site dossier, and run
the full read-only scan. Documentation now distinguishes this API/content Copilot
from the CLI-only Norml WordPress Copilot Advanced and names Claude Desktop /
Cowork, Claude Code, Codex, and Gemini CLI explicitly.

## [1.0.0] — 2026-06-16

Manage a WordPress site from Claude over the REST API — for non-technical site
owners, with no SSH and no developer tooling.

### Self-contained
- Everything the skill knows about a site lives in **one folder you name**:
  readable `project-notes.md` + `changelog.md` at the top, machinery in a hidden
  `.wpm/` (connection config + the auto-generated site scan). Nothing is written
  to shared system locations — delete the folder and the skill forgets the site.

### Two environments, auto-detected
- Works in **Claude Code** (terminal) and the **Claude desktop app** (sandbox),
  detecting which and adapting.
- In the desktop app it verifies your site is reachable — and walks you through
  the one-time **Settings → Capabilities → Domain allowlist** step — *before*
  asking for any credential, so a password is never requested against an
  unreachable site.

### Secure credential handling
- The Application Password is stored in your OS secret store (macOS Keychain,
  Windows Credential Manager, or Linux libsecret) where available, or a locked,
  git-ignored file otherwise.
- It's passed to requests without ever appearing on a command line, in shell
  history, or in the conversation. All authenticated calls are HTTPS-only.
- Defaults that limit blast radius: editor-role recommended over admin, and
  rotation guidance for the file-based fallback.

### One-click connect
- Uses WordPress's built-in Application Password authorization screen — click,
  authorize, copy. No external services, no extra infrastructure.

### Knows your site
- On first connect it scans the site over REST into a small set of notes it reads
  before acting (so it checks what's actually editable before trying), and keeps a
  running, tagged changelog of every change — context compounds across sessions.
- Re-scan any time with *"rescan my site."*

### Safe by default
- Reads and low-risk single edits run immediately; anything touching multiple
  items, user roles, or site-wide settings asks for confirmation first; genuinely
  dangerous operations are refused.

**Requirements:** WordPress 5.6+ and an administrator or editor account.
Content-only — no theme/plugin code, no database operations, no server access.
