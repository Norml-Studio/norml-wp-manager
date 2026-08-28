# Install norml-wp-manager

One-time setup. Takes about 10 minutes including generating the WordPress
Application Password.

## Prerequisites

- **macOS** 12+ or **Windows** 10+ (or the Claude desktop app / Cowork — see below)
- **Claude Code** (recommended) **or the Claude desktop app / Cowork**
  → If you don't have Claude Code yet: https://claude.com/claude-code
- A **WordPress 5.6+** site (Application Passwords are built into core
  starting at 5.6)
- A **WordPress admin or editor account** on that site
- Ability to log in to wp-admin and create an Application Password
- **`python3`** on your PATH — **required.** The site scan parses every REST
  response in Python (no pip packages, just the interpreter). macOS and most Linux
  ship it; on Windows the PowerShell scan path doesn't need it.
- **`jq`** — optional. Used to read the small `config.json` when present; the scripts
  fall back to `python3` if `jq` isn't installed.

> **No SSH, no WP-CLI, no developer tooling required.** This skill talks
> to WordPress only through its built-in REST API.

### Which Claude can run this?

There are two environments. The skill detects which one it's in and runs the
matching setup runbook.

| Environment | What it is | How the password is stored |
|---|---|---|
| **Console** — Claude Code on macOS / Windows / Linux | A real terminal on your own machine. Most secure. | OS secret store — macOS Keychain, Windows Credential Manager, or Linux libsecret. Claude never sees it. (Headless Linux with no keyring falls back to the floor file below.) |
| **Desktop** — the Claude desktop app / Cowork | A cloud sandbox with access to your project folder. | A protected, git-ignored file (`credential`) inside your site folder — the **floor tier**. Less secure than a keychain; use an editor-role password and rotate it. |
| claude.ai (web / mobile) | No filesystem access. | **Doesn't work** — use Claude Code or the desktop app instead. |

#### Everything for a site lives in one folder

There is no system-wide config directory. Each site you manage gets **one folder you
name** (e.g. `acme-marketing/`):

```
acme-marketing/
├── README.md            ← 4 plain lines: what this is, how to move/delete it
├── project-notes.md     ← your durable notes + gotchas (yours to edit; survives rescans)
├── changelog.md         ← append-only log of every change + decision
└── .wpm/                ← the machinery (hidden; don't hand-edit)
    ├── config.json      ← connection info — NO password
    ├── credential       ← (floor tier only) the Application Password, locked to you, git-ignored
    ├── .gitignore       ← (floor tier only) one line: credential
    └── docs/            ← auto-generated read-only site scan (00-connection … 04-rest-capabilities)
```

Move it, zip it, rename it, or delete it — nothing points outside the folder, so it's
fully portable, and deleting it makes the skill forget that site entirely.

## Step 1 — Get the skill onto your machine (Console only)

> **On the Claude desktop app / Cowork?** Skip this step. The desktop app
> auto-mounts the skill into your session at its own host project path — it does
> **not** live at `~/.claude/skills/`, and you don't copy anything. Go straight to
> Step 5 (and read the allowlist callout there first).

Install the skill directly from its public GitHub repository:

```bash
npx skills@latest add Norml-Studio/norml-wp-manager --skill=norml-wp-manager -g -a claude-code
```

This uses the open Skills CLI to install `norml-wp-manager` globally for Claude Code.
Drop `-g` only if you want it limited to the current project.

## Step 2 — Manual ZIP fallback (Console only)

Skip this step when the command above succeeds. If you received the standalone ZIP,
unzip it anywhere convenient, then copy the skill into
`~/.claude/skills/norml-wp-manager/`.

### macOS

Open `Terminal.app` and run:

```bash
mkdir -p ~/.claude/skills
cp -R "/path/to/extracted/norml-wp-manager/.claude/skills/norml-wp-manager" ~/.claude/skills/
```

Replace `/path/to/extracted/norml-wp-manager` with the real path. If you
extracted to your Desktop, that's `~/Desktop/norml-wp-manager`.

### Windows

