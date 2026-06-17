# norml-wp-manager — onboarding (Claude desktop app / Cowork)

> Dual-purpose: a human can read this top to bottom; Claude follows it step by
> step as the desktop first-run runbook. The matching terminal runbook is
> `onboarding-console.md`; the 2-link chooser is `onboarding.md`.

You're running in the **Claude desktop app** (or **Cowork**). Your code runs in a
cloud sandbox, so two things are true here that aren't true in Claude Code on your
own machine:

1. **No OS Keychain.** The sandbox can't reach your system secret store, so the
   Application Password is stored as a protected file inside your site folder
   (the **floor tier**), not in macOS Keychain / Windows Credential Manager.
2. **Outbound network is locked down.** The sandbox can only reach an allowlist of
   domains — package registries + GitHub + Anthropic by default. **Your WordPress
   site is not on it.** This is the one thing that has to be fixed before anything
   else works, so the runbook does it **first**, before asking for any credential.

> **The mental model.** Everything Claude learns about your site lives in **one
> folder you name** — say `acme-marketing/`. Inside it: a couple of readable files
> that are yours to edit, and a hidden `.wpm/` folder that's the tool's machinery.
> Move it, zip it, or delete it and the skill simply forgets that site — nothing
> else on your computer is touched. Your password lives inside that folder too, so
> it travels with it. Files written into this folder persist to your real disk
> across sessions (the desktop app maps it in at its real path).

> **Why the order matters (the one rule that fixes the old failure).** Every action
> this skill takes is an HTTPS call to your site. In the old flow the skill asked
> for the password first, wrote it to disk, and only *then* hit the network wall —
> so the password was leaked into chat for nothing and had to be revoked. This
> runbook proves the sandbox can reach your site **before** it ever asks for a
> credential. No password until the path is open.

---

## What the runbook produces

One **site folder** you name (default: your site's slug, e.g. `acme-marketing/`),
created inside your Claude project folder so it persists to disk:

```
acme-marketing/
├── README.md            ← 4 plain lines: what this is, how to move/delete it
├── project-notes.md     ← your durable notes + gotchas (you and Claude edit this)
├── changelog.md         ← append-only log of every change + decision
└── .wpm/                ← the machinery (hidden; don't hand-edit)
    ├── config.json      ← connection info — NO password
    ├── credential       ← your Application Password, locked to you, never committed
    ├── .gitignore       ← one line: credential
    └── docs/            ← auto-generated site scan: 00-connection … 04-rest-capabilities
```

The readable files at the top are yours. The `.wpm/` folder is the tool's — leave
it alone. **Delete the whole site folder and the skill forgets this site.**

---

## Step 1 — Open the network path to your site  ← do this FIRST

**Claude collects only your production URL here — not a password.** Then it runs an
**anonymous** reachability probe (no credentials involved):

```bash
# anonymous — answers only "can the sandbox reach your site at all?"
curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "https://YOURSITE.com/wp-json"
```

| Probe result | What it means | What happens next |
|---|---|---|
| `200` (and the body looks like REST JSON) | The path is open, REST is alive. | **Gate passed.** Go to Step 2. |
| Blocked / `000` / proxy `403` / "blocked by your network egress settings" | The domain isn't allowlisted yet — a **sandbox** setting, **not** a WordPress problem. | **Stop.** Add the domain (below), then tell Claude — it re-probes and continues once it sees `200`. |
| `200` but the body is an HTML page, not JSON | Wrong URL, or a security plugin disabled REST. | Verify the URL; check Wordfence / "Disable REST API". Re-probe. Not an allowlist issue. |

### Add your site to the allowlist (one time)

```
Your WordPress domain isn't on the sandbox's outbound allowlist yet — that's why
the probe was blocked. One-time setting, NOT a WordPress problem.

  1. Settings → Capabilities → "Allow network egress".
  2. Leave the "Domain allowlist" dropdown on "Package managers only".
  3. In "Additional allowed domains", add  yoursite.com
     (or  *.yoursite.com  to include staging) → Add.
  4. Do NOT switch the dropdown to "All domains" — narrow-adding your own host is
     safer and sufficient.

Tell me when it's added and I'll re-check.
```

> **On a Team or Enterprise plan?** This list is often **admin-locked** — only a
> workspace admin can edit it. If you can't add the domain, either ask your admin
> to add it, **or run this skill from Claude Code on your own Mac** instead. Claude
> Code has no allowlist *and* stores your password in the OS keychain — the more
> secure setup. (See `onboarding-console.md`.)

Claude re-runs the probe each time you say you've added the domain, and only moves
on once it returns `200`. **No Application Password is requested until this passes.**

---

## Step 2 — Give Claude your site basics

Now that the path is open, Claude asks, in chat:

| Field | Example | Notes |
|---|---|---|
| Site name | `acme-marketing` | Short, lowercase, dashes. Names the folder + the password's label. Validated `^[a-z0-9]+(-[a-z0-9]+)*$`. |
| Production URL | `https://acme.com` | Must be **https**. No trailing slash. The host you just allowlisted. |
| WordPress username | `acme-editor` | Your **login slug** — not display name, not email. Check at `{site}/wp-admin/profile.php`. |
| Site folder | `acme-marketing` (in your project folder) | Where this site's folder is created. Defaults to your site slug inside the current Claude project folder. |

**Folder safety checks Claude runs before creating anything** — it will re-prompt
for a different folder if any apply:

- The folder would land **inside the skill's own directory** (skill updates wipe
  it) — refused.
