# norml-wp-manager — onboarding (Claude Code / terminal)

> Dual-purpose: a human can read this top to bottom; Claude follows it step by
> step as the terminal first-run runbook. The matching desktop-app runbook is
> `onboarding-desktop.md`; the 2-link chooser is `onboarding.md`.

You're running **Claude Code** in a terminal on your own machine. This is the most
secure setup (**Console mode**):

- Your Application Password goes into the **OS secret store** — macOS Keychain,
  Windows Credential Manager, or Linux libsecret — captured by a native OS dialog.
  It never lands in a file, and **Claude never sees it**.
- The network is your machine's network — **no allowlist to configure** (that's a
  desktop-app thing only). No reachability gate needed here.
- **Everything Claude knows about your site lives in one folder you name** — a
  *site folder* (e.g. `acme-marketing/`) with two readable files at the top and the
  tool's machinery hidden in `.wpm/`. Nothing scattered into system directories.
  Move the folder, zip it, or delete it — the skill follows.

> The easiest path is just to say **"set up my WordPress access"** and let Claude
> drive. This file is what it follows, and what to read if you'd rather do it by
> hand.

---

## What you end up with — one site folder

Claude creates **one folder per site**, named after the site (default = the
kebab-case slug you give it). Open it and you see:

```
acme-marketing/                  ← THE unit. You named it. Visible, portable, safe to move/zip/delete.
├── README.md                    ← 4 plain lines: what this is, how to move/delete it
├── project-notes.md             ← your durable notes + gotchas. Hand-edit freely. Survives rescans.
├── changelog.md                 ← append-only log of every change + decision + scan
└── .wpm/                        ← the machinery (hidden). You don't hand-edit this.
    ├── config.json              ← connection info. NO password. chmod 600.
    ├── .gitignore               ← (Linux-no-keychain fallback only) one line: credential
    ├── credential               ← (fallback only) the raw password, born owner-read-only
    └── docs/                     ← auto-generated site scan Claude reads before it acts
        ├── 00-connection.md     ← env, who you're connected as + roles, last scan time
        ├── 01-site.md           ← WP version (best-effort), settings, REST namespaces
        ├── 02-content-model.md  ← post types (+ which are REST-visible), taxonomies, counts
        ├── 03-plugins-theme.md  ← active theme, plugin inventory, detected key plugins
        └── 04-rest-capabilities.md  ← what you can actually read/edit over REST
```

On macOS / Windows / Linux-with-a-working-keyring, the password is in the **OS
secret store**, so the `credential` file and its `.gitignore` **don't exist** — the
keychain holds the secret instead. The `credential` file only appears on the
honest fallback path (Linux/WSL with no keyring — see Step 3).

**Where the folder goes:** wherever you point it — the current directory, or an
absolute path you type (`~/Sites/acme-marketing`). Claude refuses a few unsafe
spots and warns about one (see "Folder safety" below).

---

## Step 1 — Give Claude your site basics

Claude asks, one at a time, in chat:

| Field | Example | Notes |
|---|---|---|
| Site name | `acme-marketing` | Short, lowercase, dashes. Names the folder + the keychain entry. |
| Production URL | `https://acme.com` | **Must be `https://`.** No trailing slash. (`http://localhost` allowed for local dev only.) |
| WordPress username | `acme-editor` | Your **login slug** — not display name, not email. Check at `{site}/wp-admin/profile.php`. |
| Site folder | `~/Sites/acme-marketing` | Where this site's folder lives. Created if missing. Defaults to the site slug in the current directory. |

Claude then writes `{site-folder}/.wpm/config.json` (chmod 600), which records the
URL, your username, the detected environment, and a **pointer** to where the
password is stored (the keychain entry name). **No secret in the file** — ever.

> **Folder safety.** Before creating the folder, Claude refuses it and re-prompts if
> it would land **inside the skill's own folder** (that gets wiped on every skill
> update), or if it's a system root like `$HOME`, `/`, `/tmp`, or `~/.claude`. It
> also **warns loudly** if the folder is inside a cloud-sync tree (Dropbox, iCloud,
> Google Drive, OneDrive) — on the fallback path your password file would get
> uploaded there. Pick a non-synced folder, or accept the risk and rotate weekly.