Open `Windows Terminal` or `PowerShell` and run:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\skills" | Out-Null
Copy-Item -Recurse -Force "C:\path\to\extracted\norml-wp-manager\.claude\skills\norml-wp-manager" "$env:USERPROFILE\.claude\skills\"
```

Replace `C:\path\to\extracted\norml-wp-manager` with the real path.

## Step 3 — Make manually copied scripts executable (macOS only)

The Skills CLI preserves the repository's executable permissions. Run this only when
you used the manual ZIP fallback:

```bash
chmod +x ~/.claude/skills/norml-wp-manager/scripts/*.sh
```

Windows skips this step.

## Step 4 — Verify Claude sees the skill

Open Claude Code (in any folder). In the chat, type:

> "List my available skills"

You should see `norml-wp-manager` in the response. If not, restart Claude Code
and try again. (In the desktop app the skill is mounted automatically — if it
doesn't appear, confirm the skill is attached to your project.)

## Step 5 — Run first-time setup (the easy way)

In Claude, say:

> *"Set up my WordPress access."*

Claude detects your environment and walks you through onboarding **in chat**. The two
runbooks differ in one important way, so read the one that matches you:

- **Console** (Claude Code): the full step-by-step is
  `~/.claude/skills/norml-wp-manager/onboarding-console.md`. A native OS dialog
  captures your Application Password straight into the OS secret store — you never
  type it into the terminal.

- **Desktop** (the Claude desktop app / Cowork): the full step-by-step is
  `onboarding-desktop.md`.

> ### Desktop / Cowork: add your site domain to the allowlist FIRST
>
> The desktop sandbox can only reach an allowlist of domains (package registries +
> GitHub + Anthropic by default). **Your WordPress site is not on it**, and the skill
> will refuse to ask for a password until it can actually reach your site. Do this
> **before** the credential step:
>
> 1. **Settings → Capabilities → "Allow network egress."**
> 2. Leave the "Domain allowlist" dropdown on **"Package managers only."**
> 3. In **"Additional allowed domains,"** add `yoursite.com` (or `*.yoursite.com` to
>    include staging) → **Add.**
> 4. Don't switch the dropdown to "All domains" — narrow-adding your own host is
>    safer and sufficient.
>
> Then tell Claude it's added; it re-checks reachability and continues. On a Team or
> Enterprise plan this list may be admin-locked — ask your workspace admin, or use
> Claude Code instead (no allowlist there).

Either way, Claude finishes by testing the REST API and scaffolding your site folder
(`README.md` + `project-notes.md` + `changelog.md` at the top, and the auto-generated
scan in `.wpm/docs/`).

### Manual fallback (Console)

If you'd rather run setup outside of Claude (headless SSH session, or you just prefer
terminal scripts):

**macOS:**
```bash
bash ~/.claude/skills/norml-wp-manager/scripts/setup-macos.sh
```

**Windows:**
```powershell
& "$env:USERPROFILE\.claude\skills\norml-wp-manager\scripts\setup-windows.ps1"
```

If Windows refuses with an execution-policy error, run this once first:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Both scripts use the same OS dialog for the password capture — the manual flow
doesn't ask you to type the secret into the terminal either. On headless Linux / WSL
with no keyring, use `scripts/setup-portable.sh`, which writes the floor-tier
`credential` file instead.

## Step 6 — Use it

Once setup finishes, ask Claude things like:

- *"What plugins are installed on my site?"*
- *"List my custom post types."*
- *"Show me my last 10 published posts."*
- *"What's the ACF field group on my homepage?"*
- *"Update the post with ID 42 — change the title to 'New Headline'."*
- *"Set the featured image on the About page."*

Claude routes everything through the WordPress REST API. Destructive operations
always ask for confirmation first.

## Troubleshooting

| Problem | Fix |
|---|---|
| Claude can't see the skill | **Console:** restart Claude Code; confirm `norml-wp-manager` is at `~/.claude/skills/norml-wp-manager/` (macOS) or `%USERPROFILE%\.claude\skills\norml-wp-manager\` (Windows). **Desktop:** confirm the skill is attached to your project. |
| Desktop: the probe / a call is "blocked by your network egress settings" (or `000`) | Your site domain isn't allowlisted. Settings → Capabilities → add `yoursite.com` (see Step 5), then re-check. This is a sandbox setting, **not** a WordPress problem. |
| `401 Unauthorized` during setup | The username or Application Password is wrong. Re-run setup; double-check the username at `https://yoursite.com/wp-admin/profile.php` (Username field). |
| `403 Forbidden` on an endpoint **after** the site is reachable | Your WP role is too low for that endpoint — use an editor or admin account (admin is needed for plugin/theme/settings reads). |
| `No Application Passwords` section in wp-admin | WordPress is older than 5.6 (upgrade) or a security plugin has disabled the feature. |
| Setup script won't run on Windows | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` in PowerShell first. |
| `Connection refused` / DNS error | **Console:** the URL is wrong or the site is down — open it in a browser. **Desktop:** almost always the allowlist (see above). |
| Claude says the secret-store entry is missing (Console) | The macOS Keychain or Windows Credential Manager entry got deleted. Re-run setup — it re-creates it. |
| `neither jq nor python3 found` during a scan | Install `python3` (the scan requires it). `jq` is optional. |

If you get stuck, contact whoever sent you this package.

## Updating later

When a new version of the skill is sent to you:

1. **Console:** re-extract the package and re-run Step 2 (the copy command) — it
   overwrites the old skill folder. **Desktop:** the mounted skill updates with your
   project; there's nothing to copy.
2. **Your site folders are never touched by a skill update** — they live wherever you
   put them, not inside the skill folder. Your connection config, your Application
   Password, and your `project-notes.md` / `changelog.md` all stay put.
3. To refresh the site scan against the current version of WordPress, say
   *"rescan my site."*

## What's NOT installed

For full transparency, here's everything the skill puts on your machine:

- **Console only:** the skill folder at `~/.claude/skills/norml-wp-manager/` (read by
  Claude Code). On the desktop app the skill is mounted into the session at a host
  project path — nothing is copied to `~/.claude/skills/`.
- **One site folder per site, wherever you choose** — containing readable
  `project-notes.md` + `changelog.md`, plus a hidden `.wpm/` with the connection
  `config.json` (no secrets), the auto-generated scan in `.wpm/docs/`, and — only on
  the floor tier — a git-ignored `credential` file.
- **Console (OS-store path) only:** one entry in macOS Keychain / Windows Credential
  Manager / Linux libsecret named `norml-wp-manager-{site-name}` holding your
  Application Password.

There is **no** system-wide config directory — nothing is written to a system
configuration folder or anywhere outside the site folder you name. It does **not**
install any system
services, daemons, PowerShell modules, pip packages, or Node packages (it uses the
`python3` already on your machine to parse scan output). It does **not** touch SSH
config or SSH keys. It does **not** modify your WordPress install other than the
Application Password you create during onboarding (which you can revoke from wp-admin
at any time).