- The folder is a system root (`$HOME`, `/`, `/tmp`, `/etc`) or `~/.claude` — refused.
- The folder is inside a **cloud-sync tree** (Dropbox, iCloud, OneDrive, Google
  Drive, `Library/CloudStorage`) — **warned loudly**: your password file could be
  uploaded to a third-party cloud and shared with anyone you share the folder with.
  `.gitignore` does nothing against cloud sync. Pick a non-synced folder, or
  explicitly accept the risk and rotate the password weekly.

> **Editor, not administrator.** For day-to-day content work, generate an
> **editor-role** Application Password. A leaked editor password can't install
> plugins, edit users, or escalate — which caps the damage far more than anything
> else here. Use an admin password only if you specifically need plugin/theme/
> settings access (and know that the site scan needs admin to read the full
> plugin/theme list — without it, those parts of the scan say "not visible at this
> role," which is fine).

---

## Step 3 — Generate the Application Password (one click)

Claude hands you the built-in WordPress **authorize** link (ships with WordPress,
no extra setup, no Norml infrastructure):

```
https://yoursite.com/wp-admin/authorize-application.php?app_name=norml-wp-manager-{site-name}
```

Click it → log into WordPress if prompted → you'll see **"Authorize
norml-wp-manager-{site}?"** → click **Yes, authorize** → WordPress shows a
24-character password **once**. Copy it.

> Prefer the manual route? `{site}/wp-admin/profile.php` → *Application Passwords* →
> name it `norml-wp-manager-{site-name}` → *Add New Application Password* → copy.

> The Application Password is **not** your WordPress login password — it's a
> separate token you can revoke any time without changing your login.

---

## Step 4 — Paste it once, and Claude finishes up

> **Before you paste — what this costs, plainly:** Pasting the password here means it
> is saved in this conversation's history (on Claude's servers) for as long as the
> conversation is retained. That's why we (a) recommend an **editor-role** password
> and (b) recommend you **revoke + regenerate** it at the end of your session — it
> costs nothing and closes the exposure. Claude will offer to walk you through the
> revoke when you're done.

Paste the 24-character password into chat. Claude then, without you doing anything
further:

1. Creates the site folder + `.wpm/`, and writes the password to
   `{site_folder}/.wpm/credential` — created **already locked to you** (born with
   owner-only permissions; not created world-readable and fixed afterward).
2. Writes `{site_folder}/.wpm/.gitignore` containing the single line `credential`,
   right next to the secret.
3. **Verifies the secret is actually git-ignored.** If git is present and
   `git check-ignore` does *not* confirm the file is excluded, Claude **backs the
   credential out** and warns you — it will not leave a committable password on
   disk.
4. **On Windows in the sandbox**, locks the file's ACL to your account. (If the
   underlying filesystem can't honor per-user permissions, Claude tells you so
   plainly — "treat this folder as readable by anyone with an account on this PC,
   rotate weekly" — rather than falsely claiming it's owner-only.)
5. Drops its in-memory copy of the password. From here on it's read from the file
   at call time and **never** placed on a command line (so it can't leak into
   process listings or the transcript).
6. Writes `{site_folder}/.wpm/config.json` — connection info, **no secret**.
7. Runs the authenticated check `GET /wp-json/wp/v2/users/me` — now guaranteed to
   reach WordPress — and confirms your id + roles.
8. Runs the read-only **site scan** and writes `.wpm/docs/00-connection.md` …
   `04-rest-capabilities.md`, plus scaffolds `README.md`, `project-notes.md`, and
   `changelog.md` at the top of the folder.
9. Reports what it created and where, then emits the security flags below.

If setup is interrupted before the auth check passes, Claude removes the empty
`.wpm/` scaffold — no half-written password or stray folders left behind.

That's the whole flow: **open the path → paste the key once → wait → ready.**

---

## After setup — the security flags Claude raises

At the end of setup Claude explicitly tells you:

1. **Your password is in plaintext on disk** (the floor tier) — locked to your
   user and git-ignored, but only as safe as the folder it's in. Rotate on the
   cadence below.