---

## Step 2 — Generate the Application Password

The fast way is the one-click authorize link Claude hands you — it ships with
WordPress itself, no extra setup:

```
https://yoursite.com/wp-admin/authorize-application.php?app_name=norml-wp-manager-{site-name}
```

Click → log in if prompted → **Yes, authorize** → WordPress shows a 24-character
password **once**.

> Manual route (for WP builds that hide the authorize screen):
> `{site}/wp-admin/profile.php` → *Application Passwords* → name it
> `norml-wp-manager-{site-name}` → *Add New Application Password*.

> **Use an editor-role account by default.** Editor covers all the content work this
> skill does (posts, pages, ACF fields, SEO meta, media). Only use an admin account
> if you specifically need to touch plugins, themes, or site settings — a leaked
> editor password can't install plugins or change users.

> The Application Password is **not** your WordPress login password. Revoke it any
> time without affecting your login.

---

## Step 3 — A native OS dialog captures it (you never type it in the terminal)

Claude runs a small helper that **pops a native OS dialog**, then stores the
password directly in your OS secret store. **Claude only sees the dialog's exit
code — never the password value.** Spaces in the displayed password don't matter;
the helper strips them.

| Platform | Where it goes | Captured by |
|---|---|---|
| **macOS** | Keychain | An AppleScript window titled `norml-wp-manager — {site}`. Paste, click **Store**. (Stored over stdin, not on the command line.) |
| **Windows** | Credential Manager | The standard Windows credential dialog (username pre-filled). Paste, **OK**. |
| **Linux** | libsecret / GNOME Keyring | `secret-tool`, **only if a working keyring is detected** (Claude runs a quick store→lookup→delete round-trip first). |

The keychain entry is named `norml-wp-manager-{site-name}`. At call time Claude
looks the password up inline and pipes it straight to `curl` — it never appears in
a command line, in your shell history, or in the chat transcript.

