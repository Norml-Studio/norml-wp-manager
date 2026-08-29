# Install Norml WordPress Copilot

Public product name: **Norml WordPress Copilot**. Installed skill:
`norml-wp-manager`.

Repository: `normlstudio/norml-wordpress-copilot`. The installed slug remains
`norml-wp-manager` for compatibility with existing installations and local state.

The first run connects one WordPress site, analyzes it read-only, and creates a
reusable local site folder with a visible `capabilities.md`. After that, work in
plain language.

## Requirements

- WordPress 5.6+ with HTTPS.
- An editor or administrator login that can create a dedicated Application
  Password. Prefer editor unless administrator-only surfaces are required.
- One supported AI environment:
  - Claude Desktop / Cowork;
  - Claude Code;
  - Codex;
  - Gemini CLI.
- Terminal setup requires `curl` and `python3`. PowerShell uses its native JSON
  support.

No SSH, WP-CLI, database access, local WordPress install, or GitHub connection is
required. Those belong to Norml WordPress Copilot Advanced.

## Install in a terminal runtime

Choose the command for the environment that will run the skill.

### Claude Code

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a claude-code
```

### Codex

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a codex
```

### Gemini CLI

```bash
npx skills@latest add normlstudio/norml-wordpress-copilot --skill=norml-wp-manager -g -a gemini-cli
```

Then open the runtime in the folder where site dossiers should live and say:

> Set up my WordPress access.

The terminal runbook opens a native OS prompt for the Application Password and
stores it in macOS Keychain, Windows Credential Manager, or Linux libsecret when
available. It never asks for the secret in chat or on a command line.

Manual setup entry points:

```bash
bash ~/.claude/skills/norml-wp-manager/scripts/setup-macos.sh
```

```powershell
& "$env:USERPROFILE\.claude\skills\norml-wp-manager\scripts\setup-windows.ps1"
```

The skill may be installed at a runtime-specific adapter path rather than
`~/.claude/skills`; when that is true, ask the runtime to resolve the installed
skill folder and run the matching script from there.

## Install in Claude Desktop / Cowork

1. Download the standalone `norml-wp-manager.zip` package.
2. Add the skill ZIP to Claude Desktop / Cowork.
3. Extract or expose the uploaded package files so you can open the bundled
   `connect.html` locally in Chrome or Edge.
4. In Claude, say: **“Set up my WordPress access.”**
5. Before authentication, add the exact WordPress hostname under **Settings →
   Capabilities → Allow network egress**. Do not enable all domains.

The local connector does not make network requests. It:

1. collects the non-secret site URL, slug, and WordPress login;
2. opens WordPress's own authorization page;
3. accepts the dedicated Application Password outside chat;
4. asks you to select the parent folder where the site dossier should be created;
5. writes a one-time `credential.handoff` beside the non-secret config.

Return to Claude and say:

> Connection handoff is ready.

Claude runs `scripts/import-desktop-handoff.sh` or
`scripts/import-desktop-handoff.ps1`. The importer verifies git exclusion, locks
the credential file to the current user, tests WordPress authentication, deletes
the handoff, and runs the full read-only scan. If authentication fails, it does
not delete the handoff so you can correct the setup without re-entering unrelated
details.

If the browser does not support local folder access, use a terminal runtime for
setup; never paste the Application Password into chat as a fallback.

## What onboarding creates

```text
your-site/
├── README.md
├── capabilities.md
├── project-notes.md
├── changelog.md
└── .wpm/
    ├── config.json
    ├── credential              # desktop / no-keychain fallback only
    ├── .gitignore
    └── docs/
        ├── 00-connection.md
        ├── 01-site.md
        ├── 02-content-model.md
        ├── 03-plugins-theme.md
        └── 04-rest-capabilities.md
```

`capabilities.md` is the first file to read. It records what this specific login
can read, create, update, and delete, plus blockers and the work that requires the
Advanced Copilot. The numbered scan files hold the underlying evidence.

## Verify the connection

After setup, ask:

> Explain this WordPress site and what you can safely change.

The answer must come from the generated dossier rather than assumptions. You can
also ask **“rescan my site”** after roles, plugins, fields, or content types change.

## Credential safety

- The Application Password is never entered into chat.
- `config.json` stores only connection metadata and a secret pointer.
- Terminal runtimes use the OS secret store when available.
- The Desktop / Cowork file fallback is gitignored and locked to the current user.
- Authenticated requests use HTTPS.
- Revoke or rotate the dedicated Application Password at any time in the
  WordPress user profile.

## Troubleshooting

| Symptom | What to check |
|---|---|
| The skill is not visible | Restart the runtime and confirm `norml-wp-manager` is installed or uploaded. |
| Desktop says the site is blocked | Add only the WordPress hostname under Settings → Capabilities. |
| `401 Unauthorized` | Confirm the WordPress login slug, revoke the old Application Password, and authorize a new one. |
| `403 Forbidden` on one endpoint | The connected role or REST configuration does not allow that surface; consult `capabilities.md`. |
| The local connector cannot choose a folder | Open it in current Chrome or Edge, or complete setup in a terminal runtime. |
| A content type is missing | It may not have `show_in_rest`; use wp-admin or ask a developer to expose it. |

## What is not installed

The skill does not add a daemon, system service, WordPress plugin, database agent,
SSH key, or GitHub integration. Per-site knowledge lives only in the site folder
you choose. Deleting that folder makes the Copilot forget the site; separately
revoke the Application Password in WordPress.