2. **If your site has a lot of administrators** ("N admins is a lot for one
   site — consider trimming").
3. **If a third-party admin-level agent is installed** (ManageWP-Worker, Jetpack,
   iThemes Sync, etc.) — anything with standing admin access to your site, surfaced
   from the scan.

---

## Security — because the password is on disk here

The sandbox has no OS keychain, so the floor tier is **honest plaintext**: a file
locked to your user and excluded from git. We don't pretend to encrypt it — any key
the skill could auto-decrypt with would have to sit on the same disk as the file it
protects, which protects nothing. The real protection is keeping the password's
**power** and **lifetime** small:

- **Use an editor-role password, not administrator** (unless you truly need admin).
  This is the single biggest risk reducer.
- **The password was in chat once** (Step 4). The safest close-out is to **revoke +
  regenerate** it at the end of your session — Claude will offer to walk you
  through it. It costs nothing. **Treat this as the default way to end a desktop
  session**, not an optional extra.
- **Rotate the on-disk password regularly.** A simple, consistent rule: *editor
  role + revoke at the end of a desktop session + rotate monthly if you keep it
  standing.* In wp-admin, revoke `norml-wp-manager-{site-name}`, generate a new one,
  tell Claude "I rotated the password," and re-paste.
- **Keep the folder out of cloud sync** (Step 2). Git-ignore protects against
  commits; it does nothing against Dropbox/iCloud/Drive uploading the file.
- **Want the most secure setup instead?** Run from **Claude Code** on your own Mac —
  the password goes into the macOS Keychain and never touches chat or disk. See
  `onboarding-console.md`.

---

## Moving, deleting, or forgetting a site

- **Move / rename:** `mv acme-marketing ~/somewhere-else` — the password rides along
  inside the folder and everything keeps working. Nothing points back out of the
  folder, so nothing goes stale.
- **Forget this site:** delete the folder (`rm -rf acme-marketing`). That removes
  100% of the on-disk state — there's no system-directory copy and nothing in the
  skill folder. Then **revoke the Application Password in wp-admin** (the one piece of
  state that lives on the WordPress site, not on your disk).

---

## Re-scanning later

When something changes on your site, ask Claude to refresh the scan — it re-checks
reachability first, then rewrites only the affected docs and notes what changed.
Your `project-notes.md` and `changelog.md` are **never** overwritten by a rescan.

| You say | What refreshes |
|---|---|
| "rescan my site" / "refresh architecture" | everything (`00`–`04`) |
| "recheck connection" / "is my site reachable" | `00` |
| "redo content model" / "I added a custom post type" | `00`, `02` |
| "rescan plugins" / "re-check the theme" | `00`, `03` |
| "recheck what I can edit over REST" | `00`, `04` |

---

## Troubleshooting

The big one in the sandbox: a `403` (or a refused/timed-out call) is **two
different failures** with two different fixes. Tell them apart by **whether the
anonymous `/wp-json` probe still passes**.

| Symptom | Cause | Fix |
|---|---|---|
| "blocked by your network egress settings" / probe returns proxy `403` / `000` / the anonymous `/wp-json` probe itself fails | **Egress allowlist** — the sandbox can't reach your domain. **Not** WordPress. | Step 1 — add the domain in Settings → Capabilities, then re-probe. **Quick test:** re-run the anonymous probe; if it *also* fails, it's egress. |
| `403` on a specific endpoint **after** the anonymous probe returns `200`, with a real WP JSON body (`rest_cannot_edit`, `rest_forbidden`) | **WordPress capability** — your WP user's role is too low for that endpoint (e.g. an editor writing `/wp/v2/settings`). | Use an editor/admin account for that action. This is the *only* case where "your role is too low" is the right diagnosis. |
| `401 Unauthorized` on the auth check | Wrong username, or revoked/mistyped password | Username must be the **login slug** (check `{site}/wp-admin/profile.php`); regenerate the AP and re-paste. |
| `rest_no_route` / `404` on a known endpoint, with real WP JSON | Feature not REST-exposed — a CPT registered without `show_in_rest`, or a security plugin disabled REST | Network's fine. A developer flips `show_in_rest`; or check Wordfence / "Disable REST API" plugins. Claude also notes this in the scan and won't fire doomed writes at it. |
| No "Application Passwords" section in wp-admin | WP older than 5.6, or disabled by a plugin | Upgrade WordPress, or install the *Application Passwords* plugin. |
| Can't edit the allowlist | Team/Enterprise plan, admin-locked | Ask your workspace admin to add the domain, or use **Claude Code** on your Mac (no allowlist there). |

> **Why this matters:** the old version mis-read a sandbox egress `403` as "your WP
> user lacks capability" and sent people chasing WordPress roles. The split above is
> the fix — if the anonymous probe is blocked, it's the allowlist; if the probe
> passes but an authenticated call `403`s, it's a real WordPress permission.