> **Headless Linux / WSL / SSH session with no keyring?** There's no OS vault to use,
> so Claude falls back to the **honest floor**: it writes the password to
> `{site-folder}/.wpm/credential` as a raw string, **born owner-read-only**
> (`umask 077`, equivalent to `chmod 600`), and adds a `.gitignore` next to it. It
> then runs an **assertive gitignore check** — `git check-ignore` must confirm the
> file is excluded; if it isn't, Claude **backs the password out** rather than risk
> committing it. On this path: use an **editor-role** password and **rotate it
> monthly** (the file is plaintext, protected only by file permissions + git
> exclusion — there's no honest way to encrypt it at rest). The same fallback applies
> on Windows without Credential Manager, where Claude locks the file's ACL via
> `icacls` instead of `chmod`.

> Prefer to run it yourself? Use the self-contained script:
> `bash ~/.claude/skills/norml-wp-manager/scripts/setup-macos.sh` (macOS) /
> `scripts/setup-windows.ps1` (Windows) / `scripts/setup-portable.sh` (Linux
> fallback). Same dialog, same result.

---

## Step 4 — Test, scan, done

Claude automatically:

1. Calls `GET /wp-json/wp/v2/users/me` over HTTPS to confirm the credentials work
   (shows your id, name, and **roles**).
2. Creates the site folder's `README.md`, `project-notes.md`, and `changelog.md`.
3. Runs the read-only **architecture scan** (GET/HEAD/OPTIONS only) and writes the
   five numbered docs into `.wpm/docs/` — connection + identity, site basics,
   content model, plugins/theme, and the REST capability map.
4. Reports what it created and where, plus any **security flags** (below).

After this, just ask in plain English — *"list my plugins,"* *"show my last 10
posts,"* *"update post 42's title."* Before any edit, Claude reads
`04-rest-capabilities.md` and `02-content-model.md` first, so it won't fire a doomed
request at something REST can't touch — it'll tell you to edit that in wp-admin (or
have a developer flip `show_in_rest`) instead.

> **Editor vs admin, honestly:** an editor password fully populates connection,
> content model, and most of the capability map. **Site settings (`01`) and the
> plugin/theme inventory (`03`) need admin** — without it those docs simply note
> "not visible at this role." Nothing breaks; you just see less.

---

## After setup — security flags Claude will surface

At the end of setup Claude explicitly calls out, when they apply:

- **(fallback path only)** the password is plaintext on disk — rotate monthly.
- **too many administrators** — "N admin accounts is a lot for one site; consider
  trimming" (counted during the scan).
- **third-party admin-level agents** — plugins like ManageWP-Worker, Jetpack, or
  iThemes Sync that also hold broad access (cross-referenced from the plugin scan).

---

## What gets written to disk

| Path | Holds | Secret? |
|---|---|---|
| `{site-folder}/.wpm/config.json` | URL, username, environment, keychain pointer | No |
| OS secret store `norml-wp-manager-{site}` | The Application Password | **Yes — OS-managed**, looked up at runtime |
| `{site-folder}/.wpm/credential` *(fallback only)* | The Application Password, raw | **Yes — plaintext, chmod 600 + gitignored** |
| `{site-folder}/.wpm/docs/00–04` | Auto site scan (rescannable, do-not-hand-edit) | No |
| `{site-folder}/project-notes.md` | Durable workflows + gotchas (yours to edit) | No |
| `{site-folder}/changelog.md` | Every write + decision + scan | No |

**Nothing is written to a system config directory and nothing per-site lands in the
skill folder** (`~/.claude/skills/...`) — that gets overwritten on every skill
update. Everything for a site lives in the one site folder you named.

---

## Rescan later

When the site changes, ask Claude to refresh — it rewrites only the affected docs
and never touches your `project-notes.md` / `changelog.md`:

| You say | Rewrites |
|---|---|
| "rescan my site" / "refresh architecture" | all of `00–04` |
| "recheck connection" | `00` |
| "I added a custom post type" / "redo content model" | `02` |
| "rescan plugins" / "re-check the theme" | `03` |
| "recheck what I can edit over REST" | `04` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Claude can't see the skill | Not in the skills folder | Confirm `~/.claude/skills/norml-wp-manager/` exists; restart Claude Code. |
| `401 Unauthorized` on the test | Wrong username or password | Username = login slug (check `profile.php`); regenerate the AP and re-run the password step. |
| `403 Forbidden` on an endpoint | **WP role too low** (in Console, network is always open, so a 403 is *always* a capability problem — never an allowlist one) | Use an editor/admin account; admin needed for plugins/themes/settings. |
| `Could not find keychain entry` | Entry deleted, or name mismatch | Re-run setup — it recreates the entry. |
| `rest_no_route` / `404` | Feature not REST-exposed | A developer flips `show_in_rest`, or a security plugin (Wordfence, "Disable REST API") re-enabled. |
| No "Application Passwords" in wp-admin | WP < 5.6 or disabled by a plugin | Upgrade WP, or install the *Application Passwords* plugin. |
| Production URL rejected at setup | It's `http://` | The skill requires `https://` for any password-bearing call (except explicit `localhost`). Use the https URL. |

---

## Moving, rotating, and deleting

**Move the folder:** `mv acme-marketing ~/somewhere-else` just works on the fallback
path — the password rides along and all internal paths are relative. On the OS-store
path the folder moves fine too; if you move it to a **different machine**, Claude
runs a quick 3-line *re-attach* on next run (reuses your config, re-stores the
password in the new machine's keychain).

**Rotate / revoke:**
1. wp-admin → Profile → *Application Passwords* → **X** next to `norml-wp-manager-{site}`.
   It dies immediately.
2. Remove the local copy:
   `security delete-generic-password -s "norml-wp-manager-{site}"` (macOS) /
   `cmdkey /delete:norml-wp-manager-{site}` (Windows). On the fallback path, just delete
   `.wpm/credential`.
3. Generate a fresh AP and re-run the password step.

**Forget this site entirely:** `rm -rf acme-marketing` removes 100% of on-disk state
(no system-config orphans, nothing in the skill folder). On the OS-store path, also
run the `delete-generic-password` / `cmdkey /delete` above so no orphan vault entry
is left. Either way, **revoke the AP in wp-admin** — that's the only state that lives
off your machine.

---

> **On a sandboxed setup instead?** If you're in the Claude **desktop app** or
> **Cowork**, there's no OS keychain and the network is behind an allowlist you must
> open first — follow `onboarding-desktop.md`, not this file.
