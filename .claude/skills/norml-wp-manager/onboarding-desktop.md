# Norml WordPress Copilot — Desktop onboarding

> Use this runbook in the Claude desktop app or Cowork. Console users follow
> `onboarding-console.md` instead.

The Desktop environment has two constraints: outbound domains must be explicitly
allowed, and the sandbox cannot reach macOS Keychain, Windows Credential Manager,
or Linux libsecret. This runbook solves both without asking the user to paste a
WordPress credential into the AI conversation.

## What setup creates

One folder per site:

```text
example-site/
├── README.md
├── capabilities.md              generated answer to “what can you do here?”
├── project-notes.md             durable site-specific knowledge
├── changelog.md                 readable operation and decision log
└── .wpm/
    ├── config.json              connection metadata; no secret
    ├── credential               imported private Application Password
    ├── .gitignore               excludes credential + the short-lived handoff
    └── docs/                    generated REST evidence, 00–04
```

The folder is portable. Keep it outside cloud-sync folders. Delete it to remove
the local dossier, then revoke the Application Password in WordPress.

## Step 1 — Prove the site is reachable

Collect only the production URL. Before any credential exists, run an anonymous
request:

```bash
curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "https://example.com/wp-json"
```

- `200` with REST JSON: continue.
- Sandbox/proxy `403`, `000`, DNS failure, or timeout: stop. Ask the user to add
  the site domain under Settings → Capabilities → Allow network egress →
  Additional allowed domains. Keep the default narrow policy; do not switch to
  “All domains.” Re-probe until it passes.
- `200` with HTML rather than REST JSON: the URL is wrong or WordPress REST is
  disabled. Fix that before continuing.

No Application Password is requested or created before this gate passes.

## Step 2 — Collect non-secret site details

Ask for:

- a kebab-case site name, used for the folder;
- the HTTPS production URL;
- the WordPress login name, not display name or email;
- the parent folder where the site dossier should live.

Refuse `$HOME`, `/`, `/tmp`, system/config roots, the skill directory itself, or
a folder inside the installed skill. Warn and get explicit acceptance before a
Dropbox, iCloud, OneDrive, Google Drive, or other cloud-sync location.

Prefer an Editor account for routine content work. Administrator is needed only
for endpoints such as full plugin/theme inventory, settings, and users.

## Step 3 — Open the local connector

Open `connect.html` from this skill folder in Chrome or Edge. It is a self-contained
local page with network access disabled by Content Security Policy.

The page asks the user to:

1. enter the WordPress URL, site folder name, and login name;
2. open WordPress's built-in `authorize-application.php` screen;
3. approve `norml-wordpress-copilot-{site}`;
4. paste the one-time Application Password into the local page—not chat;
5. choose the dossier's parent folder.

The local page writes only:

```text
{site-folder}/.wpm/config.json
{site-folder}/.wpm/.gitignore
{site-folder}/.wpm/credential.handoff
```

It makes no network request and sends the credential nowhere. The handoff is
short-lived; the next step validates, imports, and deletes it.

If the browser does not support the secure folder picker, hard-stop and route to
Claude Code, Codex, or Gemini CLI onboarding. Never fall back to asking for the
secret in chat.

## Step 4 — Import the handoff

When the user says “Connection handoff is ready,” run the platform helper against
the exact site folder:

```bash
bash scripts/import-desktop-handoff.sh "/absolute/path/to/example-site"
```

Windows PowerShell:

```powershell
& scripts/import-desktop-handoff.ps1 "C:\absolute\path\to\example-site"
```

The helper:

1. verifies Git ignores `credential.handoff` before importing;
2. locks the handoff and config to the current OS user, then rewrites the credential
   with owner-only/ACL controls without echoing it;
3. authenticates with `GET /wp-json/wp/v2/users/me`;
4. deletes the handoff only after authentication succeeds;
5. scaffolds the visible dossier files;
6. runs the read-only site scan;
7. generates `capabilities.md` plus `.wpm/docs/00–04`.

If authentication fails, the private credential is removed and the handoff stays
in place so the user can correct the login name or regenerate the Application
Password. Do not retry blindly.

## Step 5 — Explain the site once

After the scan, read in this order:

1. `capabilities.md` — the visible operating contract;
2. `.wpm/docs/02-content-model.md` — post types and taxonomies;
3. `.wpm/docs/03-plugins-theme.md` — the REST-visible build surface;
4. `project-notes.md` — durable site-specific rules;
5. the newest entries in `changelog.md`.

Give the user a concise first-run explanation:

- which content surfaces are readable and writable;
- which operations depend on the connected role or build;
- which work is blocked by REST;
- which requests require Norml WordPress Copilot Advanced.

Then the normal loop is simply: ask for an outcome → inspect current state →
confirm when required → make the change → read it back → log it.

## Security contract

- Never ask for the Application Password in chat.
- Never print, log, copy, summarize, or inspect the credential contents.
- Never put it in argv, config JSON, Markdown, Git, or a shell trace.
- The only transient plaintext file is `.wpm/credential.handoff`; it is Git-ignored
  before creation and deleted immediately after a successful import.
- The standing Desktop credential is a local private file because the sandbox has
  no OS secret-store access. Use an Editor credential when possible and rotate it
  regularly. WordPress Application Passwords are separate and independently
  revocable.
- Keep the dossier outside cloud sync.

## Troubleshooting

| Symptom | Meaning | Response |
|---|---|---|
| Anonymous `/wp-json` fails | Desktop egress allowlist or site reachability | Fix the allowlist/URL before authorization |
| No Application Passwords section | WordPress < 5.6 or feature disabled | Upgrade or re-enable Application Passwords |
| `401` during import | Wrong login slug, revoked, or incomplete Application Password | Correct/regenerate, rerun the local connector |
| Real WordPress JSON `403` after anonymous `200` | The WordPress role lacks that capability | Use the appropriate Editor/Admin account |
| Browser has no folder picker | Unsupported browser | Open `connect.html` in Chrome/Edge or use a CLI runtime |
| Git ignore gate fails | The handoff could be committed | Stop; fix ignore behavior before re-running |

## Rotate or revoke

In WordPress, open the connected user's profile → Application Passwords → revoke
`norml-wordpress-copilot-{site}`. To reconnect, rerun `connect.html` and the import
helper. Revocation does not change the user's normal WordPress password.
